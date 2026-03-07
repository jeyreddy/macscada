// MARK: - AlarmManager.swift
//
// ISA-18.2 compliant alarm management service. Processes real-time tag values
// to detect, track, and transition alarm states for all configured alarm points.
//
// ── State Machine (per alarm instance) ────────────────────────────────────────
//
//   Normal  ──raiseAlarm()──►  UnacknowledgedActive
//                                   │            │
//              acknowledgeAlarm()◄──┘            │ transitionToRTN()
//                   │                            ▼
//           AcknowledgedActive     UnacknowledgedRTN
//                   │                            │
//   transitionToRTN()│              acknowledgeAlarm()
//                   ▼                            │
//                Normal  ◄─────────────────────-┘
//
//   Any state ──shelveAlarm()──► Shelved ──unshelveAlarm()──► Normal
//
//   Out-of-Service: per-config flag, suppresses detection (no alarm instance created)
//
// ── Deadband / Hysteresis ─────────────────────────────────────────────────────
//   AlarmConfig.checkRTNCleared(value:) only returns true when PV clears all
//   thresholds by the full deadband amount. This prevents chattering when PV
//   oscillates near the alarm setpoint. Until the PV clears the deadband,
//   AlarmManager holds the current active state without state change.
//
// ── loadFromDB strategy ───────────────────────────────────────────────────────
//   Only shelved alarms are restored from the database. Active/RTN alarms are
//   intentionally NOT restored — blindly re-populating activeAlarms from the DB
//   would create ghost alarms that can never self-resolve if the condition cleared
//   while the app was offline. checkAlarms() re-raises them naturally once live
//   tag values arrive from the polling loop.
//
// ── Auto-unshelve ─────────────────────────────────────────────────────────────
//   Each shelved alarm with a duration gets a Task in `shelveTimers` that calls
//   unshelveAlarm() after the specified interval. Timers are cancelled on manual
//   unshelve and persisted across app restarts via shelvedUntil Date on the alarm.
//
// ── Notifications ─────────────────────────────────────────────────────────────
//   triggerAlarmNotification() sends a UNUserNotification when an alarm fires.
//   The bundle identifier guard prevents crashes when running via `swift run`
//   (no .app bundle proxy = no notification centre).
//
// ── Integration ───────────────────────────────────────────────────────────────
//   TagEngine calls checkAlarms(for:) after every tag value update.
//   DataService injects `historian` into AlarmManager post-init.
//   AlarmListView observes @Published arrays and unacknowledgedCount.

import Foundation
import Combine
import UserNotifications

/// ISA-18.2 compliant alarm manager.
///
/// State machine per alarm instance:
///   Normal → UnackActive (raiseAlarm)
///   UnackActive → AckActive (acknowledgeAlarm)
///   UnackActive → UnackRTN  (transitionToRTN — PV cleared with deadband)
///   AckActive   → Normal    (transitionToRTN — already acked, fully resolved)
///   UnackRTN    → Normal    (acknowledgeAlarm — operator confirmed the event)
///   Any active  → Shelved   (shelveAlarm — temporarily suppressed with auto-unshelve)
///   Shelved     → Normal    (unshelveAlarm — PV re-evaluated after unshelve)
///
/// Out-of-Service is a per-config flag (AlarmConfig.outOfService); it skips alarm
/// detection entirely for that tag without creating an alarm instance.
@MainActor
class AlarmManager: ObservableObject {

    // MARK: - Published Properties

    @Published var activeAlarms: [Alarm] = []
    @Published var shelvedAlarms: [Alarm] = []
    @Published var alarmHistory: [Alarm] = []
    @Published var alarmConfigs: [AlarmConfig] = []
    @Published var unacknowledgedCount: Int = 0

    // MARK: - Historian (injected by DataService)

    var historian: Historian? = nil

    // MARK: - Private State

    /// Last known ISA-18.2 state per tag name for fast look-up in checkAlarms.
    private var alarmStates: [String: AlarmState] = [:]
    /// Tag names that currently have a shelved alarm — checked in checkAlarms hot path.
    private var shelvedTagNames: Set<String> = []
    /// Auto-unshelve tasks keyed by alarm UUID.
    private var shelveTimers: [UUID: Task<Void, Never>] = [:]

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
            Logger.shared.info("AlarmManager: loaded \(savedConfigs.count) alarm configs")

            let history = try await h.loadAlarmHistory()
            alarmHistory = history

            // Only restore shelved alarms — active/RTN alarms are intentionally NOT
            // restored. If we blindly re-populate activeAlarms from the DB, any alarm
            // whose condition cleared while the app was offline becomes a permanent
            // ghost that can never self-resolve. Let checkAlarms() re-raise them
            // naturally once tag polling delivers fresh values.
            let nonNormal = try await h.loadActiveAlarms()
            activeAlarms  = []      // start clean; stale active alarms are discarded
            shelvedAlarms = nonNormal.filter { $0.state == .shelved }

