import SwiftUI

// MARK: - HMIScreen

/// The single canvas layout that is persisted to disk.
struct HMIScreen: Codable, Equatable {
    var name: String              = "Screen 1"
    var canvasWidth: Double       = 1280
    var canvasHeight: Double      = 800
    var backgroundColor: CodableColor = .darkBackground
    var objects: [HMIObject]      = []
    var modifiedAt: Date          = Date()
}
