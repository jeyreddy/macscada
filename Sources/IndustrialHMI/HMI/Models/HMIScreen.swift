import SwiftUI

// MARK: - HMIScreen.swift
//
// Top-level document model for one HMI designer canvas.
//
// ── Persistence ────────────────────────────────────────────────────────────────
//   Each HMIScreen is stored as its own JSON file:
//     ~/Library/Application Support/IndustrialHMI/screens/<uuid>.json
//   HMIScreenStore manages the directory and reads/writes these files.
//
// ── Canvas coordinate system ───────────────────────────────────────────────────
//   The canvas is 1280 × 800 canvas units by default (canvasWidth/canvasHeight).
//   This matches the CompositeHMIView cell size (cellW/cellH) so that objects
//   placed at 1:1 scale in the designer render at full fidelity in the composite view.
//   HMIObjectView converts object positions to screen space:
//     screenX = obj.x * scale + obj.width  * scale / 2
//     screenY = obj.y * scale + obj.height * scale / 2
//
// ── backgroundColor ────────────────────────────────────────────────────────────
//   Stored as CodableColor (RGBA components) since SwiftUI Color is not Codable.
//   Default is darkBackground (#141420).

// MARK: - HMIScreen

/// The complete layout document for one HMI designer canvas.
/// Stored as `screens/<uuid>.json`; contains all HMIObjects for the screen.
struct HMIScreen: Codable, Equatable {
    var name: String              = "Screen 1"
    var canvasWidth: Double       = 1280
    var canvasHeight: Double      = 800
    var backgroundColor: CodableColor = .darkBackground
    var objects: [HMIObject]      = []
    var modifiedAt: Date          = Date()

    init(name: String = "Screen 1") {
        self.name = name
    }
}
