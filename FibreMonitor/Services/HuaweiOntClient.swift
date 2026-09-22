import Foundation

/// Talks to a Huawei OptiXstar ONT (tested against the HG8145X6-10 web UI).
///
/// Login mirrors the web page: fetch a token from `/asp/GetRandCount.asp`, then post
/// the base64 password to `/login.cgi`. The session lives in a cookie. When it
/// expires the router serves its login page instead of data; the client then logs in
/// again once. A rejected login is never retried automatically, because the router
/// locks logins after a few wrong passwords.
public actor HuaweiOntClient {
    public struct Credentials: Equatable, Sendable {
        public var host: String
        public var username: String
        public var password: String
        public init(host: String, username: String, password: String) {
            self.host = host; self.username = username; self.password = password
        }
    }

    private let transport: OntTransport
    private var credentials: Credentials
    private var loggedIn = false
    /// Set after a rejected login; cleared only when the credentials change.
    private var loginBlocked = false

    private var lastCounters: (rx: UInt64, tx: UInt64, time: Date)?
    private var traffic = TrafficState()
    private let maxHistory = 60

    public init(credentials: Credentials, transport: OntTransport = URLSessionOntTransport()) {
        self.credentials = credentials
        self.transport = transport
    }

    public func update(credentials new: Credentials) {
        guard new != credentials else { return }
        credentials = new
        loggedIn = false
        loginBlocked = false
        lastCounters = nil
        traffic = TrafficState()
    }

    public var isLoginBlocked: Bool { loginBlocked }

    // MARK: Session

    public func login() async throws {
        guard !credentials.password.isEmpty else { throw OntError.notConfigured }
        guard !loginBlocked else { throw OntError.loginRejected }
        await transport.resetSession(host: credentials.host)
        let token = HuaweiJs.clean(try await transport.send(.init(.post, "/asp/GetRandCount.asp"), host: credentials.host))
        guard !token.isEmpty, !token.contains("<") else { throw OntError.badResponse("login token") }

        let reply = try await transport.send(.init(.post, "/login.cgi", form: [
            ("UserName", credentials.username),
            ("PassWord", Data(credentials.password.utf8).base64EncodedString()),
            ("Language", "english"),
            ("x.X_HW_Token", token),
        ], ajax: false), host: credentials.host)

        // Success is a tiny page that redirects to index.asp; failure re-serves the login page.
        guard reply.contains("index.asp") else {
            loggedIn = false
            loginBlocked = true
            throw OntError.loginRejected
        }
        loggedIn = true
        // Load the main page once like a browser would, so the session is fully set up.
        _ = try? await transport.send(.init(.get, "/index.asp", ajax: false), host: credentials.host)
    }

    public func logout() async {
        guard loggedIn else { return }
        loggedIn = false
        if let token = try? await freshToken() {
            _ = try? await transport.send(.init(.post, "/logout.cgi?RequestFile=html/logout.html",
                                                form: [("x.X_HW_Token", token)], ajax: false),
                                          host: credentials.host)
        }
        lastCounters = nil
    }

    /// Sends a data request, logging in first if needed and once more if the session expired.
    private func fetch(_ request: OntRequest) async throws -> String {
        if !loggedIn { try await login() }
        let first = try await transport.send(request, host: credentials.host)
        if HuaweiJs.looksLikeData(first) { return first }
        loggedIn = false
        try await login()
        let second = try await transport.send(request, host: credentials.host)
        guard HuaweiJs.looksLikeData(second) else { throw OntError.sessionExpired }
        return second
    }

    private func freshToken() async throws -> String {
        let t = HuaweiJs.clean(try await transport.send(.init(.post, "/html/ssmp/common/GetRandToken.asp"), host: credentials.host))
        guard !t.isEmpty, !t.contains("<") else { throw OntError.sessionExpired }
        return t
    }

    private static func cacheBuster() -> String { String(Int(Date().timeIntervalSince1970 * 1000)) }

    // MARK: Traffic

    /// Polls the WAN byte counters and returns speeds from the change since the last poll.
    public func pollTraffic(now: Date = Date()) async throws -> TrafficState {
        let text = try await fetch(.init(.get, "/html/bbsp/common/get_wan_list_pppwanstat.asp?_=\(Self.cacheBuster())"))
        var stats = HuaweiJs.records(of: "WaninfoStats", in: text, fallbackParams: Self.statsParams)
        if stats.isEmpty {
            // IPoE (DHCP/static) WANs report through the IP variant.
            let ip = try await fetch(.init(.get, "/html/bbsp/common/get_wan_list_ipwanstat.asp?_=\(Self.cacheBuster())"))
            stats = HuaweiJs.records(of: "WaninfoStats", in: ip, fallbackParams: Self.statsParams)
        }
        guard let first = stats.first, let counters = Self.counters(from: first) else {
            throw OntError.badResponse("traffic counters")
        }
        apply(counters: counters, at: now)
        return traffic
    }

    static let statsParams = ["domain", "BytesSent", "BytesReceived", "PacketsSent", "PacketsReceived",
                              "UnicastSent", "UnicastReceived", "MulticastSent", "MulticastReceived",
                              "BroadcastSent", "BroadcastReceived", "BytesSentHigh", "BytesSentLow",
                              "BytesReceivedHigh", "BytesReceivedLow"]

    /// Uses the 64-bit high/low pair when the firmware provides it, else the plain counter.
    static func counters(from r: [String: String]) -> (rx: UInt64, tx: UInt64)? {
        func value(_ plain: String, _ high: String, _ low: String) -> UInt64? {
            if let h = UInt64(r[high] ?? ""), let l = UInt64(r[low] ?? "") { return (h << 32) | l }
            return UInt64(r[plain] ?? "")
        }
        guard let rx = value("BytesReceived", "BytesReceivedHigh", "BytesReceivedLow"),
              let tx = value("BytesSent", "BytesSentHigh", "BytesSentLow") else { return nil }
        return (rx, tx)
    }

    /// Byte delta between polls, allowing for 32-bit counter wrap. Returns nil when the
    /// counter went backwards for another reason (e.g. the PPPoE session reconnected).
    static func delta(previous: UInt64, current: UInt64) -> UInt64? {
        if current >= previous { return current - previous }
        if previous <= UInt64(UInt32.max) && previous > UInt64(UInt32.max) / 2 {
            return (UInt64(UInt32.max) + 1 - previous) + current
        }
        return nil
    }

    private func apply(counters: (rx: UInt64, tx: UInt64), at now: Date) {
        defer { lastCounters = (counters.rx, counters.tx, now) }
        guard let last = lastCounters else { return }
        let seconds = now.timeIntervalSince(last.time)
        guard seconds >= 0.3,
              let dRx = Self.delta(previous: last.rx, current: counters.rx),
              let dTx = Self.delta(previous: last.tx, current: counters.tx) else { return }
        let down = Double(dRx) * 8 / seconds / 1_000_000
        let up = Double(dTx) * 8 / seconds / 1_000_000
        // Anything above 10 Gbps is a counter glitch, not traffic.
        guard down < 10_000, up < 10_000 else { return }
        traffic.downloadMbps = down
        traffic.uploadMbps = up
        traffic.peakDownloadMbps = max(traffic.peakDownloadMbps, down)
        traffic.peakUploadMbps = max(traffic.peakUploadMbps, up)
        traffic.history.append(ThroughputSample(downloadMbps: down, uploadMbps: up, time: now))
        if traffic.history.count > maxHistory { traffic.history.removeFirst(traffic.history.count - maxHistory) }
    }

    // MARK: WAN

    public func fetchWan() async throws -> WanInfo {
        let token = try await freshTokenLoggingIn()
        let text = try await fetch(.init(.post, "/html/bbsp/common/getwanlist.asp", form: [("x.X_HW_Token", token)]))
        return Self.parseWan(text)
    }

    static func parseWan(_ text: String) -> WanInfo {
        let ppp = HuaweiJs.records(of: "WanPPP", in: text, fallbackParams: wanPppParams)
        let ip = HuaweiJs.records(of: "WanIP", in: text, fallbackParams: wanIpParams)
        let all = ppp.map { ($0, "PPPoE") } + ip.map { ($0, "IPoE") }
        // Prefer the connected internet WAN over TR-069/VoIP-only ones.
        let ranked = all.sorted { a, b in score(a.0) > score(b.0) }
        guard let best = ranked.first else { return WanInfo() }
        let (r, type) = best
        var wan = WanInfo()
        wan.name = r["Name"] ?? ""
        wan.connectionStatus = r["ConnectionStatus"] ?? r["Status"] ?? ""
        wan.connectionType = type
        wan.ipAddress = r["IPAddress"] ?? ""
        wan.gateway = r["Gateway"] ?? ""
        wan.dnsServers = (r["dnsstr"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        wan.vlanId = r["VlanId"] ?? ""
        wan.uptimeSeconds = Int(r["Uptime"] ?? "") ?? 0
        wan.lastError = r["LastConnErr"] ?? ""
        return wan
    }

    private static func score(_ r: [String: String]) -> Int {
        var s = 0
        if (r["ConnectionStatus"] ?? r["Status"]) == "Connected" { s += 4 }
        if (r["ServiceList"] ?? "").uppercased().contains("INTERNET") { s += 2 }
        if !(r["IPAddress"] ?? "").isEmpty { s += 1 }
        return s
    }

    static let wanPppParams = ["domain", "X_HW_VXLAN_Enable", "X_HW_OperateDisable", "ConnectionTrigger", "MACAddress", "Status",
                               "LastConnErr", "RemoteWanInfo", "Name", "Enable", "EnableLanDhcp", "DstIPForwardingList",
                               "ConnectionStatus", "Mode", "IPAddress", "Gateway", "NATEnable", "X_HW_NatType", "dnsstr",
                               "Username", "Password", "DialMode", "ConnectionControl", "VlanId", "MultiVlanID", "Pri8021",
                               "LcpEchoReqCheck", "ServiceList", "ExServiceList", "Tr069Flag", "IdleDisconnectTime", "MacId",
                               "IPv4Enable", "IPv6Enable", "IPv6MultiCastVlan", "PriPolicy", "DefaultPri", "MaxMRUSize",
                               "PPPoEACName", "X_HW_IdleDetectMode", "Uptime", "DNSOverrideAllowed", "X_HW_LowerLayers",
                               "PPPoESessionID", "X_HW_IGMPEnable", "StaticRouteInfo", "X_HW_DscpToPbitTbl", "Hurl", "Motm",
                               "X_HW_BridgeEnable", "X_HW_NPTv6Enable", "X_HW_SpeedLimit_UP", "X_HW_SpeedLimit_DOWN",
                               "X_HW_PingResponseEnable", "X_HW_PingResponseWhiteList", "IPForwardModeEnabled", "X_HW_UpPortId"]

    static let wanIpParams = ["domain", "X_HW_VXLAN_Enable", "X_HW_OperateDisable", "ConnectionTrigger", "MACAddress", "Status",
                              "LastConnErr", "RemoteWanInfo", "Name", "Enable", "EnableLanDhcp", "DstIPForwardingList",
                              "ConnectionStatus", "Mode", "IPMode", "IPAddress", "SubnetMask", "Gateway", "NATEnable",
                              "X_HW_NatType", "dnsstr", "VlanId", "MultiVlanID", "Pri8021", "VenderClassID", "ClientID",
                              "ServiceList", "ExServiceList", "Tr069Flag", "MacId", "IPv4Enable", "IPv6Enable",
                              "IPv6MultiCastVlan", "PriPolicy", "DefaultPri", "MaxMTUSize", "DHCPLeaseTime", "NTPServer",
                              "TimeZoneInfo", "SIPServer", "StaticRouteInfo", "VendorInfo", "DHCPLeaseTimeRemaining", "Uptime",
                              "DNSOverrideAllowed", "X_HW_LowerLayers", "X_HW_IPoEName", "X_HW_IPoEPassword", "X_HW_IGMPEnable",
                              "X_HW_DscpToPbitTbl", "IPv4IPAddressSecond", "IPv4SubnetMaskSecond", "IPv4IPAddressThird",
                              "IPv4SubnetMaskThird", "X_HW_NPTv6Enable", "X_HW_SpeedLimit_UP", "X_HW_SpeedLimit_DOWN",
                              "X_HW_LteProfile", "X_HW_PingResponseEnable", "X_HW_PingResponseWhiteList", "IPForwardModeEnabled",
                              "X_HW_UpPortId"]

    // MARK: Optical

    public func fetchOptical() async throws -> OpticalInfo {
        let token = try await freshTokenLoggingIn()
        let text = try await fetch(.init(.post, "/html/amp/common/getSmartDiagnoseResult.asp", form: [("x.X_HW_Token", token)]))
        var info = Self.parseSmartDiagnose(text)
        // TX power and temperature, when the firmware exposes them. Optional.
        if let optic = try? await fetch(.init(.post, "/html/ssmp/common/getOpticTxRx.asp")) {
            Self.mergeOpticTxRx(optic, into: &info)
        }
        return info
    }

    static func parseSmartDiagnose(_ text: String) -> OpticalInfo {
        var info = OpticalInfo()
        info.rxPowerDbm = parseDbm(HuaweiJs.stringVar("opticInfo", in: text))
        info.ponMode = HuaweiJs.stringVar("ontPonMode", in: text) ?? ""
        if info.ponMode.lowercased() == "epon" {
            info.registrationState = HuaweiJs.stringVar("eponStatus", in: text) ?? ""
        } else {
            info.registrationState = HuaweiJs.stringVar("gponStatus", in: text) ?? ""
        }
        return info
    }

    static func mergeOpticTxRx(_ text: String, into info: inout OpticalInfo) {
        let defs = HuaweiJs.definitions(in: text)
        for (name, params) in defs where params.contains("RxPower") || params.contains("TxPower") {
            guard let r = HuaweiJs.records(of: name, in: text).first else { continue }
            if let rx = parseDbm(r["RxPower"]) { info.rxPowerDbm = rx }
            if let tx = parseDbm(r["TxPower"]) { info.txPowerDbm = tx }
            if let t = Double(r["Temperature"] ?? "") { info.temperatureC = t }
            return
        }
    }

    static func parseDbm(_ raw: String?) -> Double? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty, raw != "--" else { return nil }
        return Double(raw)
    }

    // MARK: Devices

    public func fetchDevices() async throws -> [OntDevice] {
        let text = try await fetch(.init(.post, "/html/bbsp/common/GetLanUserDevInfo.asp"))
        return Self.parseDevices(text)
    }

    static let userDeviceParams = ["Domain", "IpAddr", "MacAddr", "Port", "IpType", "DevType", "DevStatus", "PortType",
                                   "Time", "HostName", "IPv4Enabled", "IPv6Enabled", "DeviceType", "UserDevAlias",
                                   "UserSpecifiedDeviceType", "LeaseTimeRemaining", "TrafficSendRate", "TrafficRecvRate"]

    /// All known devices, online first, de-duplicated by MAC (the page lists some twice).
    static func parseDevices(_ text: String) -> [OntDevice] {
        var seen = Set<String>()
        var devices: [OntDevice] = []
        for r in HuaweiJs.records(of: "USERDevice", in: text, fallbackParams: userDeviceParams) {
            let mac = (r["MacAddr"] ?? "").lowercased()
            guard !mac.isEmpty, seen.insert(mac).inserted else { continue }
            devices.append(OntDevice(
                mac: mac,
                ip: r["IpAddr"] ?? "",
                hostName: r["HostName"] ?? "",
                routerAlias: r["UserDevAlias"] ?? "",
                dhcpVendor: r["DevType"] ?? "",
                port: ConnectionPort(raw: r["Port"] ?? ""),
                isOnline: (r["DevStatus"] ?? "").lowercased() == "online",
                connectedTime: r["Time"] ?? ""
            ))
        }
        return devices.sorted { a, b in
            if a.isOnline != b.isOnline { return a.isOnline }
            return a.ip.localizedStandardCompare(b.ip) == .orderedAscending
        }
    }

    // MARK: Actions

    public func reboot() async throws {
        let token = try await freshTokenLoggingIn()
        // Same request the web UI's "Restart" button submits from the main page.
        _ = try await transport.send(.init(.post,
            "/CustomApp/set.cgi?x=InternetGatewayDevice.X_HW_DEBUG.SMP.DM.ResetBoard&RequestFile=../CustomApp/mainpage.asp",
            form: [("x.X_HW_Token", token)], ajax: false), host: credentials.host)
        loggedIn = false
        lastCounters = nil
    }

    private func freshTokenLoggingIn() async throws -> String {
        if !loggedIn { try await login() }
        do {
            return try await freshToken()
        } catch {
            loggedIn = false
            try await login()
            return try await freshToken()
        }
    }
}
