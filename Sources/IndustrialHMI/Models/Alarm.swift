import Foundation

// MARK: - Alarm.swift
//
// Data models for the ISA-18.2 alarm management system.
//
// ── ISA-18.2 state machine ────────────────────────────────────────────────────
//
//   Process value crosses threshold
//           ↓
//   AlarmState.unacknowledgedActive    ← operator must press Ack
//        │                   │
//   acknowledge()       returnToNormal()
//        ↓                   ↓
//   .acknowledgedActive  .unacknowledgedRTN   ← still needs Ack even though RTN
//        │                   │
//   returnToNormal()    acknowledge()
//        ↓                   ↓
//        └────────────► .normal              ← leaves active list
//
//   Additional states:
//     .shelved      — operator temporarily suppressed (optional auto-unshelve time)
//     .outOfService — maintenance mode (AlarmConfig.outOfService = true)
//     .suppressed   — disabled by config (AlarmConfig.enabled = false)
//
// ── AlarmConfig vs Alarm ──────────────────────────────────────────────────────
//   AlarmConfig — static setpoint definition (stored in ConfigDatabase):
//     • tagName, highHigh/high/low/lowLow thresholds, deadband, priority
//     • checkViolation(value:) → determines if an active alarm should fire
//     • checkRTNCleared(value:) → determines when an alarm can return to normal
//
//   Alarm — a live alarm instance (held in AlarmManager.activeAlarms):
//     • Created by AlarmManager when checkViolation returns true
//     • Carries the trigger value, timestamps, and current state
//     • Mutated via acknowledge() / returnToNormal() / shelve() / unshelve()
//
// ── Deadband (hysteresis) ────────────────────────────────────────────────────
//   AlarmConfig.deadband prevents "alarm chattering" — repeated trigger/clear
//   when a process value oscillates near the threshold boundary.
//   For a high alarm at 90 % with deadband 1 %:
//     • Alarm fires when PV ≥ 90 %
//     • RTN fires when PV < 89 % (90 - 1)
//   checkRTNCleared(value:) applies this hysteresis for each threshold.
//
// ── Audit trail ───────────────────────────────────────────────────────────────
//   AlarmJournalEntry records every state transition (ack, RTN, shelve, unshelve)
//   with the operator username, timestamp, and optional reason.
//   These are written to the SQLite `alarm_journal` table for regulatory compliance.

/// Represents an active alarm condition in the industrial control system.
/// Follows the ISA-18.2 alarm management lifecycle (active → acked → RTN → normal).
struct Alarm: Identifiable, Codable {
    // MARK: - Properties

    let id: UUID
    var tagName: String
    var message: String
    var severity: AlarmSeverity
    var state: AlarmState
    var triggerTime: Date
    var acknowledgedTime: Date?
    var acknowledgedBy: String?
    var returnToNormalTime: Date?
    var value: Double?              // Process value at trigger time

    // ISA-18.2 Shelving fields
    var shelvedBy: String?
    var shelvedAt: Date?
    var shelvedUntil: Date?         // nil = shelved indefinitely
    var shelveReason: String?

    // MARK: - Initialization

    init(
        id: UUID = UUID(),
        tagName: String,
        message: String,
        severity: AlarmSeverity,
        state: AlarmState = .unacknowledgedActive,
        triggerTime: Date = Date(),
        value: Double? = nil
    ) {
        self.id = id
        self.tagName = tagName
        self.message = message
        self.severity = severity
        self.state = state
        self.triggerTime = triggerTime
        self.value = value
    }

    // MARK: - ISA-18.2 State Transitions

    /// Operator acknowledges the alarm.
    /// - UnackActive  → AckActive  (condition still on — stays visible)
    /// - UnackRTN     → Normal     (fully resolved — leaves active list)
    mutating func acknowledge(by username: String = "Operator") {
        acknowledgedTime = Date()
        acknowledgedBy   = username
        switch state {
        case .unacknowledgedActive:  state = .acknowledgedActive
        case .unacknowledgedRTN:     state = .normal
        default: break
        }
    }

    /// Process value has returned to normal range.
    /// - UnackActive  → UnackRTN   (still needs ack — stays visible)
    /// - AckActive    → Normal     (already acked — fully resolved, leaves active list)
    mutating func returnToNormal() {
        returnToNormalTime = Date()
        switch state {
        case .unacknowledgedActive:  state = .unacknowledgedRTN
        case .acknowledgedActive:    state = .normal
        default: break
        }
    }

