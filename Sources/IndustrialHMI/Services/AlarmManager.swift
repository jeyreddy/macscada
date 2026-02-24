import Foundation
import Combine

/// ISA-18.2 compliant alarm manager.
///
/// activeAlarms contains only alarms that are VISIBLE to the operator:
///   • .unacknowledgedActive  — condition on, not yet acked
///   • .acknowledgedActive    — condition on, acked (still showing)
///   • .unacknowledgedRTN     — condition cleared, acked needed
///
/// An alarm leaves activeAlarms (→ history only) when it reaches .normal:
///   • UnackActive + Ack  → AckActive    (stays visible, condition still on)
///   • AckActive  + RTN   → Normal       (removed — fully resolved)
///   • UnackActive + RTN  → UnackRTN     (stays visible, needs ack)
///   • UnackRTN   + Ack   → Normal       (removed — operator confirmed the event)
@MainActor
class AlarmManager: ObservableObject {

    // MARK: - Published Properties

    @Published var activeAlarms: [Alarm] = []
    @Published var alarmHistory: [Alarm] = []
    @Published var alarmConfigs: [AlarmConfig] = []
    @Published var unacknowledgedCount: Int = 0

    // MARK: - Private

    /// Tracks the last known ISA-18.2 state per tag name.
    private var alarmStates: [String: AlarmState] = [:]

    // MARK: - Init

    init() {
        Logger.shared.info("AlarmManager (ISA-18.2) initialized")
    }

    // MARK: - Alarm Configuration

    func addAlarmConfig(_ config: AlarmConfig) {
        alarmConfigs.append(config)
        Logger.shared.info("Added alarm config for: \(config.tagName)")
    }

    func removeAlarmConfig(_ config: AlarmConfig) {
        alarmConfigs.removeAll { $0.id == config.id }
    }

    func updateAlarmConfig(_ config: AlarmConfig) {
        if let i = alarmConfigs.firstIndex(where: { $0.id == config.id }) {
            alarmConfigs[i] = config
        }
    }

    // MARK: - Alarm Detection  (ISA-18.2 state machine)

    func checkAlarms(for tag: Tag) {
        guard let config = alarmConfigs.first(where: { $0.tagName == tag.name }),
              config.enabled,
              tag.quality == .good,
              let value = tag.value.numericValue else { return }

        let (violated, severity, message) = config.checkViolation(value: value)
        let currentState = alarmStates[tag.name]

        if violated, let severity, let message {
            // ── Alarm condition is ACTIVE ──────────────────────────────────
            switch currentState {
            case nil, .normal:
                // Fresh alarm
                raiseAlarm(tagName: tag.name, message: message, severity: severity, value: value)

            case .unacknowledgedRTN:
                // Re-alarm: value went bad again before operator acked the RTN.
                // Supersede the pending-ack RTN with a new Unack Active alarm.
                removeFromActive(tagName: tag.name, state: .unacknowledgedRTN, toHistory: true)
                raiseAlarm(tagName: tag.name, message: message, severity: severity, value: value)

            default:
                break   // already .unacknowledgedActive or .acknowledgedActive — no duplicate
            }

        } else {
            // ── Condition has CLEARED ──────────────────────────────────────
            guard let currentState else { return }
            if currentState.conditionActive {
                transitionToRTN(tagName: tag.name)
            }
        }
    }

    // MARK: - Alarm Actions

    /// Acknowledge a single alarm.
    /// - UnackActive → AckActive  (stays in active list; condition still on)
    /// - UnackRTN    → Normal     (leaves active list; fully resolved)
    func acknowledgeAlarm(_ alarm: Alarm, by username: String = "Operator") {
        guard let idx = activeAlarms.firstIndex(where: { $0.id == alarm.id }),
              activeAlarms[idx].state.requiresAction else { return }

        activeAlarms[idx].acknowledge(by: username)
        let updated = activeAlarms[idx]
        syncHistory(updated)

        switch updated.state {
        case .acknowledgedActive:
            alarmStates[alarm.tagName] = .acknowledgedActive
            // Stays in activeAlarms — condition still present

        case .normal:
            alarmStates[alarm.tagName] = .normal
            activeAlarms.remove(at: idx)    // fully resolved

        default: break
        }

        recalcUnackCount()
        Logger.shared.info("Ack \(alarm.tagName) by \(username) → \(updated.state.rawValue)")
    }

