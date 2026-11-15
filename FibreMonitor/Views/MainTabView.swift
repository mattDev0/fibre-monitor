import SwiftUI

public struct MainTabView: View {
    @StateObject private var viewModel = MonitorViewModel()
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some View {
        TabView(selection: $viewModel.selectedTab) {
            DashboardView(viewModel: viewModel)
                .tabItem {
                    Label("Dashboard", systemImage: "gauge.with.dots.needle.67percent")
                }
                .tag(AppTab.dashboard)

            ClientsTabView(viewModel: viewModel)
                .tabItem {
                    Label("Clients", systemImage: "laptopcomputer.and.iphone")
                }
                .tag(AppTab.clients)

            WifiTabView(viewModel: viewModel)
                .tabItem {
                    Label("Wi-Fi", systemImage: "wifi")
                }
                .tag(AppTab.wifi)

            SettingsTabView(viewModel: viewModel)
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(AppTab.settings)
        }
        .sheet(isPresented: $viewModel.awaitingRouterSelection) {
            RouterLaunchPickerView(viewModel: viewModel)
        }
        .alert(
            viewModel.actionMessage ?? "",
            isPresented: Binding(
                get: { viewModel.actionMessage != nil },
                set: { if !$0 { viewModel.actionMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        }
        .onAppear {
            if !viewModel.awaitingRouterSelection {
                if !viewModel.settings.isConfigured {
                    viewModel.selectedTab = .settings
                } else {
                    viewModel.startPolling()
                }
            }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                if !viewModel.awaitingRouterSelection && viewModel.settings.isConfigured && !viewModel.isLoggedOut {
                    viewModel.startPolling()
                }
            case .background:
                viewModel.stopPolling()
            default:
                break
            }
        }
    }
}
