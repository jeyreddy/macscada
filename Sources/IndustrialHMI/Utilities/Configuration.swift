import Foundation

/// Application configuration settings
struct Configuration {
    // MARK: - OPC-UA Settings
    
    /// OPC-UA server endpoint URL
    static let opcuaServerURL = "opc.tcp://mac:4840"
    
    /// Connection timeout in seconds
    static let connectionTimeout: TimeInterval = 30.0
    
    /// Subscription update interval in seconds
    static let subscriptionInterval: TimeInterval = 1.0
    
    /// Maximum number of tags to subscribe to simultaneously
    static let maxSubscriptionTags = 1000
    
    // MARK: - Historian Settings
    
    /// Data retention period in days
    static let historianRetentionDays = 90
    
    /// Batch size for historian writes
    static let historianBatchSize = 100
    
    /// Historian write interval in seconds
    static let historianWriteInterval: TimeInterval = 1.0
    
    // MARK: - Alarm Settings
    
    /// Enable audio alarm notifications
    static let alarmAudioEnabled = true
    
    /// Enable visual alarm notifications
    static let alarmVisualEnabled = true
    
    /// Alarm acknowledgment timeout in seconds (auto-acknowledge)
    static let alarmAcknowledgmentTimeout: TimeInterval? = nil // nil = never auto-ack
    
    // MARK: - UI Settings
    
    /// Trend chart maximum data points
    static let trendMaxDataPoints = 1000
    
    /// Trend chart default time range in hours
    static let trendDefaultTimeRangeHours = 24
    
    /// Tag table refresh rate in seconds
    static let tagTableRefreshRate: TimeInterval = 0.5
    
    // MARK: - Performance Settings
    
    /// Control logic scan rate in seconds
    static let controlScanRate: TimeInterval = 1.0
    
    /// Maximum number of device instances
    static let maxDeviceInstances = 100
    
    /// Enable performance monitoring
    static let performanceMonitoringEnabled = true
    
    // MARK: - Security Settings
    
    /// Require user authentication
    static let requireAuthentication = false // Set to true in production
    
    /// Session timeout in minutes
    static let sessionTimeoutMinutes = 30
    
    /// Enable audit logging
    static let auditLoggingEnabled = true
    
    // MARK: - Development Settings
    
    /// Enable simulation mode (no real OPC-UA server required)
    static let simulationMode = false // Set to false when using real OPC-UA server
    
    /// Enable verbose logging
    static let verboseLogging = true
    
    /// Enable SwiftUI debug tools
    static let swiftUIDebugEnabled = false
}

// MARK: - User Preferences

/// User-specific preferences (stored in UserDefaults)
class UserPreferences: ObservableObject {
    @Published var darkModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(darkModeEnabled, forKey: "darkModeEnabled")
        }
    }
    
    @Published var compactView: Bool {
        didSet {
            UserDefaults.standard.set(compactView, forKey: "compactView")
        }
    }
    
    @Published var showToolbar: Bool {
        didSet {
            UserDefaults.standard.set(showToolbar, forKey: "showToolbar")
        }
    }
    
    init() {
        self.darkModeEnabled = UserDefaults.standard.bool(forKey: "darkModeEnabled")
        self.compactView = UserDefaults.standard.bool(forKey: "compactView")
        self.showToolbar = UserDefaults.standard.bool(forKey: "showToolbar")
    }
}
