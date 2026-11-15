import Foundation

public struct ThroughputSample: Equatable, Sendable {
    public var downloadMbps: Double
    public var uploadMbps: Double
    public var time: Date
}

public struct TrafficState: Equatable, Sendable {
    public var downloadMbps: Double = 0
    public var uploadMbps: Double = 0
    public var peakDownloadMbps: Double = 0
    public var peakUploadMbps: Double = 0
    public var history: [ThroughputSample] = []
}

public struct WanInfo: Equatable, Sendable {
    /// TR-069 path of the connection, e.g. InternetGatewayDevice.WANDevice.1...WANPPPConnection.1
    public var domain: String = ""
    public var name: String = ""
    public var connectionStatus: String = ""
    public var connectionType: String = ""   // "PPPoE" or "IPoE"
    public var ipAddress: String = ""
    public var gateway: String = ""
    public var dnsServers: [String] = []
    public var vlanId: String = ""
    public var uptimeSeconds: Int = 0
    public var lastError: String = ""

    public var isConnected: Bool { connectionStatus.lowercased() == "connected" }

    /// 10.x, 100.64/10 and 172.16/12 WAN addresses mean the ISP uses carrier-grade NAT.
    public var isCarrierNat: Bool {
        let parts = ipAddress.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 10 { return true }
        if parts[0] == 100 && (64...127).contains(parts[1]) { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        return false
    }
}

public struct OpticalInfo: Equatable, Sendable {
    public var rxPowerDbm: Double?
    public var txPowerDbm: Double?
    public var temperatureC: Double?
    public var ponMode: String = ""        // "gpon" / "epon"
    public var registrationState: String = ""  // GPON O1..O7, or EPON status

    public var isRegistered: Bool {
        if ponMode.lowercased() == "epon" { return registrationState.lowercased() == "online" }
        return registrationState.uppercased() == "O5"
    }

    public enum Quality: Equatable { case good, weak, bad, tooStrong, unknown }

    /// GPON class B+ receivers work between about -8 and -27 dBm.
    public var rxQuality: Quality {
        guard let rx = rxPowerDbm else { return .unknown }
        if rx > -8 { return .tooStrong }
        if rx >= -24 { return .good }
        if rx >= -27 { return .weak }
        return .bad
    }

    public var registrationText: String {
        switch registrationState.uppercased() {
        case "O1": return "Initial (O1)"
        case "O2": return "Standby (O2)"
        case "O3": return "Serial number (O3)"
        case "O4": return "Ranging (O4)"
        case "O5": return "Registered (O5)"
        case "O6": return "Signal interrupted (O6)"
        case "O7": return "Emergency stop (O7)"
        case "": return "Unknown"
        default: return registrationState
        }
    }
}

public enum ConnectionPort: Equatable, Sendable {
    case wifi24(ssidIndex: Int)
    case wifi5(ssidIndex: Int)
    case lan(Int)
    case other(String)

    /// `ssidBands` (SSID index -> "2.4GHz"/"5GHz", from the router's Wi-Fi list) decides the band.
    /// Without it, the usual Huawei layout is assumed: SSID1-4 on 2.4 GHz, SSID5-8 on 5 GHz.
    public init(raw: String, ssidBands: [Int: String] = [:]) {
        let upper = raw.uppercased()
        if upper.hasPrefix("SSID"), let n = Int(upper.dropFirst(4)) {
            if let band = ssidBands[n] {
                self = band.hasPrefix("5") ? .wifi5(ssidIndex: n) : .wifi24(ssidIndex: n)
            } else {
                self = n >= 5 ? .wifi5(ssidIndex: n) : .wifi24(ssidIndex: n)
            }
        } else if upper.hasPrefix("LAN"), let n = Int(upper.dropFirst(3)) {
            self = .lan(n)
        } else {
            self = .other(raw)
        }
    }

