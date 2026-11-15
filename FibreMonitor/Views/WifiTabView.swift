import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

public struct WifiTabView: View {
    @ObservedObject var viewModel: MonitorViewModel
    @State private var pendingRadio: (radio: WifiRadio, enable: Bool)?
    @State private var qrTarget: WifiNetwork?

    public init(viewModel: MonitorViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if !viewModel.settings.isConfigured {
                        WifiEmptyCard(message: "Add a router in Settings to manage Wi-Fi networks.")
                    } else if viewModel.wifi.radios.isEmpty && viewModel.wifi.networks.isEmpty {
                        WifiEmptyCard(message: viewModel.isConnected ? "Reading Wi-Fi configuration…" : "Waiting for the router…")
                    } else {
                        radiosCard

                        ForEach(groupedNetworks, id: \.title) { group in
                            VStack(alignment: .leading, spacing: 10) {
                                CardHeader(icon: "dot.radiowaves.left.and.right", title: group.title) {
                                    Pill(text: "\(group.networks.count) SSID\(group.networks.count == 1 ? "" : "s")", color: .secondary)
                                }

                                ForEach(group.networks) { network in
                                    WifiNetworkRow(network: network) {
                                        qrTarget = network
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
            .navigationTitle("Wi-Fi")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if viewModel.isWifiSaving {
                        ProgressView()
                    }
                }
            }
        }
        .alert(
            pendingRadio.map { "Turn \(MonitorViewModel.bandName($0.radio.band)) Wi-Fi \($0.enable ? "on" : "off")?" } ?? "",
            isPresented: Binding(get: { pendingRadio != nil }, set: { if !$0 { pendingRadio = nil } })
        ) {
            Button("Cancel", role: .cancel) { pendingRadio = nil }
            Button(pendingRadio?.enable == false ? "Turn Off" : "Turn On", role: pendingRadio?.enable == false ? .destructive : nil) {
                if let p = pendingRadio {
                    Task { await viewModel.setRadio(p.radio, enabled: p.enable) }
                }
                pendingRadio = nil
            }
        } message: {
            Text(
                pendingRadio?.enable == false
                    ? "Devices on this band disconnect and move to the other band if they can. If this iPhone is on it, it will reconnect."
                    : "The radio takes a few seconds to start."
            )
        }
        .sheet(item: $qrTarget) { network in
            WifiQrSheet(viewModel: viewModel, network: network)
        }
    }

    private var radiosCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "wifi", title: "Radios") {
                if viewModel.isWifiSaving { ProgressView() }
            }
            ForEach(viewModel.wifi.radios) { radio in
                HStack(spacing: 12) {
                    Image(systemName: radio.enabled ? "wifi" : "wifi.slash")
                        .foregroundColor(radio.enabled ? .accentColor : .secondary)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(MonitorViewModel.bandName(radio.band))
                            .font(.subheadline.weight(.semibold))
                        let names = viewModel.wifi.networks(on: radio).map(\.name).filter { !$0.isEmpty }
                        Text(radio.enabled ? (names.isEmpty ? "On" : names.joined(separator: " · ")) : "Off")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }

                    Spacer()

                    Toggle(
                        "\(MonitorViewModel.bandName(radio.band)) Radio",
                        isOn: Binding(get: { radio.enabled }, set: { pendingRadio = (radio, $0) })
                    )
                    .labelsHidden()
                    .disabled(viewModel.isWifiSaving || !viewModel.isConnected)
                }
                .padding(10)
                .liquidGlassPill()
            }
        }
        .liquidGlassCard()
    }

    private var groupedNetworks: [(title: String, networks: [WifiNetwork])] {
        var groups: [(title: String, networks: [WifiNetwork])] = []
        var matched = Set<Int>()
        for radio in viewModel.wifi.radios {
            let list = viewModel.wifi.allNetworks(on: radio)
            if !list.isEmpty {
                list.forEach { matched.insert($0.id) }
                groups.append((MonitorViewModel.bandName(radio.band), list))
            }
        }
        let remainder = viewModel.wifi.networks.filter { !matched.contains($0.id) }
        if !remainder.isEmpty {
            groups.append(("Other Networks", remainder))
        }
        return groups
    }
}

