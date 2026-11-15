import Foundation
import Network
import SwiftUI
import UIKit

public enum AppTab: Hashable, Sendable {
    case dashboard, clients, wifi, settings
}

@MainActor
public final class MonitorViewModel: ObservableObject {
    @Published public var selectedTab: AppTab = .dashboard
    @Published public private(set) var isLoggedOut = false
    @Published public private(set) var traffic = TrafficState()
    @Published public private(set) var wan = WanInfo()
    @Published public private(set) var optical = OpticalInfo()
    @Published public private(set) var devices: [OntDevice] = []
    @Published public private(set) var health = RouterHealth()
    @Published public private(set) var wifi = WifiState()
    @Published public private(set) var lan = LanInfo()
    @Published public private(set) var isWifiSaving = false

    public enum DiagnosticMode: String, CaseIterable { case ping = "Ping", traceroute = "Traceroute" }
    @Published public var diagnosticMode: DiagnosticMode = .ping
    @Published public var diagnosticHost = "8.8.8.8"
    @Published public var pingCount = 4
    @Published public private(set) var diagnosticOutput = DiagnosticOutput()
    @Published public private(set) var isDiagnosing = false
    private var diagnosticTask: Task<Void, Never>?
    @Published public private(set) var isConnected = false
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var lastUpdate: Date?
    @Published public var errorMessage: String?
    @Published public private(set) var isConnectionFailure = false
    @Published public var actionMessage: String?
    @Published public var awaitingRouterSelection: Bool
    @Published public private(set) var isPhoneOnWifi = true

    public let settings: SettingsStore
    private let client: HuaweiOntClient
    private let pathMonitor = NWPathMonitor()
    private var pollTask: Task<Void, Never>?
    private var lastSlowPoll: Date = .distantPast
    private let slowInterval: TimeInterval = 10
    // Health, Wi-Fi and LAN come from full web pages (50-130 KB), so poll them rarely.
    private var lastPagePoll: Date = .distantPast
    private let pageInterval: TimeInterval = 30
    private var lastLanPoll: Date = .distantPast
    private let lanInterval: TimeInterval = 300

