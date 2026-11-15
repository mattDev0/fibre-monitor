import XCTest
@testable import FibreMonitor

final class GnmtnCompatibilityTests: XCTestCase {
    private let creds = HuaweiOntClient.Credentials(host: "192.168.2.1", username: "root", password: "pw")

    private func router() -> FakeTransport {
        let t = FakeTransport()
        t.on("/asp/GetRandCount.asp", Fixtures.token)
        t.on("/login.cgi", Fixtures.loginOk)
        t.on("/index.asp", Fixtures.indexPage)
        t.on("/html/ssmp/common/GetRandToken.asp", Fixtures.token)
        return t
    }

    func testGnmtnPppWanListWithoutConstructorDefinition() {
        let wan = HuaweiOntClient.parseWan(Fixtures.gnmtnWanList)
        XCTAssertEqual(wan.domain, "InternetGatewayDevice.WANDevice.1.WANConnectionDevice.1.WANPPPConnection.1")
        XCTAssertEqual(wan.name, "ACS_HSI")
        XCTAssertEqual(wan.connectionStatus, "Connected")
        XCTAssertTrue(wan.isConnected)
        XCTAssertEqual(wan.connectionType, "PPPoE")
        XCTAssertEqual(wan.ipAddress, "10.0.0.2")
        XCTAssertTrue(wan.isCarrierNat)
        XCTAssertEqual(wan.gateway, "10.0.0.3")
        XCTAssertEqual(wan.dnsServers, ["203.0.113.4", "203.0.113.5"])
        XCTAssertEqual(wan.vlanId, "10")
        XCTAssertEqual(wan.uptimeSeconds, 283901)
        XCTAssertEqual(wan.lastError, "ERROR_NONE")
    }

    func testGnmtnPppWanStat11ArgTrafficCounters() async throws {
        let t = router()
        t.on("/html/bbsp/common/get_wan_list_pppwanstat.asp",
             Fixtures.gnmtnPppWanStat(sent: "1000", received: "2000"),
             Fixtures.gnmtnPppWanStat(sent: "251000", received: "2502000"))
        t.on("/html/bbsp/common/get_wan_list_ipwanstat.asp", Fixtures.gnmtnIpWanStatEmpty)

        let client = HuaweiOntClient(credentials: creds, transport: t)
        let start = Date()
        let first = try await client.pollTraffic(now: start)
        XCTAssertEqual(first.downloadMbps, 0)
        let second = try await client.pollTraffic(now: start.addingTimeInterval(2))
        XCTAssertEqual(second.downloadMbps, 10, accuracy: 0.0001)
        XCTAssertEqual(second.uploadMbps, 1, accuracy: 0.0001)
        XCTAssertFalse(t.paths().contains("/html/bbsp/common/get_wan_list_ipwanstat.asp"))
    }

    func testGnmtnSmartDiagnoseAndGracefulMissingOpticTxRx() async throws {
        let parsed = HuaweiOntClient.parseSmartDiagnose(Fixtures.gnmtnSmartDiagnose)
        XCTAssertEqual(parsed.rxPowerDbm, -15.93)
        XCTAssertEqual(parsed.ponMode, "gpon")
        XCTAssertEqual(parsed.registrationState, "O5")
        XCTAssertTrue(parsed.isRegistered)
        XCTAssertEqual(parsed.rxQuality, .good)

        let t = router()
        t.on("/html/amp/common/getSmartDiagnoseResult.asp", Fixtures.gnmtnSmartDiagnose)
        t.on("/html/ssmp/common/getOpticTxRx.asp", "<html><body>404 Not Found</body></html>")

        let client = HuaweiOntClient(credentials: creds, transport: t)
        let info = try await client.fetchOptical()
        XCTAssertEqual(info.rxPowerDbm, -15.93)
        XCTAssertNil(info.txPowerDbm)
        XCTAssertNil(info.temperatureC)
        XCTAssertEqual(t.paths().filter { $0 == "/login.cgi" }.count, 1)
    }

