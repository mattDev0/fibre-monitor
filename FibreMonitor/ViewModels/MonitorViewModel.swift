import Foundation
import SwiftUI

@MainActor
public final class MonitorViewModel: ObservableObject {
    @Published public private(set) var traffic = TrafficState()
    @Published public private(set) var wan = WanInfo()
    @Published public private(set) var optical = OpticalInfo()
    @Published public private(set) var devices: [OntDevice] = []
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
                if let d = try? await client.fetchDevices() { devices = d }
            }
            isConnected = true
            errorMessage = nil
            lastUpdate = Date()
        } catch {
            isConnected = false
            errorMessage = Self.describe(error)
        }
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
