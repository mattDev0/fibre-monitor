import XCTest
@testable import FibreMonitor

final class HuaweiJsTests: XCTestCase {
    func testUnescapeHexAndStandardEscapes() {
        XCTAssertEqual(HuaweiJs.unescape("192\\x2e168\\x2e100\\x2e1"), "192.168.100.1")
        XCTAssertEqual(HuaweiJs.unescape("a\\\"b\\\\c\\n"), "a\"b\\c\n")
        XCTAssertEqual(HuaweiJs.unescape("\\u00e9t\\u00e9"), "été")
    }

    func testInstancesHandleCommasQuotesAndBareTokens() {
        let text = #"x = new Array(new Foo("a,b","c\"d", 12, null),new Foo('e',"f"),null);"#
        XCTAssertEqual(HuaweiJs.instances(of: "Foo", in: text), [["a,b", "c\"d", "12", "null"], ["e", "f"]])
    }

    func testInstancesDoNotMatchLongerConstructorNames() {
        let text = #"new USERDeviceNew("x"), new USERDevice("y")"#
        XCTAssertEqual(HuaweiJs.instances(of: "USERDevice", in: text), [["y"]])
    }

    func testRecordsUseInlineDefinition() {
        let text = #"function Pair(Left, Right) {} var l = new Array(new Pair("1","2"),null);"#
        XCTAssertEqual(HuaweiJs.records(of: "Pair", in: text), [["Left": "1", "Right": "2"]])
    }

    func testStringVar() {
        XCTAssertEqual(HuaweiJs.stringVar("opticInfo", in: Fixtures.smartDiagnose), "-18.25")
        XCTAssertEqual(HuaweiJs.stringVar("eponStatus", in: Fixtures.smartDiagnose), "")
        XCTAssertNil(HuaweiJs.stringVar("missing", in: Fixtures.smartDiagnose))
    }

    func testLooksLikeData() {
        XCTAssertTrue(HuaweiJs.looksLikeData(Fixtures.pppStats(sent: "1", received: "2")))
        XCTAssertTrue(HuaweiJs.looksLikeData(Fixtures.devices))
        XCTAssertFalse(HuaweiJs.looksLikeData(Fixtures.loginPage))
    }
}

final class ParsingTests: XCTestCase {
    func testWanParsing() {
        let wan = HuaweiOntClient.parseWan(Fixtures.wanList)
        XCTAssertEqual(wan.connectionStatus, "Connected")
        XCTAssertTrue(wan.isConnected)
        XCTAssertEqual(wan.connectionType, "PPPoE")
        XCTAssertEqual(wan.ipAddress, "10.20.30.40")
        XCTAssertTrue(wan.isCarrierNat)
        XCTAssertEqual(wan.gateway, "10.20.0.1")
        XCTAssertEqual(wan.dnsServers, ["203.0.113.1", "203.0.113.2"])
        XCTAssertEqual(wan.vlanId, "10")
        XCTAssertEqual(wan.uptimeSeconds, 93784)
    }

    func testOpticalParsing() {
        var info = HuaweiOntClient.parseSmartDiagnose(Fixtures.smartDiagnose)
        XCTAssertEqual(info.rxPowerDbm, -18.25)
        XCTAssertTrue(info.isRegistered)
        XCTAssertEqual(info.rxQuality, .good)
        HuaweiOntClient.mergeOpticTxRx(Fixtures.opticTxRx, into: &info)
        XCTAssertEqual(info.txPowerDbm, 2.31)
        XCTAssertEqual(info.rxPowerDbm, -18.30)
        XCTAssertEqual(info.temperatureC, 47)
    }

    func testRxQualityBands() {
        func q(_ v: Double?) -> OpticalInfo.Quality { OpticalInfo(rxPowerDbm: v).rxQuality }
        XCTAssertEqual(q(-5), .tooStrong)
        XCTAssertEqual(q(-15.7), .good)
        XCTAssertEqual(q(-25.5), .weak)
        XCTAssertEqual(q(-29), .bad)
        XCTAssertEqual(q(nil), .unknown)
    }

