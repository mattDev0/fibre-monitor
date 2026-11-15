import XCTest
@testable import FibreMonitor

final class InMemoryPasswordStore: PasswordStore {
    private(set) var storage: [String: String] = [:]

    init(_ initial: [String: String] = [:]) {
        self.storage = initial
    }

    func password(forAccount account: String) -> String? {
        storage[account]
    }

    func setPassword(_ password: String, forAccount account: String) {
        if password.isEmpty {
            storage.removeValue(forKey: account)
        } else {
            storage[account] = password
        }
    }

    func deletePassword(forAccount account: String) {
        storage.removeValue(forKey: account)
    }
}

final class FailingWritePasswordStore: PasswordStore {
    private(set) var storage: [String: String]

    init(_ initial: [String: String] = [:]) {
        self.storage = initial
    }

    func password(forAccount account: String) -> String? {
        storage[account]
    }

    func setPassword(_ password: String, forAccount account: String) {
        // Simulate a failed Keychain write by ignoring non-empty stores.
    }

    func deletePassword(forAccount account: String) {
        storage.removeValue(forKey: account)
    }
}

final class RouterProfileTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "dev.mattdev0.fibremonitor.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (defaults, suite)
    }

    @MainActor
    func testFreshInstallStartsEmptyAndUnconfigured() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = InMemoryPasswordStore()

        let settings = SettingsStore(defaults: defaults, passwordStore: store)
        XCTAssertTrue(settings.profiles.isEmpty)
        XCTAssertNil(settings.activeProfile)
        XCTAssertFalse(settings.isConfigured)
        XCTAssertEqual(settings.host, "")
        XCTAssertEqual(settings.password, "")
    }

    @MainActor
    func testMigrationFromV1PreservesHostUsernamePasswordAndAliases() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("192.168.100.1", forKey: "router_host")
        defaults.set("admin", forKey: "router_username")
        defaults.set(["AA:BB:CC:00:00:01": "My Phone", "aa:bb:cc:00:00:02": "Living TV"], forKey: "device_aliases")
        let store = InMemoryPasswordStore(["router": "legacy-pw-123"])

        let settings = SettingsStore(defaults: defaults, passwordStore: store)
        XCTAssertEqual(settings.profiles.count, 1)
        let profile = settings.profiles[0]
        XCTAssertEqual(profile.name, "Previous router")
        XCTAssertEqual(profile.host, "192.168.100.1")
        XCTAssertEqual(profile.username, "admin")
        XCTAssertEqual(settings.activeProfile?.id, profile.id)
        XCTAssertTrue(settings.isConfigured)
        XCTAssertEqual(settings.password, "legacy-pw-123")
        XCTAssertEqual(store.password(forAccount: profile.id.uuidString), "legacy-pw-123")
        XCTAssertNil(store.password(forAccount: "router"), "legacy account should be cleared after verified migration")
        XCTAssertEqual(settings.alias(for: "aa:bb:cc:00:00:01"), "My Phone")
        XCTAssertEqual(settings.alias(for: "AA:BB:CC:00:00:02"), "Living TV")

        // Re-initializing must not re-run migration or duplicate the profile.
        let reloaded = SettingsStore(defaults: defaults, passwordStore: store)
        XCTAssertEqual(reloaded.profiles.count, 1)
        XCTAssertEqual(reloaded.profiles[0].id, profile.id)
        XCTAssertEqual(reloaded.password, "legacy-pw-123")
        XCTAssertEqual(reloaded.alias(for: "aa:bb:cc:00:00:01"), "My Phone")
    }

    @MainActor
    func testMigrationPreservesLegacyPasswordWhenWriteFails() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("192.168.100.1", forKey: "router_host")
        let store = FailingWritePasswordStore(["router": "precious-pw"])

        let settings = SettingsStore(defaults: defaults, passwordStore: store)
        XCTAssertEqual(settings.profiles.count, 1)
        XCTAssertEqual(store.password(forAccount: "router"), "precious-pw")
    }

    @MainActor
    func testKeychainPerProfileAliasesAndCrud() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = InMemoryPasswordStore()
        let settings = SettingsStore(defaults: defaults, passwordStore: store)

        let p1 = settings.addProfile(
            RouterProfile(name: "Previous router", host: "192.168.100.1", username: "root"),
            password: "pw1",
            select: true
        )
        let p2 = settings.addProfile(
            RouterProfile.mtnTemplate(),
            password: "pw2",
            select: false
        )

        XCTAssertEqual(settings.profiles.count, 2)
        XCTAssertEqual(store.password(forAccount: p1.id.uuidString), "pw1")
        XCTAssertEqual(store.password(forAccount: p2.id.uuidString), "pw2")
        XCTAssertEqual(settings.password, "pw1")

        // Per-profile device aliases.
        settings.setAlias("Router 1 Phone", for: "AA:BB:CC:00:00:01")
        settings.selectProfile(p2.id)
        XCTAssertEqual(settings.password, "pw2")
        XCTAssertNil(settings.alias(for: "aa:bb:cc:00:00:01"))
        settings.setAlias("MTN Phone", for: "AA:BB:CC:00:00:01")
        XCTAssertEqual(settings.alias(for: "aa:bb:cc:00:00:01"), "MTN Phone")
        XCTAssertEqual(settings.alias(for: "aa:bb:cc:00:00:01", profileId: p1.id), "Router 1 Phone")

        // Reorder profiles.
        settings.moveProfiles(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        XCTAssertEqual(settings.profiles.map(\.id), [p2.id, p1.id])

        // Update profile 2 password without affecting profile 1.
        var edited = p2
        edited.name = "MTN Main"
        settings.updateProfile(edited, password: "pw2-updated")
        XCTAssertEqual(store.password(forAccount: p2.id.uuidString), "pw2-updated")
        XCTAssertEqual(store.password(forAccount: p1.id.uuidString), "pw1")

        // Delete active profile cleans up Keychain + aliases and falls back to remaining profile.
        settings.deleteProfile(p2.id)
        XCTAssertEqual(settings.profiles.map(\.id), [p1.id])
        XCTAssertNil(store.password(forAccount: p2.id.uuidString))
        XCTAssertNil(settings.alias(for: "aa:bb:cc:00:00:01", profileId: p2.id))
        XCTAssertEqual(settings.activeProfile?.id, p1.id)
    }

    func testMtnTemplateDefaultsAndEmptyPassword() {
        let t = RouterProfile.mtnTemplate()
        XCTAssertEqual(t.name, "New router (MTN)")
        XCTAssertEqual(t.host, "192.168.2.1")
        XCTAssertEqual(t.username, "root")
        XCTAssertNil(t.lastUsed)
    }

    func testHostValidation() {
        XCTAssertTrue(HuaweiOntClient.isValidHost("192.168.2.1"))
        XCTAssertTrue(HuaweiOntClient.isValidHost("192.168.100.1"))
        XCTAssertTrue(HuaweiOntClient.isValidHost("ont.local"))
        XCTAssertTrue(HuaweiOntClient.isValidHost("my-router.home:8080"))

        XCTAssertFalse(HuaweiOntClient.isValidHost(""))
        XCTAssertFalse(HuaweiOntClient.isValidHost("   "))
        XCTAssertFalse(HuaweiOntClient.isValidHost("http://192.168.2.1"))
        XCTAssertFalse(HuaweiOntClient.isValidHost("192.168.2.1/html"))
        XCTAssertFalse(HuaweiOntClient.isValidHost("8.8.8.8; reboot"))
        XCTAssertFalse(HuaweiOntClient.isValidHost(".."))
        XCTAssertFalse(HuaweiOntClient.isValidHost("-bad"))
    }

    func testIndexAspIdentityDetection() async throws {
        let t = FakeTransport()
        t.on("/asp/GetRandCount.asp", Fixtures.token)
        t.on("/login.cgi", Fixtures.loginOk)
        t.on("/index.asp", Fixtures.indexPage)

        let client = HuaweiOntClient(
            credentials: .init(host: "192.168.2.1", username: "root", password: "pw"),
            transport: t
        )
        try await client.login()
        let identity = await client.detectedIdentity
        XCTAssertEqual(identity?.model, "HG8145X6-10")
        XCTAssertEqual(identity?.cfgMode, "GNMTNNCE")
    }

    @MainActor
    func testSwitchingRoutersLogsOutResetsCookiesClearsStateAndConnectsToNewRouter() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = InMemoryPasswordStore()
        let settings = SettingsStore(defaults: defaults, passwordStore: store)

        let profileA = settings.addProfile(
            RouterProfile(name: "Previous router", host: "192.168.100.1", username: "root"),
            password: "pwA",
            select: true
        )
        let profileB = settings.addProfile(
            RouterProfile.mtnTemplate(),
            password: "pwB",
            select: false
        )

        let t = FakeTransport()
        t.on("/asp/GetRandCount.asp", Fixtures.token)
        t.on("/login.cgi", Fixtures.loginOk)
        t.on("/index.asp", Fixtures.indexPage)
        t.on("/html/ssmp/common/GetRandToken.asp", Fixtures.token)
        t.on("/logout.cgi", "")
        t.on("/html/bbsp/common/get_wan_list_pppwanstat.asp",
             Fixtures.pppStats(sent: "1000", received: "2000"),
             Fixtures.pppStats(sent: "2000", received: "4000"))
        t.on("/html/bbsp/common/getwanlist.asp", Fixtures.wanList)
        t.on("/html/amp/common/getSmartDiagnoseResult.asp", Fixtures.smartDiagnose)
        t.on("/html/ssmp/common/getOpticTxRx.asp", Fixtures.opticTxRx)
        t.on("/html/amp/common/wlan_list.asp", Fixtures.wlanList(radio1: true, radio2: true))
        t.on("/html/ssmp/deviceinfo/deviceinfo.asp", Fixtures.deviceInfoPage)
        t.on("/html/bbsp/common/GetLanUserDevInfo.asp", Fixtures.devices)
        t.on("/html/bbsp/dhcpservercfg/dhcp2.asp", Fixtures.dhcpPage)

        let vm = MonitorViewModel(settings: settings, transport: t)
        XCTAssertTrue(vm.awaitingRouterSelection, "2+ profiles should prompt launch picker before polling")

        // Connect to router A.
        await vm.switchRouter(to: profileA)
        XCTAssertFalse(vm.awaitingRouterSelection)
        XCTAssertTrue(vm.isConnected)
        XCTAssertEqual(vm.wan.ipAddress, "10.20.30.40")
        XCTAssertEqual(vm.devices.count, 3)
        XCTAssertEqual(settings.activeProfile?.detectedModel, "HG8145X6-10")
        XCTAssertEqual(settings.activeProfile?.cfgMode, "GNMTNNCE")

        // Switch to router B when B's 192.168.2.1 host fails to respond: verifies logout + reset + clear state + fallback hint.
        t.fail(host: "192.168.2.1")
        await vm.switchRouter(to: profileB)

        // Old router A must have received /logout.cgi before any request to router B.
        let logoutIdx = t.recordedRequests.firstIndex {
            $0.host == "192.168.100.1" && $0.request.path.hasPrefix("/logout.cgi")
        }
        let bLoginIdx = t.recordedRequests.firstIndex {
            $0.host == "192.168.2.1" && $0.request.path == "/asp/GetRandCount.asp"
        }
        XCTAssertNotNil(logoutIdx, "switching must log out of old router")
        XCTAssertNotNil(bLoginIdx)
        if let logoutIdx, let bLoginIdx {
            XCTAssertLessThan(logoutIdx, bLoginIdx)
        }
        XCTAssertTrue(t.resetHosts.contains("192.168.100.1"))
        XCTAssertTrue(t.resetHosts.contains("192.168.2.1"))

        // View state from router A must be completely cleared.
        XCTAssertFalse(vm.isConnected)
        XCTAssertEqual(vm.wan, WanInfo())
        XCTAssertTrue(vm.devices.isEmpty)
        XCTAssertEqual(vm.optical, OpticalInfo())
        XCTAssertNil(vm.lastUpdate)
        XCTAssertTrue(vm.shouldSuggestFallbackHost)
        XCTAssertTrue(vm.errorMessage?.contains("192.168.100.1") == true)

        // Tapping "Try 192.168.100.1" updates active profile B to 192.168.100.1 and connects.
        await vm.useFallbackHost("192.168.100.1")
        XCTAssertTrue(vm.isConnected)
        XCTAssertEqual(settings.activeProfile?.host, "192.168.100.1")
        XCTAssertFalse(vm.shouldSuggestFallbackHost)
    }
}
