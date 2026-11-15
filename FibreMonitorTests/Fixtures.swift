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

extension Fixtures {
    static let deviceInfoPage = """
    <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
    <html><head><script language="JavaScript" type="text/javascript">
    function stDeviceInfo(domain,SerialNumber,HardwareVersion,SoftwareVersion,ModelName,VendorID,ReleaseTime,Mac,Description,ManufactureInfo,DeviceAlias, WanMac) {
        this.domain = domain;
    }
    var deviceInfos = new Array(new stDeviceInfo("InternetGatewayDevice.DeviceInfo","0000000000000000","1A2B.C","V5R000C00S100","HG8145X6-10","HWTC","2024-01-01_00:00:00 ","00:11:22:33:44:55","OptiXstar HG8145X6-10 GPON Terminal","","",""),null);
    var cpuUsed = '23%';
    var memUsed = '61%';
    if (ProductType == '2') {
        var dev_uptime = '90061';
    } else {
        var dev_uptime = '';
    }
    </script></head><body></body></html>
    """

    static func wlanList(radio1: Bool, radio2: Bool) -> String {
        """
        function stWlanInfo(domain,name,ssid,X_HW_ServiceEnable,enable,X_HW_RFBand,bindenable)
        {
            this.domain = domain;
        }
        function stRadio(domain,OperatingFrequencyBand,Enable)
        {
            this.domain = domain;
        }
        var WlanInfo = new Array(new stWlanInfo("InternetGatewayDevice.LANDevice.1.WLANConfiguration.1","ath0","Test Home","1","1","2.4GHz"),new stWlanInfo("InternetGatewayDevice.LANDevice.1.WLANConfiguration.2","ath5","Test Fast","1","1","5GHz"),new stWlanInfo("InternetGatewayDevice.LANDevice.1.WLANConfiguration.5","ath4","Test Extra","1","1","5GHz"),null);
        var RadioList = new Array(new stRadio("InternetGatewayDevice.LANDevice.1.WiFi.Radio.1","2.4GHz","\(radio1 ? 1 : 0)"),new stRadio("InternetGatewayDevice.LANDevice.1.WiFi.Radio.2","5GHz","\(radio2 ? 1 : 0)"),null);
        var RadioCopy = new Array(new stRadio("InternetGatewayDevice.LANDevice.1.WiFi.Radio.1","2.4GHz","\(radio1 ? 1 : 0)"),null);
        function newWlan(tid) { return new stWlanInfo('domain','SSID'+tid,'','0','1','','0'); }
        """
    }

    static let dhcpPage = """
    <!DOCTYPE html><html><head><script>
    function stipaddr(domain, enable, ipaddr, subnetmask) { this.domain = domain; }
    function dhcpmainst(domain, enable, startip, endip, leasetime, l2relayenable, HGWstartip, HGWendip, STBstartip, STBendip, Camerastartip, Cameraendip, Computerstartip, Computerendip, Phonestartip, Phoneendip, MainDNS, X_HW_Option125Enable, DNSServers, OptionEnable) { this.domain = domain; }
    var LanIp = new Array(new stipaddr("InternetGatewayDevice.LANDevice.1.LANHostConfigManagement.IPInterface.1","1","192\\x2e168\\x2e100\\x2e1","255\\x2e255\\x2e255\\x2e0"),null);
    var DhcpMain = new Array(new dhcpmainst("InternetGatewayDevice.LANDevice.1.LANHostConfigManagement","1","192\\x2e168\\x2e100\\x2e2","192\\x2e168\\x2e100\\x2e254","86400","1","","","","","","","","","","","","1","",""),null);
    </script></head></html>
    """

    static let indexPage = """
    <!DOCTYPE html><html><head><script>
    var ProductName = 'HG8145X6\\x2d10';
    var CfgMode ='GNMTNNCE';
    </script></head></html>
    """

    // MARK: GNMTNNCE firmware fixtures (synthetic, matching capture formats)

