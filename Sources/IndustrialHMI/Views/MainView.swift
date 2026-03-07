import SwiftUI

// MARK: - MainView.swift
//
// Root container view for the entire IndustrialHMI application.
// Renders a macOS-style NavigationSplitView with:
//   • Left sidebar — tab list (all Tab enum cases) + session pill at the bottom
//   • Detail pane  — content view for the selected tab
//
// ── Tab management strategy ───────────────────────────────────────────────────
//   The three most complex, state-heavy views (MonitorView, TrendView,
//   HMIDesignerView, AgentView, ProcessCanvasView) are always instantiated in a
//   ZStack and shown/hidden via opacity + allowsHitTesting.  This preserves their
//   internal state (scroll positions, filters, in-progress edits) across tab
//   switches without re-initializing them.
//
//   Lighter views (AlarmListView, AuditLogView, RecipesView, etc.) are created on
//   demand via a switch — they re-initialize on each tab visit, which is fine
//   since they load their data from persistent stores on .onAppear.
//
// ── Login overlay ─────────────────────────────────────────────────────────────
//   When sessionManager.isLoggedIn = false, LoginView covers the entire detail
//   pane via .overlay.  No HMI data is visible until the operator signs in.
//
// ── onAppear wiring ───────────────────────────────────────────────────────────
//   Critical cross-service callbacks are wired here (not in service init) because
//   closures would create retain cycles between services if stored during init:
//     • agentService.navigateToTab  — allows tools to switch tabs
//     • processCanvasStore.navigateToHMIScreen — hmiScreen block tap handler
//     • panelManager.configure(...)  — wires floating chat/voice panels
//
// ── Alarm badge ───────────────────────────────────────────────────────────────
//   The Alarms tab shows a red badge with AlarmManager.unacknowledgedCount.
//   The badge disappears when all alarms are acknowledged.
//
// ── FloatingPanelManager ──────────────────────────────────────────────────────
//   panelManager (FloatingPanelManager) manages two floating NSPanel windows
//   that overlay the main window: one for the chat (AgentView) and one for the
//   multimodal control panel (voice/gesture). These are independent of the tab system.

struct MainView: View {
    // MARK: - Environment Objects

    @EnvironmentObject var dataService:      DataService
    @EnvironmentObject var opcuaService:     OPCUAClientService
    @EnvironmentObject var tagEngine:        TagEngine
    @EnvironmentObject var alarmManager:     AlarmManager
    @EnvironmentObject var agentService:     AgentService
    @EnvironmentObject var sessionManager:   SessionManager
    @EnvironmentObject var recipeStore:      RecipeStore
    @EnvironmentObject var communityService:  CommunityService
    @EnvironmentObject var schedulerService: SchedulerService
    @EnvironmentObject var hmi3DSceneStore:  HMI3DSceneStore
    @EnvironmentObject var multimodalInput:     MultimodalInputService
    @EnvironmentObject var speechInput:         SpeechInputService
    @EnvironmentObject var gestureInput:         GestureInputService
    @EnvironmentObject var speechOutput:         SpeechOutputService
    @EnvironmentObject var processCanvasStore:   ProcessCanvasStore
    @EnvironmentObject var hmiScreenStore:       HMIScreenStore

    // MARK: - State

    @State private var selectedTab: Tab = .monitor

    @AppStorage("showRecipesTab")   private var showRecipesTab   = false
    @AppStorage("showSchedulerTab") private var showSchedulerTab = false
    @AppStorage("showAgentTab")     private var showAgentTab     = false

    /// Manages the two free-floating NSPanel windows (chat + voice/gesture).
    @StateObject private var panelManager = FloatingPanelManager()

    // Tabs shown in the sidebar — community, auditLog & agent live inside Settings
    private var visibleTabs: [Tab] {
        var tabs: [Tab] = [.monitor, .trends, .alarms, .canvas, .hmi]
        if showRecipesTab   { tabs.append(.recipes) }
        if showSchedulerTab { tabs.append(.scheduler) }
        if showAgentTab     { tabs.append(.agent) }
        tabs.append(.settings)
        return tabs
    }

    // MARK: - Body