    public var label: String {
        switch self {
        case .wifi24: return "2.4 GHz"
        case .wifi5: return "5 GHz"
        case .lan(let n): return "LAN \(n)"
        case .other(let s): return s.isEmpty ? "—" : s
        }
    }

    public var isWifi: Bool {
        switch self {
        case .wifi24, .wifi5: return true
        default: return false
        }
    }
}

public struct OntDevice: Identifiable, Equatable, Sendable {
    public var id: String { mac }
    /// Router record, e.g. InternetGatewayDevice.LANDevice.1.X_HW_UserDev.14 (used to delete or rename it).
    public var domain: String = ""
    public var mac: String
    public var ip: String
    public var hostName: String
    public var routerAlias: String
    public var dhcpVendor: String       // e.g. "android-dhcp-14"
    public var port: ConnectionPort
    public var isOnline: Bool
    public var connectedTime: String    // router format "h:m"
    public var userSpecifiedDeviceType: String = "0"
    /// Non-zero rate from `USERDevice.TrafficSendRate` / `TrafficRecvRate` (bytes/s on Huawei ONTs; nil when 0 or absent).
    public var trafficSendRate: Int? = nil
    public var trafficRecvRate: Int? = nil
    public var leaseSecondsRemaining: Int? = nil

    public init(
        domain: String = "",
        mac: String,
        ip: String,
        hostName: String,
        routerAlias: String,
        dhcpVendor: String,
        port: ConnectionPort,
        isOnline: Bool,
        connectedTime: String,
        userSpecifiedDeviceType: String = "0",
        trafficSendRate: Int? = nil,
        trafficRecvRate: Int? = nil,
        leaseSecondsRemaining: Int? = nil
    ) {
        self.domain = domain
        self.mac = mac
        self.ip = ip
        self.hostName = hostName
        self.routerAlias = routerAlias
        self.dhcpVendor = dhcpVendor
        self.port = port
        self.isOnline = isOnline
        self.connectedTime = connectedTime
        self.userSpecifiedDeviceType = userSpecifiedDeviceType
        self.trafficSendRate = trafficSendRate
        self.trafficRecvRate = trafficRecvRate
        self.leaseSecondsRemaining = leaseSecondsRemaining
    }

    public var hasTrafficRates: Bool {
        trafficSendRate != nil || trafficRecvRate != nil
    }

    /// Best name the router knows, before any local alias.
    public var displayName: String {
        for candidate in [routerAlias, hostName] {
            let t = candidate.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty && t != "--" { return t }
        }
        let vendor = dhcpVendor.trimmingCharacters(in: .whitespaces)
        if vendor.lowercased().hasPrefix("android") { return "Android device" }
        if !vendor.isEmpty && vendor != "--" { return vendor }
        return "Unknown device"
    }

    /// "1:05" -> "1h 5m", "0:24" -> "24m".
    public var connectedText: String {
        let parts = connectedTime.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return connectedTime }
        let (h, m) = (parts[0], parts[1])
        if h >= 24 { return "\(h / 24)d \(h % 24)h" }
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

public enum OntError: LocalizedError, Equatable {
    case notConfigured
    case loginRejected
    case sessionExpired
    case badResponse(String)
    case lastRadio
    case notConfirmed
    case deviceOnline
    case invalidHost
    case invalidDeviceAlias
    case invalidWifiSsid
    case invalidWifiPassword
    case unsupportedWifiSecurity(String)
    case incompleteWifiConfig([String])

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Enter the router password in Settings."
        case .loginRejected:
            return "The router rejected the login. Check the username and password in Settings. After several wrong attempts the router locks logins for a few minutes."
        case .sessionExpired:
            return "The router ended the session."
        case .badResponse(let what):
            return "Unexpected response from the router (\(what))."
        case .lastRadio:
            return "That's the only Wi-Fi band that's on. Turning it off would disconnect every Wi-Fi device, including this iPhone."
        case .deviceOnline:
            return "Only offline devices can be removed from the list, the same as on the router's page."
        case .invalidHost:
            return "Enter a host name or IP address, e.g. 8.8.8.8 or google.com."
        case .invalidDeviceAlias:
            return "Device name must be 1 to 64 printable characters."
        case .invalidWifiSsid:
            return "Network name (SSID) must be 1 to 32 bytes without control characters."
        case .invalidWifiPassword:
            return "Wi-Fi password must be 8 to 63 printable ASCII characters."
        case .unsupportedWifiSecurity(let mode):
            return "Editing is only supported for WPA2-PSK and WPA3-PSK networks (current: \(mode))."
        case .incompleteWifiConfig(let fields):
            return "Cannot edit this Wi-Fi network safely because required settings were missing from WlanBasic.asp: \(fields.joined(separator: ", "))."
        case .notConfirmed:
            return "Sent, but the router hasn't confirmed the change yet. If this iPhone was on that band, reconnect to Wi-Fi and refresh."
        }
    }
}

