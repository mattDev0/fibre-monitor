import SwiftUI

public struct DashboardView: View {
    @ObservedObject var viewModel: MonitorViewModel
    @ObservedObject var settings: SettingsStore
    @State private var showRebootAlert = false

    public init(viewModel: MonitorViewModel) {
        self.viewModel = viewModel
        self.settings = viewModel.settings
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if !settings.isConfigured {
                        NoRouterCard {
                            viewModel.selectedTab = .settings
                        }
                    } else {
                        RouterHeaderCard(viewModel: viewModel, settings: settings)

                        if let err = viewModel.errorMessage, !viewModel.isLoggedOut {
                            ErrorBanner(
                                message: err,
                                suggestFallback: viewModel.shouldSuggestFallbackHost,
                                onTryFallback: { Task { await viewModel.useFallbackHost() } },
                                openSettings: { viewModel.selectedTab = .settings }
                            )
                        }

                        FibreCard(optical: viewModel.optical)
                        SpeedSection(traffic: viewModel.traffic)
                        MetricsTileGrid(viewModel: viewModel)

                        if !viewModel.wan.gateway.isEmpty || !viewModel.wan.dnsServers.isEmpty {
                            WanExtrasCard(wan: viewModel.wan)
                        }

                        if viewModel.health.hasCpuOrMemory {
                            SystemLoadCard(health: viewModel.health)
                        }

                        RebootSection(
                            isEnabled: viewModel.isConnected && !viewModel.isLoggedOut,
                            action: { showRebootAlert = true }
                        )
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background { LiquidGlassBackground() }
            .refreshable { await viewModel.refreshAll() }
            .navigationTitle("Dashboard")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    RouterSwitcherMenu(viewModel: viewModel, settings: settings) {
                        viewModel.selectedTab = .settings
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await viewModel.refreshAll() }
                    } label: {
                        if viewModel.isRefreshing {
                            ProgressView()
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(viewModel.isRefreshing || !settings.isConfigured)
                }
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
    }
}

private struct RouterHeaderCard: View {
    @ObservedObject var viewModel: MonitorViewModel
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.green.opacity(0.16))
                        .frame(width: 44, height: 44)
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.title3.weight(.semibold))
                        .foregroundColor(.green)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.activeProfile?.name ?? "Fibre Router")
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(viewModel.displayModelName) · \(settings.host)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if !viewModel.optical.registrationState.isEmpty {
                    Pill(
                        text: viewModel.optical.registrationText,
                        color: viewModel.optical.isRegistered ? .green : .orange
                    )
                }
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusColor.opacity(0.7), radius: 3)
                Text(statusText)
                    .font(.caption.weight(.bold))
                    .foregroundColor(statusColor)
                if let last = viewModel.lastUpdate, viewModel.isConnected, !viewModel.isLoggedOut {
                    Text("• Updated \(last.formatted(date: .omitted, time: .standard))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if viewModel.isLoggedOut {
                    Button("Reconnect") {
                        viewModel.reconnectSession()
                    }
                    .font(.caption.weight(.semibold))
                    .liquidGlassSmallButton()
                }
            }
        }
        .liquidGlassCard()
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        if viewModel.isLoggedOut { return .secondary }
        return viewModel.isConnected ? .green : (viewModel.isRefreshing ? .orange : .red)
    }

    private var statusText: String {
        if viewModel.isLoggedOut { return "LOGGED OUT" }
        return viewModel.isConnected ? "LIVE" : (viewModel.isRefreshing ? "CONNECTING" : "OFFLINE")
    }
}

private struct MetricsTileGrid: View {
    @ObservedObject var viewModel: MonitorViewModel

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        let wan = viewModel.wan
        let optical = viewModel.optical
        let health = viewModel.health

        LazyVGrid(columns: columns, spacing: 12) {
            MetricTile(
                icon: "globe",
                iconTint: wan.isConnected ? .green : .orange,
                title: "WAN IP",
                value: wan.ipAddress.isEmpty ? "—" : wan.ipAddress,
                pill: wan.isCarrierNat ? ("CGNAT", .orange) : (wan.isConnected ? ("Up", .green) : nil),
                subtitle: [wan.connectionType, wan.vlanId.isEmpty ? "" : "VLAN \(wan.vlanId)"]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
            )

            MetricTile(
                icon: "clock.arrow.circlepath",
                iconTint: .blue,
                title: wan.connectionType == "IPoE" ? "WAN Uptime" : "PPPoE Uptime",
                value: InternetCard.uptime(wan.uptimeSeconds),
                subtitle: wan.connectionStatus.isEmpty ? nil : wan.connectionStatus
            )

            if let ontUptime = health.uptimeSeconds, ontUptime > 0 {
                MetricTile(
                    icon: "timer",
                    iconTint: .teal,
                    title: "ONT Uptime",
                    value: InternetCard.uptime(ontUptime),
                    subtitle: health.model.isEmpty ? nil : health.model
                )
            }

            if let tx = optical.txPowerDbm {
                MetricTile(
                    icon: "arrow.up.forward.circle",
                    iconTint: .purple,
                    title: "Tx Laser Power",
                    value: String(format: "%.2f dBm", tx),
                    subtitle: optical.temperatureC.map { String(format: "Temp %.0f °C", $0) }
                )
            } else if let temp = optical.temperatureC {
                MetricTile(
                    icon: "thermometer.medium",
                    iconTint: .orange,
                    title: "Optics Temp",
                    value: String(format: "%.0f °C", temp)
                )
            }

            Button {
                viewModel.selectedTab = .clients
            } label: {
                MetricTile(
                    icon: "laptopcomputer.and.iphone",
                    iconTint: .accentColor,
                    title: "Active Devices",
                    value: "\(viewModel.onlineDevices.count)",
                    pill: ("Clients", .accentColor),
                    subtitle: viewModel.devices.count > viewModel.onlineDevices.count
                        ? "\(viewModel.devices.count - viewModel.onlineDevices.count) offline"
                        : "Tap to view all"
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Active devices: \(viewModel.onlineDevices.count). Open Clients tab.")
        }
    }
}

private struct WanExtrasCard: View {
    let wan: WanInfo

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            if !wan.gateway.isEmpty {
                Readout(label: "Gateway", value: wan.gateway)
            }
            if !wan.dnsServers.isEmpty {
                Readout(label: "ISP DNS", value: wan.dnsServers.joined(separator: ", "))
            }
        }
        .liquidGlassCard()
    }
}

private struct RebootSection: View {
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            Label("Restart Fibre Router", systemImage: "power")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .liquidGlassActionButton(tint: .red)
        .disabled(!isEnabled)
        .padding(.top, 4)
        .accessibilityHint("Shows a confirmation prompt before restarting the router")
    }
}

private struct NoRouterCard: View {
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.router")
                .font(.system(size: 40))
                .foregroundColor(.accentColor)
            Text("No Router Configured")
                .font(.headline)
            Text("Add a Huawei OptiXstar router profile in Settings to start live fibre monitoring.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Settings", action: openSettings)
                .liquidGlassActionButton()
        }
        .frame(maxWidth: .infinity)
        .liquidGlassCard()
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
