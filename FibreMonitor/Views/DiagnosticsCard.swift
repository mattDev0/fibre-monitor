import SwiftUI

/// Ping and traceroute run by the router itself, like its Diagnostics page.
struct DiagnosticsCard: View {
    @ObservedObject var viewModel: MonitorViewModel

    private let quickTargets = ["8.8.8.8", "1.1.1.1", "google.com"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "stethoscope", title: "Diagnostics") {
                if viewModel.isDiagnosing { ProgressView() }
            }

            Picker("Test", selection: $viewModel.diagnosticMode) {
                ForEach(MonitorViewModel.DiagnosticMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.isDiagnosing)

            HStack(spacing: 8) {
                TextField("Host or IP", text: $viewModel.diagnosticHost)
                    .textFieldStyle(.roundedBorder)
                    .font(.subheadline.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .disabled(viewModel.isDiagnosing)
                if viewModel.diagnosticMode == .ping {
                    Stepper("\(viewModel.pingCount)×", value: $viewModel.pingCount, in: 1...20)
                        .font(.caption)
                        .fixedSize()
                        .disabled(viewModel.isDiagnosing)
                }
            }

            HStack(spacing: 8) {
                ForEach(quickTargets, id: \.self) { target in
                    Button(target) { viewModel.diagnosticHost = target }
                        .font(.caption.weight(.semibold))
                        .liquidGlassSmallButton()
                        .disabled(viewModel.isDiagnosing)
                }
            }

            Button {
                if viewModel.isDiagnosing { viewModel.stopDiagnostic() } else { viewModel.startDiagnostic() }
            } label: {
                Label(viewModel.isDiagnosing ? "Stop" : "Run \(viewModel.diagnosticMode.rawValue)",
                      systemImage: viewModel.isDiagnosing ? "stop.fill" : "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .liquidGlassActionButton(tint: viewModel.isDiagnosing ? .red : .accentColor)
            .disabled(!viewModel.isConnected || viewModel.diagnosticHost.trimmingCharacters(in: .whitespaces).isEmpty)

            if !viewModel.diagnosticOutput.text.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(viewModel.diagnosticOutput.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.green)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                            if let status = viewModel.diagnosticOutput.status {
                                Text(status == "Complete" ? "Done" : status.replacingOccurrences(of: "_", with: " "))
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(status == "Complete" ? .green : .orange)
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(12)
                    }
                    .frame(height: 180)
                    .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .onChange(of: viewModel.diagnosticOutput) { _ in
                        withAnimation { proxy.scrollTo("end", anchor: .bottom) }
                    }
                }
            }
        }
        .liquidGlassCard()
    }
}
