import SwiftUI

public struct DashboardView: View {
    @StateObject private var viewModel = MonitorViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var showRebootAlert = false

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    StatusRow(viewModel: viewModel, settings: viewModel.settings)

                    if let err = viewModel.errorMessage {
                        ErrorBanner(
                            message: err,
                            suggestFallback: viewModel.shouldSuggestFallbackHost,
                            onTryFallback: { Task { await viewModel.useFallbackHost() } },
                            openSettings: { showSettings = true }
                        )
                    }

                    SpeedSection(traffic: viewModel.traffic)
                    FibreCard(optical: viewModel.optical)
                    InternetCard(wan: viewModel.wan)
                    WifiCard(viewModel: viewModel)
                    DevicesCard(viewModel: viewModel)
                    DiagnosticsCard(viewModel: viewModel)
                    HealthCard(health: viewModel.health)
                    LanCard(lan: viewModel.lan)
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .background { LiquidGlassBackground() }
            .refreshable { await viewModel.refreshAll() }
            .navigationTitle("Fibre")
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    RouterSwitcherMenu(viewModel: viewModel, settings: viewModel.settings) {
                        showSettings = true
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        Task { await viewModel.refreshAll() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(viewModel.isRefreshing)

                    Button(role: .destructive) {
                        showRebootAlert = true
                    } label: {
                        Label("Restart Router", systemImage: "power")
                    }
                    .tint(.red)
                    .disabled(!viewModel.isConnected)

                    Button {
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
        }
        .sheet(isPresented: $viewModel.awaitingRouterSelection) {
            RouterLaunchPickerView(viewModel: viewModel)
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheetView(viewModel: viewModel)
        }
        .alert("Restart Router?", isPresented: $showRebootAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Restart", role: .destructive) {
                Task { await viewModel.reboot() }
            }
        } message: {
            Text("Internet and Wi-Fi drop for about 2 minutes while the router restarts.")
        }
        .alert(viewModel.actionMessage ?? "", isPresented: Binding(
            get: { viewModel.actionMessage != nil },
            set: { if !$0 { viewModel.actionMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        }
        .onAppear {
            if !viewModel.awaitingRouterSelection {
                if !viewModel.settings.isConfigured {
                    showSettings = true
                } else {
                    viewModel.startPolling()
                }
            }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                if !viewModel.awaitingRouterSelection && viewModel.settings.isConfigured {
                    viewModel.startPolling()
                }
            case .background:
                viewModel.stopPolling()
            default:
                break
            }
        }
    }
}

private struct RouterSwitcherMenu: View {
    @ObservedObject var viewModel: MonitorViewModel
    @ObservedObject var settings: SettingsStore
    let openSettings: () -> Void

    var body: some View {
        if settings.profiles.count >= 2 {
            Menu {
                ForEach(settings.profiles) { profile in
                    Button {
                        guard profile.id != settings.activeProfile?.id else { return }
                        viewModel.selectRouterAndStart(profile)
                    } label: {
                        if profile.id == settings.activeProfile?.id {
                            Label("\(profile.name) (\(profile.host))", systemImage: "checkmark")
                        } else {
                            Text("\(profile.name) (\(profile.host))")
                        }
                    }
                }
                Divider()
                Button {
                    openSettings()
                } label: {
                    Label("Manage Routers…", systemImage: "slider.horizontal.3")
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "wifi.router")
                    Text(settings.activeProfile?.name ?? "Router")
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .font(.subheadline.weight(.medium))
            }
        }
    }
}

private struct StatusRow: View {
    @ObservedObject var viewModel: MonitorViewModel
    @ObservedObject var settings: SettingsStore

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.8), radius: 4)
            Text(text)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(color)
            if let last = viewModel.lastUpdate, viewModel.isConnected {
                Text("• \(last.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if let name = settings.activeProfile?.name, !name.isEmpty {
                Text("\(name) · \(settings.host)")
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            } else if !settings.host.isEmpty {
                Text(settings.host)
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
            }
        }
    }

    private var color: Color {
        viewModel.isConnected ? .green : (viewModel.isRefreshing ? .orange : .red)
    }

    private var text: String {
        viewModel.isConnected ? "LIVE" : (viewModel.isRefreshing ? "CONNECTING" : "OFFLINE")
    }
}

private struct ErrorBanner: View {
    let message: String
    let suggestFallback: Bool
    let onTryFallback: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(message)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Settings", action: openSettings)
                    .font(.caption.weight(.semibold))
            }
            if suggestFallback {
                Button("Try 192.168.100.1", action: onTryFallback)
                    .font(.caption.weight(.semibold))
                    .liquidGlassSmallButton()
            }
        }
        .liquidGlassPanel(padding: 12)
    }
}
