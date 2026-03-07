import SwiftUI
import AppKit

// MARK: - HMIObject.swift
//
// Core data models for the HMI screen designer.
//
// ── Object model ─────────────────────────────────────────────────────────────
//   HMIObject — a single widget placed on an HMIScreen canvas.
//     • Position: (x, y) = top-left corner in canvas units (same as CanvasBlock)
//     • Size: (width, height) in canvas units
//     • Type: HMIObjectType discriminates the visual renderer in HMIObjectView
//     • Tag binding: HMITagBinding links the object to a live tag for dynamic display
//
//   HMITagBinding — links an HMI object to a tag name:
//     • tagName   — looked up in TagEngine at runtime
//     • setpoint  — alarm/fill threshold for gauge/level objects
//     • minValue/maxValue — engineering range for gauges
//     • onValue/offValue  — digital state labels for pushButton/toggleSwitch
//
//   CodableColor — bridges SwiftUI Color through Codable by storing RGBA components.
//     Converts via NSColor.usingColorSpace(.sRGB) to ensure consistent values.
//
// ── HMI object types ──────────────────────────────────────────────────────────
//   Basic shapes:
//     rectangle, ellipse, textLabel, numericDisplay,
//     levelBar, circularGauge, pushButton, toggleSwitch, trendSparkline
//
//   P&ID symbols (industrial process & instrumentation diagram):
//     centrifugalPump, motorDrive, gateValve, globeValve, ballValve,
//     checkValve, controlValve, closedVessel, openTank, pipeStraight,
//     instrumentBubble, heatExchangerSym
//
// ── Coordinate system ─────────────────────────────────────────────────────────
//   Canvas origin (0,0) is the top-left corner.
//   Objects are positioned at their top-left and sized in canvas units.
//   HMICanvasView converts to screen space:
//     screenX = obj.x * scale + obj.width * scale / 2   (SwiftUI .position centre)
//     screenY = obj.y * scale + obj.height * scale / 2
//
// ── P&ID rendering ────────────────────────────────────────────────────────────
//   P&ID symbol types are rendered by IndustrialSymbolCanvas (a SwiftUI Canvas).
//   Standard types (rectangle, ellipse, etc.) are rendered directly in HMIObjectView.

// MARK: - CodableColor

/// Codable wrapper for SwiftUI Color (which is not directly Codable).
struct CodableColor: Codable, Equatable {
    var r, g, b, a: Double

    var color: Color { Color(red: r, green: g, blue: b, opacity: a) }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.gray
        r = ns.redComponent
        g = ns.greenComponent
        b = ns.blueComponent
        a = ns.alphaComponent
    }

    // Codable memberwise init (used by JSONDecoder)
    init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    // Preset colors
    static let gray  = CodableColor(.gray)
    static let white = CodableColor(.white)
    static let black = CodableColor(.black)
    static let darkBackground = CodableColor(Color(red: 0.08, green: 0.08, blue: 0.12))
    static let steelBlue = CodableColor(Color(red: 0.27, green: 0.51, blue: 0.71))
}

// MARK: - HMIFlowDirection

enum HMIFlowDirection: String, Codable, CaseIterable {
    case left, right, up, down
}

// MARK: - HMIObjectType

enum HMIObjectType: String, Codable, CaseIterable {
    case rectangle         = "rectangle"
    case ellipse           = "ellipse"
    case textLabel         = "textLabel"
    case numericDisplay    = "numericDisplay"
    case levelBar          = "levelBar"
    case circularGauge     = "circularGauge"
    case pushButton        = "pushButton"
    case toggleSwitch      = "toggleSwitch"
    case trendSparkline    = "trendSparkline"
    // P&ID symbols (Phase 16)
    case centrifugalPump   = "centrifugalPump"
    case motorDrive        = "motorDrive"
    case gateValve         = "gateValve"
    case globeValve        = "globeValve"
    case ballValve         = "ballValve"
    case checkValve        = "checkValve"
    case controlValve      = "controlValve"
    case closedVessel      = "closedVessel"
    case openTank          = "openTank"
    case pipeStraight      = "pipeStraight"
    case instrumentBubble  = "instrumentBubble"
    case heatExchangerSym  = "heatExchangerSym"

