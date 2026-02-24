import SwiftUI

struct MainView: View {
    // MARK: - Environment Objects

    @EnvironmentObject var opcuaService: OPCUAClientService
    @EnvironmentObject var tagEngine: TagEngine
    @EnvironmentObject var alarmManager: AlarmManager

    // MARK: - State

    @State private var selectedTab: Tab = .overview
    @State private var isRunning = false

    // MARK: - Body

    var body: some View {
        NavigationSplitView {
            // Sidebar
            List(Tab.allCases, selection: $selectedTab) { tab in
                Label(tab.title, systemImage: tab.icon)
                    .tag(tab)
            }
            .navigationTitle("Industrial HMI")
            .listStyle(.sidebar)
        } detail: {
            Group {
                switch selectedTab {
                case .overview:
                    OverviewView(
                        isRunning: isRunning,
                        onStart: { Task { await startDataCollection() } },
                        onStop:  { Task { await stopDataCollection()  } }
                    )
                case .tags:
                    TagTableView()
                        .onAppear  { diagLog("DIAG [TagTableView] onAppear") }
                        .onDisappear { diagLog("DIAG [TagTableView] onDisappear") }
                case .browser:
                    OPCUABrowserView(opcuaService: opcuaService, tagEngine: tagEngine, alarmManager: alarmManager)
                        .onAppear  { diagLog("DIAG [OPCUABrowserView] onAppear") }
                        .onDisappear { diagLog("DIAG [OPCUABrowserView] onDisappear") }
                case .trends:
                    TrendView()
                case .alarms:
                    AlarmListView()
                case .settings:
                    SettingsView()
                }
            }
        }
        .onChange(of: selectedTab) { old, new in
            diagLog("DIAG [MainView] tab changed: \(old.rawValue) → \(new.rawValue)")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if isRunning {
                    Button(role: .destructive) {
                        Task { await stopDataCollection() }
                    } label: {
                        Label("Stop", systemImage: "stop.circle.fill")
                    }
                    .tint(.red)
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        Task { await startDataCollection() }
                    } label: {
                        Label("Start", systemImage: "play.circle.fill")
                    }
                    .tint(.green)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    // MARK: - Data Collection

    private func startDataCollection() async {
        isRunning = true
        if Configuration.simulationMode {
            Logger.shared.info("Starting simulation mode")
            tagEngine.startSimulation()
        } else {
            do {
                // Connect to the OPC-UA server. Individual tag subscriptions are
                // set up by OPCUABrowserViewModel when the user adds nodes to
                // Monitored Items in the Browser tab.
                try await opcuaService.connect()
                Logger.shared.info("OPC-UA connection ready — browse nodes in the Browser tab")
            } catch {
                isRunning = false
                Logger.shared.error("Connection failed: \(error)")
            }
        }
    }

    private func stopDataCollection() async {
        isRunning = false
        if Configuration.simulationMode {
            tagEngine.stopSimulation()
        } else {
            await opcuaService.disconnect()
        }
    }
}

// MARK: - Tab Enumeration

enum Tab: String, CaseIterable, Identifiable {
    case overview
    case tags
    case browser
    case trends
    case alarms
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .browser: return "OPC Browser"
        default: return rawValue.capitalized
        }
    }

    var icon: String {
        switch self {
        case .overview: return "gauge"
        case .tags:     return "tag"
        case .browser:  return "folder.badge.gearshape"
        case .trends:   return "chart.xyaxis.line"
        case .alarms:   return "exclamationmark.triangle"
        case .settings: return "gear"
        }
    }
}

// MARK: - Overview View

struct OverviewView: View {
    @EnvironmentObject var opcuaService: OPCUAClientService
    @EnvironmentObject var tagEngine: TagEngine
    @EnvironmentObject var alarmManager: AlarmManager

    let isRunning: Bool
    let onStart: () -> Void
    let onStop: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {

                // ── Data Collection Control ──────────────────────────────
                GroupBox {
                    VStack(spacing: 16) {
                        // Status row
                        HStack(spacing: 10) {
                            Circle()
                                .fill(connectionColor)
                                .frame(width: 14, height: 14)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(opcuaService.connectionState.rawValue)
                                    .font(.headline)
                                if opcuaService.isPolling {
                                    Text("Polling active — 1 s interval")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Text("Server: \(Configuration.opcuaServerURL)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()

                            // Connecting spinner
                            if opcuaService.connectionState == .connecting {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }

                        Divider()

                        // Start / Stop button
                        HStack {
                            Spacer()
                            if isRunning {
                                Button(role: .destructive, action: onStop) {
                                    Label("Stop Data Collection", systemImage: "stop.circle.fill")
                                        .frame(minWidth: 200)
                                }
                                .controlSize(.large)
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
                            } else {
                                Button(action: onStart) {
                                    Label("Start Data Collection", systemImage: "play.circle.fill")
                                        .frame(minWidth: 200)
                                }
                                .controlSize(.large)
                                .buttonStyle(.borderedProminent)
                                .tint(.green)
                                .disabled(opcuaService.connectionState == .connecting)
                            }
                            Spacer()
                        }
                    }
                } label: {
                    Label("Data Collection", systemImage: "antenna.radiowaves.left.and.right")
                }

                // ── Tag Statistics ───────────────────────────────────────
                GroupBox {
                    let stats = tagEngine.getStatistics()
                    HStack(spacing: 24) {
                        StatPill(label: "Total",     value: "\(stats.totalTags)",     color: .primary)
                        StatPill(label: "Good",      value: "\(stats.goodTags)",      color: .green)
                        StatPill(label: "Uncertain", value: "\(stats.uncertainTags)", color: .yellow)
                        StatPill(label: "Bad",       value: "\(stats.badTags)",       color: .red)
                        Spacer()
                    }
                } label: {
                    Label("Tag Statistics", systemImage: "chart.bar")
                }

                // ── Active Alarms Summary ────────────────────────────────
                GroupBox {
                    let stats = alarmManager.getStatistics()
                    if stats.totalActive == 0 {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("All systems normal — no active alarms")
                                .foregroundColor(.secondary)
                        }
                    } else {
                        HStack(spacing: 24) {
                            StatPill(label: "Active",  value: "\(stats.totalActive)",     color: .red)
                            StatPill(label: "Unack",   value: "\(stats.unacknowledged)",  color: .orange)
                            StatPill(label: "Critical",value: "\(stats.critical)",         color: .red)
                            StatPill(label: "Warning", value: "\(stats.warning)",          color: .orange)
                            Spacer()
                        }
                    }
                } label: {
                    Label("Active Alarms", systemImage: "exclamationmark.triangle")
                }

                Spacer()
            }
            .padding()
        }
        .navigationTitle("Overview")
    }

    private var connectionColor: Color {
        switch opcuaService.connectionState {
        case .connected:    return .green
        case .connecting:   return .yellow
        case .disconnected: return .gray
        case .error:        return .red
        }
    }
}

// MARK: - Supporting Views

struct StatRow: View {
    let label: String
    let value: String
    var color: Color = .primary

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundColor(color)
        }
    }
}

struct StatPill: View {
    let label: String
    let value: String
    var color: Color = .primary

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title2.bold())
                .foregroundColor(color)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

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
