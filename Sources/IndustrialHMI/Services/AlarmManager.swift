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

    // MARK: - Historian (injected by DataService)

    var historian: Historian? = nil

    // MARK: - Private

    /// Tracks the last known ISA-18.2 state per tag name.
    private var alarmStates: [String: AlarmState] = [:]

    // MARK: - Init

    init() {
        Logger.shared.info("AlarmManager (ISA-18.2) initialized")
    }

    // MARK: - Bootstrap from DB

    func loadFromDB() async {
        guard let h = historian else { return }
        do {
            let savedConfigs = try await h.loadAlarmConfigs()
            alarmConfigs = savedConfigs
            Logger.shared.info("AlarmManager: loaded \(savedConfigs.count) alarm configs from DB")

            let history = try await h.loadAlarmHistory()
            alarmHistory = history
            Logger.shared.info("AlarmManager: loaded \(history.count) alarm history records from DB")

            let active = try await h.loadActiveAlarms()
            activeAlarms = active
            for alarm in active {
                alarmStates[alarm.tagName] = alarm.state
            }
            recalcUnackCount()
            Logger.shared.info("AlarmManager: restored \(active.count) active alarms from DB")
        } catch {
            Logger.shared.error("AlarmManager: failed to load from DB — \(error)")
        }
    }

    // MARK: - Alarm Configuration

    func addAlarmConfig(_ config: AlarmConfig) {
        alarmConfigs.append(config)
        Logger.shared.info("Added alarm config for: \(config.tagName)")
        persistConfig(config)
    }

    func removeAlarmConfig(_ config: AlarmConfig) {
        alarmConfigs.removeAll { $0.id == config.id }
        if let h = historian {
            Task { try? await h.deleteAlarmConfig(id: config.id) }
        }
    }

    func updateAlarmConfig(_ config: AlarmConfig) {
        if let i = alarmConfigs.firstIndex(where: { $0.id == config.id }) {
            alarmConfigs[i] = config
        }
        persistConfig(config)
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
                raiseAlarm(tagName: tag.name, message: message, severity: severity, value: value)

            case .unacknowledgedRTN:
                removeFromActive(tagName: tag.name, state: .unacknowledgedRTN, toHistory: true)
                raiseAlarm(tagName: tag.name, message: message, severity: severity, value: value)

            default:
                break
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

    func acknowledgeAlarm(_ alarm: Alarm, by username: String = "Operator") {
        guard let idx = activeAlarms.firstIndex(where: { $0.id == alarm.id }),
              activeAlarms[idx].state.requiresAction else { return }

        activeAlarms[idx].acknowledge(by: username)
        let updated = activeAlarms[idx]
        syncHistory(updated)
        persistAlarmUpdate(updated)

        switch updated.state {
        case .acknowledgedActive:
            alarmStates[alarm.tagName] = .acknowledgedActive

        case .normal:
            alarmStates[alarm.tagName] = .normal
            activeAlarms.remove(at: idx)

        default: break
        }

        recalcUnackCount()
        Logger.shared.info("Ack \(alarm.tagName) by \(username) → \(updated.state.rawValue)")
    }

    func acknowledgeAllAlarms(by username: String = "Operator") {
        for i in activeAlarms.indices {
            guard activeAlarms[i].state.requiresAction else { continue }
            activeAlarms[i].acknowledge(by: username)
            syncHistory(activeAlarms[i])
            persistAlarmUpdate(activeAlarms[i])
            alarmStates[activeAlarms[i].tagName] = activeAlarms[i].state
        }
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
        persistAlarmInsert(alarm)
        Logger.shared.warning("ALARM: \(message)")
    }

    private func transitionToRTN(tagName: String) {
        guard let idx = activeAlarms.firstIndex(where: {
            $0.tagName == tagName && $0.state.conditionActive
        }) else { return }

        activeAlarms[idx].returnToNormal()
        let updated = activeAlarms[idx]
        syncHistory(updated)
        persistAlarmUpdate(updated)

        switch updated.state {
        case .unacknowledgedRTN:
            alarmStates[tagName] = .unacknowledgedRTN

        case .normal:
            alarmStates[tagName] = .normal
            activeAlarms.remove(at: idx)
            recalcUnackCount()

        default: break
        }

        Logger.shared.info("RTN: \(tagName) → \(updated.state.rawValue)")
    }

    private func removeFromActive(tagName: String, state: AlarmState, toHistory: Bool) {
        guard let idx = activeAlarms.firstIndex(where: {
            $0.tagName == tagName && $0.state == state
        }) else { return }
        if toHistory { syncHistory(activeAlarms[idx]) }
        activeAlarms.remove(at: idx)
        recalcUnackCount()
    }

    private func syncHistory(_ alarm: Alarm) {
        if let hIdx = alarmHistory.firstIndex(where: { $0.id == alarm.id }) {
            alarmHistory[hIdx] = alarm
        }
    }

    private func recalcUnackCount() {
        unacknowledgedCount = activeAlarms.filter { $0.state.requiresAction }.count
    }

    // MARK: - DB persistence helpers (fire-and-forget)

    private func persistConfig(_ config: AlarmConfig) {
        guard let h = historian else { return }
        Task { try? await h.saveAlarmConfig(config) }
    }

    private func persistAlarmInsert(_ alarm: Alarm) {
        guard let h = historian else { return }
        Task { try? await h.insertAlarmEvent(alarm) }
    }

    private func persistAlarmUpdate(_ alarm: Alarm) {
        guard let h = historian else { return }
        Task { try? await h.updateAlarmEvent(alarm) }
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
