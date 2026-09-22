# Fibre Monitor

iPhone app for **Huawei OptiXstar HG8145X6** fibre routers (ONTs). It logs in to the
router's web interface on the local network and shows:

- live download / upload speed (from the WAN byte counters) with a one-minute graph
- fibre signal: received optical power, quality, and GPON registration state
- internet connection: PPPoE/IPoE status, WAN IP (flags carrier-grade NAT), uptime, ISP DNS
- connected devices with Wi-Fi band or LAN port and connected time, renameable on the phone
- router restart

Native SwiftUI, iOS 16+, with the system Liquid Glass look on iOS 26.

## Install
GitHub Actions builds an unsigned IPA on every push (Xcode 26, no Mac needed).
Download `FibreMonitor.ipa` from **Releases** (or the workflow run's artifacts) and
install it with [Sideloadly](https://sideloadly.io/), AltStore or SideStore using a
free Apple ID. Then open the app, allow **Local Network** access, and enter the router
password in Settings. The phone must be on the router's Wi-Fi.

## How it talks to the router
Same requests as the router's own web page:

| What | Endpoint |
|------|----------|
| Login | `POST /asp/GetRandCount.asp` (token) → `POST /login.cgi` (base64 password) |
| Traffic counters | `GET /html/bbsp/common/get_wan_list_pppwanstat.asp` |
| WAN status | `POST /html/bbsp/common/getwanlist.asp` |
| Optical / PON | `POST /html/amp/common/getSmartDiagnoseResult.asp`, `/html/ssmp/common/getOpticTxRx.asp` |
| Devices | `POST /html/bbsp/common/GetLanUserDevInfo.asp` |
| Restart | `POST /CustomApp/set.cgi?x=InternetGatewayDevice.X_HW_DEBUG.SMP.DM.ResetBoard` |
| Logout | `POST /logout.cgi?RequestFile=html/logout.html` |

Responses are JavaScript (`new Type("\x2e...")`) rather than JSON; `HuaweiJs` parses
them, mapping fields by the constructor definitions the router sends along.

The app never retries a rejected password (the router locks logins after a few
failures) and logs out when it goes to the background, so the router's web page
stays available.

## Layout
```
FibreMonitor/Services   HuaweiOntClient (session + parsing), HuaweiJs, transport, settings (Keychain)
FibreMonitor/Views      SwiftUI screens, LiquidGlass helpers
FibreMonitorTests       parser and session tests against synthetic router responses
tools/gen_icon.py       regenerates the app icon
```
