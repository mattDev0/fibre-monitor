# Fibre Monitor 2.0 Progress

## Phase 1: Router profiles (multi-router)
**Status:** Implemented and tested against synthetic fixtures (awaiting CI verification).

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
- Added unit tests in `FibreMonitorTests/RouterProfileTests.swift` covering fresh install, v1 migration (including failed-write safety), per-profile Keychain and aliases, profile CRUD/reorder, MTN template defaults, host validation, `index.asp` identity parsing, router switching order (`logout` -> cookie reset -> clear state -> new login), and `"Try 192.168.100.1"` fallback.

### Decisions
- **Launch picker behavior:** When 2+ profiles exist at launch, polling does not start automatically until the user selects which router they are currently connected to, avoiding accidental login attempts against the wrong router (and protecting against login lockout).
- **Empty install:** A clean 2.0 install with no 1.x settings starts with zero profiles and opens Settings / Add Router so the friend can choose the `"New router (MTN)"` or standard template and enter the password himself.

### Unverified on hardware
- Live `SystemKeychainStore` migration and `ProductName`/`CfgMode` capture on the physical 1.x and GNMTNNCE routers (verified in CI via `InMemoryPasswordStore` and synthetic `index.asp` fixtures).
