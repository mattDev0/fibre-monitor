import Foundation
import Security

/// Connection settings. The router password is kept in the Keychain, the rest in UserDefaults.
@MainActor
public final class SettingsStore: ObservableObject {
    public static let shared = SettingsStore()

    private enum Keys {
        static let host = "router_host"
        static let username = "router_username"
        static let pollInterval = "poll_interval_seconds"
        static let aliases = "device_aliases"
        static let keychainService = "dev.mattdev0.fibremonitor.router"
    }

    private let defaults: UserDefaults

    @Published public var host: String { didSet { defaults.set(host, forKey: Keys.host) } }
    @Published public var username: String { didSet { defaults.set(username, forKey: Keys.username) } }
    @Published public var pollIntervalSeconds: Int { didSet { defaults.set(pollIntervalSeconds, forKey: Keys.pollInterval) } }
    @Published public private(set) var aliases: [String: String] { didSet { defaults.set(aliases, forKey: Keys.aliases) } }
    @Published public var password: String { didSet { Self.savePassword(password) } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        host = defaults.string(forKey: Keys.host) ?? "192.168.100.1"
        username = defaults.string(forKey: Keys.username) ?? "root"
        let interval = defaults.integer(forKey: Keys.pollInterval)
        pollIntervalSeconds = interval > 0 ? interval : 2
        aliases = defaults.dictionary(forKey: Keys.aliases) as? [String: String] ?? [:]
        password = Self.loadPassword() ?? ""
    }

    public var isConfigured: Bool { !password.isEmpty && !host.isEmpty }

    public var credentials: HuaweiOntClient.Credentials {
        .init(host: host.trimmingCharacters(in: .whitespaces),
              username: username.trimmingCharacters(in: .whitespaces),
              password: password)
    }

    public func alias(for mac: String) -> String? {
        aliases[mac.lowercased()]
    }

    public func setAlias(_ alias: String, for mac: String) {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { aliases.removeValue(forKey: mac.lowercased()) } else { aliases[mac.lowercased()] = trimmed }
    }

    // MARK: Keychain

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Keys.keychainService,
         kSecAttrAccount as String: "router"]
    }

    private static func loadPassword() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func savePassword(_ password: String) {
        SecItemDelete(query as CFDictionary)
        guard !password.isEmpty else { return }
        var q = query
        q[kSecValueData as String] = Data(password.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}
