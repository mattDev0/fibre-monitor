import SwiftUI

struct DevicesCard: View {
    @ObservedObject var viewModel: MonitorViewModel
    @State private var showOffline = false
    @State private var renaming: OntDevice?
    @State private var newName = ""
    @State private var removing: OntDevice?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "laptopcomputer.and.iphone", title: "Devices") {
                Pill(text: "\(viewModel.onlineDevices.count) online", color: .accentColor)
            }

            if visible.isEmpty {
                Text(viewModel.isConnected ? "No devices connected" : "Waiting for the router…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ForEach(visible) { device in
                Button {
                    newName = viewModel.settings.alias(for: device.mac) ?? ""
                    renaming = device
                } label: {
                    DeviceRow(device: device, name: viewModel.name(for: device))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button {
                        newName = viewModel.settings.alias(for: device.mac) ?? ""
                        renaming = device
                    } label: { Label("Rename", systemImage: "pencil") }
                    if !device.isOnline {
                        Button(role: .destructive) { removing = device } label: {
                            Label("Remove from list", systemImage: "trash")
                        }
                    }
                }
            }

            let offlineCount = viewModel.devices.count - viewModel.onlineDevices.count
            if offlineCount > 0 {
                Button(showOffline ? "Hide offline devices" : "Show \(offlineCount) offline devices") {
                    withAnimation { showOffline.toggle() }
                }
                .font(.caption.weight(.semibold))
                .liquidGlassSmallButton()
            }
        }
        .liquidGlassCard()
        .confirmationDialog(removing.map { "Remove \(viewModel.name(for: $0))?" } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove from list", role: .destructive) {
                if let d = removing { Task { await viewModel.removeDevice(d) } }
                removing = nil
            }
        } message: {
            Text("This only clears the offline device from the router's list. If it connects again it will reappear.")
        }
        .alert("Rename device", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let d = renaming { viewModel.settings.setAlias(newName, for: d.mac) }
                renaming = nil
            }
        } message: {
            Text("Saved on this iPhone only. Leave empty to use the router's name.")
        }
    }

    private var visible: [OntDevice] {
        showOffline ? viewModel.devices : viewModel.onlineDevices
    }
}

private struct DeviceRow: View {
    let device: OntDevice
    let name: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.port.isWifi ? "wifi" : "cable.connector")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(device.isOnline ? .accentColor : .secondary)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(device.isOnline ? 0.15 : 0.05), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(device.ip.isEmpty ? device.mac : device.ip)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(device.port.label).font(.caption2.weight(.bold)).foregroundColor(.secondary)
                if device.isOnline {
                    Text(device.connectedText).font(.caption2).foregroundColor(.secondary)
                } else {
                    Text("Offline").font(.caption2).foregroundColor(.secondary)
                }
            }
        }
        .padding(10)
        .liquidGlassPill()
        .opacity(device.isOnline ? 1 : 0.6)
    }
}
