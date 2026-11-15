import Foundation
import Security

/// Seam around Keychain password storage so unit tests can inspect per-profile accounts.
public protocol PasswordStore {
    func password(forAccount account: String) -> String?
    func setPassword(_ password: String, forAccount account: String)
    func deletePassword(forAccount account: String)
}

/// Keychain storage for router passwords, one item per profile UUID under `dev.mattdev0.fibremonitor.router`.
public final class SystemKeychainStore: PasswordStore {
    public static let defaultService = "dev.mattdev0.fibremonitor.router"
    private let service: String

    public init(service: String = defaultService) {
        self.service = service
    }

    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func password(forAccount account: String) -> String? {
        var q = query(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setPassword(_ password: String, forAccount account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
        guard !password.isEmpty else { return }
        var q = query(account: account)
        q[kSecValueData as String] = Data(password.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    public func deletePassword(forAccount account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
    }
}

/// Connection profiles and preferences. Each profile's password lives in the Keychain; metadata lives in UserDefaults.
@MainActor
public final class SettingsStore: ObservableObject {
    public static let shared = SettingsStore()

    private enum Keys {
        static let profiles = "router_profiles"
        static let activeProfileId = "active_router_profile_id"
        static let profileAliases = "profile_device_aliases"
        static let pollInterval = "poll_interval_seconds"
        static let migrated = "v2_profiles_migrated"

        // Legacy 1.x keys
        static let legacyHost = "router_host"
        static let legacyUsername = "router_username"
        static let legacyAliases = "device_aliases"
        static let legacyKeychainAccount = "router"
    }

    private let defaults: UserDefaults
    private let passwordStore: PasswordStore

    @Published public private(set) var profiles: [RouterProfile] = []
    @Published public var activeProfileId: UUID? {
        didSet { saveActiveProfileId() }
    }
    @Published public var pollIntervalSeconds: Int {
        didSet { defaults.set(pollIntervalSeconds, forKey: Keys.pollInterval) }
    }
    @Published public private(set) var profileAliases: [String: [String: String]] = [:]

    public init(defaults: UserDefaults = .standard, passwordStore: PasswordStore = SystemKeychainStore()) {
        self.defaults = defaults
        self.passwordStore = passwordStore

        let interval = defaults.integer(forKey: Keys.pollInterval)
        self.pollIntervalSeconds = interval > 0 ? interval : 2

        if defaults.bool(forKey: Keys.migrated) || defaults.data(forKey: Keys.profiles) != nil {
            if let data = defaults.data(forKey: Keys.profiles),
               let decoded = try? JSONDecoder().decode([RouterProfile].self, from: data) {
                self.profiles = decoded
            }
            self.profileAliases = defaults.dictionary(forKey: Keys.profileAliases) as? [String: [String: String]] ?? [:]
            if let idStr = defaults.string(forKey: Keys.activeProfileId),
               let uuid = UUID(uuidString: idStr),
               profiles.contains(where: { $0.id == uuid }) {
                self.activeProfileId = uuid
            } else {
                self.activeProfileId = profiles.first?.id
            }
        } else {
            migrateFromV1()
        }
    }

    public var activeProfile: RouterProfile? {
        if let activeProfileId, let match = profiles.first(where: { $0.id == activeProfileId }) {
            return match
        }
        return profiles.first
    }

    public var host: String { activeProfile?.host ?? "" }
    public var username: String { activeProfile?.username ?? "root" }

    public var password: String {
        guard let id = activeProfile?.id else { return "" }
        return password(for: id)
    }

    public var isConfigured: Bool {
        activeProfile != nil && !host.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }

    public var credentials: HuaweiOntClient.Credentials {
        .init(
            host: host.trimmingCharacters(in: .whitespaces),
            username: username.trimmingCharacters(in: .whitespaces),
            password: password
        )
    }

    public func password(for profileId: UUID) -> String {
        passwordStore.password(forAccount: profileId.uuidString) ?? ""
    }

    public func setPassword(_ password: String, for profileId: UUID) {
        passwordStore.setPassword(password, forAccount: profileId.uuidString)
        objectWillChange.send()
    }

    // MARK: Profile management

    @discardableResult
    public func addProfile(_ profile: RouterProfile, password: String, select: Bool = true) -> RouterProfile {
        var item = profile
        item.name = Self.cleanName(item.name, fallbackHost: item.host)
        item.host = item.host.trimmingCharacters(in: .whitespaces)
        item.username = Self.cleanUsername(item.username)
        if select { item.lastUsed = Date() }

        profiles.append(item)
        passwordStore.setPassword(password, forAccount: item.id.uuidString)
        if select || activeProfileId == nil {
            activeProfileId = item.id
        }
        saveProfiles()
        return item
    }

    public func updateProfile(_ profile: RouterProfile, password: String? = nil) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var updated = profile
        updated.name = Self.cleanName(updated.name, fallbackHost: updated.host)
        updated.host = updated.host.trimmingCharacters(in: .whitespaces)
        updated.username = Self.cleanUsername(updated.username)
        profiles[index] = updated
        if let password {
            passwordStore.setPassword(password, forAccount: updated.id.uuidString)
        }
        saveProfiles()
    }

    public func deleteProfile(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        passwordStore.deletePassword(forAccount: id.uuidString)
        profileAliases.removeValue(forKey: id.uuidString)
        saveAliases()
        if activeProfileId == id {
            activeProfileId = profiles.first?.id
        }
        saveProfiles()
    }

    public func moveProfiles(fromOffsets source: IndexSet, toOffset destination: Int) {
        profiles.move(fromOffsets: source, toOffset: destination)
        saveProfiles()
    }

    public func selectProfile(_ id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].lastUsed = Date()
        activeProfileId = id
        saveProfiles()
    }

    public func recordDetection(for profileId: UUID, model: String?, cfgMode: String?) {
        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else { return }
        var changed = false
        if let model, !model.isEmpty, profiles[index].detectedModel != model {
            profiles[index].detectedModel = model
            changed = true
        }
        if let cfgMode, !cfgMode.isEmpty, profiles[index].cfgMode != cfgMode {
            profiles[index].cfgMode = cfgMode
            changed = true
        }
        if changed { saveProfiles() }
    }

    // MARK: Per-profile device aliases (keyed by MAC)

    public func alias(for mac: String) -> String? {
        guard let id = activeProfile?.id else { return nil }
        return alias(for: mac, profileId: id)
    }

    public func setAlias(_ alias: String, for mac: String) {
        guard let id = activeProfile?.id else { return }
        setAlias(alias, for: mac, profileId: id)
    }

    public func alias(for mac: String, profileId: UUID) -> String? {
        profileAliases[profileId.uuidString]?[mac.lowercased()]
    }

    public func setAlias(_ alias: String, for mac: String, profileId: UUID) {
        let key = profileId.uuidString
        var dict = profileAliases[key] ?? [:]
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            dict.removeValue(forKey: mac.lowercased())
        } else {
            dict[mac.lowercased()] = trimmed
        }
        if dict.isEmpty {
            profileAliases.removeValue(forKey: key)
        } else {
            profileAliases[key] = dict
        }
        saveAliases()
    }

    // MARK: Migration & persistence

    private func migrateFromV1() {
        let legacyHost = defaults.string(forKey: Keys.legacyHost)
        let legacyUser = defaults.string(forKey: Keys.legacyUsername)
        let legacyAliases = defaults.dictionary(forKey: Keys.legacyAliases) as? [String: String]
        let legacyPassword = passwordStore.password(forAccount: Keys.legacyKeychainAccount)

        let hasLegacyData = legacyHost != nil
            || legacyUser != nil
            || (legacyAliases?.isEmpty == false)
            || (legacyPassword?.isEmpty == false)

        if hasLegacyData {
            let trimmedHost = legacyHost?.trimmingCharacters(in: .whitespaces) ?? ""
            let host = trimmedHost.isEmpty ? "192.168.100.1" : trimmedHost
            let trimmedUser = legacyUser?.trimmingCharacters(in: .whitespaces) ?? ""
            let username = trimmedUser.isEmpty ? "root" : trimmedUser

            let profile = RouterProfile(
                id: UUID(),
                name: "Previous router",
                host: host,
                username: username,
                lastUsed: Date()
            )
            profiles = [profile]
            activeProfileId = profile.id

            if let legacyAliases, !legacyAliases.isEmpty {
                let normalized = Dictionary(
                    legacyAliases.map { ($0.key.lowercased(), $0.value) },
                    uniquingKeysWith: { _, latest in latest }
                )
                profileAliases[profile.id.uuidString] = normalized
                saveAliases()
            }

            if let legacyPassword, !legacyPassword.isEmpty {
                passwordStore.setPassword(legacyPassword, forAccount: profile.id.uuidString)
                // Only remove the legacy Keychain item once the per-profile copy is confirmed readable.
                if passwordStore.password(forAccount: profile.id.uuidString) == legacyPassword {
                    passwordStore.deletePassword(forAccount: Keys.legacyKeychainAccount)
                }
            }

            saveProfiles()
        }

        defaults.set(true, forKey: Keys.migrated)
    }

    private func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: Keys.profiles)
        }
    }

    private func saveActiveProfileId() {
        if let activeProfileId {
            defaults.set(activeProfileId.uuidString, forKey: Keys.activeProfileId)
        } else {
            defaults.removeObject(forKey: Keys.activeProfileId)
        }
    }

    private func saveAliases() {
        defaults.set(profileAliases, forKey: Keys.profileAliases)
    }

    private static func cleanName(_ raw: String, fallbackHost: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let hostTrimmed = fallbackHost.trimmingCharacters(in: .whitespaces)
        return hostTrimmed.isEmpty ? "Router" : hostTrimmed
    }

    private static func cleanUsername(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "root" : trimmed
    }
}
