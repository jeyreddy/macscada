// MARK: - HMI3DModels.swift
//
// Data models for the 3D HMI plant-floor view.
// All models are Codable and persisted via HMI3DSceneStore to
// ~/Library/Application Support/IndustrialHMI/hmi3d_scene.json.
//
// ── Model Hierarchy ───────────────────────────────────────────────────────────
//   HMI3DScene                    — top-level scene document
//     environmentStyle: Scene3DEnvironment   — lighting preset
//     cameraPreset: Camera3DPreset           — initial camera position
//     equipment: [HMI3DEquipment]            — all placed equipment
//
// ── HMI3DEquipment ────────────────────────────────────────────────────────────
//   id: UUID                         — unique identifier (also SCNNode.name)
//   type: Equipment3DType            — what to build (pump, tank, valve, etc.)
//   label: String                    — shown as a floating SCNText label in scene
//   posX/posY/posZ: Float            — world-space position (metres, Y=up)
//   rotationY: Float                 — Y-axis rotation in degrees
//   scaleX/scaleY/scaleZ: Float      — non-uniform scale
//   tagBinding: String?              — tag name for live animation
//   minTagValue/maxTagValue: Double  — range for normalising tag value to 0–1 fraction
//   color: CodableColor              — equipment material colour
//   diameter: Float                  — used by pipe geometry
//
// ── Camera Presets ────────────────────────────────────────────────────────────
//   isometric   — SCNVector3(20, 20, 20) looking at origin
//   topDown     — SCNVector3(0, 35, 0.001) — tiny Z prevents degenerate lookAt
//   frontView   — SCNVector3(0, 5, 30)
//   perspective — SCNVector3(15, 12, 25)
//
// ── Lighting Environments ─────────────────────────────────────────────────────
//   darkIndustrial  — ambient 150, warm key, dark background
//   brightWarehouse — ambient 500, neutral key, light background
//   outdoorRefinery — ambient 300, sunlight key, sky-tone background
//   HMI3DSceneView applies these to the SCNScene lighting on setup and update.
//
// ── HMIDisplayMode ────────────────────────────────────────────────────────────
//   .twoD, .threeD, .both — stored in @AppStorage("hmi.displayMode").
//   HMIDesignerView switches content based on this value.
//   HMI3DDesignerView respects showDisplayModePicker flag for embedded use.

import Foundation
import SceneKit

// MARK: - HMIDisplayMode

/// Controls whether the HMI tab shows 2D canvas, 3D scene, or both side-by-side.
enum HMIDisplayMode: String, Codable, CaseIterable {
    case twoD   = "2D"
    case threeD = "3D"
    case both   = "Both"

    var displayName: String { rawValue }
}

// MARK: - Camera3DPreset

enum Camera3DPreset: String, Codable, CaseIterable {
    case isometric  = "Isometric"
    case topDown    = "Top Down"
    case frontView  = "Front View"
    case perspective = "Perspective"

    var position: SCNVector3 {
        switch self {
        case .isometric:   return SCNVector3(20, 20, 20)
        case .topDown:     return SCNVector3(0, 35, 0.001)
        case .frontView:   return SCNVector3(0, 5, 30)
        case .perspective: return SCNVector3(15, 12, 25)
        }
    }

    var lookAt: SCNVector3 { SCNVector3(0, 0, 0) }
}

// MARK: - Scene3DEnvironment

enum Scene3DEnvironment: String, Codable, CaseIterable {
    case darkIndustrial  = "Dark Industrial"
    case brightWarehouse = "Bright Warehouse"
    case outdoorRefinery = "Outdoor Refinery"

    var ambientIntensity: CGFloat {
        switch self {
        case .darkIndustrial:  return 150
        case .brightWarehouse: return 500
        case .outdoorRefinery: return 300
        }
    }

    var ambientColor: NSColor {
        switch self {
        case .darkIndustrial:  return NSColor(white: 0.15, alpha: 1)
        case .brightWarehouse: return NSColor(white: 0.8,  alpha: 1)
        case .outdoorRefinery: return NSColor(red: 0.85, green: 0.8, blue: 0.6, alpha: 1)
        }
    }

    var keyLightIntensity: CGFloat {
        switch self {
        case .darkIndustrial:  return 1200
        case .brightWarehouse: return 800
        case .outdoorRefinery: return 1500
        }
    }

    var backgroundColor: NSColor {
        switch self {
        case .darkIndustrial:  return NSColor(red: 0.06, green: 0.07, blue: 0.10, alpha: 1)
        case .brightWarehouse: return NSColor(red: 0.75, green: 0.80, blue: 0.88, alpha: 1)
        case .outdoorRefinery: return NSColor(red: 0.55, green: 0.70, blue: 0.90, alpha: 1)
        }
    }
}

// MARK: - Equipment3DType

enum Equipment3DType: String, Codable, CaseIterable {
    // Rotating
    case centrifugalPump  = "centrifugalPump"
    case compressor       = "compressor"
    case motorDrive       = "motorDrive"
    // Vessels
    case verticalTank     = "verticalTank"
    case horizontalTank   = "horizontalTank"
    case processVessel    = "processVessel"
    case separator        = "separator"
    case heatExchanger    = "heatExchanger"
    // Piping
    case gateValve        = "gateValve"
    case controlValve     = "controlValve"
    case pipeSection      = "pipeSection"
    case pipeElbow        = "pipeElbow"
    case pipeTee          = "pipeTee"
    // Structures
    case structuralColumn = "structuralColumn"
    case platform         = "platform"

