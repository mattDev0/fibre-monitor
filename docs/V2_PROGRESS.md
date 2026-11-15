# Fibre Monitor 2.0 Progress

## Phase 1: Router profiles (multi-router)
**Status:** Complete — `ios-build` run `43759315760` passed all unit tests and device build on `v2` (`106169b`).

### What was done
- Added `RouterProfile` (`id: UUID`, `name`, `host`, `username`, `lastUsed`, optional `detectedModel`, `cfgMode`) plus the `"New router (MTN)"` template (`192.168.2.1`, `root`, blank password) in `FibreMonitor/Models/RouterProfile.swift`.
- Refactored `SettingsStore` (`FibreMonitor/Services/SettingsStore.swift`) around a `PasswordStore` seam (`SystemKeychainStore` in production using service `dev.mattdev0.fibremonitor.router` and account `profile.id.uuidString`):
  - One-time v1 -> v2 migration converts existing single-router settings (`router_host`, `router_username`, Keychain account `router`, `device_aliases`) into a `"Previous router"` profile and moves the password only after confirming the per-profile Keychain write succeeds.
  - Device aliases are now stored per profile, keyed by lowercased MAC address.
  - Added profile add, update, delete, reorder, selection, and model/`CfgMode` detection persistence.
- Updated `HuaweiOntClient` (`FibreMonitor/Services/HuaweiOntClient.swift`):
  - Exposed `isValidHost(_:)` publicly with leading-dot/hyphen and `..` guards.
  - Read `ProductName` and `CfgMode` from `/index.asp` during `login()` into `detectedIdentity`.
  - Updated `logout()` to clear cached session/WAN/Wi-Fi state and always reset transport cookies, and added `switchCredentials(_:)` to cleanly log out and reset session state when switching profiles.
- Updated `MonitorViewModel` (`FibreMonitor/ViewModels/MonitorViewModel.swift`) to require router selection on launch when 2+ profiles exist (`awaitingRouterSelection`), log out / reset cookies / clear view state on `switchRouter(to:)`, and flag reachability failures with a `"Try 192.168.100.1"` suggestion when the active host is different.
- Added `RouterProfilesView.swift` (launch picker, profile row, add/edit sheet with templates and host validation) and updated `SettingsSheetView.swift` and `DashboardView.swift` with multi-router management (add, edit, delete with confirmation, reorder) and a header router switcher menu.
- Added unit tests in `FibreMonitorTests/RouterProfileTests.swift`.

### Decisions
- **Launch picker behavior:** When 2+ profiles exist at launch, polling does not start automatically until the user selects which router they are currently connected to, avoiding accidental login attempts against the wrong router (and protecting against login lockout).
- **Empty install:** A clean 2.0 install with no 1.x settings starts with zero profiles and opens Settings / Add Router so the friend can choose the `"New router (MTN)"` or standard template and enter the password himself.

---

## Phase 2: Parser compatibility with the new firmware (HG8145X6-10, GNMTNNCE)
**Status:** Complete — `ios-build` run `43760300032` passed all unit tests and device build on `v2` (`680ddc9`).

### What was done
- Added synthetic GNMTNNCE fixtures in `FibreMonitorTests/Fixtures.swift` matching the exact constructor formats, `\xNN` escaping, and argument layouts from `captures/hg8145x6-gnmtn/`:
  - `gnmtnWanList` (PPPoE `WanPPP` with 44 arguments and no constructor definition, `IPWanList` null, `IPv6AddressInfo` / `IPv6WanInfo`)
  - `gnmtnPppWanStat` (11-argument `WaninfoStats`) and `gnmtnIpWanStatEmpty`
  - `gnmtnSmartDiagnose` (`opticInfo = '\x2d15\x2e93'`, `ontPonMode = 'gpon'`, `gponStatus = 'O5'`)
  - `gnmtnDevices` (18-arg `USERDevice` + 17-arg `USERDeviceNew`, non-zero rates, `\x2d\x2d` placeholder alias) and `gnmtnDevicesNewOnly`
  - `gnmtnDhcpInfo` (`DHCPInfo` lease enrichment)
  - `gnmtnWlanList` (3 SSIDs across 2.4 GHz and 5 GHz, duplicate `stRadio` array, `newWlan` template)
  - `gnmtnDhcp2` (`stipaddr` for `IPInterface.1` `192.168.100.1` + `IPInterface.2` `192.168.2.1`, and `MainDhcpRange` `dhcpmainst`)
