import SwiftUI

struct WifiCard: View {
    @ObservedObject var viewModel: MonitorViewModel
    @State private var pending: (radio: WifiRadio, enable: Bool)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "wifi", title: "Wi-Fi") {
                if viewModel.isWifiSaving { ProgressView() }
            }
            if viewModel.wifi.radios.isEmpty {
                Text(viewModel.isConnected ? "Reading Wi-Fi…" : "Waiting for the router…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            ForEach(viewModel.wifi.radios) { radio in
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: radio.enabled ? "wifi" : "wifi.slash")
                        .foregroundColor(radio.enabled ? .accentColor : .secondary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(MonitorViewModel.bandName(radio.band)).font(.subheadline.weight(.semibold))
                        let names = viewModel.wifi.networks(on: radio).map(\.name).filter { !$0.isEmpty }
                        Text(radio.enabled ? (names.isEmpty ? "On" : names.joined(separator: " · ")) : "Off")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { radio.enabled },
                        set: { pending = (radio, $0) }
                    ))
                    .labelsHidden()
                    .disabled(viewModel.isWifiSaving || !viewModel.isConnected)
                }
                .padding(10)
                .liquidGlassPill()
            }
        }
        .liquidGlassCard()
        .alert(pending.map { "Turn \(MonitorViewModel.bandName($0.radio.band)) Wi-Fi \($0.enable ? "on" : "off")?" } ?? "",
               isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Cancel", role: .cancel) { pending = nil }
            Button(pending?.enable == false ? "Turn Off" : "Turn On", role: pending?.enable == false ? .destructive : nil) {
                if let p = pending { Task { await viewModel.setRadio(p.radio, enabled: p.enable) } }
                pending = nil
            }
        } message: {
            Text(pending?.enable == false
                 ? "Devices on this band disconnect and move to the other band if they can. If this iPhone is on it, it will reconnect."
                 : "The radio takes a few seconds to start.")
        }
    }
}

struct HealthCard: View {
    let health: RouterHealth

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "cpu", title: "Router") {
                if !health.model.isEmpty {
                    Text(health.model).font(.caption2.weight(.bold)).foregroundColor(.secondary)
                }
            }
            HStack(spacing: 8) {
                Readout(label: "CPU", value: health.cpuPercent.map { "\($0)%" } ?? "—")
                Readout(label: "Memory", value: health.memoryPercent.map { "\($0)%" } ?? "—")
                Readout(label: "Up for", value: InternetCard.uptime(health.uptimeSeconds ?? 0))
            }
            if !health.firmware.isEmpty {
                Readout(label: "Firmware", value: [health.firmware, health.hardware].filter { !$0.isEmpty }.joined(separator: " · "))
            }
        }
        .liquidGlassCard()
    }
}

struct LanCard: View {
    let lan: LanInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "network", title: "Home Network") {
                Pill(text: lan.dhcpEnabled ? "DHCP on" : "DHCP off", color: lan.dhcpEnabled ? .green : .orange)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                Readout(label: "Router address", value: lan.routerIp)
                Readout(label: "Lease time", value: lan.leaseSeconds > 0 ? InternetCard.uptime(lan.leaseSeconds) : "—")
                Readout(label: "Address pool", value: lan.poolStart.isEmpty ? "—" : "\(lan.poolStart) – \(lan.poolEnd.split(separator: ".").last.map(String.init) ?? "")")
                Readout(label: "DNS for devices", value: lan.dnsServers.isEmpty ? "Router (ISP DNS)" : lan.dnsServers.joined(separator: ", "))
            }
        }
        .liquidGlassCard()
    }
}