    /// Acknowledge ALL visible alarms.
    func acknowledgeAllAlarms(by username: String = "Operator") {
        for i in activeAlarms.indices {
            guard activeAlarms[i].state.requiresAction else { continue }
            activeAlarms[i].acknowledge(by: username)
            syncHistory(activeAlarms[i])
            alarmStates[activeAlarms[i].tagName] = activeAlarms[i].state
        }
        // Remove any that reached .normal (were UnackRTN → Normal)
        activeAlarms.removeAll { $0.state == .normal }
        recalcUnackCount()
        Logger.shared.info("All alarms acknowledged by \(username)")
    }

    func clearAlarmHistory() {
        alarmHistory.removeAll()
        Logger.shared.info("Alarm history cleared")
    }

    // MARK: - Filtering helpers

    func getUnacknowledgedAlarms() -> [Alarm] {
        activeAlarms.filter { $0.state.requiresAction }
    }

    func getAlarms(withSeverity severity: AlarmSeverity) -> [Alarm] {
        activeAlarms.filter { $0.severity == severity }
    }

    func getAlarms(forTag tagName: String) -> [Alarm] {
        activeAlarms.filter { $0.tagName == tagName }
    }

    // MARK: - Statistics

    func getStatistics() -> AlarmStatistics {
        AlarmStatistics(
            totalActive:     activeAlarms.count,
            unacknowledged:  unacknowledgedCount,
            critical:        activeAlarms.filter { $0.severity == .critical }.count,
            warning:         activeAlarms.filter { $0.severity == .warning  }.count,
            info:            activeAlarms.filter { $0.severity == .info     }.count,
            totalHistory:    alarmHistory.count
        )
    }

    // MARK: - Private helpers

    private func raiseAlarm(tagName: String, message: String,
                            severity: AlarmSeverity, value: Double) {
        let alarm = Alarm(tagName: tagName, message: message,
                          severity: severity, state: .unacknowledgedActive, value: value)
        activeAlarms.append(alarm)
        alarmHistory.append(alarm)
        alarmStates[tagName] = .unacknowledgedActive
        recalcUnackCount()
        triggerAlarmNotification(alarm)
        Logger.shared.warning("ALARM: \(message)")
    }

    /// Transition the alarm for tagName from conditionActive → RTN state.
    private func transitionToRTN(tagName: String) {
        guard let idx = activeAlarms.firstIndex(where: {
            $0.tagName == tagName && $0.state.conditionActive
        }) else { return }

        activeAlarms[idx].returnToNormal()
        let updated = activeAlarms[idx]
        syncHistory(updated)

        switch updated.state {
        case .unacknowledgedRTN:
            alarmStates[tagName] = .unacknowledgedRTN
            // Stays visible — operator must still ack

        case .normal:
            alarmStates[tagName] = .normal
            activeAlarms.remove(at: idx)    // AckActive→Normal: fully resolved
            recalcUnackCount()

        default: break
        }

        Logger.shared.info("RTN: \(tagName) → \(updated.state.rawValue)")
    }

    /// Remove a specific alarm from activeAlarms (superseded / re-alarmed).
    private func removeFromActive(tagName: String, state: AlarmState, toHistory: Bool) {
        guard let idx = activeAlarms.firstIndex(where: {
            $0.tagName == tagName && $0.state == state
        }) else { return }
        if toHistory { syncHistory(activeAlarms[idx]) }
        activeAlarms.remove(at: idx)
        recalcUnackCount()
    }

    /// Sync an alarm's current state back into alarmHistory.
    private func syncHistory(_ alarm: Alarm) {
        if let hIdx = alarmHistory.firstIndex(where: { $0.id == alarm.id }) {
            alarmHistory[hIdx] = alarm
        }
    }

    /// Recompute unacknowledgedCount from activeAlarms.
    private func recalcUnackCount() {
        unacknowledgedCount = activeAlarms.filter { $0.state.requiresAction }.count
    }

    // MARK: - Notifications

    private func triggerAlarmNotification(_ alarm: Alarm) {
        let notification = NSUserNotification()
        notification.title = "Process Alarm: \(alarm.severity.rawValue)"
        notification.informativeText = alarm.message
        notification.soundName = alarm.severity.soundEnabled
            ? NSUserNotificationDefaultSoundName : nil
        NSUserNotificationCenter.default.deliver(notification)
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
}
