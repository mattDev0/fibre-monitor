import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

public struct WifiTabView: View {
    @ObservedObject var viewModel: MonitorViewModel
    @State private var pendingRadio: (radio: WifiRadio, enable: Bool)?
    @State private var qrTarget: WifiNetwork?
    @State private var editTarget: WifiNetwork?

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
                        WifiEmptyCard(
                            message: wifiEmptyMessage,
                            isLoading: viewModel.isRefreshing && !viewModel.isLoggedOut,
                            actionTitle: viewModel.isLoggedOut ? "Reconnect" : nil,
                            action: viewModel.isLoggedOut ? { viewModel.reconnectSession() } : nil
                        )
                    } else {
                        radiosCard

                        ForEach(groupedNetworks, id: \.title) { group in
                            VStack(alignment: .leading, spacing: 10) {
                                CardHeader(icon: "dot.radiowaves.left.and.right", title: group.title) {
                                    Pill(text: "\(group.networks.count) SSID\(group.networks.count == 1 ? "" : "s")", color: .secondary)
                                }

                                ForEach(group.networks) { network in
                                    WifiNetworkRow(
                                        network: network,
                                        isEditDisabled: viewModel.isWifiSaving || !viewModel.isConnected,
                                        openEdit: { editTarget = network },
                                        openQr: { qrTarget = network }
                                    )
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
            if let p = pendingRadio, !p.enable {
                if viewModel.isPhoneOnWifi {
                    Text("This iPhone is currently on Wi-Fi. Turning off \(MonitorViewModel.bandName(p.radio.band)) will disconnect this app immediately if you're on this band. Devices on this band will disconnect and move to another band if they can.")
                } else {
                    Text("Devices on \(MonitorViewModel.bandName(p.radio.band)) will disconnect and move to another band if they can.")
                }
            } else {
                Text("The radio takes a few seconds to start.")
            }
        }
        .sheet(item: $qrTarget) { network in
            WifiQrSheet(viewModel: viewModel, network: network)
        }
        .sheet(item: $editTarget) { network in
            WifiEditSheet(viewModel: viewModel, network: network)
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
                        .accessibilityHidden(true)

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
                    .accessibilityLabel("Toggle \(MonitorViewModel.bandName(radio.band)) Wi-Fi")
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

    private var wifiEmptyMessage: String {
        if viewModel.isLoggedOut { return "Session is logged out. Tap Reconnect to manage Wi-Fi." }
        if viewModel.isConnected { return "Reading Wi-Fi configuration…" }
        if let err = viewModel.errorMessage { return err }
        return viewModel.isRefreshing ? "Loading Wi-Fi configuration…" : "Waiting for the router… Pull down to refresh."
    }
}

private struct WifiNetworkRow: View {
    let network: WifiNetwork
    let isEditDisabled: Bool
    let openEdit: () -> Void
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

            HStack(spacing: 8) {
                Button(action: openEdit) {
                    Label("Edit", systemImage: "pencil")
                        .font(.caption.weight(.semibold))
                }
                .liquidGlassSmallButton()
                .disabled(isEditDisabled)
                .accessibilityLabel("Edit Wi-Fi name and password for \(network.name)")

                Button(action: openQr) {
                    Label("QR", systemImage: "qrcode")
                        .font(.caption.weight(.semibold))
                }
                .liquidGlassSmallButton()
                .accessibilityLabel("Show QR code and password for \(network.name)")
            }
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
                            Haptics.impact(.light)
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

/// Ephemeral editor for WPA2-PSK / WPA3-PSK SSID & passphrase (`#704`).
/// Refuses edits when security mode is unsupported or required `WlanBasic.asp` fields are missing/masked,
/// requires typed SSID confirmation before submit, and wipes sensitive state on dismiss/background.
private struct WifiEditSheet: View {
    @ObservedObject var viewModel: MonitorViewModel
    let network: WifiNetwork

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var config: WifiSsidConfig?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var ssidInput = ""
    @State private var passwordInput = ""
    @State private var showPassword = false
    @State private var showConfirmSheet = false
    @State private var isSaving = false
    @State private var saveErrorText: String?

    private var hasChanges: Bool {
        guard let config else { return false }
        return ssidInput != config.ssid || passwordInput != config.psk
    }

    private var validationError: String? {
        do {
            try HuaweiOntClient.validateWifiCredentials(ssid: ssidInput, password: passwordInput)
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "Invalid Wi-Fi settings."
        }
    }

    private var canSubmit: Bool {
        guard let config else { return false }
        return config.authMode.isEditableWpa2Or3Psk
            && config.missingEditFields.isEmpty
            && hasChanges
            && validationError == nil
            && !isSaving
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack {
                        Spacer()
                        ProgressView("Reading Wi-Fi configuration…")
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background { LiquidGlassBackground() }
                } else if let loadError {
                    ScrollView {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.largeTitle)
                                .foregroundColor(.orange)
                            Text(loadError)
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
                        .padding()
                    }
                    .background { LiquidGlassBackground() }
                } else if let config {
                    if !config.authMode.isEditableWpa2Or3Psk {
                        refusalView(
                            title: "Unsupported Security Mode",
                            message: "Editing is limited to WPA2-PSK and WPA3-PSK networks. This SSID currently uses \(config.authMode.displayName)."
                        )
                    } else if !config.missingEditFields.isEmpty {
                        refusalView(
                            title: "Cannot Edit Safely",
                            message: "Required router settings were missing or masked (\(config.missingEditFields.joined(separator: ", "))), so changing credentials is disabled."
                        )
                    } else {
                        editForm(for: config)
                    }
                }
            }
            .navigationTitle("Edit Wi-Fi")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if config != nil && config?.authMode.isEditableWpa2Or3Psk == true && config?.missingEditFields.isEmpty == true {
                        Button("Save") {
                            saveErrorText = nil
                            showConfirmSheet = true
                        }
                        .disabled(!canSubmit)
                    }
                }
            }
        }
        .task { await loadConfig() }
        .onDisappear { wipeSensitiveState() }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                wipeSensitiveState()
                dismiss()
            }
        }
        .sheet(isPresented: $showConfirmSheet) {
            WifiEditConfirmSheet(
                newSsid: ssidInput,
                band: network.band,
                isPhoneOnWifi: viewModel.isPhoneOnWifi,
                isSaving: isSaving,
                errorText: saveErrorText
            ) {
                await commitSave()
            }
        }
    }

    @ViewBuilder
    private func editForm(for cfg: WifiSsidConfig) -> some View {
        Form {
            Section {
                TextField("Network name (SSID)", text: $ssidInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Network Name (SSID)")
            } footer: {
                Text("\(ssidInput.utf8.count)/32 UTF-8 bytes")
                    .foregroundColor(ssidInput.utf8.count > 32 ? .red : .secondary)
            }

            Section {
                HStack(spacing: 8) {
                    if showPassword {
                        TextField("Wi-Fi password", text: $passwordInput)
                            .font(.body.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        SecureField("Wi-Fi password", text: $passwordInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showPassword ? "Hide password" : "Reveal password")
                }
            } header: {
                Text("Passphrase")
            } footer: {
                Text("8 to 63 printable ASCII characters (\(passwordInput.count)/63). Fetched live and never saved on this iPhone.")
            }

            if let validationError {
                Section {
                    Label(validationError, systemImage: "exclamationmark.circle.fill")
                        .font(.subheadline)
                        .foregroundColor(.red)
                }
            }

            Section("Network Details") {
                LabeledContent("Band", value: MonitorViewModel.bandName(network.band))
                LabeledContent("Security", value: cfg.authMode.displayName)
                LabeledContent("Hidden", value: cfg.isHidden ? "Yes" : "No")
            }
        }
    }

    private func refusalView(title: String, message: String) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.largeTitle)
                    .foregroundColor(.orange)
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .liquidGlassCard()
            .padding()
        }
        .background { LiquidGlassBackground() }
    }

    private func loadConfig() async {
        isLoading = true
        loadError = nil
        do {
            let loaded = try await viewModel.fetchWifiSsidConfig(for: network)
            config = loaded
            ssidInput = loaded.ssid
            passwordInput = loaded.psk
        } catch {
            loadError = MonitorViewModel.describe(error, host: viewModel.settings.host)
        }
        isLoading = false
    }

    private func commitSave() async {
        guard let cfg = config else { return }
        isSaving = true
        saveErrorText = nil
        do {
            _ = try await viewModel.updateWifiCredentials(
                config: cfg,
                newSsid: ssidInput,
                newPassword: passwordInput
            )
            isSaving = false
            showConfirmSheet = false
            wipeSensitiveState()
            dismiss()
        } catch {
            isSaving = false
            saveErrorText = MonitorViewModel.describe(error, host: viewModel.settings.host)
        }
    }

    private func wipeSensitiveState() {
        config = nil
        passwordInput = ""
        showPassword = false
        showConfirmSheet = false
        saveErrorText = nil
    }
}