    static let gnmtnWanList = """
    function() {
      var IPWanList = new Array(null);
      var PPPWanList = new Array(new WanPPP("InternetGatewayDevice.WANDevice.1.WANConnectionDevice.1.WANPPPConnection.1","0","0","AlwaysOn","02\\x3a00\\x3a5E\\x3a00\\x3a00\\x3a01","Connected","ERROR\\x5fNONE","","ACS\\x5fHSI","1","","","Connected","IP\\x5fRouted","10\\x2e0\\x2e0\\x2e2","10\\x2e0\\x2e0\\x2e3","1","0","203\\x2e0\\x2e113\\x2e4\\x2c203\\x2e0\\x2e113\\x2e5","user\\x40isp\\x2etest","\\x2a\\x2a\\x2asensitive\\x20data\\x20replaced\\x2a\\x2a\\x2a","AlwaysOn","4294967295","10","4294967295","0","0","TR069\\x5fINTERNET","","0","180","1","1","1","0","Specified","0","1492","bras\\x2dtest\\x2d01","DetectBidirectionally","283901","0","","0"),null);
      function IPv6AddressInfo(domain, IPAddressStatus, Origin,IPAddress,PreferredTime,ValidTime,ValidTimeRemaining) { this.IPAddress = IPAddress; }
      var IPv6AddressList = new Array(null);
      function IPv6WanInfo(domain, Type, ConnectionStatus, L2EncapType, MACAddress, Vlan, Pri, DNSServers, AFTRName, AFTRPeerAddr,DefaultRouterAddress,V6UpTime) { this.Type = Type; }
      var IPv6WanInfoList = new Array(new IPv6WanInfo("InternetGatewayDevice.WANDevice.1.X_HW_ShowInterface.1","WAN","Connecting","PPPoE","02\\x3a00\\x3a5E\\x3a00\\x3a00\\x3a01","10","0","","","","","0"),null);
      return {};
    }
    """

    static func gnmtnPppWanStat(sent: String, received: String) -> String {
        """
        function() {
          return new Array(new WaninfoStats("InternetGatewayDevice.WANDevice.1.WANConnectionDevice.1.WANPPPConnection.1.Stats","\(sent)","\(received)","31000","136000","31000","136000","0","0","1","0"),null);
        }
        """
    }

    static let gnmtnIpWanStatEmpty = """
    function() {
      return new Array(null);
    }
    """

    static let gnmtnSmartDiagnose = """
    function() {
      function stLinkStatus(domain, status) { this.domain = domain; this.Status = status; }
      function pwdBandSecurityStatus(domain, PWD_2G_Security, PWD_5G_Security) { this.domain = domain; }
      function getResult() {
          var opticInfo = '\\x2d15\\x2e93';
          var ontPonMode = 'gpon';
          var gponStatus = 'O5';
          var eponStatus = '';
          var regStatus = '';
          if (opticInfo == "--" || opticInfo == "") { opticInfo = "nok"; } else { opticInfo = "ok"; }
          return { opticInfo: opticInfo, regStatus: 'ok' };
      }
      return getResult();
    }
    """

    static let gnmtnDevices = """
    function USERDevice(Domain,IpAddr,MacAddr,Port,IpType,DevType,DevStatus,PortType,Time,HostName,IPv4Enabled,IPv6Enabled,DeviceType,UserDevAlias,UserSpecifiedDeviceType,LeaseTimeRemaining,TrafficSendRate,TrafficRecvRate) { this.Domain = Domain; }
    function USERDeviceNew(Domain, IpAddr, MacAddr, Port, IpType, DevType, DevStatus, PortType, Time, HostName, IPv4Enabled, IPv6Enabled, DeviceType, UserDevAlias, UserSpecifiedDeviceType, LeaseTimeRemaining, RealMacAddr) { this.Domain = Domain; }
    var UserDevList = new Array(new USERDevice("InternetGatewayDevice.LANDevice.1.X_HW_UserDev.1","192\\x2e168\\x2e100\\x2e10","02\\x3a00\\x3a5E\\x3a00\\x3a00\\x3a02","SSID1","DHCP","android\\x2ddhcp\\x2d14","Online","WIFI","10\\x3a43","","1","1","0","","0","59531","12500","240000"),new USERDevice("InternetGatewayDevice.LANDevice.1.X_HW_UserDev.2","192\\x2e168\\x2e2\\x2e2","02\\x3a00\\x3a5E\\x3a00\\x3a00\\x3a03","SSID2","DHCP","MSFT\\x205\\x2e0","Online","WIFI","0\\x3a9","Work\\x2dLaptop","1","1","0","Laptop\\x20Alias","3","85812","0","0"),new USERDevice("InternetGatewayDevice.LANDevice.1.X_HW_UserDev.3","192\\x2e168\\x2e100\\x2e23","02\\x3a00\\x3a5E\\x3a00\\x3a00\\x3a04","SSID5","DHCP","android\\x2ddhcp\\x2d16","Offline","WIFI","17\\x3a46","Tablet","1","1","0","\\x2d\\x2d","0","19139","0","0"),null);
    var UserDevinfo = new Array(new USERDeviceNew("InternetGatewayDevice.LANDevice.1.X_HW_UserDev.1","192\\x2e168\\x2e100\\x2e10","02\\x3a00\\x3a5E\\x3a00\\x3a00\\x3a02","SSID1","DHCP","android\\x2ddhcp\\x2d14","Online","WIFI","10\\x3a43","","1","1","0","","0","59531","02\\x3a00\\x3a5E\\x3a00\\x3a00\\x3a02"),new USERDeviceNew("InternetGatewayDevice.LANDevice.1.X_HW_UserDev.2","192\\x2e168\\x2e2\\x2e2","02\\x3a00\\x3a5E\\x3a00\\x3a00\\x3a03","SSID2","DHCP","MSFT\\x205\\x2e0","Online","WIFI","0\\x3a9","Work\\x2dLaptop","1","1","0","Laptop\\x20Alias","3","85812","02\\x3a00\\x3a5E\\x3a00\\x3a00\\x3a03"),new USERDeviceNew("InternetGatewayDevice.LANDevice.1.X_HW_UserDev.3","192\\x2e168\\x2e100\\x2e23","02\\x3a00\\x3a5E\\x3a00\\x3a00\\x3a04","SSID5","DHCP","android\\x2ddhcp\\x2d16","Offline","WIFI","17\\x3a46","Tablet","1","1","0","\\x2d\\x2d","0","19139","02\\x3a00\\x3a5E\\x3a00\\x3a00\\x3a04"),null);
    """

