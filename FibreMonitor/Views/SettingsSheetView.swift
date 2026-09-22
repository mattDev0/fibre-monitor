import SwiftUI

struct SettingsSheetView: View {
    @ObservedObject var settings: SettingsStore
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var username = ""
    @State private var password = ""
    @State private var interval = 2

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Router address") {
                        TextField("192.168.100.1", text: $host)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numbersAndPunctuation)
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
                    Text("The same username and password you use on the router's web page. The password is stored in this iPhone's Keychain. After several wrong passwords the router blocks logins for a few minutes.")
                }

                Section("Updates") {
                    Stepper("Every \(interval) second\(interval == 1 ? "" : "s")", value: $interval, in: 1...10)
                }

                Section("About") {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Router", value: "Huawei OptiXstar HG8145X6")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        settings.host = host.trimmingCharacters(in: .whitespaces)
                        settings.username = username.trimmingCharacters(in: .whitespaces)
                        settings.password = password
                        settings.pollIntervalSeconds = interval
                        onSave()
                        dismiss()
                    }
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
                }
            }
            .onAppear {
                host = settings.host
                username = settings.username
                password = settings.password
                interval = settings.pollIntervalSeconds
            }
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}