    func testDeviceParsing() {
        let devices = HuaweiOntClient.parseDevices(Fixtures.devices)
        XCTAssertEqual(devices.count, 3, "duplicates across lists are dropped")
        XCTAssertEqual(devices.filter(\.isOnline).count, 2)
        XCTAssertFalse(devices.last!.isOnline, "offline devices sort last")

        let tv = devices.first { $0.mac == "aa:bb:cc:00:00:02" }!
        XCTAssertEqual(tv.displayName, "Living-Room-TV")
        XCTAssertEqual(tv.port, .wifi5(ssidIndex: 5))
        XCTAssertEqual(tv.connectedText, "1d 2h")

        let phone = devices.first { $0.mac == "aa:bb:cc:00:00:01" }!
        XCTAssertEqual(phone.displayName, "Android device")
        XCTAssertEqual(phone.port.label, "2.4 GHz")
        XCTAssertEqual(phone.connectedText, "1h 5m")

        let pc = devices.first { $0.mac == "aa:bb:cc:00:00:03" }!
        XCTAssertEqual(pc.displayName, "Office PC", "router-side alias wins over host name")
        XCTAssertEqual(pc.port.label, "LAN 2")
    }

    func testCounterDeltaHandlesWrapAndReset() {
        XCTAssertEqual(HuaweiOntClient.delta(previous: 100, current: 350), 250)
        let max32 = UInt64(UInt32.max)
        XCTAssertEqual(HuaweiOntClient.delta(previous: max32 - 99, current: 50), 150)
        XCTAssertNil(HuaweiOntClient.delta(previous: 1_000, current: 10), "small counter going back is a reset")
    }

    func testHighLowCountersPreferred() {
        let r = ["BytesReceived": "5", "BytesSent": "6",
                 "BytesReceivedHigh": "1", "BytesReceivedLow": "2", "BytesSentHigh": "0", "BytesSentLow": "7"]
        let c = HuaweiOntClient.counters(from: r)!
        XCTAssertEqual(c.rx, (1 << 32) | 2)
        XCTAssertEqual(c.tx, 7)
    }
}

final class SessionTests: XCTestCase {
    private let creds = HuaweiOntClient.Credentials(host: "192.168.100.1", username: "root", password: "p@ss+word")

    private func router() -> FakeTransport {
        let t = FakeTransport()
        t.on("/asp/GetRandCount.asp", Fixtures.token)
        t.on("/login.cgi", Fixtures.loginOk)
        t.on("/index.asp", "<html></html>")
        t.on("/html/ssmp/common/GetRandToken.asp", Fixtures.token)
        return t
    }

    func testLoginPostsBase64PasswordAndToken() async throws {
        let t = router()
        let client = HuaweiOntClient(credentials: creds, transport: t)
        try await client.login()

        let login = t.requests.first { $0.path == "/login.cgi" }!
        let fields = Dictionary(uniqueKeysWithValues: login.form)
        XCTAssertEqual(fields["UserName"], "root")
        XCTAssertEqual(fields["PassWord"], Data("p@ss+word".utf8).base64EncodedString())
        XCTAssertEqual(fields["x.X_HW_Token"], HuaweiJs.clean(Fixtures.token), "BOM stripped from token")
        XCTAssertEqual(fields["Language"], "english")
        XCTAssertTrue(login.encodedForm.contains("PassWord=cEBzcyt3b3Jk"), login.encodedForm)
        XCTAssertEqual(t.resets, 1)
    }

    func testRejectedLoginIsNotRetried() async {
        let t = router()
        t.on("/login.cgi", Fixtures.loginPage)
        let client = HuaweiOntClient(credentials: creds, transport: t)

        do { _ = try await client.pollTraffic(); XCTFail("expected rejection") } catch {
            XCTAssertEqual(error as? OntError, .loginRejected)
        }
        do { _ = try await client.pollTraffic(); XCTFail("expected rejection") } catch {
            XCTAssertEqual(error as? OntError, .loginRejected)
        }
        XCTAssertEqual(t.paths().filter { $0 == "/login.cgi" }.count, 1, "second poll must not try the password again")

        // New credentials clear the block.
        t.on("/login.cgi", Fixtures.loginOk)
        t.on("/html/bbsp/common/get_wan_list_pppwanstat.asp", Fixtures.pppStats(sent: "1", received: "2"))
        await client.update(credentials: .init(host: creds.host, username: "root", password: "new"))
        _ = try? await client.pollTraffic()
        XCTAssertEqual(t.paths().filter { $0 == "/login.cgi" }.count, 2)
    }

