// MARK: - RecipeStore.swift
//
// Manages recipe CRUD lifecycle and process activation for the IndustrialHMI.
//
// ── What is a Recipe? ─────────────────────────────────────────────────────────
//   A Recipe is a named collection of tag/setpoint pairs that configure the
//   process for a specific production grade or operating mode. Operators apply
//   recipes to quickly switch between production recipes (e.g., Grade A → Grade B).
//
// ── Activation Strategy ───────────────────────────────────────────────────────
//   For each setpoint in the recipe:
//     1. Look up the tag in TagEngine.tags dictionary.
//     2. If tag.nodeId is non-empty AND tag is not calculated → OPC-UA write
//        via OPCUAClientService.writeValue(). Handles live PLC tags.
//     3. Otherwise → TagEngine.resolveWrite() directly. Handles:
//        - Simulation mode tags (no real PLC)
//        - Modbus/MQTT tags (their drivers push new values via tagEngine)
//        - Calculated tags (can't be written — skipped with failure entry)
//   Results collected into RecipeActivationResult.successes / .failures.
//   The last result is published so RecipesView can display it.
//
// ── Persistence ───────────────────────────────────────────────────────────────
//   Recipes stored in ConfigDatabase SQLite `recipes` table via Historian.
//   loadFromDB() called by DataService on startup. Each CRUD operation
//   immediately fire-and-forgets a Task to update the DB.
//
// ── Version Tracking ──────────────────────────────────────────────────────────
//   updateRecipe() auto-increments recipe.version so engineers can audit
//   which version was active at any given time (version logged at activation).
//
// ── Integration ───────────────────────────────────────────────────────────────
//   DataService owns RecipeStore and injects historian post-init.
//   SchedulerService holds a weak reference to RecipeStore to trigger activations
//   from scheduled jobs (actionType == .activateRecipe).
//   AgentService calls activateRecipe() via the `activateRecipe` tool.

import Foundation

// MARK: - RecipeStore

/// Manages recipe CRUD and process activation.
///
/// **Activation strategy** (per setpoint):
/// 1. Look up the tag in `tagEngine`.
/// 2. If the tag has a non-empty `nodeId` and is not a calculated tag → write via OPC-UA.
/// 3. Otherwise (simulation mode, empty nodeId, or `.calculated` type) → write directly
///    into `tagEngine` (covers Modbus/MQTT tags that update via their own drivers too).
/// 4. Collect successes and failures; return a `RecipeActivationResult`.
@MainActor
class RecipeStore: ObservableObject {

    // MARK: - Published

    @Published var recipes:               [Recipe] = []
    @Published var lastActivationResult:  RecipeActivationResult?
    @Published var isActivating:          Bool = false

    // MARK: - Dependencies (set by DataService)

    var historian:    Historian?
    private let tagEngine:    TagEngine
    private let opcuaService: OPCUAClientService

    // MARK: - Init

    init(tagEngine: TagEngine, opcuaService: OPCUAClientService) {
        self.tagEngine    = tagEngine
        self.opcuaService = opcuaService
    }

    // MARK: - Bootstrap

    func loadFromDB() async {
        guard let h = historian else { return }
        do {
            recipes = try await h.loadRecipes()
            Logger.shared.info("RecipeStore: loaded \(recipes.count) recipe(s)")
        } catch {
            Logger.shared.error("RecipeStore: load failed — \(error)")
        }
    }

    // MARK: - CRUD

    func addRecipe(_ recipe: Recipe) {
        recipes.append(recipe)
        persist(recipe)
        Logger.shared.info("RecipeStore: added '\(recipe.name)'")
    }

    /// Replace an existing recipe; increments its version number.
    func updateRecipe(_ recipe: Recipe) {
        guard let idx = recipes.firstIndex(where: { $0.id == recipe.id }) else { return }
        var updated   = recipe
        updated.version += 1
        recipes[idx]  = updated
        persist(updated)
    }

    func deleteRecipe(id: UUID) {
        guard let r = recipes.first(where: { $0.id == id }) else { return }
        recipes.removeAll { $0.id == id }
        if let h = historian {
            Task { try? await h.deleteRecipe(id: id) }
        }
        Logger.shared.info("RecipeStore: deleted '\(r.name)'")
    }

    // MARK: - Activation

    /// Write all setpoints in `recipe` to the live process.
    ///
    /// Requires `canWrite` role — callers are responsible for checking before invoking.
    @discardableResult
    func activateRecipe(_ recipe: Recipe, by username: String) async -> RecipeActivationResult {
        isActivating = true
        defer { isActivating = false }

        var succeeded: [String]                          = []
        var failed:    [(tagName: String, reason: String)] = []

        for sp in recipe.setpoints {
            do {
                try await writeSetpoint(sp)
                succeeded.append(sp.tagName)
            } catch {
                failed.append((sp.tagName, error.localizedDescription))
                Logger.shared.error("Recipe '\(recipe.name)': write failed for \(sp.tagName) — \(error.localizedDescription)")
            }
        }

        // Update recipe metadata
        let activatedAt = Date()
        if let idx = recipes.firstIndex(where: { $0.id == recipe.id }) {
            recipes[idx].lastActivatedAt  = activatedAt
            recipes[idx].lastActivatedBy  = username
            persist(recipes[idx])
        }

        let result = RecipeActivationResult(
            recipe:      recipe,
            succeeded:   succeeded,
            failed:      failed,
            activatedAt: activatedAt,
            activatedBy: username
        )
        lastActivationResult = result

        if let h = historian {
            Task { try? await h.logRecipeActivation(result) }
        }

        Logger.shared.info(
            "Recipe '\(recipe.name)' activated by \(username): " +
            "\(succeeded.count) OK, \(failed.count) failed")
        return result
    }

    // MARK: - Private

    private func writeSetpoint(_ sp: RecipeSetpoint) async throws {
        guard let tag = tagEngine.getTag(named: sp.tagName) else {
            throw RecipeError.tagNotFound(sp.tagName)
        }

        let newValue: TagValue = (tag.dataType == .digital)
            ? .digital(sp.value != 0)
            : .analog(sp.value)

        let usesOPCUA = !tag.nodeId.isEmpty && tag.dataType != .calculated
        if usesOPCUA {
            do {
                try await opcuaService.writeTag(nodeId: tag.nodeId, value: newValue)
            } catch {
                throw RecipeError.opcuaWriteFailed(sp.tagName, error)
            }
        }

        // Always update TagEngine so the UI reflects the new value immediately
        tagEngine.updateTag(name: sp.tagName, value: newValue,
                            quality: .good, timestamp: Date())
    }

    private func persist(_ recipe: Recipe) {
        guard let h = historian else { return }
        Task { try? await h.saveRecipe(recipe) }
    }
}