- Extended `OntDevice` (`FibreMonitor/Models/OntModels.swift`) with `userSpecifiedDeviceType`, `trafficSendRate`, `trafficRecvRate`, `leaseSecondsRemaining`, plus `LanInfo.secondaryIp` and `RouterHealth.hasCpuOrMemory` / `hasAnyData`.
- Updated `HuaweiOntClient` (`FibreMonitor/Services/HuaweiOntClient.swift`):
  - `parseDevices`: parses 18-arg `USERDevice` first and falls back to 17-arg `USERDeviceNew` (deduplicating by MAC), normalizes `"--"` placeholders to `""`, maps `UserSpecifiedDeviceType`, `LeaseTimeRemaining`, and non-zero `TrafficSendRate` / `TrafficRecvRate`.
  - `fetchDevices`: optionally calls `GetLanUserDhcpInfo.asp` (`enrichDevices(_:withDhcpInfo:)`) to fill missing hostnames, DHCP vendor class, or remaining lease time without failing if unavailable.
  - `parseLan`: records secondary LAN interface IP (`IPInterface.2`) in `LanInfo.secondaryIp`.
  - `parseWifi`: checks `X_HW_ServiceEnable != "0"`.
  - `fetchOptical` / `fetchHealth`: avoids extra `login()` retries when optional `getOpticTxRx.asp` or `deviceinfo.asp` returns a non-login error page (only re-logging in when a login page is detected).
- Added unit tests in `FibreMonitorTests/GnmtnCompatibilityTests.swift` covering all GNMTNNCE parsers while preserving all 1.x tests in `HuaweiOntClientTests.swift`.

### Verified `wanPppParams` mapping (44-argument `WanPPP` in `bbsp_common_getwanlist.asp`)
Every index `0...43` in `HuaweiOntClient.wanPppParams` matches the 44-argument `new WanPPP(...)` record in `captures/hg8145x6-gnmtn/bbsp_common_getwanlist.asp` without offset:
- `0` `domain`: `InternetGatewayDevice.WANDevice.1.WANConnectionDevice.1.WANPPPConnection.1`
- `1` `X_HW_VXLAN_Enable`: `0`, `2` `X_HW_OperateDisable`: `0`, `3` `ConnectionTrigger`: `AlwaysOn`
- `4` `MACAddress`: `02:00:5E:00:00:01` (capture MAC)
- `5` `Status`: `Connected`, `6` `LastConnErr`: `ERROR_NONE`, `7` `RemoteWanInfo`: `""`
- `8` `Name`: `ACS_HSI`, `9` `Enable`: `1`, `10` `EnableLanDhcp`: `""`, `11` `DstIPForwardingList`: `""`
- `12` `ConnectionStatus`: `Connected`, `13` `Mode`: `IP_Routed`
- `14` `IPAddress`: `10.0.0.2`, `15` `Gateway`: `10.0.0.3`
- `16` `NATEnable`: `1`, `17` `X_HW_NatType`: `0`
- `18` `dnsstr`: `203.0.113.4,203.0.113.5`
- `19` `Username`, `20` `Password`, `21` `DialMode`: `AlwaysOn`, `22` `ConnectionControl`: `4294967295`
- `23` `VlanId`: `10`, `24` `MultiVlanID`: `4294967295`, `25` `Pri8021`: `0`, `26` `LcpEchoReqCheck`: `0`
- `27` `ServiceList`: `TR069_INTERNET`, `28` `ExServiceList`: `""`, `29` `Tr069Flag`: `0`
- `30` `IdleDisconnectTime`: `180`, `31` `MacId`: `1`, `32` `IPv4Enable`: `1`, `33` `IPv6Enable`: `1`
- `34` `IPv6MultiCastVlan`: `0`, `35` `PriPolicy`: `Specified`, `36` `DefaultPri`: `0`, `37` `MaxMRUSize`: `1492`
- `38` `PPPoEACName`: `at-bras-ne8k-x8-01`, `39` `X_HW_IdleDetectMode`: `DetectBidirectionally`
- `40` `Uptime`: `283901`, `41` `DNSOverrideAllowed`: `0`, `42` `X_HW_LowerLayers`: `""`, `43` `PPPoESessionID`: `0`

## Needs capture / Unverified on GNMTNNCE hardware
- `POST /html/ssmp/common/getOpticTxRx.asp` (Tx power, optical temperature, voltage, bias) — referenced in `index.asp`, not captured.
- `GET /html/ssmp/deviceinfo/deviceinfo.asp` (CPU, memory, ONT uptime, serial, firmware) — in menu, not captured.
- `bbsp/maintenance/diagnosecommon.asp` (`IPPingDiagnostics` / `TraceRouteDiagnostics`) — in menu, not captured.
- `POST /logout.cgi?RequestFile=html/logout.html` — not captured on GNMTNNCE.
- Non-zero `TrafficSendRate` / `TrafficRecvRate` unit confirmation (all devices in `bbsp_common_GetLanUserDevInfo.asp` reported `"0"`).
- Live `SystemKeychainStore` migration on a physical device.

---

## Phase 3: UI redesign (Liquid Glass 4-tab layout & Wi-Fi QR)
**Status:** Implemented and tested against synthetic fixtures (awaiting CI verification).