    func testGnmtnDevices18ArgAndUserDeviceNewDedupAndRates() {
        let devices = HuaweiOntClient.parseDevices(
            Fixtures.gnmtnDevices,
            ssidBands: [1: "2.4GHz", 2: "5GHz", 5: "5GHz"]
        )
        XCTAssertEqual(devices.count, 3, "USERDevice and USERDeviceNew with same MAC must deduplicate")

        let phone = devices.first { $0.mac == "02:00:5e:00:00:02" }!
        XCTAssertEqual(phone.port, .wifi24(ssidIndex: 1))
        XCTAssertEqual(phone.trafficSendRate, 12500)
        XCTAssertEqual(phone.trafficRecvRate, 240000)
        XCTAssertTrue(phone.hasTrafficRates)
        XCTAssertEqual(phone.leaseSecondsRemaining, 59531)

        let laptop = devices.first { $0.mac == "02:00:5e:00:00:03" }!
        XCTAssertEqual(laptop.port, .wifi5(ssidIndex: 2))
        XCTAssertEqual(laptop.routerAlias, "Laptop Alias")
        XCTAssertEqual(laptop.userSpecifiedDeviceType, "3")
        XCTAssertNil(laptop.trafficSendRate)
        XCTAssertNil(laptop.trafficRecvRate)
        XCTAssertFalse(laptop.hasTrafficRates)

        let tablet = devices.first { $0.mac == "02:00:5e:00:00:04" }!
        XCTAssertEqual(tablet.routerAlias, "", "-- placeholder alias should normalize to empty")
        XCTAssertEqual(tablet.displayName, "Tablet")
        XCTAssertFalse(tablet.isOnline)
    }

    func testUserDeviceNewOnlyParsing() {
        let devices = HuaweiOntClient.parseDevices(Fixtures.gnmtnDevicesNewOnly)
        XCTAssertEqual(devices.count, 1)
        let box = devices[0]
        XCTAssertEqual(box.mac, "02:00:5e:00:00:09")
        XCTAssertEqual(box.port, .lan(1))
        XCTAssertEqual(box.routerAlias, "Media Box")
        XCTAssertEqual(box.userSpecifiedDeviceType, "4")
        XCTAssertNil(box.trafficSendRate)
        XCTAssertNil(box.trafficRecvRate)
    }

    func testDhcpInfoEnrichmentAndGracefulFallback() async throws {
        let t = router()
        t.on("/html/bbsp/common/GetLanUserDevInfo.asp", Fixtures.gnmtnDevices)
        t.on("/html/bbsp/common/GetLanUserDhcpInfo.asp", Fixtures.gnmtnDhcpInfo)

        let client = HuaweiOntClient(credentials: creds, transport: t)
        let enriched = try await client.fetchDevices()
        let phone = enriched.first { $0.mac == "02:00:5e:00:00:02" }!
        XCTAssertEqual(phone.hostName, "Pixel-Phone")
        XCTAssertEqual(phone.displayName, "Pixel-Phone")

        // When GetLanUserDhcpInfo.asp is unavailable, fetchDevices still succeeds cleanly.
        t.on("/html/bbsp/common/GetLanUserDhcpInfo.asp", "<html><body>Not Found</body></html>")
        let plain = try await client.fetchDevices()
        XCTAssertEqual(plain.first { $0.mac == "02:00:5e:00:00:02" }?.hostName, "")
        XCTAssertEqual(t.paths().filter { $0 == "/login.cgi" }.count, 1)
    }

    func testGnmtnWlanListThreeSsidsAndDedupedRadios() {
        let w = HuaweiOntClient.parseWifi(Fixtures.gnmtnWlanList())
        XCTAssertEqual(w.radios, [
            WifiRadio(index: 1, band: "2.4GHz", enabled: true),
            WifiRadio(index: 2, band: "5GHz", enabled: true),
        ])
        XCTAssertEqual(w.networks.map(\.ssidIndex), [1, 2, 5])
        XCTAssertEqual(w.networks(on: w.radios[0]).map(\.name), ["TestNet-2G"])
        XCTAssertEqual(w.networks(on: w.radios[1]).map(\.name), ["TestNet-5G", "TestNet-Extra"])
    }

    func testGnmtnDhcp2PrimaryAndSecondaryInterfaces() {
        let lan = HuaweiOntClient.parseLan(Fixtures.gnmtnDhcp2)
        XCTAssertEqual(lan.routerIp, "192.168.100.1")
        XCTAssertEqual(lan.secondaryIp, "192.168.2.1")
        XCTAssertEqual(lan.subnetMask, "255.255.255.0")
        XCTAssertTrue(lan.dhcpEnabled)
        XCTAssertEqual(lan.poolStart, "192.168.100.2")
        XCTAssertEqual(lan.poolEnd, "192.168.100.254")
        XCTAssertEqual(lan.leaseSeconds, 86400)
    }

    func testMissingDeviceInfoDoesNotTriggerExtraRelogin() async {
        let t = router()
        t.on("/html/ssmp/deviceinfo/deviceinfo.asp", "<html><body>404 Not Found</body></html>")
        let client = HuaweiOntClient(credentials: creds, transport: t)
        do {
            _ = try await client.fetchHealth()
            XCTFail("expected badResponse")
        } catch {
            XCTAssertEqual(error as? OntError, .badResponse("deviceinfo"))
        }
        XCTAssertEqual(t.paths().filter { $0 == "/login.cgi" }.count, 1)
    }
}
