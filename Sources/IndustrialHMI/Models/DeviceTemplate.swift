import Foundation
import SwiftUI

/// Protocol defining a reusable device template for industrial equipment
protocol DeviceTemplate: Identifiable {
    /// Device type identifier (e.g., "TankLevel", "Pump", "Valve")
    var deviceType: String { get }
    
    /// Tag definitions required by this device
    var tagDefinitions: [TagDefinition] { get }
    
    /// Alarm configurations for this device
    var alarmConfigs: [AlarmConfig] { get }
    
    /// Control logic executed each scan cycle
    func executeControlLogic(tags: [String: Tag]) -> [String: TagValue]
    
    /// SwiftUI view for device faceplate graphics
    @ViewBuilder var faceplate: AnyView { get }
}

// MARK: - Tag Definition

/// Defines a tag that belongs to a device template
struct TagDefinition: Identifiable, Codable {
    let id: UUID
    var localName: String      // Tag name within device (e.g., "LEVEL_PV")
    var nodeId: String?        // OPC-UA node ID (assigned during instantiation)
    var dataType: TagDataType
    var unit: String?
    var description: String?
    var isInput: Bool          // True for process values, false for outputs
    
    init(
        id: UUID = UUID(),
        localName: String,
        nodeId: String? = nil,
        dataType: TagDataType,
        unit: String? = nil,
        description: String? = nil,
        isInput: Bool = true
    ) {
        self.id = id
        self.localName = localName
        self.nodeId = nodeId
        self.dataType = dataType
        self.unit = unit
        self.description = description
        self.isInput = isInput
    }
}

// MARK: - Device Instance

/// An instance of a device template with specific tag bindings
struct DeviceInstance: Identifiable, Codable {
    let id: UUID
    var name: String                    // Unique device name (e.g., "TANK_001")
    var templateType: String            // Which template to use
    var tagBindings: [String: String]   // Local name -> OPC-UA nodeId
    var enabled: Bool
    var position: CGPoint?              // Position on graphics display
    
    init(
        id: UUID = UUID(),
        name: String,
        templateType: String,
        tagBindings: [String: String] = [:],
        enabled: Bool = true,
        position: CGPoint? = nil
    ) {
        self.id = id
        self.name = name
        self.templateType = templateType
        self.tagBindings = tagBindings
        self.enabled = enabled
        self.position = position
    }
}

// MARK: - Example Device Template: Tank Level

/// Example tank level monitoring and control device
struct TankLevelTemplate: DeviceTemplate {
    let id = UUID()
    let deviceType = "TankLevel"
    
    var tagDefinitions: [TagDefinition] {
        [
            TagDefinition(
                localName: "LEVEL_PV",
                dataType: .analog,
                unit: "%",
                description: "Tank level process value",
                isInput: true
            ),
            TagDefinition(
                localName: "PUMP_CMD",
                dataType: .digital,
                description: "Pump start/stop command",
                isInput: false
            ),
            TagDefinition(
                localName: "PUMP_STATUS",
                dataType: .digital,
                description: "Pump running feedback",
                isInput: true
            ),
            TagDefinition(
                localName: "HIGH_SETPOINT",
                dataType: .analog,
                unit: "%",
                description: "High level setpoint",
                isInput: false
            ),
            TagDefinition(
                localName: "LOW_SETPOINT",
                dataType: .analog,
                unit: "%",
                description: "Low level setpoint",
                isInput: false
            )
        ]
    }
    
    var alarmConfigs: [AlarmConfig] {
        [
            AlarmConfig(
                tagName: "LEVEL_PV",
                highHigh: 95.0,
                high: 90.0,
                low: 10.0,
                lowLow: 5.0,
                priority: .high,
                deadband: 1.0
            )
        ]
    }
    
    /// Simple on/off pump control logic
    func executeControlLogic(tags: [String: Tag]) -> [String: TagValue] {
        var outputs: [String: TagValue] = [:]
        
        // Get current values
        guard let levelTag = tags["LEVEL_PV"],
              let highSetpointTag = tags["HIGH_SETPOINT"],
              let lowSetpointTag = tags["LOW_SETPOINT"],
              let level = levelTag.value.numericValue,
              let highSetpoint = highSetpointTag.value.numericValue,
              let lowSetpoint = lowSetpointTag.value.numericValue else {
            return outputs
        }
        
        // Simple on/off control with hysteresis
        let currentPumpState = tags["PUMP_CMD"]?.value
        
        if level >= highSetpoint {
            // Level too high - stop pump
            outputs["PUMP_CMD"] = .digital(false)
        } else if level <= lowSetpoint {
            // Level too low - start pump
            outputs["PUMP_CMD"] = .digital(true)
        } else {
            // In deadband - maintain current state
            if case .digital(let running) = currentPumpState {
                outputs["PUMP_CMD"] = .digital(running)
            } else {
                outputs["PUMP_CMD"] = .digital(false)
            }
        }
        
        return outputs
    }
    
    /// SwiftUI faceplate for tank level display
    var faceplate: AnyView {
        AnyView(
            VStack(spacing: 10) {
                Text("Tank Level")
                    .font(.headline)
                
                // Tank graphic (simplified)
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray, lineWidth: 2)
                        .frame(width: 100, height: 150)
                    
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.blue)
                        .frame(width: 100, height: 100) // TODO: Make dynamic based on level
                }
                
                Text("75.5%")  // TODO: Make dynamic
                    .font(.title2)
                    .bold()
                
                HStack {
                    Circle()
                        .fill(Color.green)  // TODO: Make dynamic based on pump status
                        .frame(width: 20, height: 20)
                    Text("Pump Running")
                        .font(.caption)
                }
            }
            .padding()
        )
    }
}

// MARK: - Device Template Registry

/// Central registry of available device templates
class DeviceTemplateRegistry {
    static let shared = DeviceTemplateRegistry()
    
    private var templates: [String: any DeviceTemplate] = [:]
    
    private init() {
        // Register built-in templates
        register(TankLevelTemplate())
    }
    
    func register(_ template: any DeviceTemplate) {
        templates[template.deviceType] = template
    }
    
    func getTemplate(type: String) -> (any DeviceTemplate)? {
        return templates[type]
    }
    
    func getAllTemplateTypes() -> [String] {
        return Array(templates.keys).sorted()
    }
}