private struct WifiEditConfirmSheet: View {
    let newSsid: String
    let band: String
    let isPhoneOnWifi: Bool
    let isSaving: Bool
    let errorText: String?
    let onConfirm: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var typedSsid = ""

    private var matchesSsid: Bool {
        typedSsid == newSsid
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("All Devices Will Disconnect", systemImage: "wifi.exclamationmark")
                            .font(.headline)
                            .foregroundColor(.orange)
                        Text(
                            isPhoneOnWifi
                                ? "When the router applies these settings, all devices on \(MonitorViewModel.bandName(band)) — including this iPhone — will disconnect immediately. You will need to rejoin \"\(newSsid)\" in Settings → Wi-Fi with the new password."
                                : "When the router applies these settings, every device on \(MonitorViewModel.bandName(band)) will disconnect and must rejoin \"\(newSsid)\" with the new password."
                        )
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    TextField("Type \(newSsid)", text: $typedSsid)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Type the new SSID to confirm")
                } footer: {
                    Text("Enter \"\(newSsid)\" exactly to apply the change.")
                }

                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Confirm Wi-Fi Change")
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
                        Button("Apply") {
                            Task { await onConfirm() }
                        }
                        .disabled(!matchesSsid)
                    }
                }
            }
        }
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
    var isLoading: Bool = false
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            if isLoading {
                ProgressView()
            } else {
                Image(systemName: "wifi")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
            }
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .liquidGlassSmallButton()
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .liquidGlassCard()
    }
}