    func testExpiredSessionLogsInOnceAndRetries() async throws {
        let t = router()
        t.on("/html/bbsp/common/get_wan_list_pppwanstat.asp",
             Fixtures.pppStats(sent: "1000", received: "2000"),
             Fixtures.loginPage,
             Fixtures.pppStats(sent: "1000", received: "2000"))
        let client = HuaweiOntClient(credentials: creds, transport: t)
        _ = try await client.pollTraffic()
        _ = try await client.pollTraffic()
        XCTAssertEqual(t.paths().filter { $0 == "/login.cgi" }.count, 2)
    }

    func testTrafficSpeedFromCounterDelta() async throws {
        let t = router()
        t.on("/html/bbsp/common/get_wan_list_pppwanstat.asp",
             Fixtures.pppStats(sent: "1000", received: "0"),
             Fixtures.pppStats(sent: "251000", received: "2500000"))
        let client = HuaweiOntClient(credentials: creds, transport: t)
        let start = Date()
        let first = try await client.pollTraffic(now: start)
        XCTAssertEqual(first.downloadMbps, 0)
        let second = try await client.pollTraffic(now: start.addingTimeInterval(2))
        XCTAssertEqual(second.downloadMbps, 10, accuracy: 0.0001)   // 2.5 MB in 2 s
        XCTAssertEqual(second.uploadMbps, 1, accuracy: 0.0001)      // 250 kB in 2 s
        XCTAssertEqual(second.history.count, 1)
    }

    func testRebootAndLogoutUseFreshToken() async throws {
        let t = router()
        t.on("/CustomApp/set.cgi", "")
        t.on("/logout.cgi", "")
        let client = HuaweiOntClient(credentials: creds, transport: t)
        try await client.reboot()
        let reboot = t.requests.first { $0.path.hasPrefix("/CustomApp/set.cgi") }!
        XCTAssertTrue(reboot.path.contains("X_HW_DEBUG.SMP.DM.ResetBoard"))
        XCTAssertEqual(reboot.form.first?.0, "x.X_HW_Token")

        try await client.login()
        await client.logout()
        XCTAssertTrue(t.paths().contains("/logout.cgi"))
    }
}

final class RouterPagesTests: XCTestCase {
    private let creds = HuaweiOntClient.Credentials(host: "192.168.100.1", username: "root", password: "pw")

    private func router() -> FakeTransport {
        let t = FakeTransport()
        t.on("/asp/GetRandCount.asp", Fixtures.token)
        t.on("/login.cgi", Fixtures.loginOk)
        t.on("/index.asp", "<html></html>")
        t.on("/html/ssmp/common/GetRandToken.asp", Fixtures.token)
        return t
    }

    func testHealthParsing() {
        let h = HuaweiOntClient.parseHealth(Fixtures.deviceInfoPage)
        XCTAssertEqual(h.cpuPercent, 23)
        XCTAssertEqual(h.memoryPercent, 61)
        XCTAssertEqual(h.uptimeSeconds, 90061)
        XCTAssertEqual(h.model, "HG8145X6-10")
        XCTAssertEqual(h.firmware, "V5R000C00S100")
        XCTAssertEqual(h.hardware, "1A2B.C")
    }

    func testWifiParsingDedupesRadiosAndSkipsTemplate() {
        let w = HuaweiOntClient.parseWifi(Fixtures.wlanList(radio1: true, radio2: false))
        XCTAssertEqual(w.radios, [WifiRadio(index: 1, band: "2.4GHz", enabled: true),
                                  WifiRadio(index: 2, band: "5GHz", enabled: false)])
        XCTAssertEqual(w.networks.map(\.ssidIndex), [1, 2, 5])
        XCTAssertEqual(w.networks(on: w.radios[1]).map(\.name), ["Test Fast", "Test Extra"])
    }

    func testDeviceBandComesFromWifiList() {
        // SSID2 is a 5 GHz network on this router, which the old SSID1-4 rule got wrong.
        let text = """
        function USERDevice(Domain,IpAddr,MacAddr,Port,IpType,DevType,DevStatus,PortType,Time,HostName) { }
        var l = new Array(new USERDevice("d","192\\x2e168\\x2e100\\x2e9","aa\\x3abb\\x3acc\\x3a00\\x3a00\\x3a09","SSID2","DHCP","","Online","WIFI","0\\x3a5","Phone"),null);
        """
        XCTAssertEqual(HuaweiOntClient.parseDevices(text).first?.port, .wifi24(ssidIndex: 2))
        XCTAssertEqual(HuaweiOntClient.parseDevices(text, ssidBands: [2: "5GHz"]).first?.port, .wifi5(ssidIndex: 2))
    }

