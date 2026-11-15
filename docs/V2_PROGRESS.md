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
**Status:** Implemented and tested against synthetic GNMTNNCE fixtures (awaiting CI verification).

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
