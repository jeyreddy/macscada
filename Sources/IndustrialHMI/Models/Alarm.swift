import Foundation

/// Represents an alarm condition in the industrial control system
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
    var value: Double?  // Value that triggered the alarm
    
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
}

// MARK: - Alarm Configuration

/// Configuration for threshold-based alarms on a tag
struct AlarmConfig: Codable, Identifiable {
    let id: UUID
    var tagName: String
    
    // Threshold values (nil = disabled)
    var highHigh: Double?    // Critical high alarm
    var high: Double?        // Warning high alarm
    var low: Double?         // Warning low alarm
    var lowLow: Double?      // Critical low alarm
    
    var priority: AlarmPriority
    var deadband: Double     // Hysteresis to prevent alarm flapping
    var enabled: Bool
    
    init(
        id: UUID = UUID(),
        tagName: String,
        highHigh: Double? = nil,
        high: Double? = nil,
        low: Double? = nil,
        lowLow: Double? = nil,
        priority: AlarmPriority = .medium,
        deadband: Double = 0.5,
        enabled: Bool = true
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
    }
    
    /// Check if value violates any threshold
    func checkViolation(value: Double) -> (violated: Bool, severity: AlarmSeverity?, message: String?) {
        guard enabled else { return (false, nil, nil) }
        
        // Check in order of severity
        if let hh = highHigh, value >= hh {
            return (true, .critical, "High-High alarm: \(value) >= \(hh)")
        }
        if let h = high, value >= h {
            return (true, .warning, "High alarm: \(value) >= \(h)")
        }
        if let ll = lowLow, value <= ll {
            return (true, .critical, "Low-Low alarm: \(value) <= \(ll)")
        }
        if let l = low, value <= l {
            return (true, .warning, "Low alarm: \(value) <= \(l)")
        }
        
        return (false, nil, nil)
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
    case suppressed           = "Suppressed"

    /// True when the operator still needs to press Ack.
    var requiresAction: Bool {
        self == .unacknowledgedActive || self == .unacknowledgedRTN
    }

    /// True when the alarm condition (process value) is currently out of range.
    var conditionActive: Bool {
        self == .unacknowledgedActive || self == .acknowledgedActive
    }

    /// True when this alarm should appear in the active alarm list.
    var isVisible: Bool {
        self != .normal && self != .suppressed
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
