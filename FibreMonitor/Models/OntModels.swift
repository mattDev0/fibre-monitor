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
    /// Router record, e.g. InternetGatewayDevice.LANDevice.1.X_HW_UserDev.14 (used to delete it).
    public var domain: String = ""
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
    case lastRadio
    case notConfirmed
    case deviceOnline
    case invalidHost

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
}

public struct LanInfo: Equatable, Sendable {
    public var routerIp: String = ""
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