    func testLanParsing() {
        let lan = HuaweiOntClient.parseLan(Fixtures.dhcpPage)
        XCTAssertEqual(lan.routerIp, "192.168.100.1")
        XCTAssertEqual(lan.subnetMask, "255.255.255.0")
        XCTAssertTrue(lan.dhcpEnabled)
        XCTAssertEqual(lan.poolStart, "192.168.100.2")
        XCTAssertEqual(lan.poolEnd, "192.168.100.254")
        XCTAssertEqual(lan.leaseSeconds, 86400)
        XCTAssertEqual(lan.dnsServers, [])
    }

    func testRadioToggleSendsWebFormAndConfirms() async throws {
        let t = router()
        t.on("/html/amp/common/wlan_list.asp", Fixtures.wlanList(radio1: true, radio2: true), Fixtures.wlanList(radio1: true, radio2: false))
        t.on("/html/amp/wlanbasic/set.cgi", "")
        let client = HuaweiOntClient(credentials: creds, transport: t)
        let after = try await client.setRadio(2, enabled: false)
        XCTAssertEqual(after.radios.first { $0.index == 2 }?.enabled, false)

        let set = t.requests.first { $0.path.hasPrefix("/html/amp/wlanbasic/set.cgi") }!
        XCTAssertTrue(set.path.contains("y=InternetGatewayDevice.LANDevice.1.WiFi.Radio.2"))
        XCTAssertTrue(set.path.contains("x=InternetGatewayDevice.X_HW_DEBUG.AMP.SetWifiCoverEnable"))
        XCTAssertEqual(set.form.map { $0.0 }, ["x.Enable", "x.RadioInst", "y.Enable", "x.X_HW_Token"])
        XCTAssertEqual(set.form.map { $0.1 }.prefix(3), ["0", "2", "0"])
    }

    func testRefusesToTurnOffTheLastRadio() async {
        let t = router()
        t.on("/html/amp/common/wlan_list.asp", Fixtures.wlanList(radio1: false, radio2: true))
        let client = HuaweiOntClient(credentials: creds, transport: t)
        do {
            _ = try await client.setRadio(2, enabled: false)
            XCTFail("expected refusal")
        } catch {
            XCTAssertEqual(error as? OntError, .lastRadio)
        }
        XCTAssertFalse(t.paths().contains("/html/amp/wlanbasic/set.cgi"))
    }

    func testExpiredSessionOnHtmlPageTriggersRelogin() async throws {
        let t = router()
        t.on("/html/ssmp/deviceinfo/deviceinfo.asp", Fixtures.loginPage, Fixtures.deviceInfoPage)
        let client = HuaweiOntClient(credentials: creds, transport: t)
        let h = try await client.fetchHealth()
        XCTAssertEqual(h.cpuPercent, 23)
        XCTAssertEqual(t.paths().filter { $0 == "/login.cgi" }.count, 2)
    }
}

final class DiagnosticsAndDeleteTests: XCTestCase {
    private let creds = HuaweiOntClient.Credentials(host: "192.168.100.1", username: "root", password: "pw")

    private func router() -> FakeTransport {
        let t = FakeTransport()
        t.on("/asp/GetRandCount.asp", Fixtures.token)
        t.on("/login.cgi", Fixtures.loginOk)
        t.on("/index.asp", "<html></html>")
        t.on("/html/ssmp/common/GetRandToken.asp", Fixtures.token)
        t.on("/html/bbsp/common/getwanlist.asp", Fixtures.wanList)
        t.on("/html/bbsp/maintenance/complex.cgi", "<html>diagnose page</html>")
        return t
    }