    var defaultSize: CGSize {
        switch self {
        case .rectangle:         return CGSize(width: 120, height: 80)
        case .ellipse:           return CGSize(width: 120, height: 80)
        case .textLabel:         return CGSize(width: 160, height: 40)
        case .numericDisplay:    return CGSize(width: 120, height: 60)
        case .levelBar:          return CGSize(width: 60,  height: 160)
        case .circularGauge:     return CGSize(width: 160, height: 160)
        case .pushButton:        return CGSize(width: 120, height: 50)
        case .toggleSwitch:      return CGSize(width: 100, height: 44)
        case .trendSparkline:    return CGSize(width: 200, height: 100)
        // P&ID
        case .centrifugalPump:   return CGSize(width: 80,  height: 80)
        case .motorDrive:        return CGSize(width: 80,  height: 80)
        case .gateValve:         return CGSize(width: 60,  height: 60)
        case .globeValve:        return CGSize(width: 60,  height: 80)
        case .ballValve:         return CGSize(width: 60,  height: 60)
        case .checkValve:        return CGSize(width: 70,  height: 60)
        case .controlValve:      return CGSize(width: 60,  height: 100)
        case .closedVessel:      return CGSize(width: 80,  height: 160)
        case .openTank:          return CGSize(width: 100, height: 140)
        case .pipeStraight:      return CGSize(width: 160, height: 40)
        case .instrumentBubble:  return CGSize(width: 70,  height: 70)
        case .heatExchangerSym:  return CGSize(width: 120, height: 80)
        }
    }

    var icon: String {
        switch self {
        case .rectangle:         return "rectangle"
        case .ellipse:           return "circle"
        case .textLabel:         return "textformat"
        case .numericDisplay:    return "number.square"
        case .levelBar:          return "chart.bar.fill"
        case .circularGauge:     return "gauge.medium"
        case .pushButton:        return "button.programmable"
        case .toggleSwitch:      return "switch.2"
        case .trendSparkline:    return "chart.line.uptrend.xyaxis"
        // P&ID
        case .centrifugalPump:   return "arrow.clockwise.circle.fill"
        case .motorDrive:        return "bolt.circle.fill"
        case .gateValve:         return "diamond.fill"
        case .globeValve:        return "triangle.fill"
        case .ballValve:         return "circle.fill"
        case .checkValve:        return "arrowtriangle.right.fill"
        case .controlValve:      return "slider.vertical.3"
        case .closedVessel:      return "cylinder.fill"
        case .openTank:          return "cup.and.saucer"
        case .pipeStraight:      return "minus.rectangle"
        case .instrumentBubble:  return "circle.badge.i.fill"
        case .heatExchangerSym:  return "thermometer.medium"
        }
    }

    var displayName: String {
        switch self {
        case .rectangle:         return "Rectangle"
        case .ellipse:           return "Ellipse"
        case .textLabel:         return "Text Label"
        case .numericDisplay:    return "Numeric"
        case .levelBar:          return "Level Bar"
        case .circularGauge:     return "Circular Gauge"
        case .pushButton:        return "Push Button"
        case .toggleSwitch:      return "Toggle Switch"
        case .trendSparkline:    return "Trend Sparkline"
        // P&ID
        case .centrifugalPump:   return "Centrifugal Pump"
        case .motorDrive:        return "Motor Drive"
        case .gateValve:         return "Gate Valve"
        case .globeValve:        return "Globe Valve"
        case .ballValve:         return "Ball Valve"
        case .checkValve:        return "Check Valve"
        case .controlValve:      return "Control Valve"
        case .closedVessel:      return "Closed Vessel"
        case .openTank:          return "Open Tank"
        case .pipeStraight:      return "Pipe Straight"
        case .instrumentBubble:  return "Instrument Bubble"
        case .heatExchangerSym:  return "Heat Exchanger"
        }
    }