            // alarmStates must NOT contain stale active entries — only shelved ones.
            for alarm in shelvedAlarms {
                alarmStates[alarm.tagName] = .shelved
                shelvedTagNames.insert(alarm.tagName)
                // Restore auto-unshelve timer if duration hasn't expired.
                if let until = alarm.shelvedUntil {
                    scheduleUnshelve(alarmId: alarm.id, tagName: alarm.tagName, until: until)
                }
            }
            recalcUnackCount()
            Logger.shared.info("AlarmManager: restored \(shelvedAlarms.count) shelved alarms; " +
                               "active alarms will re-trigger from live tag values")
        } catch {
            Logger.shared.error("AlarmManager: failed to load from DB — \(error)")
        }
    }

    // MARK: - Alarm Configuration

    func addAlarmConfig(_ config: AlarmConfig) {
        alarmConfigs.append(config)
        persistConfig(config)
        Logger.shared.info("Added alarm config for: \(config.tagName)")
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

    // MARK: - Out-of-Service (ISA-18.2)

    /// Take an alarm config out of service (maintenance mode).
    /// New alarm conditions are suppressed while OOS; existing active alarms remain.
    func putOutOfService(_ configId: UUID, by username: String, reason: String? = nil) {
        guard let idx = alarmConfigs.firstIndex(where: { $0.id == configId }) else { return }
        alarmConfigs[idx].outOfService = true
        alarmConfigs[idx].outOfServiceBy = username
        alarmConfigs[idx].outOfServiceReason = reason
        persistConfig(alarmConfigs[idx])
        Logger.shared.info("OOS: \(alarmConfigs[idx].tagName) by \(username)")
    }

    /// Return an alarm config to service.
    func returnToService(_ configId: UUID, by username: String) {
        guard let idx = alarmConfigs.firstIndex(where: { $0.id == configId }) else { return }
        alarmConfigs[idx].outOfService = false
        alarmConfigs[idx].outOfServiceBy = nil
        alarmConfigs[idx].outOfServiceReason = nil
        persistConfig(alarmConfigs[idx])
        Logger.shared.info("RTS: \(alarmConfigs[idx].tagName) by \(username)")
    }

    // MARK: - Alarm Detection  (ISA-18.2 state machine)

    func checkAlarms(for tag: Tag) {
        guard let config = alarmConfigs.first(where: { $0.tagName == tag.name }),
              config.enabled,
              !config.outOfService,               // ISA-18.2: skip Out-of-Service tags
              !shelvedTagNames.contains(tag.name), // ISA-18.2: skip Shelved alarms
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
                // Re-activated before operator acknowledged the previous event.
                removeFromActive(tagName: tag.name, state: .unacknowledgedRTN, toHistory: true)
                raiseAlarm(tagName: tag.name, message: message, severity: severity, value: value)

            default:
                break   // already active — no state change needed
            }

        } else {
            // ── Condition has CLEARED — apply deadband before RTN ──────────
            guard let currentState, currentState.conditionActive else { return }
            // ISA-18.2: only RTN when value has cleared threshold with full deadband hysteresis
            if config.checkRTNCleared(value: value) {
                transitionToRTN(tagName: tag.name)
            }
            // else: PV is in the deadband zone — hold current state to prevent chattering
        }
    }

    // MARK: - Alarm Actions

    func acknowledgeAlarm(_ alarm: Alarm, by username: String = "Operator") {
        guard let idx = activeAlarms.firstIndex(where: { $0.id == alarm.id }),
              activeAlarms[idx].state.requiresAction else { return }

        let prevState = activeAlarms[idx].state
        activeAlarms[idx].acknowledge(by: username)
        let updated = activeAlarms[idx]
        syncHistory(updated)
        persistAlarmUpdate(updated)
        logTransition(updated, from: prevState, to: updated.state, by: username)

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
            let prev = activeAlarms[i].state
            activeAlarms[i].acknowledge(by: username)
            syncHistory(activeAlarms[i])
            persistAlarmUpdate(activeAlarms[i])
            logTransition(activeAlarms[i], from: prev, to: activeAlarms[i].state, by: username)
            alarmStates[activeAlarms[i].tagName] = activeAlarms[i].state
        }
        activeAlarms.removeAll { $0.state == .normal }
        recalcUnackCount()
        Logger.shared.info("All alarms acknowledged by \(username)")
    }

    // MARK: - Shelving (ISA-18.2)

    /// Shelve an active alarm, temporarily suppressing it.
    /// - Parameters:
    ///   - alarm:    The alarm to shelve (must be in `activeAlarms`).
    ///   - username: Operator who performed the shelve.
    ///   - duration: How long to shelve; nil = indefinite. Default = 8 hours.
    ///   - reason:   Optional justification recorded in the alarm journal.
    func shelveAlarm(
        _ alarm: Alarm,
        by username: String,
        duration: TimeInterval? = 8 * 3600,
        reason: String? = nil
    ) {
        guard let idx = activeAlarms.firstIndex(where: { $0.id == alarm.id }) else { return }
        let prevState = activeAlarms[idx].state
        let until: Date? = duration.map { Date().addingTimeInterval($0) }

        var shelved = activeAlarms[idx]
        shelved.shelve(by: username, until: until, reason: reason)
        activeAlarms.remove(at: idx)
        shelvedAlarms.append(shelved)
        shelvedTagNames.insert(shelved.tagName)
        alarmStates[shelved.tagName] = .shelved

        syncHistory(shelved)
        persistAlarmUpdate(shelved)
        logTransition(shelved, from: prevState, to: .shelved, by: username, reason: reason)

        if let until {
            scheduleUnshelve(alarmId: shelved.id, tagName: shelved.tagName, until: until)
        }

        recalcUnackCount()
        let durStr = duration.map { " for \(Int($0 / 3600))h" } ?? " indefinitely"
        Logger.shared.info("Shelved \(alarm.tagName) by \(username)\(durStr)")
    }

    /// Manually unshelve an alarm by its UUID.
    func unshelveAlarm(id alarmId: UUID, by username: String) {
        guard let idx = shelvedAlarms.firstIndex(where: { $0.id == alarmId }) else { return }
        var alarm = shelvedAlarms[idx]
        alarm.unshelve()
        shelvedAlarms.remove(at: idx)
        shelvedTagNames.remove(alarm.tagName)
        shelveTimers[alarmId]?.cancel()
        shelveTimers.removeValue(forKey: alarmId)
        alarmStates[alarm.tagName] = .normal

        // Alarm is cleared — move to history as normal
        syncHistory(alarm)
        persistAlarmUpdate(alarm)
        logTransition(alarm, from: .shelved, to: .normal, by: username, reason: "Unshelved")
        recalcUnackCount()
        Logger.shared.info("Unshelved \(alarm.tagName) by \(username)")
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
            shelved:         shelvedAlarms.count,
            critical:        activeAlarms.filter { $0.severity == .critical }.count,
            warning:         activeAlarms.filter { $0.severity == .warning  }.count,
            info:            activeAlarms.filter { $0.severity == .info     }.count,
            totalHistory:    alarmHistory.count
        )
    }

    // MARK: - Private state machine helpers

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
        logTransition(alarm, from: .normal, to: .unacknowledgedActive, by: "System")
        Logger.shared.warning("ALARM: \(message)")
    }

    private func transitionToRTN(tagName: String) {
        guard let idx = activeAlarms.firstIndex(where: {
            $0.tagName == tagName && $0.state.conditionActive
        }) else { return }

        let prevState = activeAlarms[idx].state
        activeAlarms[idx].returnToNormal()
        let updated = activeAlarms[idx]
        syncHistory(updated)
        persistAlarmUpdate(updated)
        logTransition(updated, from: prevState, to: updated.state, by: "System")

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
        } else {
            alarmHistory.append(alarm)
        }
    }

    private func recalcUnackCount() {
        unacknowledgedCount = activeAlarms.filter { $0.state.requiresAction }.count
    }

    // MARK: - Auto-unshelve timer

    private func scheduleUnshelve(alarmId: UUID, tagName: String, until: Date) {
        shelveTimers[alarmId]?.cancel()
        shelveTimers[alarmId] = Task { @MainActor [weak self] in
            let delay = max(0, until.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.unshelveAlarm(id: alarmId, by: "System (auto-unshelve)")
        }
    }

    // MARK: - Alarm Journal

    private func logTransition(
        _ alarm: Alarm,
        from prevState: AlarmState,
        to newState: AlarmState,
        by username: String,
        reason: String? = nil
    ) {
        guard let h = historian else { return }
        let entry = AlarmJournalEntry(
            alarmId:   alarm.id,
            tagName:   alarm.tagName,
            prevState: prevState,
            newState:  newState,
            changedBy: username,
            reason:    reason
        )
        Task { try? await h.logAlarmJournalEntry(entry) }
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
        // UNUserNotificationCenter requires a proper .app bundle proxy.
        // When launched via `swift run` there is no bundle proxy and the call crashes.
        guard Bundle.main.bundleIdentifier != nil else { return }

        let content = UNMutableNotificationContent()
        content.title = "Process Alarm: \(alarm.severity.rawValue)"
        content.body  = alarm.message
        if alarm.severity.soundEnabled {
            content.sound = .default
        }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - Alarm Statistics

struct AlarmStatistics {
    let totalActive: Int
    let unacknowledged: Int
    let shelved: Int
    let critical: Int
    let warning: Int
    let info: Int
    let totalHistory: Int
}
