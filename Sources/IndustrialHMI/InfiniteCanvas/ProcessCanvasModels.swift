import SwiftUI
import Foundation

// MARK: - ProcessCanvas (the document)
//
// A ProcessCanvas is the top-level document saved to
//   ~/Library/Application Support/IndustrialHMI/processcanvases.json
// (array of all canvases in the app).
//
// The canvas uses an infinite coordinate space measured in "canvas units".
// One canvas unit = one point at scale 1.0.
// The viewport state (scale + pan) is NOT persisted — it resets on every launch.

/// A named layout document containing an arrangement of CanvasBlocks.
/// Multiple canvases can exist; only one is "active" at a time.
struct ProcessCanvas: Identifiable, Codable, Equatable {
    var id:          UUID   = UUID()
    var name:        String = "Process Overview"
    var blocks:      [CanvasBlock] = []
    var bgHex:       String = "#0D1117"   // dark navy — matches the app chrome
    var gridSize:    Double = 120         // canvas-unit spacing between grid lines
    var gridVisible: Bool   = true

    // Equality is identity-based — content changes don't affect canvas identity.
    static func == (lhs: ProcessCanvas, rhs: ProcessCanvas) -> Bool { lhs.id == rhs.id }
}

// MARK: - CanvasBlock
//
// A block is a rectangular widget placed on the canvas.
// Canvas-space coordinates: (x, y) is the TOP-LEFT corner.
// Screen-space position is computed by ProcessCanvasBlockView as:
//   screenX = canvasX * scale + pan.x
//   screenY = canvasY * scale + pan.y
//   screenW = canvasW * scale
//   screenH = canvasH * scale

/// A single rectangular widget on the Process Canvas.
/// Carries its own appearance (bg/border color) and a content descriptor.
struct CanvasBlock: Identifiable, Codable {
    var id:        UUID   = UUID()
    var title:     String = "Block"
    var showTitle: Bool   = true

    // Canvas-space position (top-left corner) and size — stored in canvas units
    var x: Double = 0
    var y: Double = 0
    var w: Double = 300
    var h: Double = 200

    // Visual appearance — hex strings like "#161B22"
    var bgHex:     String = "#161B22"
    var borderHex: String = "#30363D"

    /// What this block shows; drives the content renderer in ProcessCanvasBlockView.
    var content:   BlockContent
}

// MARK: - BlockContent
//
// Uses a flat struct with a `kind` discriminator rather than an enum with associated
// values so that Codable stays trivial — JSONEncoder/Decoder work without any custom
// implementation, and adding new fields doesn't break existing saved canvases
// (new keys are simply absent and default-initialised on decode).
//
// Block kinds and their required fields:
//   "label"       — text, fontSize
//   "tagMonitor"  — tagIDs (table: tag name | live value | quality dot)
//   "statusGrid"  — tagIDs (coloured tiles: green=running, orange=alarm, red=bad)
//   "alarmPanel"  — maxAlarms (ISA-18.2 alarm list)
//   "navButton"   — navLabel, navX/Y/Scale (animates the canvas viewport on tap)
//   "equipment"   — equipKind, equipTagID (pump/motor/valve/tank icon with status)
//   "trendMini"   — tagIDs, minutes (sparklines for up to 3 tags)
//   "hmiScreen"   — hmiScreenID, hmiScreenName (link to a screen in the HMI tab)
//   "screenGroup" — screenGroupEntries, screenGroupCols (multi-screen composite view)

/// Content descriptor for a CanvasBlock.
/// Only the fields relevant to the active `kind` are used; others are ignored.
struct BlockContent: Codable {

    // MARK: Discriminator
    /// Determines which content view is rendered. See kind list above.
    var kind: String

    // MARK: label
    var text:     String = ""
    var fontSize: Double = 28

    // MARK: tagMonitor / statusGrid / trendMini
    /// Tag names (not nodeIds) to display. Tags are looked up live from TagEngine.
    var tagIDs: [String] = []

    // MARK: trendMini
    /// History window in minutes for the sparkline (currently decorative — real history requires Historian query).
    var minutes: Int = 30

    // MARK: alarmPanel
    /// Maximum number of alarm rows to show (oldest overflow silently dropped).
    var maxAlarms: Int = 5