    var category: String {
        switch self {
        case .rectangle, .ellipse, .textLabel, .numericDisplay,
             .levelBar, .circularGauge, .pushButton, .toggleSwitch, .trendSparkline:
            return "Basic"
        default:
            return "P&ID"
        }
    }
}

// MARK: - ColorThreshold

/// A threshold entry: fill color changes when tag value >= this value.
struct ColorThreshold: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var value: Double       // tag value at which this color applies
    var color: CodableColor

    init(id: UUID = UUID(), value: Double, color: CodableColor) {
        self.id = id; self.value = value; self.color = color
    }
}

// MARK: - TagBinding

/// Associates an HMI object with an OPC-UA tag.
struct TagBinding: Codable, Equatable {
    var tagName: String
    /// Color thresholds for shape fill / bar fill (sorted ascending by value).
    var colorThresholds: [ColorThreshold] = []
    /// printf-style format string for numeric displays. e.g. "%.1f"
    var numberFormat: String = "%.1f"
    /// Unit string shown next to numeric values.
    var unit: String = ""
}

// MARK: - HMIObject

/// A single graphical element on the HMI canvas.
struct HMIObject: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var type: HMIObjectType

    // ── Geometry (logical canvas coordinates, top-left origin) ──────────────
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var rotation: Double = 0      // degrees
    var zIndex: Int = 0

    // ── Shape Style ─────────────────────────────────────────────────────────
    var fillColor: CodableColor   = .steelBlue
    var strokeColor: CodableColor = .white
    var strokeWidth: Double       = 1.5
    var cornerRadius: Double      = 4          // rectangles only

    // ── Text Style ──────────────────────────────────────────────────────────
    var staticText: String        = "Label"
    var fontSize: Double          = 14
    var fontBold: Bool            = false
    var textColor: CodableColor   = .white

    // ── Numeric Display ─────────────────────────────────────────────────────
    var numberFormat: String      = "%.1f"
    var unit: String              = ""

    // ── Level Bar ───────────────────────────────────────────────────────────
    var barIsVertical: Bool       = true
    var barMin: Double            = 0
    var barMax: Double            = 100

    // ── Circular Gauge (Phase 14) ────────────────────────────────────────────
    var gaugeMin:          Double = 0
    var gaugeMax:          Double = 100
    var gaugeSweepDegrees: Double = 270   // arc width (default 270° = 3/4 circle)

    // ── Button / Switch write values (Phase 14) ──────────────────────────────
    var writeOnValue:      Double = 1.0   // value written on press / toggle-to-ON
    var writeOffValue:     Double = 0.0   // toggle-to-OFF value

    // ── Sparkline (Phase 14) ─────────────────────────────────────────────────
    var sparklineMinutes:  Int    = 15    // history window in minutes
    var sparklineShowFill: Bool   = true  // fill area under line

    // ── P&ID Industrial (Phase 16) ───────────────────────────────────────────
    var equipmentVariant: String         = ""      // valve subtypes, tank variants
    var flowDirection: HMIFlowDirection  = .right  // pumps, pipes
    var showISATag: Bool                 = true    // letter code in bubble / "M" in motor
    var animateRunning: Bool             = true    // animate pump/motor when tag > writeOnValue
    var pipeSegmentCount: Int            = 3       // animated chevron count in pipeStraight

    // ── Tag Binding ─────────────────────────────────────────────────────────
    var tagBinding: TagBinding?

    // ── Designer metadata ────────────────────────────────────────────────────
    var designerLabel: String     = ""

    // MARK: - CodingKeys (explicit — required for backward-compatible custom init)

    enum CodingKeys: String, CodingKey {
        case id, type, x, y, width, height, rotation, zIndex
        case fillColor, strokeColor, strokeWidth, cornerRadius
        case staticText, fontSize, fontBold, textColor
        case numberFormat, unit
        case barIsVertical, barMin, barMax
        case gaugeMin, gaugeMax, gaugeSweepDegrees
        case writeOnValue, writeOffValue
        case sparklineMinutes, sparklineShowFill
        // Phase 16 P&ID
        case equipmentVariant, flowDirection, showISATag, animateRunning, pipeSegmentCount
        case tagBinding, designerLabel
    }

    // MARK: Convenience init
    init(type: HMIObjectType, x: Double, y: Double) {
        self.type   = type
        self.x      = x
        self.y      = y
        self.width  = type.defaultSize.width
        self.height = type.defaultSize.height
        // Give dark-background types an appropriate default fill
        if type == .textLabel || type == .pushButton || type == .toggleSwitch {
            fillColor = .darkBackground
        }
    }

    // MARK: Custom Decodable init
    /// Decodes with backward compatibility: Phase 14 fields use decodeIfPresent
    /// so existing screen JSON files (without the new keys) decode without error.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id            = try c.decode(UUID.self,           forKey: .id)
        type          = try c.decode(HMIObjectType.self,  forKey: .type)
        x             = try c.decode(Double.self,         forKey: .x)
        y             = try c.decode(Double.self,         forKey: .y)
        width         = try c.decode(Double.self,         forKey: .width)
        height        = try c.decode(Double.self,         forKey: .height)
        rotation      = try c.decodeIfPresent(Double.self,      forKey: .rotation)      ?? 0
        zIndex        = try c.decodeIfPresent(Int.self,         forKey: .zIndex)         ?? 0
        fillColor     = try c.decode(CodableColor.self,         forKey: .fillColor)
        strokeColor   = try c.decode(CodableColor.self,         forKey: .strokeColor)
        strokeWidth   = try c.decode(Double.self,               forKey: .strokeWidth)
        cornerRadius  = try c.decode(Double.self,               forKey: .cornerRadius)
        staticText    = try c.decode(String.self,               forKey: .staticText)
        fontSize      = try c.decode(Double.self,               forKey: .fontSize)
        fontBold      = try c.decode(Bool.self,                 forKey: .fontBold)
        textColor     = try c.decode(CodableColor.self,         forKey: .textColor)
        numberFormat  = try c.decode(String.self,               forKey: .numberFormat)
        unit          = try c.decode(String.self,               forKey: .unit)
        barIsVertical = try c.decode(Bool.self,                 forKey: .barIsVertical)
        barMin        = try c.decode(Double.self,               forKey: .barMin)
        barMax        = try c.decode(Double.self,               forKey: .barMax)
        tagBinding    = try c.decodeIfPresent(TagBinding.self,  forKey: .tagBinding)
        designerLabel = try c.decodeIfPresent(String.self,      forKey: .designerLabel) ?? ""
        // Phase 14 — new fields: fall back to defaults when key is absent
        gaugeMin          = try c.decodeIfPresent(Double.self, forKey: .gaugeMin)          ?? 0
        gaugeMax          = try c.decodeIfPresent(Double.self, forKey: .gaugeMax)          ?? 100
        gaugeSweepDegrees = try c.decodeIfPresent(Double.self, forKey: .gaugeSweepDegrees) ?? 270
        writeOnValue      = try c.decodeIfPresent(Double.self, forKey: .writeOnValue)      ?? 1.0
        writeOffValue     = try c.decodeIfPresent(Double.self, forKey: .writeOffValue)     ?? 0.0
        sparklineMinutes  = try c.decodeIfPresent(Int.self,    forKey: .sparklineMinutes)  ?? 15
        sparklineShowFill = try c.decodeIfPresent(Bool.self,   forKey: .sparklineShowFill) ?? true
        // Phase 16 P&ID — fall back to defaults when key is absent
        equipmentVariant  = try c.decodeIfPresent(String.self,           forKey: .equipmentVariant)  ?? ""
        flowDirection     = try c.decodeIfPresent(HMIFlowDirection.self, forKey: .flowDirection)     ?? .right
        showISATag        = try c.decodeIfPresent(Bool.self,             forKey: .showISATag)        ?? true
        animateRunning    = try c.decodeIfPresent(Bool.self,             forKey: .animateRunning)    ?? true
        pipeSegmentCount  = try c.decodeIfPresent(Int.self,              forKey: .pipeSegmentCount)  ?? 3
    }
}
