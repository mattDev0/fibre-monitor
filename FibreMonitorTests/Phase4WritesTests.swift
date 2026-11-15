import XCTest
@testable import FibreMonitor

final class Phase4WritesTests: XCTestCase {

    // MARK: - #198 Device Rename

    func testValidateDeviceAliasBoundsAndPrintableRules() throws {
        XCTAssertEqual(try HuaweiOntClient.validateDeviceAlias("  Studio Mac  "), "Studio Mac")
        XCTAssertEqual(try HuaweiOntClient.validateDeviceAlias(String(repeating: "a", count: 64)).utf8.count, 64)

        for empty in ["", "   ", "\n\t "] {
            XCTAssertThrowsError(try HuaweiOntClient.validateDeviceAlias(empty)) { error in
                XCTAssertEqual(error as? OntError, .invalidDeviceAlias)
            }
        }

        XCTAssertThrowsError(try HuaweiOntClient.validateDeviceAlias(String(repeating: "a", count: 65))) { error in
            XCTAssertEqual(error as? OntError, .invalidDeviceAlias)
        }
        // Multi-byte UTF-8 > 64 bytes (17 x 4 = 68 bytes) must be rejected.
        XCTAssertThrowsError(try HuaweiOntClient.validateDeviceAlias(String(repeating: "😀", count: 17))) { error in
            XCTAssertEqual(error as? OntError, .invalidDeviceAlias)
        }
        for badChar in ["Bad\u{00}Name", "Line\nBreak", "Del\u{7F}Char"] {
            XCTAssertThrowsError(try HuaweiOntClient.validateDeviceAlias(badChar)) { error in
                XCTAssertEqual(error as? OntError, .invalidDeviceAlias)
            }
        }
    }

    func testRenameDevicePostsExactRequest198AndRefetchesDevices() async throws {
        let transport = FakeTransport()
        transport.on("/index.asp", Fixtures.indexPage)
        transport.on("/asp/GetRandCount.asp", Fixtures.token)
        transport.on("/html/ssmp/common/GetRandToken.asp", Fixtures.token)
        transport.on("/login.cgi", Fixtures.loginOk)
        transport.on("/html/bbsp/userdevinfo/set.cgi", "")
        transport.on("/html/amp/common/wlan_list.asp", Fixtures.gnmtnWlanList())
        transport.on("/html/bbsp/common/GetLanUserDevInfo.asp", Fixtures.gnmtnDevices)
        transport.on("/html/bbsp/common/GetLanUserDhcpInfo.asp", Fixtures.gnmtnDhcpInfo)

        let client = HuaweiOntClient(
            credentials: .init(host: "192.168.100.1", username: "admin", password: "secret"),
            transport: transport
        )
        let device = OntDevice(
            domain: "InternetGatewayDevice.LANDevice.1.X_HW_UserDev.2",
            mac: "02:00:5e:00:00:03",
            ip: "192.168.2.2",
            hostName: "Work-Laptop",
            routerAlias: "Laptop Alias",
            dhcpVendor: "MSFT 5.0",
            port: .wifi5(ssidIndex: 2),
            isOnline: true,
            connectedTime: "0:9",
            userSpecifiedDeviceType: "3"
        )

        let updated = try await client.renameDevice(device, alias: "  Studio Laptop  ")
        XCTAssertFalse(updated.isEmpty)

        let post = try XCTUnwrap(transport.requests.first { $0.path.hasPrefix("/html/bbsp/userdevinfo/set.cgi") })
        XCTAssertEqual(post.method, .post)
        XCTAssertFalse(post.ajax)
        XCTAssertEqual(
            post.path,
            "/html/bbsp/userdevinfo/set.cgi?x=InternetGatewayDevice.LANDevice.1.X_HW_UserDev.2&RequestFile=html/bbsp/userdevinfo/userdetdevinfo.asp"
        )
        XCTAssertEqual(post.form.map(\.0), ["x.UserDevAlias", "x.UserSpecifiedDeviceType", "x.X_HW_Token"])
        XCTAssertEqual(post.form.map(\.1), [
            "Studio Laptop",
            "3",
            "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0"
        ])
        XCTAssertTrue(transport.paths().contains("/html/bbsp/common/GetLanUserDevInfo.asp"))
    }

