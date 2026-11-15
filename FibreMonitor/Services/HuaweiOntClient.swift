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

    public struct RouterIdentity: Equatable, Sendable {
        public var model: String?
        public var cfgMode: String?

        public init(model: String? = nil, cfgMode: String? = nil) {
            self.model = model
            self.cfgMode = cfgMode
        }
    }

    private let transport: OntTransport
    private var credentials: Credentials
    private var loggedIn = false
    /// Set after a rejected login; cleared only when the credentials change.
    private var loginBlocked = false
    public private(set) var detectedIdentity: RouterIdentity?

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
        wanDomain = nil
        ssidBands = [:]
        detectedIdentity = nil
    }

    /// Logs out of any active session, resets transport cookies, and switches to new router credentials.
    public func switchCredentials(_ new: Credentials) async {
        await logout()
        credentials = new
        loggedIn = false
        loginBlocked = false
        lastCounters = nil
        traffic = TrafficState()
        wanDomain = nil
        ssidBands = [:]
        detectedIdentity = nil
        await transport.resetSession(host: new.host)
    }

    public var isLoginBlocked: Bool { loginBlocked }

    // MARK: Session

    public func login() async throws {
        guard !credentials.password.isEmpty, !credentials.host.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw OntError.notConfigured
        }
        guard Self.isValidHost(credentials.host) else { throw OntError.invalidHost }
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
        // Load the main page once like a browser would, so the session is fully set up and identity can be read.
        if let indexText = try? await transport.send(.init(.get, "/index.asp", ajax: false), host: credentials.host) {
            let model = HuaweiJs.stringVar("ProductName", in: indexText)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let cfg = HuaweiJs.stringVar("CfgMode", in: indexText)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if (model?.isEmpty == false) || (cfg?.isEmpty == false) {
                detectedIdentity = RouterIdentity(
                    model: model?.isEmpty == false ? model : nil,
                    cfgMode: cfg?.isEmpty == false ? cfg : nil
                )
            }
        }
    }

    public func logout() async {
        let wasLoggedIn = loggedIn
        let currentHost = credentials.host
        loggedIn = false
        lastCounters = nil
        wanDomain = nil
        ssidBands = [:]
        detectedIdentity = nil
        if wasLoggedIn, let token = try? await freshToken() {
            _ = try? await transport.send(.init(.post, "/logout.cgi?RequestFile=html/logout.html",
                                                form: [("x.X_HW_Token", token)], ajax: false),
                                          host: currentHost)
        }
        await transport.resetSession(host: currentHost)
    }

    /// Sends a data request, logging in first if needed and once more if the session expired.
    /// Full HTML pages are checked for `expect` (text the real page always contains), because
    /// an expired session answers with the login page instead.
    private func fetch(_ request: OntRequest, expect: String? = nil) async throws -> String {
        func valid(_ text: String) -> Bool {
            if let expect { return text.contains(expect) }
            return HuaweiJs.looksLikeData(text)
        }
        if !loggedIn { try await login() }
        let first = try await transport.send(request, host: credentials.host)
        if valid(first) { return first }
        loggedIn = false
        try await login()
        let second = try await transport.send(request, host: credentials.host)
        guard valid(second) else { throw OntError.sessionExpired }
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
        let wan = Self.parseWan(text)
        if !wan.domain.isEmpty { wanDomain = wan.domain }
        return wan
    }

    /// Internet WAN used as the source interface for ping and traceroute.
    private var wanDomain: String?

    // MARK: Diagnostics (router-side ping / traceroute)

    private static let diagnosePage = "RequestFile=html/bbsp/maintenance/diagnosecommon.asp"

    public static func isValidHost(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty, h.count <= 253 else { return false }
        guard !h.hasPrefix("."), !h.hasPrefix("-"), !h.contains("..") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:")
        return h.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private func diagnosticInterface() async throws -> String {
        if let d = wanDomain { return d }
        let wan = try await fetchWan()
        guard !wan.domain.isEmpty else { throw OntError.badResponse("internet connection") }
        return wan.domain
    }

    /// Starts a ping from the router, like the Diagnostics page. Read progress with `pingOutput()`.
    public func startPing(host: String, count: Int = 4) async throws {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard Self.isValidHost(h) else { throw OntError.invalidHost }
        let interface = try await diagnosticInterface()
        let token = try await freshTokenLoggingIn()
        _ = try await transport.send(.init(.post,
            "/html/bbsp/maintenance/complex.cgi?x=InternetGatewayDevice.IPPingDiagnostics&RUNSTATE_FLAG=Ping&\(Self.diagnosePage)",
            form: [("x.Host", h), ("x.DiagnosticsState", "Requested"), ("x.NumberOfRepetitions", String(min(max(count, 1), 50))),
                   ("x.DSCP", "0"), ("x.DataBlockSize", "56"), ("x.Timeout", "10000"), ("x.Interface", interface),
                   ("RUNSTATE_FLAG.value", "START"), ("x.X_HW_Token", token)],
            ajax: false), host: credentials.host)
    }

    public func pingOutput() async throws -> DiagnosticOutput {
        DiagnosticOutput.parse(try await fetch(.init(.post, "/html/bbsp/maintenance/GetPingResult.asp")))
    }

    /// Starts a traceroute from the router. Read progress with `traceOutput()`.
    public func startTrace(host: String) async throws {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard Self.isValidHost(h) else { throw OntError.invalidHost }
        let interface = try await diagnosticInterface()
        let token = try await freshTokenLoggingIn()
        _ = try await transport.send(.init(.post,
            "/html/bbsp/maintenance/complex.cgi?x=InternetGatewayDevice.TraceRouteDiagnostics&RUNSTATE_FLAG=Traceroute&\(Self.diagnosePage)",
            form: [("x.Interface", interface), ("x.X_HW_ProtocolType", "0"), ("x.DiagnosticsState", "Requested"),
                   ("x.Host", h), ("x.DataBlockSize", "38"), ("RUNSTATE_FLAG.value", "START"), ("x.X_HW_Token", token)],
            ajax: false), host: credentials.host)
    }

    public func traceOutput() async throws -> DiagnosticOutput {
        DiagnosticOutput.parse(try await fetch(.init(.post, "/html/bbsp/maintenance/GetRouteResult.asp")))
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
        wan.domain = r["domain"] ?? ""
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
        if let optic = try? await transport.send(.init(.post, "/html/ssmp/common/getOpticTxRx.asp"), host: credentials.host),
           HuaweiJs.looksLikeData(optic) {
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
        var devices = Self.parseDevices(text, ssidBands: ssidBands)
        // Optional DHCP lease enrichment; older firmwares or sessions without it still succeed.
        if let dhcp = try? await transport.send(.init(.post, "/html/bbsp/common/GetLanUserDhcpInfo.asp"), host: credentials.host),
           HuaweiJs.looksLikeData(dhcp) {
            devices = Self.enrichDevices(devices, withDhcpInfo: dhcp)
        }
        return devices
    }

    /// SSID index -> "2.4GHz"/"5GHz" from the router's Wi-Fi list; learned by `fetchWifi()`.
    private var ssidBands: [Int: String] = [:]

    /// Removes an offline device from the router's list, like the device page's Delete button
    /// (which the router only offers for offline devices). Returns the refreshed list.
    public func deleteDevice(_ device: OntDevice) async throws -> [OntDevice] {
        guard !device.isOnline else { throw OntError.deviceOnline }
        guard device.domain.hasPrefix("InternetGatewayDevice.LANDevice.1.X_HW_UserDev.") else {
            throw OntError.badResponse("device record")
        }
        let token = try await freshTokenLoggingIn()
        _ = try await transport.send(.init(.post,
            "/html/bbsp/userdevinfo/del.cgi?x=InternetGatewayDevice.LANDevice.1.X_HW_UserDev"
                + "&RequestFile=html/bbsp/userdevinfo/userdevinfosmart.asp",
            form: [(device.domain, ""), ("x.X_HW_Token", token)]), host: credentials.host)
        let after = try await fetchDevices()
        guard !after.contains(where: { $0.mac == device.mac }) else { throw OntError.notConfirmed }
        return after
    }

    public static func validateDeviceAlias(_ alias: String) throws -> String {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 64 else {
            throw OntError.invalidDeviceAlias
        }
        let allPrintable = trimmed.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
        guard allPrintable else { throw OntError.invalidDeviceAlias }
        return trimmed
    }

    /// Renames a device on the router (`#198`), then re-fetches the device list.
    public func renameDevice(_ device: OntDevice, alias: String) async throws -> [OntDevice] {
        guard device.domain.hasPrefix("InternetGatewayDevice.LANDevice.1.X_HW_UserDev.") else {
            throw OntError.badResponse("device record")
        }
        let cleanAlias = try Self.validateDeviceAlias(alias)
        let token = try await freshTokenLoggingIn()
        let deviceType = device.userSpecifiedDeviceType.isEmpty ? "0" : device.userSpecifiedDeviceType
        _ = try await transport.send(.init(.post,
            "/html/bbsp/userdevinfo/set.cgi?x=\(device.domain)&RequestFile=html/bbsp/userdevinfo/userdetdevinfo.asp",
            form: [
                ("x.UserDevAlias", cleanAlias),
                ("x.UserSpecifiedDeviceType", deviceType),
                ("x.X_HW_Token", token)
            ],
            ajax: false), host: credentials.host)
        return try await fetchDevices()
    }

    // MARK: Router health

    private static func looksLikeLoginPage(_ text: String) -> Bool {
        text.contains("login.cgi") || text.contains("txt_Username")
    }

    public func fetchHealth() async throws -> RouterHealth {
        if !loggedIn { try await login() }
        let req = OntRequest(.get, "/html/ssmp/deviceinfo/deviceinfo.asp", ajax: false)
        let first = try await transport.send(req, host: credentials.host)
        if first.contains("cpuUsed") || first.contains("stDeviceInfo") {
            return Self.parseHealth(first)
        }
        guard Self.looksLikeLoginPage(first) else { throw OntError.badResponse("deviceinfo") }
        loggedIn = false
        try await login()
        let second = try await transport.send(req, host: credentials.host)
        guard second.contains("cpuUsed") || second.contains("stDeviceInfo") else {
            throw OntError.sessionExpired
        }
        return Self.parseHealth(second)
    }

    static func parseHealth(_ text: String) -> RouterHealth {
        var h = RouterHealth()
        h.cpuPercent = Int((HuaweiJs.stringVar("cpuUsed", in: text) ?? "").replacingOccurrences(of: "%", with: ""))
        h.memoryPercent = Int((HuaweiJs.stringVar("memUsed", in: text) ?? "").replacingOccurrences(of: "%", with: ""))
        h.uptimeSeconds = Int(HuaweiJs.stringVar("dev_uptime", in: text) ?? "")
        if let info = HuaweiJs.records(of: "stDeviceInfo", in: text).first {
            h.model = info["ModelName"] ?? ""
            h.firmware = info["SoftwareVersion"] ?? ""
            h.hardware = info["HardwareVersion"] ?? ""
        }
        return h
    }

    // MARK: Wi-Fi

    public func fetchWifi() async throws -> WifiState {
        let text = try await fetch(.init(.get, "/html/amp/common/wlan_list.asp", ajax: false), expect: "stRadio")
        let state = Self.parseWifi(text)
        ssidBands = Dictionary(state.networks.map { ($0.ssidIndex, $0.band) }, uniquingKeysWith: { a, _ in a })
        return state
    }

    static func parseWifi(_ text: String) -> WifiState {
        var state = WifiState()
        var seen = Set<Int>()
        for r in HuaweiJs.records(of: "stRadio", in: text, fallbackParams: ["domain", "OperatingFrequencyBand", "Enable"]) {
            guard let index = Int((r["domain"] ?? "").split(separator: ".").last ?? ""), seen.insert(index).inserted else { continue }
            state.radios.append(WifiRadio(index: index, band: r["OperatingFrequencyBand"] ?? "", enabled: r["Enable"] == "1"))
        }
        let params = ["domain", "name", "ssid", "X_HW_ServiceEnable", "enable", "X_HW_RFBand", "bindenable"]
        for r in HuaweiJs.records(of: "stWlanInfo", in: text, fallbackParams: params) {
            // Skip the page's own template record ('domain', 'SSID'+tid, ...).
            guard let index = Int((r["domain"] ?? "").split(separator: ".").last ?? "") else { continue }
            let enabled = r["enable"] == "1" && r["X_HW_ServiceEnable"] != "0"
            state.networks.append(WifiNetwork(ssidIndex: index, name: r["ssid"] ?? "", band: r["X_HW_RFBand"] ?? "",
                                              enabled: enabled))
        }
        state.radios.sort { $0.index < $1.index }
        state.networks.sort { $0.ssidIndex < $1.ssidIndex }
        return state
    }

    /// Fetches ephemeral SSID security & Wi-Fi configuration from `WlanBasic.asp`.
    /// Callers must discard returned passphrases when dismissed or backgrounded.
    public func fetchWlanBasic(bandHint: String? = nil, ssidIndex: Int? = nil) async throws -> [WifiSsidConfig] {
        let text = try await fetch(.init(.get, "/html/amp/wlanbasic/WlanBasic.asp", ajax: false), expect: "stWlan")
        var configs = Self.parseWlanBasic(text)
        if let ssidIndex, !configs.contains(where: { $0.ssidIndex == ssidIndex }) {
            let suffix = (bandHint?.hasPrefix("5") == true) ? "?5G" : "?2G"
            let alt = try await fetch(.init(.get, "/html/amp/wlanbasic/WlanBasic.asp\(suffix)", ajax: false), expect: "stWlan")
            configs = Self.parseWlanBasic(alt)
        }
        return configs
    }

    static func parseWlanBasic(_ text: String) -> [WifiSsidConfig] {
        let wlanParams = [
            "domain", "name", "enable", "ssid", "wlHide", "DeviceNum", "wmmEnable",
            "BeaconType", "BasicEncryptionModes", "BasicAuthenticationMode",
            "KeyIndex", "EncryptionLevel",
            "WPAEncryptionModes", "WPAAuthenticationMode",
            "IEEE11iEncryptionModes", "IEEE11iAuthenticationMode",
            "X_HW_WPAand11iEncryptionModes", "X_HW_WPAand11iAuthenticationMode",
            "WPARekey", "RadiusServer", "RadiusPort", "RadiusKey",
            "X_HW_ServiceEnable", "LowerLayers",
            "X_HW_WAPIEncryptionModes", "X_HW_WAPIAuthenticationMode",
            "X_HW_WAPIServer", "X_HW_WAPIPort", "X_HW_WPSConfigurated",
            "UAPSDEnable", "IsolationEnable"
        ]
        let wifiParams = ["domain", "name", "enable", "ssid", "mode", "channel", "power", "Country", "AutoChannelEnable", "channelWidth"]
        let pskParams = ["domain", "psk", "kpp"]
        let wpsParams = ["domain", "X_HW_ConfigMethod", "DevicePassword", "X_HW_PinGenerator", "Enable"]

        let kppUsed = HuaweiJs.stringVar("kppUsedFlag", in: text) == "1"
        let passwordMask = HuaweiJs.stringVar("wifiPasswordMask", in: text) == "1"

        func wlanIndex(from domain: String) -> Int? {
            if let r = domain.range(of: "WLANConfiguration.") {
                let tail = domain[r.upperBound...]
                let digits = tail.prefix { $0.isNumber }
                return Int(digits)
            }
            return Int(domain.split(separator: ".").last ?? "")
        }

        var modesByIndex: [Int: String] = [:]
        for r in HuaweiJs.records(of: "stWlanWifi", in: text, fallbackParams: wifiParams) {
            guard let idx = wlanIndex(from: r["domain"] ?? ""), let mode = r["mode"], !mode.isEmpty else { continue }
            modesByIndex[idx] = mode
        }

        var pskByIndex: [Int: String] = [:]
        for r in HuaweiJs.records(of: "stPreSharedKey", in: text, fallbackParams: pskParams) {
            guard let idx = wlanIndex(from: r["domain"] ?? "") else { continue }
            let primary = r["psk"] ?? r["value"] ?? ""
            let kpp = r["kpp"] ?? ""
            pskByIndex[idx] = (kppUsed && !kpp.isEmpty) ? kpp : primary
        }

        var wpsByIndex: [Int: [String: String]] = [:]
        for r in HuaweiJs.records(of: "stWpsPin", in: text, fallbackParams: wpsParams) {
            guard let idx = wlanIndex(from: r["domain"] ?? "") else { continue }
            wpsByIndex[idx] = r
        }

        var result: [WifiSsidConfig] = []
        var seen = Set<Int>()
        for r in HuaweiJs.records(of: "stWlan", in: text, fallbackParams: wlanParams) {
            let domain = r["domain"] ?? ""
            guard let idx = wlanIndex(from: domain), seen.insert(idx).inserted else { continue }
            let psk = pskByIndex[idx] ?? ""
            let masked = passwordMask && psk == "********"
            let wps = wpsByIndex[idx]
            result.append(WifiSsidConfig(
                ssidIndex: idx,
                domain: domain,
                interfaceName: r["name"] ?? "",
                enable: r["enable"] ?? "",
                ssid: r["ssid"] ?? "",
                wlHide: r["wlHide"] ?? "",
                deviceNum: r["DeviceNum"] ?? "",
                wmmEnable: r["wmmEnable"] ?? "",
                beaconType: r["BeaconType"] ?? "",
                basicAuthenticationMode: r["BasicAuthenticationMode"] ?? "",
                basicEncryptionModes: r["BasicEncryptionModes"] ?? "",
                keyIndex: r["KeyIndex"] ?? "",
                encryptionLevel: r["EncryptionLevel"] ?? "",
                wpaEncryptionModes: r["WPAEncryptionModes"] ?? "",
                wpaAuthenticationMode: r["WPAAuthenticationMode"] ?? "",
                ieee11iEncryptionModes: r["IEEE11iEncryptionModes"] ?? "",
                ieee11iAuthenticationMode: r["IEEE11iAuthenticationMode"] ?? "",
                mixEncryptionModes: r["X_HW_WPAand11iEncryptionModes"] ?? "",
                mixAuthenticationMode: r["X_HW_WPAand11iAuthenticationMode"] ?? "",
                wpaRekey: r["WPARekey"] ?? "",
                serviceEnable: r["X_HW_ServiceEnable"] ?? "1",
                lowerLayers: r["LowerLayers"] ?? "",
                standard: modesByIndex[idx] ?? "",
                psk: psk,
                isPasswordMasked: masked,
                wpsEnable: wps?["Enable"] ?? "",
                wpsConfigMethod: wps?["X_HW_ConfigMethod"] ?? "",
                wpsPinGenerator: wps?["X_HW_PinGenerator"] ?? "",
                wpsDevicePassword: wps?["DevicePassword"] ?? "",
                hasWlanWifiRecord: modesByIndex[idx] != nil,
                hasPskRecord: pskByIndex[idx] != nil,
                hasWpsRecord: wps != nil
            ))
        }
        result.sort { $0.ssidIndex < $1.ssidIndex }
        return result
    }

    /// Turns a whole radio (2.4 GHz = 1, 5 GHz = 2) on or off, like the Wi-Fi page's switch.
    /// Refuses to switch off the last radio that is on, which would cut every Wi-Fi device off.
    public func setRadio(_ index: Int, enabled: Bool) async throws -> WifiState {
        let before = try await fetchWifi()
        guard let radio = before.radios.first(where: { $0.index == index }) else { throw OntError.badResponse("Wi-Fi radio") }
        if radio.enabled == enabled { return before }
        if !enabled && !before.radios.contains(where: { $0.index != index && $0.enabled }) {
            throw OntError.lastRadio
        }
        let token = try await freshTokenLoggingIn()
        let flag = enabled ? "1" : "0"
        _ = try await transport.send(.init(.post,
            "/html/amp/wlanbasic/set.cgi?x=InternetGatewayDevice.X_HW_DEBUG.AMP.SetWifiCoverEnable"
                + "&y=InternetGatewayDevice.LANDevice.1.WiFi.Radio.\(index)&RequestFile=html/amp/wlanbasic/WlanBasic.asp",
            form: [("x.Enable", flag), ("x.RadioInst", String(index)), ("y.Enable", flag), ("x.X_HW_Token", token)],
            ajax: false), host: credentials.host)
        // The radio restarts; read back until it reports the new state.
        for _ in 0..<6 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if let now = try? await fetchWifi(), now.radios.first(where: { $0.index == index })?.enabled == enabled {
                return now
            }
        }
        throw OntError.notConfirmed
    }

    public static func validateWifiCredentials(ssid: String, password: String) throws {
        let hasText = !ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let ssidBytes = ssid.utf8.count
        let ssidPrintable = ssid.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
        guard hasText, ssidBytes >= 1, ssidBytes <= 32, ssidPrintable else {
            throw OntError.invalidWifiSsid
        }
        let pwdAscii = password.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value <= 0x7E }
        guard password.count >= 8, password.count <= 63, pwdAscii else {
            throw OntError.invalidWifiPassword
        }
    }

    /// Builds the exact `#704` POST request from parsed `WlanBasic.asp` configuration, preserving field order
    /// and setting the 4 user-controlled fields (`y.SSID`, `w.SSID`, `k.PreSharedKey`, `w.Key`).
    static func wifiEditRequest(
        config: WifiSsidConfig,
        newSsid: String,
        newPassword: String,
        token: String
    ) throws -> OntRequest {
        guard config.authMode.isEditableWpa2Or3Psk else {
            throw OntError.unsupportedWifiSecurity(config.authMode.displayName)
        }
        let missing = config.missingEditFields
        guard missing.isEmpty else {
            throw OntError.incompleteWifiConfig(missing)
        }
        try validateWifiCredentials(ssid: newSsid, password: newPassword)

        let domain = config.domain
        let ssidInst = String(config.ssidIndex)
        let encryptionMode = config.ieee11iEncryptionModes
        let ieeeAuth = config.ieee11iAuthenticationMode

        let path = "/html/amp/wlanbasic/set.cgi"
            + "?c1=InternetGatewayDevice.X_HW_DEBUG.WLANConfigAction"
            + "&w=InternetGatewayDevice.X_HW_DEBUG.AMP.WifiCoverSetWlanBasic"
            + "&y=\(domain)"
            + "&z=\(domain).WPS"
            + "&k=\(domain).PreSharedKey.1"
            + "&c2=InternetGatewayDevice.X_HW_DEBUG.WLANConfigAction"
            + "&RequestFile=html/amp/wlanbasic/WlanBasic.asp"

        let form: [(String, String)] = [
            ("y.Enable", config.enable),
            ("y.SSIDAdvertisementEnabled", config.wlHide),
            ("y.SSID", newSsid),
            ("y.X_HW_AssociateNum", config.deviceNum),
            ("y.BeaconType", config.beaconType),
            ("y.IEEE11iAuthenticationMode", ieeeAuth),
            ("y.IEEE11iEncryptionModes", encryptionMode),
            ("k.PreSharedKey", newPassword),
            ("y.X_HW_GroupRekey", config.wpaRekey),
            ("z.Enable", config.wpsEnable),
            ("z.X_HW_ConfigMethod", config.wpsConfigMethod),
            ("z.X_HW_PinGenerator", config.wpsPinGenerator),
            ("z.DevicePassword", config.wpsDevicePassword),
            ("w.SsidInst", ssidInst),
            ("w.SSID", newSsid),
            ("w.Enable", config.enable),
            ("w.Standard", config.standard),
            ("w.BasicAuthenticationMode", config.basicAuthenticationMode),
            ("w.BasicEncryptionModes", encryptionMode),
            ("w.WPAAuthenticationMode", "EAPAuthentication"),
            ("w.WPAEncryptionModes", encryptionMode),
            ("w.IEEE11iAuthenticationMode", ieeeAuth),
            ("w.IEEE11iEncryptionModes", encryptionMode),
            ("w.MixAuthenticationMode", "EAPAuthentication"),
            ("w.MixEncryptionModes", encryptionMode),
            ("w.SSIDAdvertisementEnabled", config.wlHide),
            ("w.WMMEnable", config.wmmEnable),
            ("w.MaxAssociateNum", config.deviceNum),
            ("w.BeaconType", config.beaconType),
            ("w.WEPEncryptionLevel", config.encryptionLevel),
            ("w.WEPKeyIndex", config.keyIndex),
            ("w.Key", newPassword),
            ("c1.ActionType", "0"),
            ("c2.ActionType", "1"),
            ("c2.SSIDList", ssidInst),
            ("x.X_HW_Token", token)
        ]
        return OntRequest(.post, path, form: form, ajax: false)
    }

    /// Saves an SSID name and passphrase (`#704`) and re-reads `wlan_list.asp`, handling expected Wi-Fi drops gracefully.
    public func updateWifiCredentials(
        config: WifiSsidConfig,
        newSsid: String,
        newPassword: String
    ) async throws -> WifiUpdateResult {
        _ = try Self.wifiEditRequest(config: config, newSsid: newSsid, newPassword: newPassword, token: "validate")
        let token = try await freshTokenLoggingIn()
        let request = try Self.wifiEditRequest(config: config, newSsid: newSsid, newPassword: newPassword, token: token)
        do {
            _ = try await transport.send(request, host: credentials.host)
        } catch let url as URLError where [.networkConnectionLost, .timedOut, .cannotConnectToHost, .notConnectedToInternet].contains(url.code) {
            return WifiUpdateResult(wifi: nil, connectionDropped: true)
        }
        do {
            let refreshed = try await fetchWifi()
            return WifiUpdateResult(wifi: refreshed, connectionDropped: false)
        } catch {
            return WifiUpdateResult(wifi: nil, connectionDropped: true)
        }
    }

    // MARK: LAN

    public func fetchLan() async throws -> LanInfo {
        let text = try await fetch(.init(.get, "/html/bbsp/dhcpservercfg/dhcp2.asp", ajax: false), expect: "dhcpmainst")
        return Self.parseLan(text)
    }

    static func parseLan(_ text: String) -> LanInfo {
        var lan = LanInfo()
        let interfaces = HuaweiJs.records(of: "stipaddr", in: text)
        if let ip = interfaces.first(where: { ($0["domain"] ?? "").contains("IPInterface.1") }) ?? interfaces.first {
            lan.routerIp = ip["ipaddr"] ?? ""
            lan.subnetMask = ip["subnetmask"] ?? ""
        }
        if let ip2 = interfaces.first(where: {
            ($0["domain"] ?? "").contains("IPInterface.2") && $0["enable"] != "0" && !($0["ipaddr"] ?? "").isEmpty
        }) {
            lan.secondaryIp = ip2["ipaddr"] ?? ""
        }
        if let d = HuaweiJs.records(of: "dhcpmainst", in: text).first(where: { ($0["startip"] ?? "").contains(".") }) {
            lan.dhcpEnabled = d["enable"] == "1"
            lan.poolStart = d["startip"] ?? ""
            lan.poolEnd = d["endip"] ?? ""
            lan.leaseSeconds = Int(d["leasetime"] ?? "") ?? 0
            let dns = (d["MainDNS"].flatMap { $0.isEmpty ? nil : $0 } ?? d["DNSServers"] ?? "")
            lan.dnsServers = dns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return lan
    }

    static let userDeviceParams = ["Domain", "IpAddr", "MacAddr", "Port", "IpType", "DevType", "DevStatus", "PortType",
                                   "Time", "HostName", "IPv4Enabled", "IPv6Enabled", "DeviceType", "UserDevAlias",
                                   "UserSpecifiedDeviceType", "LeaseTimeRemaining", "TrafficSendRate", "TrafficRecvRate"]

    static let userDeviceNewParams = ["Domain", "IpAddr", "MacAddr", "Port", "IpType", "DevType", "DevStatus", "PortType",
                                      "Time", "HostName", "IPv4Enabled", "IPv6Enabled", "DeviceType", "UserDevAlias",
                                      "UserSpecifiedDeviceType", "LeaseTimeRemaining", "RealMacAddr"]

    static let dhcpInfoParams = ["domain", "name", "ip", "mac", "remaintime", "devtype", "interfacetype",
                                 "AddressSource", "ConnectedTime"]

    private static func cleanPlaceholder(_ raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespaces)
        return trimmed == "--" ? "" : trimmed
    }

    private static func parseNonZeroRate(_ raw: String?) -> Int? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces),
              let value = Int(raw), value > 0 else { return nil }
        return value
    }

    /// All known devices, online first, de-duplicated by MAC (the page lists some twice).
    /// Supports both 18-arg `USERDevice` (checked first so traffic rates are kept) and 17-arg `USERDeviceNew`.
    /// `ssidBands` maps SSID index to band from the Wi-Fi list; without it bands are guessed.
    static func parseDevices(_ text: String, ssidBands: [Int: String] = [:]) -> [OntDevice] {
        var seen = Set<String>()
        var devices: [OntDevice] = []
        let candidates = HuaweiJs.records(of: "USERDevice", in: text, fallbackParams: userDeviceParams)
            + HuaweiJs.records(of: "USERDeviceNew", in: text, fallbackParams: userDeviceNewParams)

        for r in candidates {
            let primaryMac = cleanPlaceholder(r["MacAddr"]).lowercased()
            let fallbackMac = cleanPlaceholder(r["RealMacAddr"]).lowercased()
            let mac = primaryMac.isEmpty ? fallbackMac : primaryMac
            guard !mac.isEmpty, seen.insert(mac).inserted else { continue }

            let rawType = cleanPlaceholder(r["UserSpecifiedDeviceType"])
            let lease = Int(r["LeaseTimeRemaining"] ?? "").flatMap { $0 > 0 ? $0 : nil }

            devices.append(OntDevice(
                domain: r["Domain"] ?? "",
                mac: mac,
                ip: cleanPlaceholder(r["IpAddr"]),
                hostName: cleanPlaceholder(r["HostName"]),
                routerAlias: cleanPlaceholder(r["UserDevAlias"]),
                dhcpVendor: cleanPlaceholder(r["DevType"]),
                port: ConnectionPort(raw: cleanPlaceholder(r["Port"]), ssidBands: ssidBands),
                isOnline: (r["DevStatus"] ?? "").lowercased() == "online",
                connectedTime: r["Time"] ?? "",
                userSpecifiedDeviceType: rawType.isEmpty ? "0" : rawType,
                trafficSendRate: parseNonZeroRate(r["TrafficSendRate"]),
                trafficRecvRate: parseNonZeroRate(r["TrafficRecvRate"]),
                leaseSecondsRemaining: lease
            ))
        }
        return devices.sorted { a, b in
            if a.isOnline != b.isOnline { return a.isOnline }
            return a.ip.localizedStandardCompare(b.ip) == .orderedAscending
        }
    }

    /// Enriches parsed devices with hostname, DHCP vendor class, IP, or lease remaining from `GetLanUserDhcpInfo.asp`.
    static func enrichDevices(_ devices: [OntDevice], withDhcpInfo text: String) -> [OntDevice] {
        var byMac: [String: [String: String]] = [:]
        for r in HuaweiJs.records(of: "DHCPInfo", in: text, fallbackParams: dhcpInfoParams) {
            let mac = cleanPlaceholder(r["mac"]).lowercased()
            guard !mac.isEmpty, byMac[mac] == nil else { continue }
            byMac[mac] = r
        }
        guard !byMac.isEmpty else { return devices }
        return devices.map { device in
            guard let lease = byMac[device.mac] else { return device }
            var copy = device
            if copy.hostName.isEmpty { copy.hostName = cleanPlaceholder(lease["name"]) }
            if copy.dhcpVendor.isEmpty { copy.dhcpVendor = cleanPlaceholder(lease["devtype"]) }
            if copy.ip.isEmpty { copy.ip = cleanPlaceholder(lease["ip"]) }
            if copy.leaseSecondsRemaining == nil,
               let rem = Int(lease["remaintime"] ?? ""), rem > 0 {
                copy.leaseSecondsRemaining = rem
            }
            return copy
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