    public init(settings: SettingsStore = .shared, transport: OntTransport = URLSessionOntTransport()) {
        self.settings = settings
        self.client = HuaweiOntClient(credentials: settings.credentials, transport: transport)
        self.awaitingRouterSelection = settings.profiles.count >= 2
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let onWifi = path.usesInterfaceType(.wifi)
            Task { @MainActor [weak self] in
                self?.isPhoneOnWifi = onWifi
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "dev.mattdev0.fibremonitor.netpath", qos: .utility))
    }

    deinit {
        pathMonitor.cancel()
    }

    public var onlineDevices: [OntDevice] { devices.filter(\.isOnline) }

    public var displayModelName: String {
        if !health.model.isEmpty { return health.model }
        if let detected = settings.activeProfile?.detectedModel, !detected.isEmpty { return detected }
        return "OptiXstar ONT"
    }

    public var shouldSuggestFallbackHost: Bool {
        isConnectionFailure && settings.activeProfile != nil && !settings.host.isEmpty && settings.host != "192.168.100.1"
    }

    public func name(for device: OntDevice) -> String {
        settings.alias(for: device.mac) ?? device.displayName
    }

    // MARK: Polling & Router Switching

    public func startPolling() {
        guard pollTask == nil, !awaitingRouterSelection, !isLoggedOut else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce()
                let seconds = max(1, self.settings.pollIntervalSeconds)
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            }
        }
    }

    /// Stops polling and logs out, so the router's web page stays usable for others.
    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        Task { await client.logout() }
    }

    /// Explicit user-triggered logout from Settings. Pauses polling until Reconnect is tapped.
    public func logoutSession() async {
        pollTask?.cancel()
        pollTask = nil
        diagnosticTask?.cancel()
        diagnosticTask = nil
        isLoggedOut = true
        isConnected = false
        isRefreshing = false
        await client.logout()
        actionMessage = "Logged out of router."
    }

    public func reconnectSession() {
        isLoggedOut = false
        errorMessage = nil
        startPolling()
    }

    /// Switches to a different router profile: logs out of the old session, resets cookies & view state, and polls the new one.
    public func switchRouter(to profile: RouterProfile) async {
        pollTask?.cancel()
        pollTask = nil
        diagnosticTask?.cancel()
        diagnosticTask = nil
        clearViewState()
        isLoggedOut = false
        awaitingRouterSelection = false

        await client.logout()
        settings.selectProfile(profile.id)
        await client.switchCredentials(settings.credentials)
        await pollOnce()
    }

    public func selectRouterAndStart(_ profile: RouterProfile) {
        Task {
            await switchRouter(to: profile)
            startPolling()
        }
    }

    public func settingsChanged() {
        pollTask?.cancel()
        pollTask = nil
        diagnosticTask?.cancel()
        diagnosticTask = nil
        clearViewState()
        isLoggedOut = false
        awaitingRouterSelection = false
        Task {
            await client.logout()
            await client.switchCredentials(settings.credentials)
            if settings.isConfigured {
                await pollOnce()
                startPolling()
            }
        }
    }

    public func useFallbackHost(_ fallbackHost: String = "192.168.100.1") async {
        guard var profile = settings.activeProfile else { return }
        profile.host = fallbackHost
        settings.updateProfile(profile)
        isLoggedOut = false
        errorMessage = nil
        isConnectionFailure = false
        await client.switchCredentials(settings.credentials)
        await pollOnce()
    }

    public func refreshAll() async {
        isLoggedOut = false
        lastSlowPoll = .distantPast
        lastPagePoll = .distantPast
        lastLanPoll = .distantPast
        await pollOnce()
        startPolling()
    }

    private func clearViewState() {
        traffic = TrafficState()
        wan = WanInfo()
        optical = OpticalInfo()
        devices = []
        health = RouterHealth()
        wifi = WifiState()
        lan = LanInfo()
        diagnosticOutput = DiagnosticOutput()
        isDiagnosing = false
        isConnected = false
        isRefreshing = false
        lastUpdate = nil
        errorMessage = nil
        isConnectionFailure = false
        actionMessage = nil
        lastSlowPoll = .distantPast
        lastPagePoll = .distantPast
        lastLanPoll = .distantPast
    }

    public func pollOnce() async {
        guard settings.activeProfile != nil else {
            isConnected = false
            isConnectionFailure = false
            errorMessage = "Add a router in Settings to get started."
            return
        }
        guard settings.isConfigured else {
            isConnected = false
            isConnectionFailure = false
            errorMessage = OntError.notConfigured.errorDescription
            return
        }
        if await client.isLoginBlocked {
            isConnected = false
            isConnectionFailure = false
            errorMessage = OntError.loginRejected.errorDescription
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            traffic = try await client.pollTraffic()
            if let activeId = settings.activeProfile?.id, let identity = await client.detectedIdentity {
                settings.recordDetection(for: activeId, model: identity.model, cfgMode: identity.cfgMode)
            }
            if Date().timeIntervalSince(lastSlowPoll) >= slowInterval {
                lastSlowPoll = Date()
                if let w = try? await client.fetchWan() { wan = w }
                if let o = try? await client.fetchOptical() { optical = o }
                if Date().timeIntervalSince(lastPagePoll) >= pageInterval {
                    lastPagePoll = Date()
                    // Wi-Fi first: it tells the device list which SSID is on which band.
                    if let w = try? await client.fetchWifi() { wifi = w }
                    if let h = try? await client.fetchHealth() { health = h }
                }
                if let d = try? await client.fetchDevices() { devices = d }
                if Date().timeIntervalSince(lastLanPoll) >= lanInterval {
                    lastLanPoll = Date()
                    if let l = try? await client.fetchLan() { lan = l }
                }
            }
            isConnected = true
            isConnectionFailure = false
            errorMessage = nil
            lastUpdate = Date()
        } catch {
            isConnected = false
            isConnectionFailure = Self.isReachabilityError(error)
            errorMessage = Self.describe(error, host: settings.host)
        }
    }

    public func fetchWifiSsidConfig(for network: WifiNetwork) async throws -> WifiSsidConfig {
        let configs = try await client.fetchWlanBasic(bandHint: network.band, ssidIndex: network.ssidIndex)
        guard let match = configs.first(where: { $0.ssidIndex == network.ssidIndex }) else {
            throw OntError.badResponse("Wi-Fi network configuration")
        }
        return match
    }

    public func setRadio(_ radio: WifiRadio, enabled: Bool) async {
        guard !isWifiSaving else { return }
        isWifiSaving = true
        defer { isWifiSaving = false }
        do {
            wifi = try await client.setRadio(radio.index, enabled: enabled)
            Haptics.notify(.success)
            actionMessage = "\(Self.bandName(radio.band)) Wi-Fi turned \(enabled ? "on" : "off"), confirmed by the router."
        } catch {
            Haptics.notify(.error)
            actionMessage = Self.describe(error, host: settings.host)
            if let w = try? await client.fetchWifi() { wifi = w }
        }
    }

    /// Saves a new SSID/passphrase for an editable WPA2-PSK or WPA3-PSK SSID via `#704`.
    public func updateWifiCredentials(
        config: WifiSsidConfig,
        newSsid: String,
        newPassword: String
    ) async throws -> WifiUpdateResult {
        guard !isWifiSaving else { throw OntError.badResponse("Wi-Fi update already in progress") }
        isWifiSaving = true
        defer { isWifiSaving = false }
        do {
            let result = try await client.updateWifiCredentials(
                config: config,
                newSsid: newSsid,
                newPassword: newPassword
            )
            lastPagePoll = Date()
            if result.connectionDropped {
                isConnected = false
                isConnectionFailure = true
                Haptics.notify(.warning)
                actionMessage = "Wi-Fi settings were sent. Rejoin \"\(newSsid)\" on this iPhone to reconnect."
                errorMessage = "Disconnected while saving Wi-Fi settings. Rejoin \"\(newSsid)\" on Wi-Fi to continue monitoring."
            } else {
                if let updatedWifi = result.wifi { wifi = updatedWifi }
                Haptics.notify(.success)
                actionMessage = "Wi-Fi updated to \"\(newSsid)\". Devices may take a few seconds to reconnect."
            }
            return result
        } catch {
            Haptics.notify(.error)
            throw error
        }
    }

    // MARK: Diagnostics

    public func startDiagnostic() {
        guard !isDiagnosing else { return }
        let mode = diagnosticMode, host = diagnosticHost, count = pingCount
        isDiagnosing = true
        diagnosticOutput = DiagnosticOutput(text: "Starting \(mode.rawValue.lowercased()) to \(host)…\n")
        diagnosticTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isDiagnosing = false }
            do {
                if mode == .ping {
                    try await self.client.startPing(host: host, count: count)
                } else {
                    try await self.client.startTrace(host: host)
                }
                // Ping takes about a second per reply; traceroute up to 30 hops can take a couple of minutes.
                let deadline = Date().addingTimeInterval(mode == .ping ? Double(count) * 11 + 10 : 180)
                while !Task.isCancelled && Date() < deadline {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    let out = mode == .ping ? try await self.client.pingOutput() : try await self.client.traceOutput()
                    if !out.text.isEmpty || out.isFinished { self.diagnosticOutput = out }
                    if out.isFinished { return }
                }
                if !Task.isCancelled {
                    self.diagnosticOutput.status = "Stopped waiting for the router"
                }
            } catch is CancellationError {
            } catch {
                self.diagnosticOutput = DiagnosticOutput(text: Self.describe(error, host: self.settings.host), status: "Error")
            }
        }
    }

    /// Stops following the output; the router finishes the test on its own.
    public func stopDiagnostic() {
        diagnosticTask?.cancel()
        diagnosticTask = nil
        isDiagnosing = false
        if diagnosticOutput.status == nil { diagnosticOutput.status = "Stopped" }
    }

    // MARK: Devices

    public func renameDeviceOnRouter(_ device: OntDevice, alias: String) async throws {
        do {
            let trimmed = try HuaweiOntClient.validateDeviceAlias(alias)
            devices = try await client.renameDevice(device, alias: trimmed)
            // Clear any phone-only alias override so the new router name displays immediately.
            settings.setAlias("", for: device.mac)
            Haptics.notify(.success)
            actionMessage = "Renamed device on router to \(trimmed)."
        } catch {
            Haptics.notify(.error)
            throw error
        }
    }

    public func removeDevice(_ device: OntDevice) async {
        do {
            devices = try await client.deleteDevice(device)
            Haptics.notify(.success)
            actionMessage = "Removed \(name(for: device)) from the device list."
        } catch {
            Haptics.notify(.error)
            actionMessage = Self.describe(error, host: settings.host)
        }
    }

    static func bandName(_ band: String) -> String {
        band.replacingOccurrences(of: "GHz", with: " GHz")
    }

    public func reboot() async {
        do {
            try await client.reboot()
            Haptics.notify(.warning)
            actionMessage = "Restart sent. The router will be back in about 2 minutes."
        } catch {
            Haptics.notify(.error)
            actionMessage = "Restart failed: \(Self.describe(error, host: settings.host))"
        }
    }

    static func isReachabilityError(_ error: Error) -> Bool {
        guard let url = error as? URLError else { return false }
        switch url.code {
        case .timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

    static func describe(_ error: Error, host: String = "") -> String {
        if let ont = error as? OntError { return ont.errorDescription ?? "\(ont)" }
        if isReachabilityError(error) {
            if !host.isEmpty && host != "192.168.100.1" {
                return "Can't reach the router at \(host). Make sure this iPhone is on its Wi-Fi, or try 192.168.100.1."
            }
            return "Can't reach the router. Make sure this iPhone is on its Wi-Fi."
        }
        return error.localizedDescription
    }
}

@MainActor
public enum Haptics {
    public static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(type)
    }

    public static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }
}
