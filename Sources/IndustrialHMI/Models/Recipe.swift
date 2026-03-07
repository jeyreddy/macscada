import Foundation

// MARK: - Recipe.swift
//
// Data models for the batch recipe management feature.
//
// ── What is a recipe? ─────────────────────────────────────────────────────────
//   A Recipe is a named snapshot of target setpoints for a set of process tags.
//   Activating a recipe writes all its setpoints to the live process in one shot,
//   enabling fast product/grade changes in batch manufacturing environments.
//
// ── Recipe structure ──────────────────────────────────────────────────────────
//   Recipe
//     ├── id, name, description, version, createdAt, lastActivatedAt/By
//     └── setpoints: [RecipeSetpoint]
//                       ├── tagName   — name as known to TagEngine
//                       ├── value     — target setpoint value (Double)
//                       └── displayUnit — engineering unit for display only
//
// ── Activation flow (RecipeStore) ────────────────────────────────────────────
//   1. Operator selects a recipe in RecipesView and presses "Activate".
//   2. RecipeStore.activate(_:by:) iterates setpoints:
//        • For hardware tags: calls OPCUAClientService.writeTag()
//        • For sim/calculated tags: directly updates TagEngine
//   3. Returns a RecipeActivationResult listing per-tag success/failure.
//   4. On success, RecipeStore logs the activation to the Historian.
//
// ── Persistence ───────────────────────────────────────────────────────────────
//   Recipes are stored in the ConfigDatabase SQLite file under a `recipes` table.
//   RecipeStore.loadFromDB() deserializes them on app startup.

// MARK: - RecipeSetpoint

/// A single tag setpoint within a recipe.
struct RecipeSetpoint: Identifiable, Codable {
    let id:          UUID
    var tagName:     String
    var value:       Double
    /// Display-only engineering unit (copied from the tag at creation time).
    var displayUnit: String?

    init(id: UUID = UUID(), tagName: String, value: Double, displayUnit: String? = nil) {
        self.id          = id
        self.tagName     = tagName
        self.value       = value
        self.displayUnit = displayUnit
    }
}

// MARK: - Recipe

/// A named collection of tag setpoints that can be saved and re-applied as a batch.
///
/// Activating a recipe writes all its setpoints to the live process, either via
/// OPC-UA (for hardware tags) or directly in the TagEngine (simulation / calculated tags).
struct Recipe: Identifiable, Codable {
    let id:               UUID
    var name:             String
    var description:      String
    var setpoints:        [RecipeSetpoint]
    var version:          Int           // incremented on each save
    var createdAt:        Date
    var lastActivatedAt:  Date?
    var lastActivatedBy:  String?

    init(
        id:          UUID   = UUID(),
        name:        String,
        description: String = "",
        setpoints:   [RecipeSetpoint] = []
    ) {
        self.id              = id
        self.name            = name
        self.description     = description
        self.setpoints       = setpoints
        self.version         = 1
        self.createdAt       = Date()
        self.lastActivatedAt = nil
        self.lastActivatedBy = nil
    }
}

// MARK: - RecipeActivationResult

/// Result of a single recipe activation attempt.
struct RecipeActivationResult {
    let recipe:      Recipe
    let succeeded:   [String]                          // tag names written OK
    let failed:      [(tagName: String, reason: String)]  // failures
    let activatedAt: Date
    let activatedBy: String

    var allSucceeded: Bool { failed.isEmpty }
    var successCount: Int  { succeeded.count }
    var failureCount: Int  { failed.count }
}

// MARK: - RecipeError

enum RecipeError: LocalizedError {
    case tagNotFound(String)
    case opcuaWriteFailed(String, Error)

    var errorDescription: String? {
        switch self {
        case .tagNotFound(let n):          return "Tag not found: \(n)"
        case .opcuaWriteFailed(let n, _):  return "Write failed for \(n)"
        }
    }
}
