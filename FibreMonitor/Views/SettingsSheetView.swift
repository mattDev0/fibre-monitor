import SwiftUI

struct SettingsSheetView: View {
    @ObservedObject var viewModel: MonitorViewModel
    @ObservedObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var editorMode: RouterProfileEditorView.Mode?
    @State private var pendingDelete: RouterProfile?

    init(viewModel: MonitorViewModel) {
        self.viewModel = viewModel
        self.settings = viewModel.settings
    }

    var body: some View {
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
                    Stepper("Every \(settings.pollIntervalSeconds) second\(settings.pollIntervalSeconds == 1 ? "" : "s")",
                            value: $settings.pollIntervalSeconds,
                            in: 1...10)
                }

                Section("About") {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Router", value: activeRouterDescription)
                    if let cfg = settings.activeProfile?.cfgMode, !cfg.isEmpty {
                        LabeledContent("Configuration", value: cfg)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !settings.profiles.isEmpty {
                        EditButton()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
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
    }

    private var activeRouterDescription: String {
        if let model = settings.activeProfile?.detectedModel, !model.isEmpty {
            return "Huawei OptiXstar \(model)"
        }
        return "Huawei OptiXstar HG8145X6"
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}