    var body: some View {
        NavigationSplitView {
            List(visibleTabs, selection: $selectedTab) { tab in
                Label(tab.title, systemImage: tab.icon)
                    .badge(tab == .alarms ? alarmBadge : 0)
                    .tag(tab)
            }
            .navigationTitle("Industrial HMI")
            .listStyle(.sidebar)

            // Session pill at the bottom of the sidebar
            Divider()
            sessionPill
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

        } detail: {
            // MonitorView, TrendView, HMIDesignerView stay permanently alive
            // so their state is preserved across tab switches.
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

                AgentView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(selectedTab == .agent ? 1 : 0)
                    .allowsHitTesting(selectedTab == .agent)

                ProcessCanvasView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(selectedTab == .canvas ? 1 : 0)
                    .allowsHitTesting(selectedTab == .canvas)

                // On-demand views
                Group {
                    switch selectedTab {
                    case .alarms:    AlarmListView()
                    case .recipes:   RecipesView()
                    case .scheduler: SchedulerView()
                    case .settings:  SettingsView()
                    case .auditLog:  AuditLogView()
                    case .community: CommunitySettingsView()
                    case .monitor, .trends, .hmi, .agent, .canvas:
                        Color.clear
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle(selectedTab.title)
            // Login overlay — blocks the detail pane until authenticated
            .overlay {
                if !sessionManager.isLoggedIn {
                    LoginView()
                        .environmentObject(sessionManager)
                }
            }
        }
        .onChange(of: selectedTab) { old, new in
            diagLog("DIAG [MainView] tab changed: \(old.rawValue) → \(new.rawValue)")
            sessionManager.recordActivity()
        }
        .onAppear {
            agentService.navigateToTab = { tab in selectedTab = tab }
            panelManager.configure(
                agentService:   agentService,
                sessionManager: sessionManager,
                multimodal:     multimodalInput,
                speechInput:    speechInput,
                gestureInput:   gestureInput,
                speechOutput:   speechOutput
            )
            processCanvasStore.navigateToHMIScreen = { screenID in
                hmiScreenStore.switchToScreen(id: screenID)
                selectedTab = .hmi
            }
        }
    }

    // MARK: - Helpers

    private var alarmBadge: Int { alarmManager.unacknowledgedCount }

    // MARK: - Session pill (sidebar footer)

    private var sessionPill: some View {
        HStack(spacing: HMIStyle.spacingS) {
            Image(systemName: "person.circle.fill")
                .font(.title3)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(sessionManager.currentOperator?.displayName ?? "—")
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Text(sessionManager.currentRole.displayName)
                    .font(HMIStyle.fieldLabelFont)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                sessionManager.logout()
            } label: {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Sign out")
            .disabled(!sessionManager.isLoggedIn)
        }
    }
}

// MARK: - Tab Enumeration

enum Tab: String, CaseIterable, Identifiable {
    case monitor
    case trends
    case alarms
    case canvas
    case community
    case auditLog
    case recipes
    case scheduler
    case hmi
    case agent
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .monitor:   return "Monitor"
        case .trends:    return "Trends"
        case .alarms:    return "Alarms"
        case .canvas:    return "Process Canvas"
        case .community: return "Community"
        case .auditLog:  return "Audit Log"
        case .recipes:   return "Recipes"
        case .scheduler: return "Scheduler"
        case .hmi:       return "HMI Screens"
        case .agent:     return "AI Agent"
        case .settings:  return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .monitor:   return "gauge"
        case .trends:    return "chart.xyaxis.line"
        case .alarms:    return "exclamationmark.triangle"
        case .canvas:    return "square.grid.3x3.fill"
        case .community: return "network"
        case .auditLog:  return "doc.text.magnifyingglass"
        case .recipes:   return "square.stack.3d.up"
        case .scheduler: return "calendar.badge.clock"
        case .hmi:       return "rectangle.on.rectangle"
        case .agent:     return "cpu.fill"
        case .settings:  return "gear"
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var opcuaService:    OPCUAClientService
    @EnvironmentObject var dataService:     DataService
    @EnvironmentObject var sessionManager:  SessionManager
    @EnvironmentObject var hmi3DSceneStore: HMI3DSceneStore
    @EnvironmentObject var speechInput:     SpeechInputService
    @EnvironmentObject var gestureInput:    GestureInputService
    @EnvironmentObject var speechOutput:    SpeechOutputService

    @AppStorage("showRecipesTab")   private var showRecipesTab   = false
    @AppStorage("showSchedulerTab") private var showSchedulerTab = false
    @AppStorage("showAgentTab")     private var showAgentTab     = false

    var body: some View {
        TabView {
            ConnectionsSettingsView()
                .tabItem { Label("Connections", systemImage: "cable.coaxial") }

            if sessionManager.canManageUsers {
                UserManagementView()
                    .tabItem { Label("Users", systemImage: "person.2") }
            }

            HMIDisplaySettingsView()
                .environmentObject(hmi3DSceneStore)
                .tabItem { Label("HMI Display", systemImage: "rectangle.3.group") }

            MultimodalSettingsView()
                .tabItem { Label("Voice & Gesture", systemImage: "mic.and.signal.meter.fill") }

            CommunitySettingsView()
                .tabItem { Label("Community", systemImage: "network.badge.shield.half.filled") }

            AuditLogView()
                .tabItem { Label("Audit Log", systemImage: "doc.text.magnifyingglass") }

            SidebarConfigView(showRecipesTab: $showRecipesTab, showSchedulerTab: $showSchedulerTab, showAgentTab: $showAgentTab)
                .tabItem { Label("Sidebar", systemImage: "sidebar.left") }
        }
    }
}

// MARK: - Sidebar Configuration (optional tabs toggle)

struct SidebarConfigView: View {
    @Binding var showRecipesTab:   Bool
    @Binding var showSchedulerTab: Bool
    @Binding var showAgentTab:     Bool

    var body: some View {
        Form {
            Section("Optional Tabs") {
                Toggle("Recipes",   isOn: $showRecipesTab)
                Toggle("Scheduler", isOn: $showSchedulerTab)
                Toggle("AI Agent",  isOn: $showAgentTab)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 400)
        .padding()
    }
}