public struct RouterHealth: Equatable, Sendable {
    public var cpuPercent: Int?
    public var memoryPercent: Int?
    public var uptimeSeconds: Int?
    public var model: String = ""
    public var firmware: String = ""
    public var hardware: String = ""

    public var hasCpuOrMemory: Bool { cpuPercent != nil || memoryPercent != nil }
    public var hasAnyData: Bool {
        hasCpuOrMemory || uptimeSeconds != nil || !model.isEmpty || !firmware.isEmpty
    }
}

public struct WifiRadio: Equatable, Sendable, Identifiable {
    public var id: Int { index }
    public var index: Int          // 1 = 2.4 GHz, 2 = 5 GHz on this router
    public var band: String        // "2.4GHz" / "5GHz"
    public var enabled: Bool
}

public struct WifiNetwork: Equatable, Sendable, Identifiable {
    public var id: Int { ssidIndex }
    public var ssidIndex: Int
    public var name: String
    public var band: String
    public var enabled: Bool
}

public struct WifiState: Equatable, Sendable {
    public var radios: [WifiRadio] = []
    public var networks: [WifiNetwork] = []

    public func networks(on radio: WifiRadio) -> [WifiNetwork] {
        networks.filter { $0.band == radio.band && $0.enabled }
    }

    public func allNetworks(on radio: WifiRadio) -> [WifiNetwork] {
        networks.filter { $0.band == radio.band }
    }
}

public struct LanInfo: Equatable, Sendable {
    public var routerIp: String = ""
    public var secondaryIp: String = ""
    public var subnetMask: String = ""
    public var dhcpEnabled = false
    public var poolStart: String = ""
    public var poolEnd: String = ""
    public var leaseSeconds: Int = 0
    /// Empty means devices are told to use the router itself, which forwards to the ISP's DNS.
    public var dnsServers: [String] = []
}

/// Output of a router-side ping or traceroute.
public struct DiagnosticOutput: Equatable, Sendable {
    public var text: String = ""
    /// Status after the router's `[@#@]` end marker, e.g. "Complete"; nil while still running.
    public var status: String?
    public var isFinished: Bool { status != nil }

    public init(text: String = "", status: String? = nil) {
        self.text = text
        self.status = status
    }

    /// Splits the router's output at its `[@#@]` end marker.
    public static func parse(_ raw: String) -> DiagnosticOutput {
        let joined = HuaweiJs.concatenatedStrings(in: raw)
        guard let r = joined.range(of: "[@#@]") else { return DiagnosticOutput(text: joined, status: nil) }
        let status = joined[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return DiagnosticOutput(text: String(joined[..<r.lowerBound]), status: status.isEmpty ? "Complete" : status)
    }
}

public enum WifiAuthMode: Equatable, Sendable {
    case wpa2Psk
    case wpaWpa2Psk
    case wpaPsk
    case wpa3Psk
    case wpa2Wpa3Psk
    case open
    case wep
    case wapi
    case enterprise
    case other(String)

