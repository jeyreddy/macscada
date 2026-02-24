import Foundation
import Combine

/// Manages alarm detection, state tracking, and notifications
@MainActor
class AlarmManager: ObservableObject {
    // MARK: - Published Properties
    
    @Published var activeAlarms: [Alarm] = []
    @Published var alarmHistory: [Alarm] = []
    @Published var alarmConfigs: [AlarmConfig] = []
    @Published var unacknowledgedCount: Int = 0
    
    // MARK: - Private Properties
    
    private var alarmStates: [String: AlarmState] = [:]
    private var subscriptions = Set<AnyCancellable>()
    
    // MARK: - Initialization
    
    init() {
        // Load sample alarm configurations
        loadSampleConfigs()
        Logger.shared.info("Alarm manager initialized with \(alarmConfigs.count) configurations")
    }
    
    // MARK: - Alarm Configuration
    
    /// Add new alarm configuration
    func addAlarmConfig(_ config: AlarmConfig) {
        alarmConfigs.append(config)
        Logger.shared.info("Added alarm config for tag: \(config.tagName)")
    }
    
    /// Remove alarm configuration
    func removeAlarmConfig(_ config: AlarmConfig) {
        alarmConfigs.removeAll { $0.id == config.id }
    }
    
    /// Update alarm configuration
    func updateAlarmConfig(_ config: AlarmConfig) {
        if let index = alarmConfigs.firstIndex(where: { $0.id == config.id }) {
            alarmConfigs[index] = config
        }
    }
    
    // MARK: - Alarm Detection
    
    /// Check tag value against configured alarm thresholds
    func checkAlarms(for tag: Tag) {
        guard let config = alarmConfigs.first(where: { $0.tagName == tag.name }),
              config.enabled,
              tag.quality == .good,
              let value = tag.value.numericValue else {
            return
        }
        
        let (violated, severity, message) = config.checkViolation(value: value)
        let currentState = alarmStates[tag.name]
        
        if violated, let severity = severity, let message = message {
            // Alarm condition is active
            if currentState == nil || currentState == .returnToNormal {
                // New alarm - create and trigger
                let alarm = Alarm(
                    tagName: tag.name,
                    message: message,
                    severity: severity,
                    state: .active,
                    value: value
                )
                
                activeAlarms.append(alarm)
                alarmHistory.append(alarm)
                alarmStates[tag.name] = .active
                unacknowledgedCount += 1
                
                // Trigger notifications
                triggerAlarmNotification(alarm)
                
                Logger.shared.warning("ALARM: \(message)")
            }
        } else {
            // No violation - check for return to normal
            if currentState == .active || currentState == .acknowledged {
                returnToNormal(tagName: tag.name)
            }
        }
    }
    
    /// Mark alarm as returned to normal
    private func returnToNormal(tagName: String) {
        if let index = activeAlarms.firstIndex(where: { $0.tagName == tagName && $0.state != .returnToNormal }) {
            activeAlarms[index].returnToNormal()
            alarmStates[tagName] = .returnToNormal
            
            Logger.shared.info("Alarm returned to normal: \(tagName)")
            
            // Remove from active alarms after delay
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
                await MainActor.run {
                    self.activeAlarms.removeAll { $0.tagName == tagName && $0.state == .returnToNormal }
                }
            }
        }
    }
    
    // MARK: - Alarm Actions
    
    /// Acknowledge an alarm
    func acknowledgeAlarm(_ alarm: Alarm, by username: String = "Operator") {
        if let index = activeAlarms.firstIndex(where: { $0.id == alarm.id }) {
            activeAlarms[index].acknowledge(by: username)
            alarmStates[alarm.tagName] = .acknowledged
            unacknowledgedCount = max(0, unacknowledgedCount - 1)
            
            Logger.shared.info("Alarm acknowledged by \(username): \(alarm.tagName)")
        }
    }
    
    /// Acknowledge all active alarms
    func acknowledgeAllAlarms(by username: String = "Operator") {
        for i in 0..<activeAlarms.count {
            if activeAlarms[i].state == .active {
                activeAlarms[i].acknowledge(by: username)
                alarmStates[activeAlarms[i].tagName] = .acknowledged
            }
        }
        
        unacknowledgedCount = 0
        Logger.shared.info("All alarms acknowledged by \(username)")
    }
    
    /// Clear alarm history
    func clearAlarmHistory() {
        alarmHistory.removeAll()
        Logger.shared.info("Alarm history cleared")
    }
    
    // MARK: - Filtering
    
    /// Get alarms by severity
    func getAlarms(withSeverity severity: AlarmSeverity) -> [Alarm] {
        return activeAlarms.filter { $0.severity == severity }
    }
    
    /// Get unacknowledged alarms
    func getUnacknowledgedAlarms() -> [Alarm] {
        return activeAlarms.filter { $0.state == .active }
    }
    
    /// Get alarms for specific tag
    func getAlarms(forTag tagName: String) -> [Alarm] {
        return activeAlarms.filter { $0.tagName == tagName }
    }
    
    // MARK: - Notifications
    
    /// Trigger alarm notification (audio/visual)
    private func triggerAlarmNotification(_ alarm: Alarm) {
        // Visual notification (system notification)
        let notification = NSUserNotification()
        notification.title = "Process Alarm: \(alarm.severity.rawValue)"
        notification.informativeText = alarm.message
        notification.soundName = alarm.severity.soundEnabled ? NSUserNotificationDefaultSoundName : nil
        
        NSUserNotificationCenter.default.deliver(notification)
        
        // Audio alert for critical alarms
        if alarm.severity == .critical {
            // NSSound.beep()
        }
    }
    
    // MARK: - Statistics
    
    /// Get alarm statistics
    func getStatistics() -> AlarmStatistics {
        let critical = activeAlarms.filter { $0.severity == .critical }.count
        let warning = activeAlarms.filter { $0.severity == .warning }.count
        let info = activeAlarms.filter { $0.severity == .info }.count
        
        return AlarmStatistics(
            totalActive: activeAlarms.count,
            unacknowledged: unacknowledgedCount,
            critical: critical,
            warning: warning,
            info: info,
            totalHistory: alarmHistory.count
        )
    }
    
    // MARK: - Development Helpers
    
    /// Load sample alarm configurations
    private func loadSampleConfigs() {
        // Alarm configurations are defined by the user from Alarms → Configurations.
        // No sample configs loaded — alarmConfigs starts empty.
    }
    
    /// Simulate alarm for testing
    func simulateAlarm() {
        let alarm = Alarm(
            tagName: "TEST_TAG",
            message: "Simulated test alarm",
            severity: .warning,
            state: .active,
            value: 95.0
        )
        
        activeAlarms.append(alarm)
        alarmHistory.append(alarm)
        unacknowledgedCount += 1
        
        triggerAlarmNotification(alarm)
    }
}

// MARK: - Alarm Statistics

struct AlarmStatistics {
    let totalActive: Int
    let unacknowledged: Int
    let critical: Int
    let warning: Int
    let info: Int
    let totalHistory: Int
    
    var description: String {
        """
        Active: \(totalActive) (Unack: \(unacknowledged))
        Critical: \(critical)
        Warning: \(warning)
        Info: \(info)
        History: \(totalHistory)
        """
    }
}
