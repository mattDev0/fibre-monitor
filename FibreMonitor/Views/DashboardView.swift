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
                    StatusRow(viewModel: viewModel)

                    if let err = viewModel.errorMessage {
                        ErrorBanner(message: err) { showSettings = true }
                    }

                    SpeedSection(traffic: viewModel.traffic)
                    FibreCard(optical: viewModel.optical)
                    InternetCard(wan: viewModel.wan)
                    DevicesCard(viewModel: viewModel)
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .background { LiquidGlassBackground() }
            .refreshable { await viewModel.refreshAll() }
            .navigationTitle("Fibre")
            .toolbar {
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
        .sheet(isPresented: $showSettings) {
            SettingsSheetView(settings: viewModel.settings) {
                viewModel.settingsChanged()
            }
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
            if !viewModel.settings.isConfigured { showSettings = true }
            viewModel.startPolling()
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active: viewModel.startPolling()
            case .background: viewModel.stopPolling()
            default: break
            }
        }
    }
}

private struct StatusRow: View {
    @ObservedObject var viewModel: MonitorViewModel

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
            Text(viewModel.settings.host)
                .font(.caption2.monospaced())
                .foregroundColor(.secondary)
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
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(message)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Settings", action: openSettings)
                .font(.caption.weight(.semibold))
        }
        .liquidGlassPanel(padding: 12)
    }
}
