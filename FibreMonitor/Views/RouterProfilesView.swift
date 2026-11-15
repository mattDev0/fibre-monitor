import SwiftUI

/// Shown on launch when 2 or more router profiles exist so the user picks the connected router before login.
struct RouterLaunchPickerView: View {
    @ObservedObject var viewModel: MonitorViewModel
    @State private var addingProfile = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(viewModel.settings.profiles) { profile in
                        Button {
                            viewModel.selectRouterAndStart(profile)
                        } label: {
                            RouterProfileRow(
                                profile: profile,
                                isActive: profile.id == viewModel.settings.activeProfile?.id
                            )
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text("Saved routers")
                } footer: {
                    Text("Choose the router your iPhone is currently connected to. Switching logs out of any previous router session first.")
                }

                Section {
                    Button {
                        addingProfile = true
                    } label: {
                        Label("Add Router", systemImage: "plus.circle")
                    }
                }
            }
            .navigationTitle("Choose Router")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $addingProfile) {
                RouterProfileEditorView(
                    mode: .add,
                    settings: viewModel.settings
                ) { saved in
                    viewModel.selectRouterAndStart(saved)
                }
            }
        }
        .interactiveDismissDisabled()
    }
}

struct RouterProfileRow: View {
    let profile: RouterProfile
    let isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.router")
                .font(.title3)
                .foregroundColor(isActive ? .accentColor : .secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .font(.subheadline.weight(.semibold))
                    if let model = profile.detectedModel, !model.isEmpty {
                        Text(model)
                            .font(.caption2.weight(.medium))
                            .foregroundColor(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    Text(profile.host)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                    if let cfg = profile.cfgMode, !cfg.isEmpty {
                        Text("· \(cfg)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                if let lastUsed = profile.lastUsed {
                    Text("Last used \(lastUsed.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isActive ? "Active router" : "")
    }
}

struct RouterProfileEditorView: View {
    enum Mode: Identifiable {
        case add
        case edit(RouterProfile)

        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let p): return p.id.uuidString
            }
        }
    }

    let mode: Mode
    @ObservedObject var settings: SettingsStore
    let onSave: (RouterProfile) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var host = ""
    @State private var username = "root"
    @State private var password = ""

    private var trimmedHost: String { host.trimmingCharacters(in: .whitespaces) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isHostValid: Bool { HuaweiOntClient.isValidHost(trimmedHost) }
    private var canSave: Bool {
        !trimmedName.isEmpty && isHostValid && !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                if case .add = mode {
                    Section {
                        Button {
                            let template = RouterProfile.mtnTemplate()
                            name = template.name
                            host = template.host
                            username = template.username
                            password = ""
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("New router (MTN)")
                                        .font(.subheadline.weight(.semibold))
                                    Text("192.168.2.1 · username root")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Text("Use template")
                                    .font(.caption.weight(.semibold))
                            }
                        }

                        Button {
                            name = "Previous router"
                            host = "192.168.100.1"
                            username = "root"
                            password = ""
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Standard Huawei ONT")
                                        .font(.subheadline.weight(.semibold))
                                    Text("192.168.100.1 · username root")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Text("Use template")
                                    .font(.caption.weight(.semibold))
                            }
                        }
                    } header: {
                        Text("Templates")
                    } footer: {
                        Text("Enter the router's web login password yourself below.")
                    }
                }

                Section {
                    LabeledContent("Profile name") {
                        TextField("New router (MTN)", text: $name)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Router address") {
                        TextField("192.168.2.1", text: $host)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    LabeledContent("Username") {
                        TextField("root", text: $username)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    LabeledContent("Password") {
                        SecureField("Required", text: $password)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Router login")
                } footer: {
                    if !trimmedHost.isEmpty && !isHostValid {
                        Text("Enter a valid IP address or hostname without http:// (for example 192.168.2.1 or 192.168.100.1).")
                            .foregroundColor(.red)
                    } else {
                        Text("The password is stored in this iPhone's Keychain. After several wrong passwords the router locks logins for a few minutes.")
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Router" : "Add Router")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .disabled(!canSave)
                }
            }
            .onAppear {
                switch mode {
                case .add:
                    if name.isEmpty && host.isEmpty {
                        let template = RouterProfile.mtnTemplate()
                        name = template.name
                        host = template.host
                        username = template.username
                    }
                case .edit(let profile):
                    name = profile.name
                    host = profile.host
                    username = profile.username
                    password = settings.password(for: profile.id)
                }
            }
        }
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private func save() {
        switch mode {
        case .add:
            let profile = RouterProfile(name: trimmedName, host: trimmedHost, username: username)
            let saved = settings.addProfile(profile, password: password, select: true)
            onSave(saved)
        case .edit(var existing):
            existing.name = trimmedName
            existing.host = trimmedHost
            existing.username = username
            settings.updateProfile(existing, password: password)
            onSave(existing)
        }
        dismiss()
    }
}
