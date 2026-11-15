import XCTest
@testable import FibreMonitor

final class WlanBasicTests: XCTestCase {
    func testParsesWlanBasicSsidConfigsPskStandardAndWps() {
        let configs = HuaweiOntClient.parseWlanBasic(Fixtures.gnmtnWlanBasic())
        XCTAssertEqual(configs.map(\.ssidIndex), [1, 2, 5])

        let c1 = configs[0]
        XCTAssertEqual(c1.ssid, "TestNet-2G")
        XCTAssertEqual(c1.standard, "11ax")
        XCTAssertEqual(c1.authMode, .wpaWpa2Psk)
        XCTAssertEqual(c1.psk, "pass-word;1")
        XCTAssertFalse(c1.isPasswordMasked)
        XCTAssertEqual(c1.wpsConfigMethod, "PushButton")
        XCTAssertEqual(c1.wpsEnable, "1")

        let c2 = configs[1]
        XCTAssertEqual(c2.ssid, "Example-SSID")
        XCTAssertEqual(c2.authMode, .wpa2Psk)
        XCTAssertEqual(c2.ieee11iEncryptionModes, "TKIPandAESEncryption")
        XCTAssertEqual(c2.wpsConfigMethod, "Lable")
        XCTAssertEqual(c2.wpsDevicePassword, "12345670")
        XCTAssertEqual(c2.wpsEnable, "0")

        let c5 = configs[2]
        XCTAssertEqual(c5.ssid, "OpenGuest")
        XCTAssertTrue(c5.isHidden)
        XCTAssertEqual(c5.authMode, .open)
    }

    func testUsesKppPassphraseWhenKppUsedFlagIsSet() {
        let configs = HuaweiOntClient.parseWlanBasic(Fixtures.gnmtnWlanBasic(kppUsed: true))
        XCTAssertEqual(configs.first?.psk, "kpp-secret-2")
    }

    func testMarksMaskedPasswordAndRefusesQrGeneration() {
        let configs = HuaweiOntClient.parseWlanBasic(Fixtures.gnmtnWlanBasic(passwordMask: true))
        let first = configs.first!
        XCTAssertTrue(first.isPasswordMasked)
        XCTAssertNil(first.qrPayload)
    }

    func testFormatsAndEscapesWifiQrPayload() {
        let pskPayload = WifiQrPayload.string(
            ssid: #"Home;Net\5G"#,
            password: #"a:b,c"d\"#,
            authMode: .wpa2Psk,
            isHidden: false
        )
        XCTAssertEqual(pskPayload, #"WIFI:T:WPA;S:Home\;Net\\5G;P:a\:b\,c\"d\\;;"#)

        let hiddenOpen = WifiQrPayload.string(
            ssid: "GuestNet",
            password: nil,
            authMode: .open,
            isHidden: true
        )
        XCTAssertEqual(hiddenOpen, "WIFI:T:nopass;S:GuestNet;H:true;;")

        XCTAssertNil(WifiQrPayload.string(ssid: "Corp", password: "secret", authMode: .enterprise))
    }

    @MainActor
    func testFetchWifiSsidConfigDoesNotPersistPasswordInSettings() async throws {
        let transport = FakeTransport()
        transport.on("/index.asp", Fixtures.indexPage)
        transport.on("/asp/GetRandCount.asp", Fixtures.token)
        transport.on("/html/ssmp/common/GetRandToken.asp", Fixtures.token)
        transport.on("/login.cgi", Fixtures.loginOk)
        transport.on("/html/amp/wlanbasic/WlanBasic.asp", Fixtures.gnmtnWlanBasic())
        transport.on("/logout.cgi", "")

        let suiteName = "WlanBasicTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let keychain = InMemoryPasswordStore()
        let settings = SettingsStore(defaults: defaults, passwordStore: keychain)
        var profile = RouterProfile.mtnTemplate()
        profile.host = "192.168.100.1"
        settings.addProfile(profile, password: "router-login-pw")

        let vm = MonitorViewModel(settings: settings, transport: transport)
        let network = WifiNetwork(ssidIndex: 2, name: "Example-SSID", band: "5GHz", enabled: true)
        let config = try await vm.fetchWifiSsidConfig(for: network)

        XCTAssertEqual(config.psk, "pass-word;1")
        let leaksInDefaults = defaults.dictionaryRepresentation().values.compactMap { $0 as? String }.filter { $0.contains("pass-word;1") }
        XCTAssertTrue(leaksInDefaults.isEmpty)
        XCTAssertEqual(keychain.password(forAccount: profile.id.uuidString), "router-login-pw")

        await vm.logoutSession()
        XCTAssertTrue(vm.isLoggedOut)
        XCTAssertFalse(vm.isConnected)
        XCTAssertTrue(transport.paths().contains("/logout.cgi"))
    }
}