    /// Operator shelves the alarm — temporarily suppressed until `until` (or indefinitely).
    mutating func shelve(by username: String, until: Date? = nil, reason: String? = nil) {
        shelvedBy    = username
        shelvedAt    = Date()
        shelvedUntil = until
        shelveReason = reason
        state        = .shelved
    }

    /// Clear shelve metadata when the alarm is returned to service.
    mutating func unshelve() {
        shelvedBy    = nil
        shelvedAt    = nil
        shelvedUntil = nil
        shelveReason = nil
        // AlarmManager sets the new state based on current process value.
    }
}

// MARK: - Alarm Configuration

/// Configuration for threshold-based alarms on a tag
struct AlarmConfig: Codable, Identifiable {
    let id: UUID
    var tagName: String

    // Threshold values (nil = disabled)
    var highHigh: Double?    // Critical high alarm (ISA: HIHI)
    var high: Double?        // Warning high alarm  (ISA: HI)
    var low: Double?         // Warning low alarm   (ISA: LO)
    var lowLow: Double?      // Critical low alarm  (ISA: LOLO)

    var priority: AlarmPriority
    /// Hysteresis band applied to RTN transition to prevent alarm chattering.
    var deadband: Double
    var enabled: Bool

    // ISA-18.2: Out-of-Service (maintenance mode)
    var outOfService: Bool = false
    var outOfServiceBy: String?
    var outOfServiceReason: String?

    init(
        id: UUID = UUID(),
        tagName: String,
        highHigh: Double? = nil,
        high: Double? = nil,
        low: Double? = nil,
        lowLow: Double? = nil,
        priority: AlarmPriority = .medium,
        deadband: Double = 0.5,
        enabled: Bool = true,
        outOfService: Bool = false,
        outOfServiceBy: String? = nil,
        outOfServiceReason: String? = nil
    ) {
        self.id = id
        self.tagName = tagName
        self.highHigh = highHigh
        self.high = high
        self.low = low
        self.lowLow = lowLow
        self.priority = priority
        self.deadband = deadband
        self.enabled = enabled
        self.outOfService = outOfService
        self.outOfServiceBy = outOfServiceBy
        self.outOfServiceReason = outOfServiceReason
    }

    /// Check if value violates any threshold. Returns the highest-priority active condition.
    func checkViolation(value: Double) -> (violated: Bool, severity: AlarmSeverity?, message: String?) {
        guard enabled, !outOfService else { return (false, nil, nil) }

        if let hh = highHigh, value >= hh {
            return (true, .critical, "High-High: \(String(format: "%.2f", value)) ≥ \(String(format: "%.2f", hh))")
        }
        if let h = high, value >= h {
            return (true, .warning,  "High: \(String(format: "%.2f", value)) ≥ \(String(format: "%.2f", h))")
        }
        if let ll = lowLow, value <= ll {
            return (true, .critical, "Low-Low: \(String(format: "%.2f", value)) ≤ \(String(format: "%.2f", ll))")
        }
        if let l = low, value <= l {
            return (true, .warning,  "Low: \(String(format: "%.2f", value)) ≤ \(String(format: "%.2f", l))")
        }

        return (false, nil, nil)
    }

    /// True when the process value has cleared **all** thresholds with the deadband
    /// hysteresis applied — prevents chattering when PV oscillates near a setpoint.
    ///
    /// For high thresholds: clears when value drops below `threshold - deadband`.
    /// For low  thresholds: clears when value rises above `threshold + deadband`.
    func checkRTNCleared(value: Double) -> Bool {
        if let hh = highHigh, value >= hh - deadband { return false }
        if let h  = high,     value >= h  - deadband { return false }
        if let ll = lowLow,   value <= ll + deadband { return false }
        if let l  = low,      value <= l  + deadband { return false }
        return true
    }
}

// MARK: - Alarm Severity

enum AlarmSeverity: String, Codable, CaseIterable {
    case critical = "Critical"
    case warning = "Warning"
    case info = "Info"
    
    var color: String {
        switch self {
        case .critical:
            return "red"
        case .warning:
            return "orange"
        case .info:
            return "blue"
        }
    }
    
    var soundEnabled: Bool {
        switch self {
        case .critical, .warning:
            return true
        case .info:
            return false
        }
    }
}

// MARK: - Alarm State  (ISA-18.2)