    var category: String {
        switch self {
        case .centrifugalPump, .compressor, .motorDrive:
            return "Rotating"
        case .verticalTank, .horizontalTank, .processVessel, .separator, .heatExchanger:
            return "Vessels"
        case .gateValve, .controlValve, .pipeSection, .pipeElbow, .pipeTee:
            return "Piping"
        case .structuralColumn, .platform:
            return "Structures"
        }
    }

    var displayName: String {
        switch self {
        case .centrifugalPump:  return "Centrifugal Pump"
        case .compressor:       return "Compressor"
        case .motorDrive:       return "Motor Drive"
        case .verticalTank:     return "Vertical Tank"
        case .horizontalTank:   return "Horizontal Tank"
        case .processVessel:    return "Process Vessel"
        case .separator:        return "Separator"
        case .heatExchanger:    return "Heat Exchanger"
        case .gateValve:        return "Gate Valve"
        case .controlValve:     return "Control Valve"
        case .pipeSection:      return "Pipe Section"
        case .pipeElbow:        return "Pipe Elbow"
        case .pipeTee:          return "Pipe Tee"
        case .structuralColumn: return "Structural Column"
        case .platform:         return "Platform"
        }
    }

    var icon: String {
        switch self {
        case .centrifugalPump:  return "arrow.clockwise.circle"
        case .compressor:       return "wind"
        case .motorDrive:       return "bolt.circle"
        case .verticalTank:     return "cylinder"
        case .horizontalTank:   return "cylinder.split.1x2"
        case .processVessel:    return "flask"
        case .separator:        return "rectangle.split.2x1"
        case .heatExchanger:    return "thermometer.medium"
        case .gateValve:        return "wrench.and.screwdriver"
        case .controlValve:     return "slider.horizontal.3"
        case .pipeSection:      return "minus"
        case .pipeElbow:        return "arrow.turn.up.right"
        case .pipeTee:          return "arrow.up.and.line.horizontal.and.arrow.down"
        case .structuralColumn: return "square.stack"
        case .platform:         return "rectangle.fill"
        }
    }

    /// Default scale for the equipment node (Y is height)
    var defaultScale: (x: Float, y: Float, z: Float) {
        switch self {
        case .centrifugalPump:  return (1.2, 1.0, 1.2)
        case .compressor:       return (1.5, 1.5, 1.5)
        case .motorDrive:       return (1.0, 1.0, 1.0)
        case .verticalTank:     return (1.2, 2.5, 1.2)
        case .horizontalTank:   return (3.0, 1.0, 1.2)
        case .processVessel:    return (1.0, 3.0, 1.0)
        case .separator:        return (2.5, 1.0, 1.0)
        case .heatExchanger:    return (2.0, 1.5, 1.0)
        case .gateValve:        return (0.8, 1.0, 0.8)
        case .controlValve:     return (0.8, 1.2, 0.8)
        case .pipeSection:      return (3.0, 0.4, 0.4)
        case .pipeElbow:        return (1.0, 1.0, 1.0)
        case .pipeTee:          return (1.0, 1.0, 1.0)
        case .structuralColumn: return (0.5, 4.0, 0.5)
        case .platform:         return (4.0, 0.2, 3.0)
        }
    }
}

// MARK: - HMI3DEquipment

struct HMI3DEquipment: Identifiable, Codable {
    var id: UUID = UUID()
    var type: Equipment3DType
    var label: String

    // Tag binding for live animation
    var tagBinding: String?
    var minTagValue: Double = 0
    var maxTagValue: Double = 100

    // World position and rotation
    var posX: Float = 0
    var posY: Float = 0
    var posZ: Float = 0
    var rotationY: Float = 0   // degrees around Y axis

    // Non-uniform scale
    var scaleX: Float = 1
    var scaleY: Float = 1
    var scaleZ: Float = 1

    // Appearance
    var primaryColorHex: String = "#4A90D9"
    var useAlarmColors: Bool = true

    init(type: Equipment3DType, label: String = "", pos: (Float, Float, Float) = (0, 0, 0)) {
        self.type   = type
        self.label  = label.isEmpty ? type.displayName : label
        self.posX   = pos.0
        self.posY   = pos.1
        self.posZ   = pos.2
        let s = type.defaultScale
        self.scaleX = s.x
        self.scaleY = s.y
        self.scaleZ = s.z
    }

    /// The scene-graph node name for lookup
    var nodeName: String { "eq_\(id.uuidString)" }

    /// NSColor parsed from primaryColorHex, falling back to steel blue
    var primaryNSColor: NSColor {
        guard primaryColorHex.hasPrefix("#"), primaryColorHex.count == 7 else {
            return NSColor(red: 0.29, green: 0.56, blue: 0.85, alpha: 1)
        }
        let hex = String(primaryColorHex.dropFirst())
        var rgb: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgb)
        return NSColor(
            red:   CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >>  8) & 0xFF) / 255,
            blue:  CGFloat( rgb        & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - HMI3DScene

struct HMI3DScene: Codable {
    var equipment: [HMI3DEquipment] = []
    var cameraPreset: Camera3DPreset = .isometric
    var environmentStyle: Scene3DEnvironment = .darkIndustrial
    var showGrid: Bool = true
    var showLabels: Bool = true
}
