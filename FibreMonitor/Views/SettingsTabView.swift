import SwiftUI

public struct SettingsTabView: View {
    @ObservedObject var viewModel: MonitorViewModel
    @ObservedObject var settings: SettingsStore

    @State private var editorMode: RouterProfileEditorView.Mode?
    @State private var pendingDelete: RouterProfile?

    public init(viewModel: MonitorViewModel) {
        self.viewModel = viewModel
        self.settings = viewModel.settings
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    if settings.profiles.isEmpty {
                        Text("No routers saved yet. Add your router to connect.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(settings.profiles) { profile in
                            HStack(spacing: 10) {
                                Button {
                                    guard profile.id != settings.activeProfile?.id else { return }
                                    viewModel.selectRouterAndStart(profile)
                                } label: {
                                    RouterProfileRow(
                                        profile: profile,
                                        isActive: profile.id == settings.activeProfile?.id
                                    )
                                }
                                .buttonStyle(.plain)

                                Button {
                                    editorMode = .edit(profile)
                                } label: {
                                    Image(systemName: "pencil.circle")
                                        .font(.title3)
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Edit \(profile.name)")
                            }
                        }
                        .onMove { source, destination in
                            settings.moveProfiles(fromOffsets: source, toOffset: destination)
                        }
                        .onDelete { offsets in
                            if let idx = offsets.first, settings.profiles.indices.contains(idx) {
                                pendingDelete = settings.profiles[idx]
                            }
                        }
                    }

                    Button {
                        editorMode = .add
                    } label: {
                        Label("Add Router", systemImage: "plus.circle.fill")
                    }
                } header: {
                    Text("Routers")
                } footer: {
                    Text("Tap a router to switch to it. Switching logs out of the current router session first. Swipe or tap Edit to reorder or remove a profile.")
                }

                Section("Updates") {
                    Stepper(
                        "Poll every \(settings.pollIntervalSeconds) second\(settings.pollIntervalSeconds == 1 ? "" : "s")",
                        value: $settings.pollIntervalSeconds,
                        in: 1...10
                    )
                }

                Section("Tools & Network") {
                    NavigationLink {
                        DiagnosticsScreen(viewModel: viewModel)
                    } label: {
                        Label("Diagnostics (Ping & Traceroute)", systemImage: "stethoscope")
                    }

                    NavigationLink {
                        LanScreen(viewModel: viewModel)
                    } label: {
                        Label("Home Network (LAN & DHCP)", systemImage: "network")
                    }
                }

                if settings.isConfigured {
                    Section {
                        if viewModel.isLoggedOut {
                            Button {
                                viewModel.reconnectSession()
                            } label: {
                                Label("Reconnect to Router", systemImage: "arrow.clockwise.circle")
                            }
                        } else {
                            Button(role: .destructive) {
                                Task { await viewModel.logoutSession() }
                            } label: {
                                Label("Log Out of Router", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                        }
                    } header: {
                        Text("Session")
                    } footer: {
                        Text("Logging out frees the router's single-session web interface so you can open it in a browser.")
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Router", value: activeRouterDescription)
                    if let cfg = settings.activeProfile?.cfgMode, !cfg.isEmpty {
                        LabeledContent("Configuration", value: cfg)
                    }
                    if !viewModel.health.firmware.isEmpty {
                        LabeledContent("Firmware", value: viewModel.health.firmware)
                    }
                    if !viewModel.health.hardware.isEmpty {
                        LabeledContent("Hardware", value: viewModel.health.hardware)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !settings.profiles.isEmpty {
                        EditButton()
                    }
                }
            }
        }
        .sheet(item: $editorMode) { mode in
            RouterProfileEditorView(mode: mode, settings: settings) { savedProfile in
                switch mode {
                case .add:
                    viewModel.selectRouterAndStart(savedProfile)
                case .edit:
                    if savedProfile.id == settings.activeProfile?.id {
                        viewModel.settingsChanged()
                    }
                }
            }
        }
        .confirmationDialog(
            pendingDelete.map { "Delete \($0.name)?" } ?? "",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Profile", role: .destructive) {
                if let profile = pendingDelete {
                    let wasActive = profile.id == settings.activeProfile?.id
                    settings.deleteProfile(profile.id)
                    if wasActive {
                        viewModel.settingsChanged()
                    }
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This removes the profile, its Keychain password, and its saved device names from this iPhone.")
        }
    }

    private var activeRouterDescription: String {
        if !viewModel.health.model.isEmpty {
            return "Huawei OptiXstar \(viewModel.health.model)"
        }
        if let model = settings.activeProfile?.detectedModel, !model.isEmpty {
            return "Huawei OptiXstar \(model)"
        }
        return "Huawei OptiXstar ONT"
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}

private struct DiagnosticsScreen: View {
    @ObservedObject var viewModel: MonitorViewModel

    var body: some View {
        ScrollView {
            DiagnosticsCard(viewModel: viewModel)
                .padding()
        }
        .background { LiquidGlassBackground() }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LanScreen: View {
    @ObservedObject var viewModel: MonitorViewModel

    var body: some View {
        ScrollView {
            LanCard(lan: viewModel.lan)
                .padding()
        }
        .background { LiquidGlassBackground() }
        .refreshable { await viewModel.refreshAll() }
        .navigationTitle("Home Network")
        .navigationBarTitleDisplayMode(.inline)
    }
}
