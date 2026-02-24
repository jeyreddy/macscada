import SwiftUI
import AppKit

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

// MARK: - HMIObjectType

enum HMIObjectType: String, Codable, CaseIterable {
    case rectangle      = "rectangle"
    case ellipse        = "ellipse"
    case textLabel      = "textLabel"
    case numericDisplay = "numericDisplay"
    case levelBar       = "levelBar"

    var defaultSize: CGSize {
        switch self {
        case .rectangle:      return CGSize(width: 120, height: 80)
        case .ellipse:        return CGSize(width: 120, height: 80)
        case .textLabel:      return CGSize(width: 160, height: 40)
        case .numericDisplay: return CGSize(width: 120, height: 60)
        case .levelBar:       return CGSize(width: 60,  height: 160)
        }
    }

    var icon: String {
        switch self {
        case .rectangle:      return "rectangle"
        case .ellipse:        return "circle"
        case .textLabel:      return "textformat"
        case .numericDisplay: return "number.square"
        case .levelBar:       return "chart.bar.fill"
        }
    }

    var displayName: String {
        switch self {
        case .rectangle:      return "Rectangle"
        case .ellipse:        return "Ellipse"
        case .textLabel:      return "Text Label"
        case .numericDisplay: return "Numeric"
        case .levelBar:       return "Level Bar"
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

    // ── Tag Binding ─────────────────────────────────────────────────────────
    var tagBinding: TagBinding?

    // ── Designer metadata ────────────────────────────────────────────────────
    var designerLabel: String     = ""

    // MARK: Convenience init
    init(type: HMIObjectType, x: Double, y: Double) {
        self.type   = type
        self.x      = x
        self.y      = y
        self.width  = type.defaultSize.width
        self.height = type.defaultSize.height
        // Give text label a more appropriate default fill
        if type == .textLabel { fillColor = .darkBackground }
    }
}