    static let gnmtnDevicesNewOnly = """
    function USERDeviceNew(Domain, IpAddr, MacAddr, Port, IpType, DevType, DevStatus, PortType, Time, HostName, IPv4Enabled, IPv6Enabled, DeviceType, UserDevAlias, UserSpecifiedDeviceType, LeaseTimeRemaining, RealMacAddr) { this.Domain = Domain; }
    var UserDevinfo = new Array(new USERDeviceNew("InternetGatewayDevice.LANDevice.1.X_HW_UserDev.9","192\\x2e168\\x2e100\\x2e50","02\\x3a00\\x3a5E\\x3a00\\x3a00\\x3a09","LAN1","DHCP","android\\x2ddhcp\\x2d15","Online","ETH","2\\x3a15","Wired\\x2dBox","1","1","0","Media\\x20Box","4","43200","02\\x3a00\\x3a5E\\x3a00\\x3a00\\x3a09"),null);
    """

    static let gnmtnDhcpInfo = """
    function() {
      function DHCPInfo(domain,name,ip,mac,remaintime,devtype, interfacetype,AddressSource, ConnectedTime) { this.domain = domain; }
      var UserDhcpinfo = new Array(new DHCPInfo("InternetGatewayDevice.LANDevice.1.Hosts.Host.1","Pixel\\x2dPhone","192\\x2e168\\x2e100\\x2e10","02\\x3a00\\x3a5E\\x3a00\\x3a00\\x3a02","59295","android\\x2ddhcp\\x2d14","802\\x2e11","DHCP","27105"),null);
      return UserDhcpinfo;
    }
    """

    static func gnmtnWlanList(radio1: Bool = true, radio2: Bool = true) -> String {
        """
        function stWlanInfo(domain,name,ssid,X_HW_ServiceEnable,enable,X_HW_RFBand,bindenable) { this.domain = domain; }
        var WlanInfo = new Array(new stWlanInfo("InternetGatewayDevice\\x2eLANDevice\\x2e1\\x2eWLANConfiguration\\x2e1","ath0","TestNet\\x2d2G","1","1","2\\x2e4GHz"),new stWlanInfo("InternetGatewayDevice\\x2eLANDevice\\x2e1\\x2eWLANConfiguration\\x2e2","ath5","TestNet\\x2d5G","1","1","5GHz"),new stWlanInfo("InternetGatewayDevice\\x2eLANDevice\\x2e1\\x2eWLANConfiguration\\x2e5","ath4","TestNet\\x2dExtra","1","1","5GHz"),null)
        function newWlan(tid) { return new stWlanInfo('domain','SSID'+tid,'','0','1','','0'); }
        function stRadio(domain,OperatingFrequencyBand,Enable) { this.domain = domain; }
        function WlanInfoRefresh() {
            var Radio = new Array(new stRadio("InternetGatewayDevice\\x2eLANDevice\\x2e1\\x2eWiFi\\x2eRadio\\x2e1","2\\x2e4GHz","\(radio1 ? 1 : 0)"),new stRadio("InternetGatewayDevice\\x2eLANDevice\\x2e1\\x2eWiFi\\x2eRadio\\x2e2","5GHz","\(radio2 ? 1 : 0)"),null);
        }
        var Radio = new Array(new stRadio("InternetGatewayDevice\\x2eLANDevice\\x2e1\\x2eWiFi\\x2eRadio\\x2e1","2\\x2e4GHz","\(radio1 ? 1 : 0)"),new stRadio("InternetGatewayDevice\\x2eLANDevice\\x2e1\\x2eWiFi\\x2eRadio\\x2e2","5GHz","\(radio2 ? 1 : 0)"),null);
        """
    }