    func testRenameDeviceRejectsMissingDomainAndInvalidAlias() async {
        let transport = FakeTransport()
        let client = HuaweiOntClient(
            credentials: .init(host: "192.168.100.1", username: "admin", password: "secret"),
            transport: transport
        )
        let hostOnlyDevice = OntDevice(
            domain: "InternetGatewayDevice.LANDevice.1.Hosts.Host.1",
            mac: "02:00:5e:00:00:99",
            ip: "192.168.100.99",
            hostName: "Host",
            routerAlias: "",
            dhcpVendor: "",
            port: .lan(1),
            isOnline: true,
            connectedTime: "0:1"
        )

        do {
            _ = try await client.renameDevice(hostOnlyDevice, alias: "Valid")
            XCTFail("Expected rejection for non-UserDev domain")
        } catch let error as OntError {
            XCTAssertEqual(error, .badResponse("device record"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(transport.requests.isEmpty)

        let validDomainDevice = OntDevice(
            domain: "InternetGatewayDevice.LANDevice.1.X_HW_UserDev.1",
            mac: "02:00:5e:00:00:02",
            ip: "192.168.100.10",
            hostName: "",
            routerAlias: "",
            dhcpVendor: "",
            port: .wifi24(ssidIndex: 1),
            isOnline: true,
            connectedTime: "1:0"
        )
        do {
            _ = try await client.renameDevice(validDomainDevice, alias: "   ")
            XCTFail("Expected invalidDeviceAlias")
        } catch let error as OntError {
            XCTAssertEqual(error, .invalidDeviceAlias)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    // MARK: - Strict WlanBasic Parsing & #704 Wi-Fi Credential Edit

    func testMissingEditFieldsCatchesMaskedPasswordAndMissingRecords() {
        let validConfigs = HuaweiOntClient.parseWlanBasic(Fixtures.gnmtnWlanBasic())
        let c2 = validConfigs.first { $0.ssidIndex == 2 }!
        XCTAssertTrue(c2.missingEditFields.isEmpty)
        XCTAssertTrue(c2.authMode.isEditableWpa2Or3Psk)

        let masked = HuaweiOntClient.parseWlanBasic(Fixtures.gnmtnWlanBasic(passwordMask: true)).first { $0.ssidIndex == 2 }!
        XCTAssertTrue(masked.missingEditFields.contains("PreSharedKey"))

        let noWpsHtml = Fixtures.gnmtnWlanBasic().replacingOccurrences(of: "new stWpsPin(", with: "new stWpsDisabled(")
        let noWps = HuaweiOntClient.parseWlanBasic(noWpsHtml).first { $0.ssidIndex == 2 }!
        XCTAssertTrue(noWps.missingEditFields.contains("WPS parameters"))

        let noWifiHtml = Fixtures.gnmtnWlanBasic().replacingOccurrences(of: "new stWlanWifi(", with: "new stWlanWifiDisabled(")
        let noWifi = HuaweiOntClient.parseWlanBasic(noWifiHtml).first { $0.ssidIndex == 2 }!
        XCTAssertTrue(noWifi.missingEditFields.contains("w.Standard"))
    }

    func testValidateWifiCredentialsEnforcesSsidAndPassphraseRules() throws {
        try HuaweiOntClient.validateWifiCredentials(ssid: String(repeating: "S", count: 32), password: "12345678")
        try HuaweiOntClient.validateWifiCredentials(ssid: "My Home Wi-Fi", password: String(repeating: "A", count: 63))

        for badSsid in ["", "   ", String(repeating: "S", count: 33), String(repeating: "🔥", count: 9), "Bad\nSSID"] {
            XCTAssertThrowsError(try HuaweiOntClient.validateWifiCredentials(ssid: badSsid, password: "validpass1")) { err in
                XCTAssertEqual(err as? OntError, .invalidWifiSsid)
            }
        }

        for badPwd in ["1234567", String(repeating: "P", count: 64), "passwörd1", "bad\tpass1"] {
            XCTAssertThrowsError(try HuaweiOntClient.validateWifiCredentials(ssid: "ValidSSID", password: badPwd)) { err in
                XCTAssertEqual(err as? OntError, .invalidWifiPassword)
            }
        }
    }

    func testWifiEditRequestBuildsExact704PayloadUsingParsedValuesNotConstants() throws {
        // Use non-capture values on WLANConfiguration.3 to verify every preserved field comes from parsed WlanBasic.asp.
        let customWlanBasic = """
        <!DOCTYPE html><html><head><script>
        var wifiPasswordMask='0';
        var kppUsedFlag='0';
        function stWlan(domain,name,enable,ssid,wlHide,DeviceNum,wmmEnable,BeaconType,BasicEncryptionModes,BasicAuthenticationMode,KeyIndex,EncryptionLevel,WPAEncryptionModes,WPAAuthenticationMode,IEEE11iEncryptionModes,IEEE11iAuthenticationMode,X_HW_WPAand11iEncryptionModes,X_HW_WPAand11iAuthenticationMode,WPARekey,RadiusServer,RadiusPort,RadiusKey,X_HW_ServiceEnable,LowerLayers,X_HW_WAPIEncryptionModes,X_HW_WAPIAuthenticationMode,X_HW_WAPIServer,X_HW_WAPIPort,X_HW_WPSConfigurated,UAPSDEnable,IsolationEnable) { this.domain = domain; }
        function stPreSharedKey(domain, psk, kpp) { this.domain = domain; }
        function stWpsPin(domain, X_HW_ConfigMethod, DevicePassword, X_HW_PinGenerator, Enable) { this.domain = domain; }
        function stWlanWifi(domain,name,enable,ssid,mode,channel,power,Country,AutoChannelEnable,channelWidth) { this.domain = domain; }
        var WlanWifiArr = new Array(new stWlanWifi("InternetGatewayDevice\\x2eLANDevice\\x2e1\\x2eWLANConfiguration\\x2e3","ath3","1","OldHome","11ac","36","80","NG","0","2"),null);
        var WlanArr = new Array(new stWlan("InternetGatewayDevice\\x2eLANDevice\\x2e1\\x2eWLANConfiguration\\x2e3","ath3","1","OldHome","0","16","0","11i","None","None","2","64\\x2dbit","TKIPEncryption","PSKAuthentication","AESEncryption","PSKAuthentication","AESEncryption","PSKAuthentication","7200","","1812","KEY99","1","InternetGatewayDevice\\x2eLANDevice\\x2e1\\x2eWiFi\\x2eRadio\\x2e2","SMS4","WAPIPSK","","3810","2","0","0"),null);
        var wpaPskKey = new Array(new stPreSharedKey("InternetGatewayDevice\\x2eLANDevice\\x2e1\\x2eWLANConfiguration\\x2e3\\x2ePreSharedKey\\x2e1","OldSecret99",""),null);
        var wpsPinNum = new Array(new stWpsPin("InternetGatewayDevice\\x2eLANDevice\\x2e1\\x2eWLANConfiguration\\x2e3\\x2eWPS","PushButton","87654321","STA","1"),null);
        </script></head></html>
        """

        let cfg = try XCTUnwrap(HuaweiOntClient.parseWlanBasic(customWlanBasic).first)
        let req = try HuaweiOntClient.wifiEditRequest(
            config: cfg,
            newSsid: "NewHome5G",
            newPassword: "NewSecret!42",
            token: "tok704"
        )

        XCTAssertEqual(req.method, .post)
        XCTAssertFalse(req.ajax)
        XCTAssertEqual(
            req.path,
            "/html/amp/wlanbasic/set.cgi"
                + "?c1=InternetGatewayDevice.X_HW_DEBUG.WLANConfigAction"
                + "&w=InternetGatewayDevice.X_HW_DEBUG.AMP.WifiCoverSetWlanBasic"
                + "&y=InternetGatewayDevice.LANDevice.1.WLANConfiguration.3"
                + "&z=InternetGatewayDevice.LANDevice.1.WLANConfiguration.3.WPS"
                + "&k=InternetGatewayDevice.LANDevice.1.WLANConfiguration.3.PreSharedKey.1"
                + "&c2=InternetGatewayDevice.X_HW_DEBUG.WLANConfigAction"
                + "&RequestFile=html/amp/wlanbasic/WlanBasic.asp"
        )

        let expectedKeys = [
            "y.Enable", "y.SSIDAdvertisementEnabled", "y.SSID", "y.X_HW_AssociateNum",
            "y.BeaconType", "y.IEEE11iAuthenticationMode", "y.IEEE11iEncryptionModes",
            "k.PreSharedKey", "y.X_HW_GroupRekey",
            "z.Enable", "z.X_HW_ConfigMethod", "z.X_HW_PinGenerator", "z.DevicePassword",
            "w.SsidInst", "w.SSID", "w.Enable", "w.Standard",
            "w.BasicAuthenticationMode", "w.BasicEncryptionModes",
            "w.WPAAuthenticationMode", "w.WPAEncryptionModes",
            "w.IEEE11iAuthenticationMode", "w.IEEE11iEncryptionModes",
            "w.MixAuthenticationMode", "w.MixEncryptionModes",
            "w.SSIDAdvertisementEnabled", "w.WMMEnable", "w.MaxAssociateNum",
            "w.BeaconType", "w.WEPEncryptionLevel", "w.WEPKeyIndex", "w.Key",
            "c1.ActionType", "c2.ActionType", "c2.SSIDList", "x.X_HW_Token"
        ]
        XCTAssertEqual(req.form.count, 36)
        XCTAssertEqual(req.form.map(\.0), expectedKeys)

        let values = Dictionary(uniqueKeysWithValues: req.form)
        // User-edited fields (4 fields take the new user inputs: y.SSID, w.SSID, k.PreSharedKey, w.Key)
        XCTAssertNotEqual(cfg.psk, "NewSecret!42")
        XCTAssertEqual(values["y.SSID"], "NewHome5G")
        XCTAssertEqual(values["w.SSID"], "NewHome5G")
        XCTAssertEqual(values["k.PreSharedKey"], "NewSecret!42")
        XCTAssertEqual(values["w.Key"], "NewSecret!42")
        XCTAssertEqual(values["w.Key"], values["k.PreSharedKey"])
        // Non-capture parsed fields preserved dynamically
        XCTAssertEqual(values["y.SSIDAdvertisementEnabled"], "0")
        XCTAssertEqual(values["w.SSIDAdvertisementEnabled"], "0")
        XCTAssertEqual(values["y.X_HW_AssociateNum"], "16")
        XCTAssertEqual(values["w.MaxAssociateNum"], "16")
        XCTAssertEqual(values["w.WMMEnable"], "0")
        XCTAssertEqual(values["y.IEEE11iEncryptionModes"], "AESEncryption")
        XCTAssertEqual(values["w.IEEE11iEncryptionModes"], "AESEncryption")
        XCTAssertEqual(values["y.X_HW_GroupRekey"], "7200")
        XCTAssertEqual(values["z.Enable"], "1")
        XCTAssertEqual(values["z.X_HW_ConfigMethod"], "PushButton")
        XCTAssertEqual(values["z.X_HW_PinGenerator"], "STA")
        XCTAssertEqual(values["z.DevicePassword"], "87654321")
        XCTAssertEqual(values["w.SsidInst"], "3")
        XCTAssertEqual(values["c2.SSIDList"], "3")
        XCTAssertEqual(values["w.Standard"], "11ac")
        XCTAssertEqual(values["w.WEPEncryptionLevel"], "64-bit")
        XCTAssertEqual(values["w.WEPKeyIndex"], "2")
        XCTAssertEqual(values["x.X_HW_Token"], "tok704")
    }

    func testWifiEditRequestRefusesWpa3Wpa2Wpa3WpaWpa2OpenAndMasked() throws {
        let wpa3Html = Fixtures.gnmtnWlanBasic().replacingOccurrences(
            of: #""11i","None","None","1","104\x2dbit","TKIPEncryption","PSKAuthentication","TKIPandAESEncryption","PSKAuthentication","TKIPandAESEncryption","PSKAuthentication""#,
            with: #""WPA3","None","None","1","104\x2dbit","TKIPEncryption","EAPAuthentication","AESEncryption","EAPAuthentication","AESEncryption","SAEAuthentication""#
        )
        let wpa3Cfg = try XCTUnwrap(HuaweiOntClient.parseWlanBasic(wpa3Html).first { $0.ssidIndex == 2 })
        XCTAssertEqual(wpa3Cfg.authMode, .wpa3Psk)
        XCTAssertFalse(wpa3Cfg.authMode.isEditableWpa2Or3Psk)
        XCTAssertThrowsError(try HuaweiOntClient.wifiEditRequest(config: wpa3Cfg, newSsid: "Wpa3Net", newPassword: "StrongPassword1", token: "tok3")) { err in
            XCTAssertEqual(err as? OntError, .unsupportedWifiSecurity("WPA3-SAE"))
            XCTAssertEqual(err.localizedDescription, "This network uses WPA3-SAE. Change it in the router's web page.")
        }

        let wpa23Html = Fixtures.gnmtnWlanBasic().replacingOccurrences(
            of: #""11i","None","None","1","104\x2dbit","TKIPEncryption","PSKAuthentication","TKIPandAESEncryption","PSKAuthentication","TKIPandAESEncryption","PSKAuthentication""#,
            with: #""WPA2/WPA3","None","None","1","104\x2dbit","TKIPEncryption","EAPAuthentication","AESEncryption","EAPAuthentication","AESEncryption","PSKandSAEAuthentication""#
        )
        let wpa23Cfg = try XCTUnwrap(HuaweiOntClient.parseWlanBasic(wpa23Html).first { $0.ssidIndex == 2 })
        XCTAssertEqual(wpa23Cfg.authMode, .wpa2Wpa3Psk)
        XCTAssertFalse(wpa23Cfg.authMode.isEditableWpa2Or3Psk)
        XCTAssertThrowsError(try HuaweiOntClient.wifiEditRequest(config: wpa23Cfg, newSsid: "Wpa23Net", newPassword: "StrongPassword1", token: "tok4")) { err in
            XCTAssertEqual(err as? OntError, .unsupportedWifiSecurity("WPA2/WPA3-PSK"))
            XCTAssertEqual(err.localizedDescription, "This network uses WPA2/WPA3-PSK. Change it in the router's web page.")
        }

        let all = HuaweiOntClient.parseWlanBasic(Fixtures.gnmtnWlanBasic())
        let c1WpaWpa2 = try XCTUnwrap(all.first { $0.ssidIndex == 1 })
        XCTAssertThrowsError(try HuaweiOntClient.wifiEditRequest(config: c1WpaWpa2, newSsid: "X", newPassword: "Password123", token: "t")) { err in
            XCTAssertEqual(err as? OntError, .unsupportedWifiSecurity("WPA/WPA2-PSK"))
        }

        let c5Open = try XCTUnwrap(all.first { $0.ssidIndex == 5 })
        XCTAssertThrowsError(try HuaweiOntClient.wifiEditRequest(config: c5Open, newSsid: "X", newPassword: "Password123", token: "t")) { err in
            XCTAssertEqual(err as? OntError, .unsupportedWifiSecurity(WifiAuthMode.open.displayName))
        }

        let masked = try XCTUnwrap(HuaweiOntClient.parseWlanBasic(Fixtures.gnmtnWlanBasic(passwordMask: true)).first { $0.ssidIndex == 2 })
        XCTAssertThrowsError(try HuaweiOntClient.wifiEditRequest(config: masked, newSsid: "X", newPassword: "Password123", token: "t")) { err in
            guard case .incompleteWifiConfig(let missing) = err as? OntError else {
                return XCTFail("Expected incompleteWifiConfig, got \(err)")
            }
            XCTAssertTrue(missing.contains("PreSharedKey"))
        }
    }

    func testUpdateWifiCredentialsHandlesExpectedDropAndSuccess() async throws {
        let cfg = try XCTUnwrap(HuaweiOntClient.parseWlanBasic(Fixtures.gnmtnWlanBasic()).first { $0.ssidIndex == 2 })

        // Case A: connection drops immediately on #704 POST (iPhone was on that Wi-Fi).
        let dropping = DropOnPathTransport(dropPrefix: "/html/amp/wlanbasic/set.cgi")
        dropping.on("/index.asp", Fixtures.indexPage)
        dropping.on("/asp/GetRandCount.asp", Fixtures.token)
        dropping.on("/html/ssmp/common/GetRandToken.asp", Fixtures.token)
        dropping.on("/login.cgi", Fixtures.loginOk)

        let dropClient = HuaweiOntClient(
            credentials: .init(host: "192.168.100.1", username: "admin", password: "secret"),
            transport: dropping
        )
        let dropResult = try await dropClient.updateWifiCredentials(
            config: cfg,
            newSsid: "Renamed5G",
            newPassword: "NewPassword!9"
        )
        XCTAssertTrue(dropResult.connectionDropped)
        XCTAssertNil(dropResult.wifi)

        // Case B: #704 succeeds and wlan_list.asp re-fetches cleanly.
        let succeeding = FakeTransport()
        succeeding.on("/index.asp", Fixtures.indexPage)
        succeeding.on("/asp/GetRandCount.asp", Fixtures.token)
        succeeding.on("/html/ssmp/common/GetRandToken.asp", Fixtures.token)
        succeeding.on("/login.cgi", Fixtures.loginOk)
        succeeding.on("/html/amp/wlanbasic/set.cgi", "")
        succeeding.on("/html/amp/common/wlan_list.asp", Fixtures.gnmtnWlanList())

        let okClient = HuaweiOntClient(
            credentials: .init(host: "192.168.100.1", username: "admin", password: "secret"),
            transport: succeeding
        )
        let okResult = try await okClient.updateWifiCredentials(
            config: cfg,
            newSsid: "Renamed5G",
            newPassword: "NewPassword!9"
        )
        XCTAssertFalse(okResult.connectionDropped)
        XCTAssertNotNil(okResult.wifi)
        XCTAssertTrue(succeeding.paths().contains("/html/amp/wlanbasic/set.cgi"))
    }

    // MARK: - ViewModel Phase 4 Writes & Radio Safety

    @MainActor
    func testMonitorViewModelRenameClearsLocalOverrideAndWifiDropMarksDisconnected() async throws {
        let transport = DropOnPathTransport(dropPrefix: "/html/amp/wlanbasic/set.cgi")
        transport.on("/index.asp", Fixtures.indexPage)
        transport.on("/asp/GetRandCount.asp", Fixtures.token)
        transport.on("/html/ssmp/common/GetRandToken.asp", Fixtures.token)
        transport.on("/login.cgi", Fixtures.loginOk)
        transport.on("/html/bbsp/userdevinfo/set.cgi", "")
        transport.on("/html/amp/common/wlan_list.asp", Fixtures.gnmtnWlanList())
        transport.on("/html/bbsp/common/GetLanUserDevInfo.asp", Fixtures.gnmtnDevices)
        transport.on("/html/bbsp/common/GetLanUserDhcpInfo.asp", Fixtures.gnmtnDhcpInfo)

        let suiteName = "Phase4WritesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults, passwordStore: InMemoryPasswordStore())
        settings.addProfile(RouterProfile.mtnTemplate(), password: "secret")
        settings.setAlias("Local Phone Nickname", for: "02:00:5e:00:00:03")
        XCTAssertNotNil(settings.alias(for: "02:00:5e:00:00:03"))

        let vm = MonitorViewModel(settings: settings, transport: transport)
        let device = OntDevice(
            domain: "InternetGatewayDevice.LANDevice.1.X_HW_UserDev.2",
            mac: "02:00:5e:00:00:03",
            ip: "192.168.2.2",
            hostName: "Work-Laptop",
            routerAlias: "Old",
            dhcpVendor: "",
            port: .wifi5(ssidIndex: 2),
            isOnline: true,
            connectedTime: "0:9",
            userSpecifiedDeviceType: "3"
        )
        try await vm.renameDeviceOnRouter(device, alias: "New Router Name")
        XCTAssertNil(settings.alias(for: "02:00:5e:00:00:03"))
        XCTAssertEqual(vm.devices.count, 3)

        let cfg = try XCTUnwrap(HuaweiOntClient.parseWlanBasic(Fixtures.gnmtnWlanBasic()).first { $0.ssidIndex == 2 })
        let updateResult = try await vm.updateWifiCredentials(config: cfg, newSsid: "DroppedSSID", newPassword: "NewPassword123")
        XCTAssertTrue(updateResult.connectionDropped)
        XCTAssertFalse(vm.isConnected)
        XCTAssertTrue(vm.isConnectionFailure)
        XCTAssertTrue(vm.actionMessage?.contains("Rejoin \"DroppedSSID\"") == true)
    }

    func testSetRadioRefusesLastEnabledRadio() async {
        let transport = FakeTransport()
        transport.on("/index.asp", Fixtures.indexPage)
        transport.on("/asp/GetRandCount.asp", Fixtures.token)
        transport.on("/html/ssmp/common/GetRandToken.asp", Fixtures.token)
        transport.on("/login.cgi", Fixtures.loginOk)
        transport.on("/html/amp/common/wlan_list.asp", Fixtures.gnmtnWlanList(radio1: true, radio2: false))

        let client = HuaweiOntClient(
            credentials: .init(host: "192.168.100.1", username: "admin", password: "secret"),
            transport: transport
        )
        do {
            _ = try await client.setRadio(1, enabled: false)
            XCTFail("Expected lastRadio error")
        } catch let error as OntError {
            XCTAssertEqual(error, .lastRadio)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(transport.paths().contains("/html/amp/wlanbasic/set.cgi"))
    }
}

private final class DropOnPathTransport: OntTransport, @unchecked Sendable {
    private let delegate = FakeTransport()
    private let dropPrefix: String

    init(dropPrefix: String) {
        self.dropPrefix = dropPrefix
    }

    func on(_ prefix: String, _ reply: String) {
        delegate.on(prefix, reply)
    }

    func send(_ request: OntRequest, host: String) async throws -> String {
        if request.path.hasPrefix(dropPrefix) {
            throw URLError(.networkConnectionLost)
        }
        return try await delegate.send(request, host: host)
    }

    func resetSession(host: String) async {
        await delegate.resetSession(host: host)
    }
}
