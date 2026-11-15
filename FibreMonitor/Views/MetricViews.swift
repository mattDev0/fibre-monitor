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
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("60-second throughput history")
                .accessibilityValue(
                    traffic.history.count < 2
                        ? "Collecting speed samples"
                        : String(format: "Download %.1f Mbps, Upload %.1f Mbps", traffic.downloadMbps, traffic.uploadMbps)
                )
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
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text("Mbps").font(.caption.weight(.semibold)).foregroundColor(.secondary)
            }
            Text(peak > 0 ? "Peak \(String(format: "%.1f", peak)) Mbps" : "Peak —")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassCard(tint: tint)
        .accessibilityElement(children: .combine)
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

/// Optical Rx power card with a calibrated bar reflecting `OpticalInfo.Quality` thresholds.
struct FibreCard: View {
    let optical: OpticalInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "waveform.path.ecg", title: "Optical Rx Power") {
                if !qualityText.isEmpty {
                    Pill(text: qualityText, color: qualityColor)
                } else {
                    Pill(
                        text: optical.isRegistered ? "Registered" : (optical.registrationState.isEmpty ? "—" : "Not registered"),
                        color: optical.isRegistered ? .green : .orange
                    )
                }
            }

            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(optical.rxPowerDbm.map { String(format: "%.2f", $0) } ?? "—")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .foregroundColor(optical.rxPowerDbm == nil ? .secondary : .primary)
                    .contentTransition(.numericText())
                Text("dBm")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer()
            }

            OpticalRxRangeBar(rxPowerDbm: optical.rxPowerDbm, qualityColor: qualityColor)
        }
        .liquidGlassCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Optical receive power")
        .accessibilityValue(accessibilitySummary)
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

    private var accessibilitySummary: String {
        guard let rx = optical.rxPowerDbm else { return "Unavailable" }
        return String(format: "%.2f dBm, %@", rx, qualityText)
    }
}

/// Calibrated `-32` to `-4 dBm` bar matching `OpticalInfo.Quality` zones:
/// Bad (`< -27`), Weak (`-27` to `-24`), Good (`-24` to `-8`), Too strong (`> -8`).
private struct OpticalRxRangeBar: View {
    let rxPowerDbm: Double?
    let qualityColor: Color

    private let minDbm = -32.0
    private let maxDbm = -4.0

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let totalSpan = maxDbm - minDbm
                let badFrac = (-27.0 - minDbm) / totalSpan
                let weakFrac = (-24.0 - (-27.0)) / totalSpan
                let goodFrac = (-8.0 - (-24.0)) / totalSpan
                let strongFrac = (maxDbm - (-8.0)) / totalSpan

                ZStack(alignment: .leading) {
                    HStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.red.opacity(0.65))
                            .frame(width: max(0, (geo.size.width - 6) * badFrac))
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.orange.opacity(0.75))
                            .frame(width: max(0, (geo.size.width - 6) * weakFrac))
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.green.opacity(0.75))
                            .frame(width: max(0, (geo.size.width - 6) * goodFrac))
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.red.opacity(0.65))
                            .frame(width: max(0, (geo.size.width - 6) * strongFrac))
                    }
                    .frame(height: 8)
                    .frame(maxWidth: .infinity)

                    if let rx = rxPowerDbm {
                        let clamped = min(max(rx, minDbm), maxDbm)
                        let frac = (clamped - minDbm) / totalSpan
                        let xPos = max(7, min(geo.size.width - 7, geo.size.width * frac))
                        Circle()
                            .fill(qualityColor)
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(Color.white, lineWidth: 2))
                            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                            .position(x: xPos, y: geo.size.height / 2)
                    }
                }
            }
            .frame(height: 16)

            HStack {
                Text("< -27 Bad")
                Spacer()
                Text("-24 to -8 Good")
                Spacer()
                Text("> -8 Strong")
            }
            .font(.caption2)
            .foregroundColor(.secondary)
        }
    }
}

struct MetricTile: View {
    let icon: String
    let iconTint: Color
    let title: String
    let value: String
    var pill: (text: String, color: Color)? = nil
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(iconTint)
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let pill {
                    Pill(text: pill.text, color: pill.color)
                }
            }

            Text(value.isEmpty ? "—" : value)
                .font(.system(.callout, design: .rounded).weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
        .liquidGlassCard()
        .accessibilityElement(children: .combine)
    }
}

struct SystemLoadCard: View {
    let health: RouterHealth

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "cpu", title: "System Load") {
                if !health.model.isEmpty {
                    Text(health.model)
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.secondary)
                }
            }

            if let cpu = health.cpuPercent {
                LoadBarRow(label: "CPU", percent: cpu)
            }
            if let mem = health.memoryPercent {
                LoadBarRow(label: "Memory", percent: mem)
            }

            if !health.firmware.isEmpty || !health.hardware.isEmpty {
                Readout(
                    label: "Firmware",
                    value: [health.firmware, health.hardware].filter { !$0.isEmpty }.joined(separator: " · ")
                )
            }
        }
        .liquidGlassCard()
    }
}

private struct LoadBarRow: View {
    let label: String
    let percent: Int

    private var clamped: Int { min(100, max(0, percent)) }
    private var tint: Color {
        if clamped >= 85 { return .red }
        if clamped >= 65 { return .orange }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(clamped)%")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundColor(.primary)
            }
            ProgressView(value: Double(clamped), total: 100)
                .tint(tint)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) usage")
        .accessibilityValue("\(clamped) percent")
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
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundColor(.secondary)
            Text(value.isEmpty ? "—" : value)
                .font(.footnote.monospaced().weight(.medium))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            if let footnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .liquidGlassPill()
        .accessibilityElement(children: .combine)
    }
}
