import Foundation
@testable import FibreMonitor

/// Response shapes captured from an HG8145X6-10, with made-up values.
enum Fixtures {
    static let bom = "\u{FEFF}"

    static let token = "\(bom)0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0"

    static let loginOk = """
    <html><head><title>Waiting...</title><script type="text/javascript">
    var pageName = 'index.asp';
    top.location.replace(pageName);
    </script></head><body></body></html>
    """

    static let loginPage = """
    <!DOCTYPE html><html><head><title>HG8145X6-10</title></head>
    <body><form action="login.cgi"><input id="txt_Username"/></form></body></html>
    """

    static func pppStats(sent: String, received: String) -> String {
        """
         function() {
          return new Array(new WaninfoStats("InternetGatewayDevice.WANDevice.1.WANConnectionDevice.1.WANPPPConnection.1.Stats","\(sent)","\(received)","100","200","100","200","0","0","1","0"),null);
        }
        """
    }

    static let wanList = """
    function() {
      var IPWanList = new Array(null);
      var PPPWanList = new Array(new WanPPP("InternetGatewayDevice.WANDevice.1.WANConnectionDevice.1.WANPPPConnection.1","0","0","AlwaysOn","00\\x3a11\\x3a22\\x3a33\\x3a44\\x3a55","Connected","ERROR\\x5fNONE","","ACS\\x5fHSI","1","","","Connected","IP\\x5fRouted","10\\x2e20\\x2e30\\x2e40","10\\x2e20\\x2e0\\x2e1","1","0","203\\x2e0\\x2e113\\x2e1\\x2c203\\x2e0\\x2e113\\x2e2","user\\x40isp\\x2eexample","\\x2a\\x2a\\x2asensitive\\x20data\\x20replaced\\x2a\\x2a\\x2a","AlwaysOn","4294967295","10","4294967295","0","0","TR069\\x5fINTERNET","","0","180","1","1","1","0","Specified","0","1492","ac\\x2dname","DetectBidirectionally","93784","0","","0"),null);
      var IPWanListNum = IPWanList.length - 1;
    }
    """

    static let smartDiagnose = """
    function() {
      function getResult()
      {
          var opticInfo = '\\x2d18\\x2e25';
          var ontPonMode = 'gpon';
          var gponStatus = 'O5';
          var eponStatus = '';
          var regStatus = '';
      }
    }
    """

    static let opticTxRx = """
    function() {
      function stOpticInfo(domain, TxPower, RxPower, Voltage, Temperature, Bias)
      {
          this.TxPower = TxPower;
      }
      return new Array(new stOpticInfo("InternetGatewayDevice.X_HW_DEBUG.AMP.Optic","2\\x2e31","\\x2d18\\x2e30","3300","47","12"),null);
    }
    """

    static let devices = """
    \(bom)function USERDevice(Domain,IpAddr,MacAddr,Port,IpType,DevType,DevStatus,PortType,Time,HostName,IPv4Enabled,IPv6Enabled,DeviceType,UserDevAlias,UserSpecifiedDeviceType,LeaseTimeRemaining,TrafficSendRate,TrafficRecvRate)
    {
        this.Domain = Domain;
    }
    var UserDevList = new Array(new USERDevice("InternetGatewayDevice.LANDevice.1.X_HW_UserDev.1","192\\x2e168\\x2e100\\x2e10","aa\\x3abb\\x3acc\\x3a00\\x3a00\\x3a01","SSID1","DHCP","android\\x2ddhcp\\x2d14","Online","WIFI","1\\x3a5","","1","1","0","","0","81567","0","0"),new USERDevice("InternetGatewayDevice.LANDevice.1.X_HW_UserDev.2","192\\x2e168\\x2e100\\x2e7","AA\\x3aBB\\x3aCC\\x3a00\\x3a00\\x3a02","SSID5","DHCP","","Online","WIFI","26\\x3a0","Living\\x2dRoom\\x2dTV","1","1","0","","0","100","0","0"),new USERDevice("InternetGatewayDevice.LANDevice.1.X_HW_UserDev.3","192\\x2e168\\x2e100\\x2e2","aa\\x3abb\\x3acc\\x3a00\\x3a00\\x3a03","LAN2","DHCP","","Offline","ETH","0\\x3a0","","1","1","0","Office\\x20PC","0","0","0","0"),null);
    var UserDevListCopy = new Array(new USERDevice("InternetGatewayDevice.LANDevice.1.X_HW_UserDev.1","192\\x2e168\\x2e100\\x2e10","aa\\x3abb\\x3acc\\x3a00\\x3a00\\x3a01","SSID1","DHCP","android\\x2ddhcp\\x2d14","Online","WIFI","1\\x3a5","","1","1","0","","0","81567","0","0"),null);
    function GetUserDevInfoList() { return UserDevList; }
    """
}

/// Scripted router: replies by path prefix, records every request.
final class FakeTransport: OntTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [(String, [String])] = []
    private(set) var requests: [OntRequest] = []
    private(set) var resets = 0

    /// Queue replies for a path prefix; the last one repeats.
    func on(_ prefix: String, _ replies: String...) {
        lock.lock(); defer { lock.unlock() }
        routes.removeAll { $0.0 == prefix }
        routes.append((prefix, replies))
    }

    func paths() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return requests.map { $0.path.components(separatedBy: "?")[0] }
    }

    func send(_ request: OntRequest, host: String) async throws -> String {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        guard let index = routes.lastIndex(where: { request.path.hasPrefix($0.0) }) else {
            throw URLError(.fileDoesNotExist)
        }
        var replies = routes[index].1
        let reply = replies.first ?? ""
        if replies.count > 1 { replies.removeFirst(); routes[index].1 = replies }
        return reply
    }

    func resetSession(host: String) async {
        lock.lock(); defer { lock.unlock() }
        resets += 1
    }
}