    public var isPsk: Bool {
        switch self {
        case .wpa2Psk, .wpaWpa2Psk, .wpaPsk, .wpa3Psk, .wpa2Wpa3Psk:
            return true
        default:
            return false
        }
    }

    /// Modes supported by the #704 SSID/password edit flow (WPA2-PSK, WPA3-SAE, WPA2/WPA3-PSK).
    public var isEditableWpa2Or3Psk: Bool {
        switch self {
        case .wpa2Psk, .wpa3Psk, .wpa2Wpa3Psk:
            return true
        default:
            return false
        }
    }

    /// Authentication label shown in the UI and QR sheet.
    public var displayName: String {
        switch self {
        case .wpa2Psk: return "WPA2-PSK"
        case .wpaWpa2Psk: return "WPA/WPA2-PSK"
        case .wpaPsk: return "WPA-PSK"
        case .wpa3Psk: return "WPA3-SAE"
        case .wpa2Wpa3Psk: return "WPA2/WPA3-PSK"
        case .open: return "Open (No password)"
        case .wep: return "WEP"
        case .wapi: return "WAPI"
        case .enterprise: return "WPA Enterprise"
        case .other(let raw): return raw.isEmpty ? "Unknown" : raw
        }
    }

    /// QR `WIFI:T:...` security type, or nil if QR generation isn't supported (e.g., Enterprise).
    public var qrType: String? {
        switch self {
        case .wpa2Psk, .wpaWpa2Psk, .wpaPsk, .wpa3Psk, .wpa2Wpa3Psk:
            return "WPA"
        case .open:
            return "nopass"
        case .wep:
            return "WEP"
        case .wapi, .enterprise, .other:
            return nil
        }
    }
}

/// Ephemeral SSID configuration parsed from `/html/amp/wlanbasic/WlanBasic.asp`.
/// Contains the live Wi-Fi passphrase when the router exposes it; never persist to disk.
public struct WifiSsidConfig: Equatable, Sendable, Identifiable {
    public var id: Int { ssidIndex }
    public var ssidIndex: Int
    public var domain: String
    public var interfaceName: String
    public var enable: String
    public var ssid: String
    public var wlHide: String
    public var deviceNum: String
    public var wmmEnable: String
    public var beaconType: String
    public var basicAuthenticationMode: String
    public var basicEncryptionModes: String
    public var keyIndex: String
    public var encryptionLevel: String
    public var wpaEncryptionModes: String
    public var wpaAuthenticationMode: String
    public var ieee11iEncryptionModes: String
    public var ieee11iAuthenticationMode: String
    public var mixEncryptionModes: String
    public var mixAuthenticationMode: String
    public var wpaRekey: String
    public var serviceEnable: String
    public var lowerLayers: String
    public var standard: String
    public var psk: String
    public var isPasswordMasked: Bool
    public var wpsEnable: String
    public var wpsConfigMethod: String
    public var wpsPinGenerator: String
    public var wpsDevicePassword: String
    public var hasWlanWifiRecord: Bool
    public var hasPskRecord: Bool
    public var hasWpsRecord: Bool