    // MARK: navButton
    var navLabel: String = "Navigate →"
    /// Canvas-space coordinates of the viewport centre after navigation.
    var navX:     Double = 0
    var navY:     Double = 0
    /// Canvas scale after navigation (1.0 = 100 %).
    var navScale: Double = 1

    // MARK: equipment
    /// One of: "pump" | "motor" | "valve" | "tank" | "exchanger" | "compressor"
    var equipKind:  String = "pump"
    /// Tag name whose value drives running/stopped colour of the equipment icon.
    var equipTagID: String = ""

    // MARK: hmiScreen
    /// UUID string of the linked HMIScreen (matches HMIScreenMeta.id).
    var hmiScreenID:   String = ""
    /// Cached display name shown in the block (avoids a HMIScreenStore lookup per frame).
    var hmiScreenName: String = ""

    // MARK: screenGroup
    /// Ordered list of screens to display in the composite canvas.
    var screenGroupEntries: [ScreenGroupEntry] = []
    /// Number of grid columns in the composite layout. Rows = ceil(count / cols).
    var screenGroupCols:    Int = 2

    // MARK: - Factory methods (convenience constructors)
    //
    // Use these instead of the memberwise init to avoid forgetting required fields.

    /// Static label / heading block (no live data).
    static func label(_ text: String, size: Double = 28) -> BlockContent {
        BlockContent(kind: "label", text: text, fontSize: size)
    }

    /// Live tag table showing name, value, and OPC-UA quality dot.
    static func tagMonitor(_ ids: [String]) -> BlockContent {
        BlockContent(kind: "tagMonitor", tagIDs: ids)
    }

    /// Coloured status tile grid — green/orange/red based on tag value and alarm state.
    static func statusGrid(_ ids: [String]) -> BlockContent {
        BlockContent(kind: "statusGrid", tagIDs: ids)
    }

    /// ISA-18.2 alarm list showing the most recent `max` active alarms.
    static func alarmPanel(max: Int = 5) -> BlockContent {
        BlockContent(kind: "alarmPanel", maxAlarms: max)
    }

    /// Button that animates the canvas viewport to canvas coordinates (x, y) at `scale`.
    static func navButton(label: String, x: Double, y: Double, scale: Double = 1.0) -> BlockContent {
        BlockContent(kind: "navButton", navLabel: label, navX: x, navY: y, navScale: scale)
    }

    /// Industrial equipment icon with running/alarm/stopped state from a tag.
    static func equipment(_ kind: String, tagID: String = "") -> BlockContent {
        BlockContent(kind: "equipment", equipKind: kind, equipTagID: tagID)
    }

    /// Mini sparklines for up to 3 tags over a rolling `minutes`-minute window.
    static func trendMini(_ ids: [String], minutes: Int = 30) -> BlockContent {
        BlockContent(kind: "trendMini", tagIDs: ids, minutes: minutes)
    }

    /// Link to a single HMI screen — tapping switches the HMI tab to that screen.
    static func hmiScreen(id: UUID, name: String) -> BlockContent {
        BlockContent(kind: "hmiScreen", hmiScreenID: id.uuidString, hmiScreenName: name)
    }

    /// Multi-screen group — tapping opens CompositeHMIView with all screens in a grid.
    static func screenGroup(cols: Int = 2) -> BlockContent {
        BlockContent(kind: "screenGroup", screenGroupCols: cols)
    }
}

// MARK: - ScreenGroupEntry
//
// One slot in a Screen Group block's ordered list.
// Array index determines grid position: col = index % cols, row = index / cols.

/// References one HMI screen within a Screen Group block.
struct ScreenGroupEntry: Codable, Identifiable {
    var id:            UUID   = UUID()
    /// UUID string matching HMIScreenMeta.id — used to load the screen from disk.
    var hmiScreenID:   String = ""
    /// Cached display name (shown in the mini grid preview and the composite toolbar).
    var hmiScreenName: String = ""
}

// MARK: - Color helpers

extension Color {
    /// Construct a Color from a 6-digit hex string, with or without a leading "#".
    /// Example: Color(hex: "#1E6B9B") or Color(hex: "1E6B9B")
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8)  & 0xFF) / 255
        let b = Double(int         & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

extension TagQuality {
    /// Status dot colour used in tag monitor rows and equipment blocks.
    /// green = good, red = bad, yellow = uncertain.
    var dot: Color {
        switch self {
        case .good:      return .green
        case .bad:       return .red
        case .uncertain: return .yellow
        }
    }
}
