import SwiftUI

struct SpeedSection: View {
    let traffic: TrafficState

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                SpeedCard(title: "DOWNLOAD", mbps: traffic.downloadMbps, peak: traffic.peakDownloadMbps,
                          icon: "arrow.down.circle.fill", tint: .blue)
                SpeedCard(title: "UPLOAD", mbps: traffic.uploadMbps, peak: traffic.peakUploadMbps,
                          icon: "arrow.up.circle.fill", tint: .green)
            }
            Sparkline(samples: traffic.history)
                .frame(height: 70)
                .liquidGlassCard()
        }
    }
}

private struct SpeedCard: View {
    let title: String
    let mbps: Double
    let peak: Double
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon).foregroundColor(tint)
                Text(title).font(.caption2.weight(.bold)).foregroundColor(.secondary)
                Spacer()
            }
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(mbps >= 100 ? String(format: "%.0f", mbps) : String(format: "%.2f", mbps))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text("Mbps").font(.caption.weight(.semibold)).foregroundColor(.secondary)
            }
            Text(peak > 0 ? "Peak \(String(format: "%.1f", peak)) Mbps" : "Peak —")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassCard(tint: tint)
    }
}

/// Last minute of download (blue) and upload (green).
private struct Sparkline: View {
    let samples: [ThroughputSample]

    var body: some View {
        GeometryReader { geo in
            let maxValue = max(1, samples.map { max($0.downloadMbps, $0.uploadMbps) }.max() ?? 1)
            ZStack {
                line(samples.map(\.downloadMbps), max: maxValue, in: geo.size).stroke(.blue, lineWidth: 2)
                line(samples.map(\.uploadMbps), max: maxValue, in: geo.size).stroke(.green, lineWidth: 2)
                if samples.count < 2 {
                    Text("Collecting speed samples…").font(.caption2).foregroundColor(.secondary)
                }
            }
        }
    }

    private func line(_ values: [Double], max maxValue: Double, in size: CGSize) -> Path {
        Path { p in
            guard values.count > 1 else { return }
            let step = size.width / CGFloat(values.count - 1)
            for (i, v) in values.enumerated() {
                let point = CGPoint(x: CGFloat(i) * step, y: size.height * (1 - CGFloat(v / maxValue)))
                i == 0 ? p.move(to: point) : p.addLine(to: point)
            }
        }
    }
}

struct FibreCard: View {
    let optical: OpticalInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "fibrechannel", title: "Fibre Signal") {
                Pill(text: optical.isRegistered ? "Registered" : (optical.registrationState.isEmpty ? "—" : "Not registered"),
                     color: optical.isRegistered ? .green : .orange)
            }
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(optical.rxPowerDbm.map { String(format: "%.2f", $0) } ?? "—")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("dBm received").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                Spacer()
                Text(qualityText).font(.caption.weight(.bold)).foregroundColor(qualityColor)
            }
            HStack(spacing: 8) {
                Readout(label: "PON state", value: optical.registrationText)
                if let tx = optical.txPowerDbm {
                    Readout(label: "Transmit", value: String(format: "%.2f dBm", tx))
                }
                if let t = optical.temperatureC {
                    Readout(label: "Optics temp", value: String(format: "%.0f °C", t))
                }
            }
        }
        .liquidGlassCard()
    }

    private var qualityText: String {
        switch optical.rxQuality {
        case .good: return "Good"
        case .weak: return "Weak"
        case .bad: return "Too low"
        case .tooStrong: return "Too strong"
        case .unknown: return ""
        }
    }

    private var qualityColor: Color {
        switch optical.rxQuality {
        case .good: return .green
        case .weak: return .orange
        case .bad, .tooStrong: return .red
        case .unknown: return .secondary
        }
    }
}

struct InternetCard: View {
    let wan: WanInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "globe", title: "Internet") {
                Pill(text: wan.connectionStatus.isEmpty ? "—" : wan.connectionStatus,
                     color: wan.isConnected ? .green : .orange)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                Readout(label: "WAN IP", value: wan.ipAddress.isEmpty ? "—" : wan.ipAddress,
                        footnote: wan.isCarrierNat ? "Shared ISP address (CGNAT)" : nil)
                Readout(label: "Connected for", value: Self.uptime(wan.uptimeSeconds))
                Readout(label: "Type", value: [wan.connectionType, wan.vlanId.isEmpty ? "" : "VLAN \(wan.vlanId)"]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                Readout(label: "Gateway", value: wan.gateway.isEmpty ? "—" : wan.gateway)
            }
            if !wan.dnsServers.isEmpty {
                Readout(label: "ISP DNS", value: wan.dnsServers.joined(separator: ", "))
            }
        }
        .liquidGlassCard()
    }

    static func uptime(_ seconds: Int) -> String {
        guard seconds > 0 else { return "—" }
        let d = seconds / 86_400, h = (seconds % 86_400) / 3600, m = (seconds % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

struct CardHeader<Accessory: View>: View {
    let icon: String
    let title: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack {
            Image(systemName: icon).foregroundColor(.accentColor)
            Text(title).font(.subheadline.weight(.bold))
            Spacer()
            accessory
        }
    }
}

struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundColor(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}

struct Readout: View {
    let label: String
    let value: String
    var footnote: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            if let footnote {
                Text(footnote).font(.system(size: 9)).foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .liquidGlassPill()
    }
}
