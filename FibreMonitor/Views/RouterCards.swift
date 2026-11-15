import SwiftUI

struct RouterSwitcherMenu: View {
    @ObservedObject var viewModel: MonitorViewModel
    @ObservedObject var settings: SettingsStore
    let openManageRouters: () -> Void

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
                Button(action: openManageRouters) {
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
            .accessibilityLabel("Switch router profile")
            .accessibilityValue(settings.activeProfile?.name ?? "None")
        }
    }
}

struct HealthCard: View {
    let health: RouterHealth

    var body: some View {
        SystemLoadCard(health: health)
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
                Readout(label: "Router address", value: lan.routerIp.isEmpty ? "—" : lan.routerIp)
                if !lan.secondaryIp.isEmpty {
                    Readout(label: "Secondary address", value: lan.secondaryIp)
                }
                if !lan.subnetMask.isEmpty {
                    Readout(label: "Subnet mask", value: lan.subnetMask)
                }
                Readout(label: "Lease time", value: lan.leaseSeconds > 0 ? InternetCard.uptime(lan.leaseSeconds) : "—")
                Readout(
                    label: "Address pool",
                    value: lan.poolStart.isEmpty ? "—" : "\(lan.poolStart) – \(lan.poolEnd.split(separator: ".").last.map(String.init) ?? "")"
                )
                Readout(
                    label: "DNS for devices",
                    value: lan.dnsServers.isEmpty ? "Router (ISP DNS)" : lan.dnsServers.joined(separator: ", ")
                )
            }
        }
        .liquidGlassCard()
    }
}