### What was done
- Replaced single-screen layout (`FibreMonitor/App/FibreMonitorApp.swift`, `FibreMonitor/Views/MainTabView.swift`) with a 4-tab `TabView` (`Dashboard`, `Clients`, `Wi-Fi`, `Settings`):
  - **Dashboard (`FibreMonitor/Views/DashboardView.swift`):** Top router status header (profile name, switcher menu for 2+ profiles, detected model, PON registration pill, LIVE/LOGGED OUT dot + last update, Reconnect button when logged out); Optical Rx Power card with single numeric dBm readout, quality badge, and calibrated horizontal range bar matching `OpticalInfo.Quality` zones (`< -27` Bad, `-27 to -24` Weak, `-24 to -8` Good, `> -8` Too strong); live Download/Upload cards + 60s sparkline; conditional 2x2 metrics grid (WAN status/IP/CGNAT, PPPoE/WAN uptime, conditional ONT uptime, conditional Tx laser power / optics temp, tappable Active Devices count); conditional System Load card with CPU/Memory progress bars shown only when `health.hasCpuOrMemory`; soft destructive Restart Fibre Router button with confirmation alert.
  - **Clients (`FibreMonitor/Views/ClientsTabView.swift`):** Searchable list (`.searchable`) across name, IP, MAC, and vendor, split into Online and collapsible Offline sections with band/port badges and non-zero traffic rates (`TrafficRateFormatter`), plus `ClientDetailSheet` showing full metadata, lease remaining, local iPhone rename, and offline removal with confirmation.
  - **Wi-Fi (`FibreMonitor/Views/WifiTabView.swift`):** Radio toggles with confirmation alert, SSIDs grouped by band (`2.4 GHz`, `5 GHz`), and on-demand `WifiQrSheet` backed by `CoreImage` QR generation (`WIFI:T:...`) with Share sheet, Reveal/Copy passphrase, and immediate clearing on dismiss or app background.
  - **Settings (`FibreMonitor/Views/SettingsTabView.swift`):** Inline Phase 1 multi-router profile list (switch, add, edit, reorder, delete), poll interval stepper, navigation links for Diagnostics and Home Network (`LanCard` showing `secondaryIp`), explicit `Log Out of Router` / `Reconnect` action, and About details.
- Updated `FibreMonitor/Views/LiquidGlass.swift` so pre-iOS 26 surfaces use `.regularMaterial` while iOS 26+ uses system Liquid Glass, and added VoiceOver labels/values and Dynamic Type fonts across `MetricViews.swift`, `DashboardView.swift`, `ClientsTabView.swift`, and `WifiTabView.swift`.
- Added ephemeral `WlanBasic.asp` parsing (`WifiAuthMode`, `WifiSsidConfig`, `WifiQrPayload`, `HuaweiOntClient.parseWlanBasic(_:)`, `fetchWlanBasic`) in `OntModels.swift` and `HuaweiOntClient.swift` without caching Wi-Fi passphrases in `SettingsStore` or ViewModel state.
- Added unit tests in `FibreMonitorTests/WlanBasicTests.swift` covering `WlanBasic.asp` parsing, `kppUsedFlag`, password masking, QR payload escaping, ephemeral fetch, and explicit logout.

### Decisions
- **Unverified GNMTNNCE cards/tiles hidden gracefully:** On GNMTNNCE firmware where `deviceinfo.asp` and `getOpticTxRx.asp` are uncaptured/missing, System Load, ONT Uptime, and Tx Laser Power stay hidden rather than showing placeholder dashes or errors.
- **Explicit Session Logout:** Added `MonitorViewModel.logoutSession()` (`isLoggedOut` flag) so logging out from Settings stops background polling until the user taps `Reconnect`, pulls to refresh, or switches routers.

---

## Needs capture / Unverified on GNMTNNCE hardware
- `POST /html/ssmp/common/getOpticTxRx.asp` (Tx power, optical temperature, voltage, bias) — referenced in `index.asp`, not captured.
- `GET /html/ssmp/deviceinfo/deviceinfo.asp` (CPU, memory, ONT uptime, serial, firmware) — in menu, not captured.
- `bbsp/maintenance/diagnosecommon.asp` (`IPPingDiagnostics` / `TraceRouteDiagnostics`) — in menu, not captured.
- `POST /logout.cgi?RequestFile=html/logout.html` — not captured on GNMTNNCE.
- `GET /html/amp/wlanbasic/WlanBasic.asp` vs `?2G`/`?5G` behavior when router uses a different firmware variant or `wifiPasswordMask = '1'`.
- Non-zero `TrafficSendRate` / `TrafficRecvRate` unit confirmation (all devices in `bbsp_common_GetLanUserDevInfo.asp` reported `"0"`).
- Live `SystemKeychainStore` migration on a physical device.
