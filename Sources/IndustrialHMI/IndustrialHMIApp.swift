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

@main
struct IndustrialHMIApp: App {
    // MARK: - State Objects (Singleton Services)
    
    /// OPC-UA client service for industrial protocol communication
    @StateObject private var opcuaService = OPCUAClientService()
    
    /// Central tag database for real-time process data
    @StateObject private var tagEngine = TagEngine()
    
    /// Alarm detection and management system
    @StateObject private var alarmManager = AlarmManager()
    
    // MARK: - App Lifecycle
    
    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(opcuaService)
                .environmentObject(tagEngine)
                .environmentObject(alarmManager)
                .frame(minWidth: 1200, minHeight: 800)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                    if let window = NSApp.windows.first {
                        window.title = "Industrial HMI"
                        window.makeKeyAndOrderFront(nil)
                    }
                }
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