    static let gnmtnDhcp2 = """
    <!DOCTYPE html><html><head><script>
    function dhcpmainst(domain, enable, startip, endip, leasetime, l2relayenable, HGWstartip, HGWendip, STBstartip, STBendip, Camerastartip, Cameraendip, Computerstartip, Computerendip, Phonestartip, Phoneendip, MainDNS, X_HW_Option125Enable, DNSServers, OptionEnable) { this.domain = domain; }
    function stipaddr(domain, enable, ipaddr, subnetmask) { this.domain = domain; }
    var MainDhcpRange = new Array(new dhcpmainst("InternetGatewayDevice.LANDevice.1.LANHostConfigManagement","1","192\\x2e168\\x2e100\\x2e2","192\\x2e168\\x2e100\\x2e254","86400","1","","","","","","","","","","","","1","","0"),null);
    var LanIpInfos = new Array(new stipaddr("InternetGatewayDevice.LANDevice.1.LANHostConfigManagement.IPInterface.1","1","192\\x2e168\\x2e100\\x2e1","255\\x2e255\\x2e255\\x2e0"),new stipaddr("InternetGatewayDevice.LANDevice.1.LANHostConfigManagement.IPInterface.2","1","192\\x2e168\\x2e2\\x2e1","255\\x2e255\\x2e255\\x2e0"),null);
    </script></head></html>
    """

