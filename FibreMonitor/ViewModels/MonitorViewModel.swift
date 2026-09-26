import Foundation
import SwiftUI

@MainActor
public final class MonitorViewModel: ObservableObject {
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
    @Published public var actionMessage: String?

    public let settings: SettingsStore
    private let client: HuaweiOntClient
    private var pollTask: Task<Void, Never>?
    private var lastSlowPoll: Date = .distantPast
    private let slowInterval: TimeInterval = 10
    // Health, Wi-Fi and LAN come from full web pages (50-130 KB), so poll them rarely.
    private var lastPagePoll: Date = .distantPast
    private let pageInterval: TimeInterval = 30
    private var lastLanPoll: Date = .distantPast
    private let lanInterval: TimeInterval = 300

    public init(settings: SettingsStore = .shared) {
        self.settings = settings
        self.client = HuaweiOntClient(credentials: settings.credentials)
    }

    public var onlineDevices: [OntDevice] { devices.filter(\.isOnline) }

    public func name(for device: OntDevice) -> String {
        settings.alias(for: device.mac) ?? device.displayName
    }

    // MARK: Polling

    public func startPolling() {
        guard pollTask == nil else { return }
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

    public func settingsChanged() {
        errorMessage = nil
        lastSlowPoll = .distantPast
        traffic = TrafficState()
        Task {
            await client.update(credentials: settings.credentials)
            await pollOnce()
        }
    }

    public func refreshAll() async {
        lastSlowPoll = .distantPast
        lastPagePoll = .distantPast
        lastLanPoll = .distantPast
        await pollOnce()
    }

    private func pollOnce() async {
        guard settings.isConfigured else {
            isConnected = false
            errorMessage = OntError.notConfigured.errorDescription
            return
        }
        if await client.isLoginBlocked {
            isConnected = false
            errorMessage = OntError.loginRejected.errorDescription
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            traffic = try await client.pollTraffic()
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
            errorMessage = nil
            lastUpdate = Date()
        } catch {
            isConnected = false
            errorMessage = Self.describe(error)
        }
    }

    public func setRadio(_ radio: WifiRadio, enabled: Bool) async {
        guard !isWifiSaving else { return }
        isWifiSaving = true
        defer { isWifiSaving = false }
        do {
            wifi = try await client.setRadio(radio.index, enabled: enabled)
            actionMessage = "\(Self.bandName(radio.band)) Wi-Fi turned \(enabled ? "on" : "off"), confirmed by the router."
        } catch {
            actionMessage = Self.describe(error)
            if let w = try? await client.fetchWifi() { wifi = w }
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
                self.diagnosticOutput = DiagnosticOutput(text: Self.describe(error), status: "Error")
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

    public func removeDevice(_ device: OntDevice) async {
        do {
            devices = try await client.deleteDevice(device)
            actionMessage = "Removed \(name(for: device)) from the device list."
        } catch {
            actionMessage = Self.describe(error)
        }
    }

    static func bandName(_ band: String) -> String {
        band.replacingOccurrences(of: "GHz", with: " GHz")
    }

    public func reboot() async {
        do {
            try await client.reboot()
            actionMessage = "Restart sent. The router will be back in about 2 minutes."
        } catch {
            actionMessage = "Restart failed: \(Self.describe(error))"
        }
    }

    static func describe(_ error: Error) -> String {
        if let ont = error as? OntError { return ont.errorDescription ?? "\(ont)" }
        if let url = error as? URLError {
            switch url.code {
            case .timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
                return "Can't reach the router. Make sure this iPhone is on its Wi-Fi."
            default:
                return url.localizedDescription
            }
        }
        return error.localizedDescription
    }
}
