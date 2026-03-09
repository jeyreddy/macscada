// MARK: - IndustrialHMIApp.swift
//
// Application entry point and top-level dependency injection for IndustrialHMI.
// Bootstraps all @StateObject services and provides them as @EnvironmentObject
// to the SwiftUI view hierarchy.
//
// ── Startup Sequence ──────────────────────────────────────────────────────────
//   1. AppDelegate.enforceSingleInstance() — lock file at /tmp/IndustrialHMI.lock
//      Alerts if another instance is running; offers "Terminate & Continue" or "Quit".
//   2. Configuration.migrateServerURLIfNeeded() — clears stale bare hostnames from UserDefaults
//   3. DataService creates all subordinate services (TagEngine, Historian, AlarmManager, etc.)
//   4. MultimodalInputService.placeholder() created; wired in MainView.onAppear
//   5. MainView appears → mainView.onAppear() calls:
//        multimodalInput.wire(agentService:sessionManager:)
//        panelManager.configure(all services)
//
// ── AppDelegate ───────────────────────────────────────────────────────────────
//   Single-instance enforcement via /tmp/IndustrialHMI.lock (PID file).
//   Existing PID tested with kill(pid, 0) — if alive, alert with Terminate option.
//   kill(oldPID, SIGTERM) terminates old instance; lock file written with new PID.
//   NSApp.setActivationPolicy(.regular) ensures the app appears in the Dock.
//   bringMainWindowToFront(): retried 3× (0, 150ms, 500ms) to handle SwiftUI window init delay.
//
// ── Environment Object Chain ──────────────────────────────────────────────────
//   @StateObject:
//     dataService (owns all services including tagEngine, alarmManager, etc.)
//     multimodalInput + sub-services (speechInput, gestureInput, speechOutput)
//     panelManager (NSPanel floating windows)
//   All passed down from IndustrialHMIApp.body → MainView via .environmentObject()
//
// ── diagLog() ─────────────────────────────────────────────────────────────────
//   Global diagnostic helper writing to stdout + /tmp/hmi_diag.log.
//   Gated by Configuration.verboseLogging — no-ops in production.
//   Used during startup and deep OPC-UA debugging where Logger.shared is too late.

import SwiftUI

// MARK: - App-wide Notification Names

extension Notification.Name {
    /// Navigate to a sidebar tab. Post with object: Tab (the target tab).
    static let navigateToTab     = Notification.Name("hmi.navigateToTab")
    /// Delete the currently selected HMI object (edit mode).
    static let hmiDeleteSelected = Notification.Name("hmi.deleteSelected")
}

// Diagnostic helper — writes to both stdout and /tmp/hmi_diag.log.
// No-ops when Configuration.verboseLogging is false.
let diagLogURL = URL(fileURLWithPath: "/tmp/hmi_diag.log")
func diagLog(_ msg: String) {
    guard Configuration.verboseLogging else { return }
    let line = "\(Date()) \(msg)\n"
    print(line, terminator: "")
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: diagLogURL.path) {
            if let fh = try? FileHandle(forWritingTo: diagLogURL) {
                fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
            }
        } else {
            try? data.write(to: diagLogURL)
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {

    private static let lockFile = URL(fileURLWithPath: "/tmp/IndustrialHMI.lock")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance enforcement — must run before UI appears
        enforceSingleInstance()

        // Ensure we're registered as a regular (foreground) app
        NSApp.setActivationPolicy(.regular)

        // Try immediately, then again after SwiftUI finishes creating the window
        bringMainWindowToFront()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.bringMainWindowToFront() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5)  { self.bringMainWindowToFront() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        try? FileManager.default.removeItem(at: Self.lockFile)
    }

    // MARK: - Single-instance enforcement

    private func enforceSingleInstance() {
        let myPID = ProcessInfo.processInfo.processIdentifier

        if let data     = try? Data(contentsOf: Self.lockFile),
           let pidStr   = String(data: data, encoding: .utf8),
           let oldPID   = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)),
           kill(oldPID, 0) == 0 {                          // process still alive?

            let alert = NSAlert()
            alert.messageText    = "Industrial HMI is Already Running"
            alert.informativeText =
                "An existing session (PID \(oldPID)) is already running.\n\n" +
                "Click \"Terminate & Continue\" to close it and start this session, " +
                "or \"Quit\" to exit instead."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Terminate & Continue")
            alert.addButton(withTitle: "Quit")

            if alert.runModal() == .alertFirstButtonReturn {
                // Graceful SIGTERM, then force SIGKILL after 2 s
                kill(oldPID, SIGTERM)
                var waited = 0
                while kill(oldPID, 0) == 0 && waited < 20 {
                    Thread.sleep(forTimeInterval: 0.1)
                    waited += 1
                }
                if kill(oldPID, 0) == 0 { kill(oldPID, SIGKILL) }
            } else {
                exit(0)
            }
        }

        // Write our own PID
        try? Data("\(myPID)".utf8).write(to: Self.lockFile)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        sender.windows.filter { $0.isMiniaturized }.forEach { $0.deminiaturize(nil) }
        bringMainWindowToFront()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        bringMainWindowToFront()
    }

    func bringMainWindowToFront() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()   // bypasses normal z-order restrictions
        }
    }
}