    public init(
        ssidIndex: Int,
        domain: String,
        interfaceName: String = "",
        enable: String = "",
        ssid: String = "",
        wlHide: String = "",
        deviceNum: String = "",
        wmmEnable: String = "",
        beaconType: String = "",
        basicAuthenticationMode: String = "",
        basicEncryptionModes: String = "",
        keyIndex: String = "",
        encryptionLevel: String = "",
        wpaEncryptionModes: String = "",
        wpaAuthenticationMode: String = "",
        ieee11iEncryptionModes: String = "",
        ieee11iAuthenticationMode: String = "",
        mixEncryptionModes: String = "",
        mixAuthenticationMode: String = "",
        wpaRekey: String = "",
        serviceEnable: String = "1",
        lowerLayers: String = "",
        standard: String = "",
        psk: String = "",
        isPasswordMasked: Bool = false,
        wpsEnable: String = "",
        wpsConfigMethod: String = "",
        wpsPinGenerator: String = "",
        wpsDevicePassword: String = "",
        hasWlanWifiRecord: Bool = false,
        hasPskRecord: Bool = false,
        hasWpsRecord: Bool = false
    ) {
        self.ssidIndex = ssidIndex
        self.domain = domain
        self.interfaceName = interfaceName
        self.enable = enable
        self.ssid = ssid
        self.wlHide = wlHide
        self.deviceNum = deviceNum
        self.wmmEnable = wmmEnable
        self.beaconType = beaconType
        self.basicAuthenticationMode = basicAuthenticationMode
        self.basicEncryptionModes = basicEncryptionModes
        self.keyIndex = keyIndex
        self.encryptionLevel = encryptionLevel
        self.wpaEncryptionModes = wpaEncryptionModes
        self.wpaAuthenticationMode = wpaAuthenticationMode
        self.ieee11iEncryptionModes = ieee11iEncryptionModes
        self.ieee11iAuthenticationMode = ieee11iAuthenticationMode
        self.mixEncryptionModes = mixEncryptionModes
        self.mixAuthenticationMode = mixAuthenticationMode
        self.wpaRekey = wpaRekey
        self.serviceEnable = serviceEnable
        self.lowerLayers = lowerLayers
        self.standard = standard
        self.psk = psk
        self.isPasswordMasked = isPasswordMasked
        self.wpsEnable = wpsEnable
        self.wpsConfigMethod = wpsConfigMethod
        self.wpsPinGenerator = wpsPinGenerator
        self.wpsDevicePassword = wpsDevicePassword
        self.hasWlanWifiRecord = hasWlanWifiRecord
        self.hasPskRecord = hasPskRecord
        self.hasWpsRecord = hasWpsRecord
    }

    public var isEnabled: Bool {
        enable == "1" && serviceEnable != "0"
    }

    public var isHidden: Bool {
        wlHide == "0"
    }

    /// Required fields parsed live from `WlanBasic.asp` that must be present before `#704` submit.
    public var missingEditFields: [String] {
        var missing: [String] = []
        if !domain.hasPrefix("InternetGatewayDevice.LANDevice.1.WLANConfiguration.") { missing.append("domain") }
        if enable.isEmpty { missing.append("y.Enable") }
        if wlHide.isEmpty { missing.append("y.SSIDAdvertisementEnabled") }
        if deviceNum.isEmpty { missing.append("y.X_HW_AssociateNum") }
        if wmmEnable.isEmpty { missing.append("w.WMMEnable") }
        if beaconType.isEmpty { missing.append("y.BeaconType") }
        if basicAuthenticationMode.isEmpty { missing.append("w.BasicAuthenticationMode") }
        if keyIndex.isEmpty { missing.append("w.WEPKeyIndex") }
        if encryptionLevel.isEmpty { missing.append("w.WEPEncryptionLevel") }
        if wpaRekey.isEmpty { missing.append("y.X_HW_GroupRekey") }
        if !hasWlanWifiRecord || standard.isEmpty { missing.append("w.Standard") }
        switch authMode {
        case .wpa2Psk:
            if ieee11iAuthenticationMode.isEmpty { missing.append("y.IEEE11iAuthenticationMode") }
            if ieee11iEncryptionModes.isEmpty { missing.append("y.IEEE11iEncryptionModes") }
        case .wpa3Psk, .wpa2Wpa3Psk:
            if mixAuthenticationMode.isEmpty { missing.append("y.X_HW_WPAand11iAuthenticationMode") }
            if mixEncryptionModes.isEmpty { missing.append("y.X_HW_WPAand11iEncryptionModes") }
        default:
            break
        }
        if !hasPskRecord || isPasswordMasked || psk.isEmpty { missing.append("PreSharedKey") }
        if !hasWpsRecord || wpsEnable.isEmpty || wpsConfigMethod.isEmpty || wpsPinGenerator.isEmpty || wpsDevicePassword.isEmpty {
            missing.append("WPS parameters")
        }
        return missing
    }

