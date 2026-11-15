# Fibre Monitor

iPhone app for **Huawei OptiXstar HG8145X6** fibre routers (ONTs) across firmware variants (including HG8145X6-10 / `COMMON` and `GNMTNNCE`). It logs in to the router's web interface on the local network and provides:

- **Multi-router profiles:** save multiple routers (each with Keychain credentials, detected model and config mode, and per-router device nicknames), pick on launch when 2+ profiles exist, or switch live from Dashboard / Settings
- **Dashboard:** live download/upload speed with a 60-second sparkline, optical Rx power range bar (`Good` / `Weak` / `Bad` / `Too strong`) and PON state, WAN connection details (PPPoE/IPoE, CGNAT flag, uptime, gateway, DNS), conditional ONT uptime / Tx laser power / CPU & memory load when reported by the firmware, and confirmed router restart
- **Clients:** searchable online/offline device list with Wi-Fi band or LAN port badges, live per-device traffic rates (when non-zero), DHCP vendor & lease details, **Rename on Router** (`UserDevAlias`), local iPhone-only nicknames, and offline device removal
- **Wi-Fi:** 2.4 GHz / 5 GHz radio switches (with connected-radio & last-radio safeguards), on-demand QR join code generation and passphrase reveal/copy (never saved on disk), and WPA2-PSK / WPA3-PSK SSID & password editing with typed SSID confirmation
- **Tools & LAN:** built-in router Ping / Traceroute diagnostics, LAN / DHCP pool & secondary subnet inspection, and explicit session logout

Native SwiftUI, iOS 16+, with system Liquid Glass on iOS 26+.

## Install

GitHub Actions builds an unsigned IPA on every push (Xcode 26, no Mac needed). Download `FibreMonitor.ipa` from **Releases** (or the workflow run's artifacts) and install it with [Sideloadly](https://sideloadly.io/), AltStore, or SideStore using a free Apple ID. Open the app, allow **Local Network** access, and add your router profile in **Settings** (`192.168.100.1` or `192.168.2.1` depending on router/firmware). The iPhone must be on the router's Wi-Fi.

## How it talks to the router

Uses the same requests as the router's web UI:

| Feature | Endpoint(s) |
|---------|-------------|
| Login & identity | `POST /asp/GetRandCount.asp` (token) → `POST /login.cgi` (base64 password) → `GET /index.asp` |
| CSRF token refresh | `POST /html/ssmp/common/GetRandToken.asp` |
| Logout | `POST /logout.cgi?RequestFile=html/logout.html` |
| Traffic counters | `GET /html/bbsp/common/get_wan_list_pppwanstat.asp`, `/html/bbsp/common/get_wan_list_ipwanstat.asp` |
| WAN info | `POST /html/bbsp/common/getwanlist.asp` |
| Optical & PON state | `POST /html/amp/common/getSmartDiagnoseResult.asp`, `/html/ssmp/common/getOpticTxRx.asp` |
| Router health | `GET /html/ssmp/deviceinfo/deviceinfo.asp` |
| Client list & DHCP | `POST /html/bbsp/common/GetLanUserDevInfo.asp`, `/html/bbsp/common/GetLanUserDhcpInfo.asp` |
| Rename device | `POST /html/bbsp/userdevinfo/set.cgi?x=<UserDevDomain>&RequestFile=html/bbsp/userdevinfo/userdetdevinfo.asp` |
| Remove offline client | `POST /html/bbsp/userdevinfo/del.cgi?x=InternetGatewayDevice.LANDevice.1.X_HW_UserDev` |
| Wi-Fi radios & SSIDs | `GET /html/amp/common/wlan_list.asp` |
| Wi-Fi security & PSK | `GET /html/amp/wlanbasic/WlanBasic.asp` (plus `?2G` / `?5G` fallback, ephemeral) |
| Toggle Wi-Fi radio | `POST /html/amp/wlanbasic/set.cgi?x=InternetGatewayDevice.X_HW_DEBUG.AMP.SetWifiCoverEnable&y=InternetGatewayDevice.LANDevice.1.WiFi.Radio.<n>&RequestFile=html/amp/wlanbasic/WlanBasic.asp` |
| Edit SSID / password | `POST /html/amp/wlanbasic/set.cgi?c1=...WLANConfigAction&w=...WifiCoverSetWlanBasic&y=<WlanDomain>&z=...WPS&k=...PreSharedKey.1&c2=...&RequestFile=html/amp/wlanbasic/WlanBasic.asp` |
| LAN & DHCP | `GET /html/bbsp/dhcpservercfg/dhcp2.asp` |
| Diagnostics | `POST /html/bbsp/maintenance/complex.cgi` → `GetPingResult.asp` / `GetRouteResult.asp` |
| Restart router | `POST /CustomApp/set.cgi?x=InternetGatewayDevice.X_HW_DEBUG.SMP.DM.ResetBoard&RequestFile=../CustomApp/mainpage.asp` |

Responses are JavaScript (`new Type("\x2e...")`) rather than JSON; `HuaweiJs` extracts constructors and string variables dynamically.

Safety & session behavior:
- Never retries a rejected login (the router locks accounts after repeated failed attempts).
- Logs out automatically when backgrounded or when you tap **Log Out of Router** in Settings (so the router's single-session web UI remains free).
- Never writes Wi-Fi passphrases to `UserDefaults` or Keychain; QR and Edit sheets clear sensitive state on dismiss or background.
- Guards destructive writes: refuses switching off the last active radio, warns before disconnecting the active band, requires explicit confirmation before deleting profiles/devices or restarting, and requires typing the new SSID before changing Wi-Fi credentials.

## Layout

```text
FibreMonitor/Models      Data models, error types, router profiles
FibreMonitor/Services    HuaweiOntClient, HuaweiJs, OntTransport, SettingsStore (Keychain)
FibreMonitor/ViewModels  MonitorViewModel (polling, NWPathMonitor, actions, haptics)
FibreMonitor/Views       4-tab Liquid Glass UI (Dashboard, Clients, Wi-Fi, Settings)
FibreMonitorTests        Parser, session, multi-router, WlanBasic, and Phase 4 write unit tests
tools/gen_icon.py        Regenerates the app icon
```