enum AlarmState: String, Codable {
    /// Condition present, operator has not yet acknowledged.
    case unacknowledgedActive = "Unack Active"
    /// Condition present, operator has acknowledged (alarm still on).
    case acknowledgedActive   = "Ack Active"
    /// Condition cleared, operator has not yet acknowledged the event.
    case unacknowledgedRTN    = "Unack RTN"
    /// Fully resolved — in history only, not shown in active list.
    case normal               = "Normal"
    /// Suppressed by design at config level (AlarmConfig.enabled = false).
    case suppressed           = "Suppressed"
    /// ISA-18.2: Temporarily shelved by operator with optional auto-unshelve timeout.
    case shelved              = "Shelved"
    /// ISA-18.2: Alarm point taken out of service for maintenance.
    case outOfService         = "Out of Service"

    /// True when the operator still needs to press Ack.
    var requiresAction: Bool {
        self == .unacknowledgedActive || self == .unacknowledgedRTN
    }

    /// True when the alarm condition (process value) is currently out of range.
    var conditionActive: Bool {
        self == .unacknowledgedActive || self == .acknowledgedActive
    }

    /// True when this alarm should appear in the active alarm list (not shelved, not resolved).
    var isVisible: Bool {
        self != .normal && self != .suppressed && self != .shelved && self != .outOfService
    }
}

// MARK: - Alarm Journal Entry  (ISA-18.2 audit trail)

/// Immutable record of a single ISA-18.2 alarm state transition.
/// Written to `alarm_journal` on every acknowledge / RTN / shelve / unshelve event.
struct AlarmJournalEntry: Identifiable, Codable {
    let id:        UUID
    let alarmId:   UUID
    let tagName:   String
    let prevState: AlarmState
    let newState:  AlarmState
    let changedBy: String
    let reason:    String?
    let timestamp: Date

    init(
        alarmId:   UUID,
        tagName:   String,
        prevState: AlarmState,
        newState:  AlarmState,
        changedBy: String,
        reason:    String? = nil
    ) {
        self.id        = UUID()
        self.alarmId   = alarmId
        self.tagName   = tagName
        self.prevState = prevState
        self.newState  = newState
        self.changedBy = changedBy
        self.reason    = reason
        self.timestamp = Date()
    }

    /// Init used when loading records from the database with an explicit stored timestamp.
    init(id: UUID, alarmId: UUID, tagName: String, prevState: AlarmState, newState: AlarmState,
         changedBy: String, reason: String?, timestamp: Date) {
        self.id        = id
        self.alarmId   = alarmId
        self.tagName   = tagName
        self.prevState = prevState
        self.newState  = newState
        self.changedBy = changedBy
        self.reason    = reason
        self.timestamp = timestamp
    }
}

// MARK: - Alarm Priority

enum AlarmPriority: Int, Codable, CaseIterable {
    case low = 1
    case medium = 2
    case high = 3
    case critical = 4
    
    var description: String {
        switch self {
        case .low:
            return "Low"
        case .medium:
            return "Medium"
        case .high:
            return "High"
        case .critical:
            return "Critical"
        }
    }
}

// MARK: - Sample Data

extension Alarm {
    static var samples: [Alarm] {
        [
            Alarm(tagName: "TANK_001.LEVEL_PV",
                  message: "Tank 1 level high (95.5%)",
                  severity: .warning, state: .unacknowledgedActive, value: 95.5),
            Alarm(tagName: "REACTOR_01.TEMP_PV",
                  message: "Reactor 1 temperature critical high (285.0°C)",
                  severity: .critical, state: .acknowledgedActive, value: 285.0),
            Alarm(tagName: "COMPRESSOR_A.PRESSURE_PV",
                  message: "Compressor A discharge pressure low (85.0 PSI)",
                  severity: .warning, state: .unacknowledgedRTN, value: 85.0)
        ]
    }
}

extension AlarmConfig {
    static var samples: [AlarmConfig] {
        [
            AlarmConfig(
                tagName: "TANK_001.LEVEL_PV",
                highHigh: 95.0,
                high: 90.0,
                low: 10.0,
                lowLow: 5.0,
                priority: .high,
                deadband: 1.0
            ),
            AlarmConfig(
                tagName: "REACTOR_01.TEMP_PV",
                highHigh: 280.0,
                high: 260.0,
                priority: .critical,
                deadband: 2.0
            ),
            AlarmConfig(
                tagName: "COMPRESSOR_A.PRESSURE_PV",
                highHigh: 150.0,
                high: 140.0,
                low: 90.0,
                lowLow: 80.0,
                priority: .high,
                deadband: 2.0
            )
        ]
    }
}
