import Foundation

/// Represents a single process variable (tag) in the industrial control system
struct Tag: Identifiable, Codable, Equatable {
    // MARK: - Properties
    
    /// Unique identifier for SwiftUI lists
    let id: UUID
    
    /// Human-readable tag name (e.g., "TANK_001.LEVEL_PV")
    var name: String
    
    /// OPC-UA node identifier (e.g., "ns=2;s=Tank1.Level")
    var nodeId: String
    
    /// Current tag value
    var value: TagValue
    
    /// Data quality indicator
    var quality: TagQuality
    
    /// Timestamp of last update
    var timestamp: Date
    
    /// Engineering units (e.g., "°C", "%", "PSI")
    var unit: String?
    
    /// Human-readable description
    var description: String?
    
    /// Tag data type for proper handling
    var dataType: TagDataType
    
    // MARK: - Initialization
    
    init(
        id: UUID = UUID(),
        name: String,
        nodeId: String,
        value: TagValue = .analog(0.0),
        quality: TagQuality = .uncertain,
        timestamp: Date = Date(),
        unit: String? = nil,
        description: String? = nil,
        dataType: TagDataType = .analog
    ) {
        self.id = id
        self.name = name
        self.nodeId = nodeId
        self.value = value
        self.quality = quality
        self.timestamp = timestamp
        self.unit = unit
        self.description = description
        self.dataType = dataType
    }
    
    // MARK: - Computed Properties
    
    /// Formatted value string for display
    var formattedValue: String {
        switch value {
        case .analog(let val):
            let formatted = String(format: "%.2f", val)
            if let unit = unit {
                return "\(formatted) \(unit)"
            }
            return formatted
        case .digital(let val):
            return val ? "ON" : "OFF"
        case .string(let val):
            return val
        case .none:
            return "---"
        }
    }
    
    /// Color indicator based on quality
    var qualityColor: String {
        switch quality {
        case .good:
            return "green"
        case .bad:
            return "red"
        case .uncertain:
            return "yellow"
        }
    }
}

// MARK: - Tag Value Types

/// Represents different types of tag values
enum TagValue: Codable, Equatable {
    case analog(Double)
    case digital(Bool)
    case string(String)
    case none
    
    /// Raw value for numerical operations
    var numericValue: Double? {
        switch self {
        case .analog(let val):
            return val
        case .digital(let val):
            return val ? 1.0 : 0.0
        case .string, .none:
            return nil
        }
    }
}

// MARK: - Tag Quality

/// OPC-UA quality status codes
enum TagQuality: Int, Codable, Equatable {
    case good = 0       // Data is valid and reliable
    case bad = 1        // Data is invalid or device offline
    case uncertain = 2  // Data quality is questionable
    
    var description: String {
        switch self {
        case .good:
            return "Good"
        case .bad:
            return "Bad"
        case .uncertain:
            return "Uncertain"
        }
    }
}

// MARK: - Tag Data Type

/// Tag data type classification
enum TagDataType: String, Codable, Equatable {
    case analog     // Continuous values (temperature, pressure, level)
    case digital    // Binary states (on/off, open/closed)
    case string     // Text data
    case calculated // Derived/computed values
}

// MARK: - Tag Configuration

/// Configuration for tag monitoring and alarming
struct TagConfiguration: Codable {
    var scanRate: TimeInterval = 1.0  // Update frequency in seconds
    var deadband: Double = 0.1         // Minimum change to report
    var enableLogging: Bool = true     // Store in historian
    var alarmConfig: AlarmConfig?      // Associated alarm settings
}

// MARK: - Sample Data (for development/testing)

extension Tag {
    /// Creates sample tags for development and testing
/*
    static var samples: [Tag] {
        [
            Tag(
                name: "TANK_001.LEVEL_PV",
                nodeId: "ns=2;s=Tank1.Level",
                value: .analog(75.5),
                quality: .good,
                unit: "%",
                description: "Tank 1 Level Process Value",
                dataType: .analog
            ),
            Tag(
                name: "TANK_001.PUMP_STATUS",
                nodeId: "ns=2;s=Tank1.PumpRunning",
                value: .digital(true),
                quality: .good,
                description: "Tank 1 Pump Running Status",
                dataType: .digital
            ),
            Tag(
                name: "REACTOR_01.TEMP_PV",
                nodeId: "ns=2;s=Reactor1.Temperature",
                value: .analog(245.8),
                quality: .good,
                unit: "°C",
                description: "Reactor 1 Temperature",
                dataType: .analog
            ),
            Tag(
                name: "COMPRESSOR_A.PRESSURE_PV",
                nodeId: "ns=2;s=CompressorA.DischargePressure",
                value: .analog(125.3),
                quality: .good,
                unit: "PSI",
                description: "Compressor A Discharge Pressure",
                dataType: .analog
            ),
            Tag(
                name: "VALVE_CV101.POSITION",
                nodeId: "ns=2;s=CV101.Position",
                value: .analog(45.0),
                quality: .good,
                unit: "%",
                description: "Control Valve CV-101 Position",
                dataType: .analog
            )
        ]
    }*/
}
