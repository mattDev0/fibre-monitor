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

    /// Huawei ports: SSID1-4 are the 2.4 GHz radio, SSID5-8 the 5 GHz one, LAN1-4 Ethernet.
    public init(raw: String) {
        let upper = raw.uppercased()
        if upper.hasPrefix("SSID"), let n = Int(upper.dropFirst(4)) {
            self = n >= 5 ? .wifi5(ssidIndex: n) : .wifi24(ssidIndex: n)
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
    public var mac: String
    public var ip: String
    public var hostName: String
    public var routerAlias: String
    public var dhcpVendor: String       // e.g. "android-dhcp-14"
    public var port: ConnectionPort
    public var isOnline: Bool
    public var connectedTime: String    // router format "h:m"

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
        }
    }
}
