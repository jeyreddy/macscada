// MARK: - HMI3DSceneStore.swift
//
// Manages the persistence of HMI3DScene data — one 3D scene per 2D HMI screen.
// Each 3D scene is stored as a separate JSON file keyed by the screen's UUID,
// mirroring the HMIScreenStore pattern.
//
// ── File Storage ──────────────────────────────────────────────────────────────
//   Directory: ~/Library/Application Support/IndustrialHMI/scenes3d/
//   Filename:  <screenUUID>.json (e.g. "A3F2C1D4-....json")
//   Created on first write; directory created lazily by scenesDirectory getter.
//
// ── Screen Association ────────────────────────────────────────────────────────
//   currentScreenId tracks which 2D screen this 3D scene belongs to.
//   HMIDesignerView calls loadScene(for: screenId) when the user switches screens
//   via HMIScreenListPane — matches the pattern used by HMIScreenStore.switchToScreen().
//   If no JSON file exists for a screenId, starts with an empty HMI3DScene.
//
// ── Debounced Auto-save ───────────────────────────────────────────────────────
//   saveDebounce: AnyCancellable subscribes to $scene changes via Combine.
//   Debounces with 0.5 s delay (same as HMIScreenStore) to avoid disk thrashing
//   during rapid inspector field edits or drag-move operations.
//
// ── Equipment CRUD ────────────────────────────────────────────────────────────
//   addEquipment(_:)       — append to scene.equipment, trigger save
//   updateEquipment(_:)    — replace by id, trigger save
//   removeEquipment(id:)   — remove by id, trigger save
//   All mutations go through @Published scene so HMI3DDesignerView re-renders.
//
// ── Scene Settings ────────────────────────────────────────────────────────────
//   updateEnvironment(_:)  — change Scene3DEnvironment (lighting preset)
//   updateCameraPreset(_:) — change Camera3DPreset (initial camera position)
//   Both trigger save and are controlled from HMI3DDesignerView's toolbar.

import Foundation
import Combine

// MARK: - HMI3DSceneStore

/// Manages 3D scenes paired with HMI screens (one-to-one by screen UUID).
/// Scenes persist as JSON at <ApplicationSupport>/IndustrialHMI/scenes3d/<uuid>.json
@MainActor
class HMI3DSceneStore: ObservableObject {

    // MARK: - Published state

    @Published private(set) var scene: HMI3DScene = HMI3DScene()
    @Published private(set) var currentScreenId: UUID? = nil

    // MARK: - Private

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var saveDebounce: AnyCancellable?

    // MARK: - Init

    init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    // MARK: - Directory

    private var scenesDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("IndustrialHMI/scenes3d")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sceneURL(for id: UUID) -> URL {
        scenesDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    // MARK: - Load / Save

    func loadScene(for screenId: UUID) {
        currentScreenId = screenId
        let url = sceneURL(for: screenId)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let loaded = try? decoder.decode(HMI3DScene.self, from: data) else {
            scene = HMI3DScene()
            return
        }
        scene = loaded
    }

    private func save() {
        guard let id = currentScreenId else { return }
        guard let data = try? encoder.encode(scene) else { return }
        try? data.write(to: sceneURL(for: id))
    }

    /// Debounce saves so rapid edits don't flood disk
    private func debouncedSave() {
        saveDebounce?.cancel()
        saveDebounce = Just(())
            .delay(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }
    }

    // MARK: - Equipment CRUD

    func addEquipment(_ equip: HMI3DEquipment) {
        scene.equipment.append(equip)
        debouncedSave()
    }

    func updateEquipment(_ equip: HMI3DEquipment) {
        guard let idx = scene.equipment.firstIndex(where: { $0.id == equip.id }) else { return }
        scene.equipment[idx] = equip
        debouncedSave()
    }

    func deleteEquipment(id: UUID) {
        scene.equipment.removeAll { $0.id == id }
        debouncedSave()
    }

    func clearScene() {
        scene.equipment = []
        debouncedSave()
    }

    // MARK: - Scene settings

    func setCameraPreset(_ preset: Camera3DPreset) {
        scene.cameraPreset = preset
        debouncedSave()
    }

    func setEnvironment(_ env: Scene3DEnvironment) {
        scene.environmentStyle = env
        debouncedSave()
    }

    func setShowGrid(_ v: Bool) {
        scene.showGrid = v
        debouncedSave()
    }

    func setShowLabels(_ v: Bool) {
        scene.showLabels = v
        debouncedSave()
    }

    /// Immediately save (used by HMIDisplaySettingsView Reset button)
    func resetScene() {
        scene = HMI3DScene()
        save()
    }
}
