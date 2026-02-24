import SwiftUI

struct MainView: View {
    // MARK: - Environment Objects

    @EnvironmentObject var dataService: DataService
    @EnvironmentObject var opcuaService: OPCUAClientService
    @EnvironmentObject var tagEngine: TagEngine
    @EnvironmentObject var alarmManager: AlarmManager

    // MARK: - State

    @State private var selectedTab: Tab = .monitor

    // MARK: - Body

    var body: some View {
        NavigationSplitView {
            List(Tab.allCases, selection: $selectedTab) { tab in
                Label(tab.title, systemImage: tab.icon)
                    .badge(tab == .alarms ? alarmBadge : 0)
                    .tag(tab)
            }
            .navigationTitle("Industrial HMI")
            .listStyle(.sidebar)
        } detail: {
            // MonitorView, TrendView, HMIDesignerView stay permanently in the
            // view hierarchy so their state (browser VM, trend selection, canvas)
            // is preserved across tab switches.
            ZStack {
                MonitorView(selectedTab: $selectedTab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(selectedTab == .monitor ? 1 : 0)
                    .allowsHitTesting(selectedTab == .monitor)

                TrendView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(selectedTab == .trends ? 1 : 0)
                    .allowsHitTesting(selectedTab == .trends)

                HMIDesignerView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(selectedTab == .hmi ? 1 : 0)
                    .allowsHitTesting(selectedTab == .hmi)

                // On-demand views
                Group {
                    switch selectedTab {
                    case .alarms:
                        AlarmListView()
                    case .settings:
                        SettingsView()
                    case .monitor, .trends, .hmi:
                        Color.clear  // handled by always-alive views above
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle(selectedTab.title)
        }
        .onChange(of: selectedTab) { old, new in
            diagLog("DIAG [MainView] tab changed: \(old.rawValue) → \(new.rawValue)")
        }
    }

    private var alarmBadge: Int {
        alarmManager.unacknowledgedCount
    }
}

// MARK: - Tab Enumeration

enum Tab: String, CaseIterable, Identifiable {
    case monitor
    case trends
    case alarms
    case hmi
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .monitor:  return "Monitor"
        case .trends:   return "Trends"
        case .alarms:   return "Alarms"
        case .hmi:      return "HMI Screens"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .monitor:  return "gauge"
        case .trends:   return "chart.xyaxis.line"
        case .alarms:   return "exclamationmark.triangle"
        case .hmi:      return "rectangle.on.rectangle"
        case .settings: return "gear"
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    var body: some View {
        Form {
            Section("OPC-UA Connection") {
                Text("Server: \(Configuration.opcuaServerURL)")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}