// MARK: - App

@main
struct IndustrialHMIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // MARK: - State Objects (Singleton Services)

    /// Top-level service orchestrator — owns all drivers and databases
    @StateObject private var dataService = DataService()

    /// Multimodal input layer — wired to agentService + sessionManager in onAppear
    @StateObject private var multimodalInput = MultimodalInputService.placeholder()

    // MARK: - App Lifecycle

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(dataService)
                .environmentObject(dataService.opcuaService)
                .environmentObject(dataService.tagEngine)
                .environmentObject(dataService.alarmManager)
                .environmentObject(dataService.hmiScreenStore)
                .environmentObject(dataService.agentService)
                .environmentObject(dataService.sessionManager)
                .environmentObject(dataService.recipeStore)
                .environmentObject(dataService.communityService)
                .environmentObject(dataService.schedulerService)
                .environmentObject(dataService.hmi3DSceneStore)
                .environmentObject(dataService.processCanvasStore)
                .environmentObject(multimodalInput)
                .environmentObject(multimodalInput.speechInput)
                .environmentObject(multimodalInput.gestureInput)
                .environmentObject(multimodalInput.speechOutput)
                .frame(minWidth: 1200, minHeight: 800)
                .onAppear {
                    multimodalInput.wire(
                        agentService:   dataService.agentService,
                        sessionManager: dataService.sessionManager
                    )
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            // ── About ──────────────────────────────────────────────────────
            CommandGroup(replacing: .appInfo) {
                Button("About Industrial HMI") {
                    NSApp.orderFrontStandardAboutPanel(
                        options: [
                            NSApplication.AboutPanelOptionKey.applicationName: "Industrial HMI",
                            NSApplication.AboutPanelOptionKey.applicationVersion: "0.1.0",
                            NSApplication.AboutPanelOptionKey.version: "Build 1",
                            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026"
                        ]
                    )
                }
            }

            // ── Navigate menu — Cmd+1…5 and Cmd+, ────────────────────────
            CommandMenu("Navigate") {
                Button("Monitor")        { post(.monitor)  }.keyboardShortcut("1", modifiers: .command)
                Button("Trends")         { post(.trends)   }.keyboardShortcut("2", modifiers: .command)
                Button("Alarms")         { post(.alarms)   }.keyboardShortcut("3", modifiers: .command)
                Button("HMI Screens")    { post(.hmi)      }.keyboardShortcut("4", modifiers: .command)
                Button("Process Canvas") { post(.canvas)   }.keyboardShortcut("5", modifiers: .command)
                Divider()
                Button("Settings")       { post(.settings) }.keyboardShortcut(",", modifiers: .command)
            }

            // ── HMI Editor menu ───────────────────────────────────────────
            CommandMenu("HMI Editor") {
                Button("Delete Selected Object") {
                    NotificationCenter.default.post(name: .hmiDeleteSelected, object: nil)
                }
                .keyboardShortcut(.delete, modifiers: [])
            }
        }
    }
    
    // MARK: - App Initialization
    
    init() {
        // Configure app appearance
        setupAppearance()
        
        // Initialize logging
        Logger.shared.info("Industrial HMI starting...")
        Logger.shared.info("macOS version: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        Logger.shared.info("Architecture: \(getArchitecture())")
    }
    
    // MARK: - Private Helpers
    
    private func setupAppearance() {
        // Set app-wide appearance preferences
        NSWindow.allowsAutomaticWindowTabbing = false
    }
    
    /// Posts a tab-navigation notification from within Commands (no environment access there).
    private func post(_ tab: Tab) {
        NotificationCenter.default.post(name: .navigateToTab, object: tab)
    }

    private func getArchitecture() -> String {
        #if arch(arm64)
        return "Apple Silicon (ARM64)"
        #elseif arch(x86_64)
        return "Intel (x86_64)"
        #else
        return "Unknown"
        #endif
    }
}