    func testPingOutputFormats() {
        let running = DiagnosticOutput.parse(#"function() {\n  return "PING 8.8.8.8 (8.8.8.8): 56 data bytes\n" + "64 bytes from 8.8.8.8: seq=0 ttl=112 time=15.6 ms\n";\n}"#)
        XCTAssertFalse(running.isFinished)
        XCTAssertTrue(running.text.contains("seq=0"))

        let done = DiagnosticOutput.parse(#"function() {\n  return "PING 8.8.8.8\n" + "--- 8.8.8.8 ping statistics ---\n" + "4 packets transmitted, 4 packets received, 0% packet loss\n" + "[@#@]Complete";\n}"#)
        XCTAssertEqual(done.status, "Complete")
        XCTAssertTrue(done.text.hasSuffix("0% packet loss\n"))
        XCTAssertFalse(done.text.contains("[@#@]"))

        let trace = DiagnosticOutput.parse(#""traceroute to 96.0.47.217, 30 hops max\n" + " 1  *  *  *\n" + "[@#@]Error_MaxHopCountExceeded";"#)
        XCTAssertEqual(trace.status, "Error_MaxHopCountExceeded")
        XCTAssertTrue(trace.text.hasPrefix("traceroute to 96.0.47.217"))
    }

    func testStartPingPostsDiagnosticsFormOnTheWanInterface() async throws {
        let t = router()
        let client = HuaweiOntClient(credentials: creds, transport: t)
        try await client.startPing(host: " 8.8.8.8 ", count: 4)
        let req = t.requests.first { $0.path.hasPrefix("/html/bbsp/maintenance/complex.cgi") }!
        XCTAssertTrue(req.path.contains("x=InternetGatewayDevice.IPPingDiagnostics"))
        XCTAssertTrue(req.path.contains("RUNSTATE_FLAG=Ping"))
        let f = Dictionary(uniqueKeysWithValues: req.form)
        XCTAssertEqual(f["x.Host"], "8.8.8.8")
        XCTAssertEqual(f["x.NumberOfRepetitions"], "4")
        XCTAssertEqual(f["x.DiagnosticsState"], "Requested")
        XCTAssertEqual(f["x.Interface"], "InternetGatewayDevice.WANDevice.1.WANConnectionDevice.1.WANPPPConnection.1")
        XCTAssertEqual(f["RUNSTATE_FLAG.value"], "START")
        XCTAssertEqual(req.form.last?.0, "x.X_HW_Token")
    }

    func testStartTraceUsesTracerouteDiagnostics() async throws {
        let t = router()
        let client = HuaweiOntClient(credentials: creds, transport: t)
        try await client.startTrace(host: "google.com")
        let req = t.requests.first { $0.path.hasPrefix("/html/bbsp/maintenance/complex.cgi") }!
        XCTAssertTrue(req.path.contains("x=InternetGatewayDevice.TraceRouteDiagnostics"))
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: req.form)["x.Host"], "google.com")
    }

    func testInvalidHostNeverReachesRouter() async {
        let t = router()
        let client = HuaweiOntClient(credentials: creds, transport: t)
        for bad in ["", "8.8.8.8; reboot", "a b"] {
            do { try await client.startPing(host: bad); XCTFail("accepted \(bad)") } catch {
                XCTAssertEqual(error as? OntError, .invalidHost)
            }
        }
        XCTAssertFalse(t.paths().contains("/html/bbsp/maintenance/complex.cgi"))
    }

    func testDeleteOnlyOfflineDevicesAndConfirm() async throws {
        let t = router()
        let remaining = Fixtures.devices.replacingOccurrences(of: "X_HW_UserDev.3", with: "X_HW_UserDev.3-gone")
            .replacingOccurrences(of: "aa\\x3abb\\x3acc\\x3a00\\x3a00\\x3a03", with: "aa\\x3abb\\x3acc\\x3a00\\x3a00\\x3a99")
        t.on("/html/bbsp/common/GetLanUserDevInfo.asp", Fixtures.devices, remaining)
        t.on("/html/bbsp/userdevinfo/del.cgi", "")
        let client = HuaweiOntClient(credentials: creds, transport: t)
        let devices = try await client.fetchDevices()

        let online = devices.first { $0.isOnline }!
        do { _ = try await client.deleteDevice(online); XCTFail("deleted an online device") } catch {
            XCTAssertEqual(error as? OntError, .deviceOnline)
        }

        let offline = devices.first { !$0.isOnline }!
        XCTAssertEqual(offline.domain, "InternetGatewayDevice.LANDevice.1.X_HW_UserDev.3")
        let after = try await client.deleteDevice(offline)
        XCTAssertFalse(after.contains { $0.mac == offline.mac })
        let del = t.requests.first { $0.path.hasPrefix("/html/bbsp/userdevinfo/del.cgi") }!
        XCTAssertTrue(del.path.contains("x=InternetGatewayDevice.LANDevice.1.X_HW_UserDev"))
        XCTAssertEqual(del.form.first?.0, "InternetGatewayDevice.LANDevice.1.X_HW_UserDev.3")
        XCTAssertEqual(del.form.first?.1, "")
        XCTAssertEqual(t.paths().filter { $0 == "/html/bbsp/userdevinfo/del.cgi" }.count, 1)
    }
}

