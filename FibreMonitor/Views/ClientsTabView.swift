import SwiftUI

public struct ClientsTabView: View {
    @ObservedObject var viewModel: MonitorViewModel
    @State private var searchText = ""
    @State private var selectedDevice: OntDevice?
    @State private var showOffline = true

    public init(viewModel: MonitorViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if !viewModel.settings.isConfigured {
                        ClientsEmptyCard(
                            icon: "wifi.router",
                            title: "No Router Configured",
                            message: "Add a router in Settings to see connected clients."
                        )
                    } else if filteredOnline.isEmpty && filteredOffline.isEmpty {
                        ClientsEmptyCard(
                            icon: searchText.isEmpty ? "laptopcomputer.and.iphone" : "magnifyingglass",
                            title: searchText.isEmpty
                                ? (viewModel.isConnected ? "No Clients Reported" : "Waiting for Router…")
                                : "No Matching Clients",
                            message: searchText.isEmpty
                                ? "Pull down to refresh once the router responds."
                                : "Try searching by name, IP address, MAC, or vendor."
                        )
                    } else {
                        if !filteredOnline.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                CardHeader(icon: "bolt.horizontal.circle.fill", title: "Online") {
                                    Pill(text: "\(filteredOnline.count)", color: .green)
                                }
                                ForEach(filteredOnline) { device in
                                    Button {
                                        selectedDevice = device
                                    } label: {
                                        ClientRow(device: device, displayName: viewModel.name(for: device))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .liquidGlassCard()
                        }

                        if !filteredOffline.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    CardHeader(icon: "moon.zzz", title: "Offline") {
                                        Pill(text: "\(filteredOffline.count)", color: .secondary)
                                    }
                                    Button(showOffline ? "Hide" : "Show") {
                                        withAnimation { showOffline.toggle() }
                                    }
                                    .font(.caption.weight(.semibold))
                                    .liquidGlassSmallButton()
                                }
                                if showOffline {
                                    ForEach(filteredOffline) { device in
                                        Button {
                                            selectedDevice = device
                                        } label: {
                                            ClientRow(device: device, displayName: viewModel.name(for: device))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .liquidGlassCard()
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background { LiquidGlassBackground() }
            .refreshable { await viewModel.refreshAll() }
            .searchable(text: $searchText, prompt: "Search name, IP, MAC, or vendor")
            .navigationTitle("Clients")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !viewModel.devices.isEmpty {
                        Text("\(viewModel.onlineDevices.count) online")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .sheet(item: $selectedDevice) { device in
            ClientDetailSheet(viewModel: viewModel, device: currentSnapshot(of: device))
        }
    }

    private func currentSnapshot(of device: OntDevice) -> OntDevice {
        viewModel.devices.first(where: { $0.id == device.id }) ?? device
    }

    private var filteredOnline: [OntDevice] {
        filter(viewModel.devices.filter(\.isOnline))
    }

    private var filteredOffline: [OntDevice] {
        filter(viewModel.devices.filter { !$0.isOnline })
    }

    private func filter(_ items: [OntDevice]) -> [OntDevice] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return items }
        return items.filter { d in
            let local = viewModel.name(for: d).lowercased()
            return local.contains(query)
                || d.hostName.lowercased().contains(query)
                || d.routerAlias.lowercased().contains(query)
                || d.dhcpVendor.lowercased().contains(query)
                || d.ip.lowercased().contains(query)
                || d.mac.lowercased().contains(query)
                || d.port.label.lowercased().contains(query)
        }
    }
}

private struct ClientRow: View {
    let device: OntDevice
    let displayName: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.port.isWifi ? "wifi" : "cable.connector")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(device.isOnline ? .accentColor : .secondary)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(device.isOnline ? 0.14 : 0.06), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(device.ip.isEmpty ? device.mac : device.ip)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                if let rateSummary = rateText {
                    Text(rateSummary)
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Pill(text: device.port.label, color: badgeColor)
                Text(device.isOnline ? device.connectedText : "Offline")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundColor(.secondary.opacity(0.6))
        }
        .padding(10)
        .liquidGlassPill()
        .opacity(device.isOnline ? 1 : 0.68)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Double-tap to inspect device details")
    }

    private var badgeColor: Color {
        switch device.port {
        case .wifi5: return .purple
        case .wifi24: return .blue
        case .lan: return .teal
        case .other: return .secondary
        }
    }

    private var rateText: String? {
        guard device.hasTrafficRates else { return nil }
        var parts: [String] = []
        if let down = device.trafficRecvRate, down > 0 {
            parts.append("↓ \(TrafficRateFormatter.string(bytesPerSecond: down))")
        }
        if let up = device.trafficSendRate, up > 0 {
            parts.append("↑ \(TrafficRateFormatter.string(bytesPerSecond: up))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }
}

private struct ClientDetailSheet: View {
    @ObservedObject var viewModel: MonitorViewModel
    let device: OntDevice
    @Environment(\.dismiss) private var dismiss

    @State private var showLocalRename = false
    @State private var localAliasInput = ""
    @State private var confirmRemove = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Name", value: viewModel.name(for: device))
                    LabeledContent("Status", value: device.isOnline ? "Online (\(device.connectedText))" : "Offline")
                    LabeledContent("Connection", value: device.port.label)
                    if !device.ip.isEmpty {
                        LabeledContent("IP Address", value: device.ip)
                    }
                    LabeledContent("MAC Address", value: device.mac)
                }

                if device.hasTrafficRates {
                    Section("Live Traffic") {
                        if let down = device.trafficRecvRate {
                            LabeledContent("Download Rate", value: TrafficRateFormatter.string(bytesPerSecond: down))
                        }
                        if let up = device.trafficSendRate {
                            LabeledContent("Upload Rate", value: TrafficRateFormatter.string(bytesPerSecond: up))
                        }
                    }
                }

                Section("Reported Details") {
                    if !device.routerAlias.isEmpty && device.routerAlias != "--" {
                        LabeledContent("Router Name", value: device.routerAlias)
                    }
                    if !device.hostName.isEmpty && device.hostName != "--" {
                        LabeledContent("Hostname", value: device.hostName)
                    }
                    if !device.dhcpVendor.isEmpty && device.dhcpVendor != "--" {
                        LabeledContent("DHCP Vendor", value: device.dhcpVendor)
                    }
                    if let lease = device.leaseSecondsRemaining, lease > 0 {
                        LabeledContent("Lease Remaining", value: InternetCard.uptime(lease))
                    }
                }

                Section {
                    Button {
                        localAliasInput = viewModel.settings.alias(for: device.mac) ?? ""
                        showLocalRename = true
                    } label: {
                        Label("Rename on This iPhone", systemImage: "iphone.and.arrow.forward")
                    }

                    if !device.isOnline {
                        Button(role: .destructive) {
                            confirmRemove = true
                        } label: {
                            Label("Remove from Router List", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(viewModel.name(for: device))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .alert("Rename on This iPhone", isPresented: $showLocalRename) {
            TextField("Device name", text: $localAliasInput)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                viewModel.settings.setAlias(localAliasInput, for: device.mac)
            }
        } message: {
            Text("Saved locally on this iPhone only. Leave empty to use the router's name.")
        }
        .confirmationDialog(
            "Remove \(viewModel.name(for: device))?",
            isPresented: $confirmRemove,
            titleVisibility: .visible
        ) {
            Button("Remove from List", role: .destructive) {
                Task {
                    await viewModel.removeDevice(device)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This only clears the offline device from the router's list. If it connects again it will reappear.")
        }
    }
}

private struct ClientsEmptyCard: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .liquidGlassCard()
    }
}
