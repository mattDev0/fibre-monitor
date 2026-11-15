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

    @State private var showRouterRename = false
    @State private var showLocalRename = false
    @State private var localAliasInput = ""
    @State private var confirmRemove = false

    private var currentDevice: OntDevice {
        viewModel.devices.first(where: { $0.mac == device.mac }) ?? device
    }

    private var canRenameOnRouter: Bool {
        currentDevice.domain.hasPrefix("InternetGatewayDevice.LANDevice.1.X_HW_UserDev.")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Name", value: viewModel.name(for: currentDevice))
                    LabeledContent("Status", value: currentDevice.isOnline ? "Online (\(currentDevice.connectedText))" : "Offline")
                    LabeledContent("Connection", value: currentDevice.port.label)
                    if !currentDevice.ip.isEmpty {
                        LabeledContent("IP Address", value: currentDevice.ip)
                    }
                    LabeledContent("MAC Address", value: currentDevice.mac)
                }

                if currentDevice.hasTrafficRates {
                    Section("Live Traffic") {
                        if let down = currentDevice.trafficRecvRate {
                            LabeledContent("Download Rate", value: TrafficRateFormatter.string(bytesPerSecond: down))
                        }
                        if let up = currentDevice.trafficSendRate {
                            LabeledContent("Upload Rate", value: TrafficRateFormatter.string(bytesPerSecond: up))
                        }
                    }
                }

                Section("Reported Details") {
                    if !currentDevice.routerAlias.isEmpty && currentDevice.routerAlias != "--" {
                        LabeledContent("Router Name", value: currentDevice.routerAlias)
                    }
                    if !currentDevice.hostName.isEmpty && currentDevice.hostName != "--" {
                        LabeledContent("Hostname", value: currentDevice.hostName)
                    }
                    if !currentDevice.dhcpVendor.isEmpty && currentDevice.dhcpVendor != "--" {
                        LabeledContent("DHCP Vendor", value: currentDevice.dhcpVendor)
                    }
                    if let lease = currentDevice.leaseSecondsRemaining, lease > 0 {
                        LabeledContent("Lease Remaining", value: InternetCard.uptime(lease))
                    }
                }

                Section {
                    Button {
                        showRouterRename = true
                    } label: {
                        Label("Rename on Router", systemImage: "pencil")
                    }
                    .disabled(!canRenameOnRouter || !viewModel.isConnected)

                    Button {
                        localAliasInput = viewModel.settings.alias(for: currentDevice.mac) ?? ""
                        showLocalRename = true
                    } label: {
                        Label("Rename on This iPhone Only", systemImage: "iphone")
                    }

                    if !currentDevice.isOnline {
                        Button(role: .destructive) {
                            confirmRemove = true
                        } label: {
                            Label("Remove from Router List", systemImage: "trash")
                        }
                    }
                } footer: {
                    if !canRenameOnRouter {
                        Text("This device record cannot be renamed on the router; use Rename on This iPhone Only.")
                    } else if !viewModel.isConnected {
                        Text("Reconnect to the router to save a name on the router.")
                    } else {
                        Text("Rename on Router updates the alias stored on the ONT; Rename on This iPhone Only keeps a private label on this device.")
                    }
                }
            }
            .navigationTitle(viewModel.name(for: currentDevice))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showRouterRename) {
            ClientRouterRenameSheet(viewModel: viewModel, device: currentDevice)
        }
        .alert("Rename on This iPhone Only", isPresented: $showLocalRename) {
            TextField("Device name", text: $localAliasInput)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                viewModel.settings.setAlias(localAliasInput, for: currentDevice.mac)
                Haptics.notify(.success)
            }
        } message: {
            Text("Saved locally on this iPhone only. Leave empty to use the router's name.")
        }
        .confirmationDialog(
            "Remove \(viewModel.name(for: currentDevice))?",
            isPresented: $confirmRemove,
            titleVisibility: .visible
        ) {
            Button("Remove from List", role: .destructive) {
                Task {
                    await viewModel.removeDevice(currentDevice)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This only clears the offline device from the router's list. If it connects again it will reappear.")
        }
    }
}

private struct ClientRouterRenameSheet: View {
    @ObservedObject var viewModel: MonitorViewModel
    let device: OntDevice
    @Environment(\.dismiss) private var dismiss

    @State private var aliasInput = ""
    @State private var isSaving = false
    @State private var errorText: String?

    private var trimmedInput: String {
        aliasInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validationError: String? {
        do {
            _ = try HuaweiOntClient.validateDeviceAlias(aliasInput)
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "Invalid device name."
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Device name on router", text: $aliasInput)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                } header: {
                    Text("Router Alias")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(trimmedInput.utf8.count)/64 UTF-8 bytes")
                            .foregroundColor(trimmedInput.utf8.count > 64 ? .red : .secondary)
                        if let validationError, !aliasInput.isEmpty {
                            Text(validationError)
                                .foregroundColor(.red)
                        } else {
                            Text("Updates UserDevAlias on the router and clears any iPhone-only nickname.")
                        }
                    }
                }

                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.subheadline)
                    }
                }
            }
            .navigationTitle("Rename on Router")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") {
                            Task { await submit() }
                        }
                        .disabled(validationError != nil)
                    }
                }
            }
        }
        .onAppear {
            if aliasInput.isEmpty {
                let seed = device.routerAlias.isEmpty ? device.displayName : device.routerAlias
                aliasInput = seed == "Unknown device" ? "" : seed
            }
        }
    }

    private func submit() async {
        isSaving = true
        errorText = nil
        do {
            try await viewModel.renameDeviceOnRouter(device, alias: aliasInput)
            dismiss()
        } catch {
            errorText = MonitorViewModel.describe(error, host: viewModel.settings.host)
        }
        isSaving = false
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