    static func gnmtnWlanBasic(kppUsed: Bool = false, passwordMask: Bool = false) -> String {
        let pwd = passwordMask ? "********" : "pass\\x2dword\\x3b1"
        let kppVal = kppUsed ? "kpp\\x2dsecret\\x2d2" : ""
        let maskFlag = passwordMask ? "1" : "0"
        let kppFlag = kppUsed ? "1" : "0"
        return """
        <!DOCTYPE html><html><head><script>
        var wifiPasswordMask='\(maskFlag)';
        var kppUsedFlag='\(kppFlag)';
        function stWlan(domain,name,enable,ssid,wlHide,DeviceNum,wmmEnable,BeaconType,BasicEncryptionModes,BasicAuthenticationMode,KeyIndex,EncryptionLevel,WPAEncryptionModes,WPAAuthenticationMode,IEEE11iEncryptionModes,IEEE11iAuthenticationMode,X_HW_WPAand11iEncryptionModes,X_HW_WPAand11iAuthenticationMode,WPARekey,RadiusServer,RadiusPort,RadiusKey,X_HW_ServiceEnable,LowerLayers,X_HW_WAPIEncryptionModes,X_HW_WAPIAuthenticationMode,X_HW_WAPIServer,X_HW_WAPIPort,X_HW_WPSConfigurated,UAPSDEnable,IsolationEnable) { this.domain = domain; }
        function stPreSharedKey(domain, psk, kpp) { this.domain = domain; }
        function stWpsPin(domain, X_HW_ConfigMethod, DevicePassword, X_HW_PinGenerator, Enable) { this.domain = domain; }
        function stWlanWifi(domain,name,enable,ssid,mode,channel,power,Country,AutoChannelEnable,channelWidth) { this.domain = domain; }
        var WlanWifiArr = new Array(new stWlanWifi("InternetGatewayDevice\\x2eLANDevice\\x2e1\\x2eWLANConfiguration\\x2e1","ath0","1","TestNet\\x2d2G","11ax","0","100","GH","1","1"),new stWlanWifi("InternetGatewayDevice\\x2eLANDevice\\x2e1\\x2eWLANConfiguration\\x2e2","ath5","1","Example\\x2dSSID","11ax","0","100","GH","1","4"),new stWlanWifi("InternetGatewayDevice\\x2eLANDevice\\x2e1\\x2eWLANConfiguration\\x2e5","ath4","1","Guest\\x2d5G","11ax","0","100","GH","1","4"),null);
        var WlanArr = new Array(new stWlan("InternetGatewayDevice\\x2eLANDevice\\x2e1\\x2eWLANConfiguration\\x2e1","ath0","1","TestNet\\x2d2G","1","64","1","WPAand11i","None","None","1","104\\x2dbit","TKIPEncryption","PSKAuthentication","AESEncryption","PSKAuthentication","TKIPandAESEncryption","PSKAuthentication","3600","192\\x2e168\\x2e0\\x2e100","1812","526BF435","1","InternetGatewayDevice\\x2eLANDevice\\x2e1\\x2eWiFi\\x2eRadio\\x2e1","SMS4","WAPIPSK","","3810","2","0","0"),new stWlan("InternetGatewayDevice\\x2eLANDevice\\x2e1\\x2eWLANConfiguration\\x2e2","ath5","1","Example\\x2dSSID","1","64","1","11i","None","None","1","104\\x2dbit","TKIPEncryption","PSKAuthentication","TKIPandAESEncryption","PSKAuthentication","TKIPandAESEncryption","PSKAuthentication","3600","","1812","E06ECC67","1","InternetGatewayDevice\\x2eLANDevice\\x2e1\\x2eWiFi\\x2eRadio\\x2e2","SMS4","WAPIPSK","","3810","2","0","0"),new stWlan("InternetGatewayDevice\\x2eLANDevice\\x2e1\\x2eWLANConfiguration\\x2e5","ath4","1","OpenGuest","0","64","1","Basic","None","None","1","104\\x2dbit","TKIPEncryption","PSKAuthentication","AESEncryption","PSKAuthentication","TKIPandAESEncryption","PSKAuthentication","3600","","1812","E64F76CE","1","InternetGatewayDevice\\x2eLANDevice\\x2e1\\x2eWiFi\\x2eRadio\\x2e2","SMS4","WAPIPSK","","3810","2","0","0"),null);
        var wpaPskKey = new Array(new stPreSharedKey("InternetGatewayDevice\\x2eLANDevice\\x2e1\\x2eWLANConfiguration\\x2e1\\x2ePreSharedKey\\x2e1","\(pwd)","\(kppVal)"),new stPreSharedKey("InternetGatewayDevice\\x2eLANDevice\\x2e1\\x2eWLANConfiguration\\x2e2\\x2ePreSharedKey\\x2e1","\(pwd)","\(kppVal)"),new stPreSharedKey("InternetGatewayDevice\\x2eLANDevice\\x2e1\\x2eWLANConfiguration\\x2e5\\x2ePreSharedKey\\x2e1","",""),null);
        var wpsPinNum = new Array(new stWpsPin("InternetGatewayDevice\\x2eLANDevice\\x2e1\\x2eWLANConfiguration\\x2e1\\x2eWPS","PushButton","4964285","AP","1"),new stWpsPin("InternetGatewayDevice\\x2eLANDevice\\x2e1\\x2eWLANConfiguration\\x2e2\\x2eWPS","Lable","12345670","AP","0"),new stWpsPin("InternetGatewayDevice\\x2eLANDevice\\x2e1\\x2eWLANConfiguration\\x2e5\\x2eWPS","PushButton","54616011","AP","1"),null);
        </script></head><body><input type="hidden" name="onttoken" id="hwonttoken" value="tok99"></body></html>
        """
    }
}

/// Scripted router: replies by path prefix, records every request.
final class FakeTransport: OntTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [(String, [String])] = []
    private var failingHosts: Set<String> = []
    private(set) var requests: [OntRequest] = []
    private(set) var recordedRequests: [(host: String, request: OntRequest)] = []
    private(set) var resets = 0
    private(set) var resetHosts: [String] = []

    /// Queue replies for a path prefix; the last one repeats.
    func on(_ prefix: String, _ replies: String...) {
        lock.lock(); defer { lock.unlock() }
        routes.removeAll { $0.0 == prefix }
        routes.append((prefix, replies))
    }

    func fail(host: String) {
        lock.lock(); defer { lock.unlock() }
        failingHosts.insert(host)
    }

    func allow(host: String) {
        lock.lock(); defer { lock.unlock() }
        failingHosts.remove(host)
    }

    func paths() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return requests.map { $0.path.components(separatedBy: "?")[0] }
    }

    func send(_ request: OntRequest, host: String) async throws -> String {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        recordedRequests.append((host: host, request: request))
        if failingHosts.contains(host) {
            throw URLError(.cannotConnectToHost)
        }
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
        resetHosts.append(host)
    }
}
