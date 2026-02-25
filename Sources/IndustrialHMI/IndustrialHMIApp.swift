import SwiftUI

// Diagnostic helper — writes to both stdout and /tmp/hmi_diag.log
let diagLogURL = URL(fileURLWithPath: "/tmp/hmi_diag.log")
func diagLog(_ msg: String) {
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure we're registered as a regular (foreground) app
        NSApp.setActivationPolicy(.regular)

        // Try immediately, then again after SwiftUI finishes creating the window
        bringMainWindowToFront()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.bringMainWindowToFront() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5)  { self.bringMainWindowToFront() }
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
                .frame(minWidth: 1200, minHeight: 800)
        }
        .windowToolbarStyle(.unified)
        .commands {
            // Custom menu commands
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