private struct WifiNetworkRow: View {
    let network: WifiNetwork
    let openQr: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(network.name.isEmpty ? "SSID \(network.ssidIndex)" : network.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Pill(text: network.enabled ? "Active" : "Off", color: network.enabled ? .green : .secondary)
                }
                Text("SSID \(network.ssidIndex) · \(MonitorViewModel.bandName(network.band))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 8)

            Button(action: openQr) {
                Label("QR", systemImage: "qrcode")
                    .font(.caption.weight(.semibold))
            }
            .liquidGlassSmallButton()
            .accessibilityLabel("Show QR code and password for \(network.name)")
        }
        .padding(10)
        .liquidGlassPill()
    }
}

/// Fetches the Wi-Fi passphrase on demand from `WlanBasic.asp`, renders an offline QR code,
/// and discards the passphrase immediately on dismiss or app background.
private struct WifiQrSheet: View {
    @ObservedObject var viewModel: MonitorViewModel
    let network: WifiNetwork

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var config: WifiSsidConfig?
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var showPassword = false
    @State private var copiedPassword = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if isLoading {
                        ProgressView("Reading security settings from router…")
                            .padding(.vertical, 36)
                    } else if let errorText {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.largeTitle)
                                .foregroundColor(.orange)
                            Text(errorText)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                            Button("Retry") {
                                Task { await loadConfig() }
                            }
                            .liquidGlassActionButton()
                        }
                        .frame(maxWidth: .infinity)
                        .liquidGlassCard()
                    } else if let config {
                        content(for: config)
                    }
                }
                .padding()
            }
            .background { LiquidGlassBackground() }
            .navigationTitle(network.name.isEmpty ? "Wi-Fi Network" : network.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await loadConfig() }
        .onDisappear {
            config = nil
            showPassword = false
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                config = nil
                showPassword = false
                dismiss()
            }
        }
    }

    @ViewBuilder
    private func content(for cfg: WifiSsidConfig) -> some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                HStack {
                    Text(cfg.ssid.isEmpty ? network.name : cfg.ssid)
                        .font(.title3.weight(.bold))
                    Spacer()
                    Pill(text: cfg.authMode.displayName, color: .accentColor)
                }
                if cfg.isHidden {
                    HStack {
                        Label("Hidden network", systemImage: "eye.slash")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
            }
            .liquidGlassCard()

            if let payload = cfg.qrPayload, let uiImage = QrImageGenerator.generate(from: payload) {
                VStack(spacing: 12) {
                    Image(uiImage: uiImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 220, maxHeight: 220)
                        .padding(14)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .accessibilityLabel("Wi-Fi join QR code for \(cfg.ssid)")

                    Text("Scan with iPhone or Android Camera to join \(cfg.ssid).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    let shareImage = Image(uiImage: uiImage)
                    ShareLink(
                        item: shareImage,
                        preview: SharePreview("Join Wi-Fi: \(cfg.ssid)", image: shareImage)
                    ) {
                        Label("Share QR Code", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .liquidGlassActionButton()
                }
                .liquidGlassCard()
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "qrcode")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text(qrUnavailableReason(for: cfg))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .liquidGlassCard()
            }

            if cfg.authMode != .open && !cfg.psk.isEmpty && !cfg.isPasswordMasked {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Passphrase")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)

                    HStack(spacing: 10) {
                        Text(showPassword ? cfg.psk : String(repeating: "•", count: max(8, min(cfg.psk.count, 16))))
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                        }
                        .accessibilityLabel(showPassword ? "Hide password" : "Reveal password")

                        Button {
                            UIPasteboard.general.string = cfg.psk
                            copiedPassword = true
                        } label: {
                            Label(copiedPassword ? "Copied" : "Copy", systemImage: copiedPassword ? "checkmark" : "doc.on.doc")
                                .font(.caption.weight(.semibold))
                        }
                        .liquidGlassSmallButton()
                    }
                    .padding(12)
                    .liquidGlassPill()

                    Text("Fetched live from the router and never saved on this iPhone.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .liquidGlassCard()
            }
        }
    }

    private func qrUnavailableReason(for cfg: WifiSsidConfig) -> String {
        if cfg.isPasswordMasked {
            return "This router masks Wi-Fi passphrases in its web page, so a join QR code cannot be generated automatically."
        }
        return "QR codes are available for Open and WPA/WPA2/WPA3-PSK networks."
    }

    private func loadConfig() async {
        isLoading = true
        errorText = nil
        do {
            config = try await viewModel.fetchWifiSsidConfig(for: network)
        } catch {
            errorText = MonitorViewModel.describe(error, host: viewModel.settings.host)
        }
        isLoading = false
    }
}

private enum QrImageGenerator {
    static func generate(from payload: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

private struct WifiEmptyCard: View {
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
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