    public var authMode: WifiAuthMode {
        switch beaconType {
        case "11i", "WPA2":
            if ieee11iAuthenticationMode == "PSKAuthentication" { return .wpa2Psk }
            if ieee11iAuthenticationMode == "EAPAuthentication" { return .enterprise }
        case "WPAand11i", "WPA/WPA2":
            if mixAuthenticationMode == "PSKAuthentication" { return .wpaWpa2Psk }
            if mixAuthenticationMode == "EAPAuthentication" { return .enterprise }
        case "WPA":
            if wpaAuthenticationMode == "PSKAuthentication" { return .wpaPsk }
            if wpaAuthenticationMode == "EAPAuthentication" { return .enterprise }
        case "WPA3":
            if mixAuthenticationMode == "SAEAuthentication" { return .wpa3Psk }
            if mixAuthenticationMode == "EAPAuthentication" { return .enterprise }
        case "WPA2/WPA3":
            if mixAuthenticationMode == "PSKandSAEAuthentication" { return .wpa2Wpa3Psk }
            if mixAuthenticationMode == "EAPAuthentication" { return .enterprise }
        case "Basic", "None", "":
            let openAuth = basicAuthenticationMode.isEmpty
                || basicAuthenticationMode == "None"
                || basicAuthenticationMode == "OpenSystem"
            if openAuth && (basicEncryptionModes.isEmpty || basicEncryptionModes == "None") {
                return .open
            }
            if basicEncryptionModes == "WEPEncryption" || basicAuthenticationMode == "SharedAuthentication" {
                return .wep
            }
        case "X_HW_WAPI":
            return .wapi
        default:
            break
        }
        return .other(beaconType)
    }

    public var qrPayload: String? {
        WifiQrPayload.string(ssid: ssid, password: isPasswordMasked ? nil : psk, authMode: authMode, isHidden: isHidden)
    }
}

public enum WifiQrPayload {
    public static func escape(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for ch in value {
            switch ch {
            case "\\", ";", ",", ":", "\"":
                out.append("\\")
                out.append(ch)
            default:
                out.append(ch)
            }
        }
        return out
    }

    public static func string(ssid: String, password: String?, authMode: WifiAuthMode, isHidden: Bool = false) -> String? {
        guard !ssid.isEmpty, let type = authMode.qrType else { return nil }
        let escapedSsid = escape(ssid)
        let hiddenPart = isHidden ? "H:true;" : ""
        if authMode == .open {
            return "WIFI:T:nopass;S:\(escapedSsid);\(hiddenPart);"
        }
        guard let password, !password.isEmpty else { return nil }
        return "WIFI:T:\(type);S:\(escapedSsid);P:\(escape(password));\(hiddenPart);"
    }
}

public struct WifiUpdateResult: Equatable, Sendable {
    public var wifi: WifiState?
    public var connectionDropped: Bool

    public init(wifi: WifiState?, connectionDropped: Bool) {
        self.wifi = wifi
        self.connectionDropped = connectionDropped
    }
}

public enum TrafficRateFormatter {
    public static func string(bytesPerSecond: Int) -> String {
        let clamped = max(0, bytesPerSecond)
        if clamped >= 1_000_000 {
            return String(format: "%.1f MB/s", Double(clamped) / 1_000_000)
        }
        if clamped >= 1_000 {
            let kb = Double(clamped) / 1_000
            return kb >= 100 ? String(format: "%.0f KB/s", kb) : String(format: "%.1f KB/s", kb)
        }
        return "\(clamped) B/s"
    }
}
