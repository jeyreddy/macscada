import Foundation
import Combine

// MARK: - HMIScreenStore.swift
//
// Persistence layer for the HMI screen designer.
//
// ── Storage layout ────────────────────────────────────────────────────────────
//   ~/Library/Application Support/IndustrialHMI/screens/
//     index.json             — ordered [HMIScreenMeta] (id + name only)
//     <uuid>.json            — one HMIScreen per file (full objects array)
//
//   Separating the index from individual screen files means:
//   • Listing all screens (for picker menus) is fast — only index.json is read.
//   • Loading a specific screen is lazy — only when the operator switches to it.
//   • Deleting a screen is a single file removal.
//
// ── Active screen ─────────────────────────────────────────────────────────────
//   `screen` is the currently active HMIScreen held in memory.
//   Changes are debounced 500 ms and auto-saved via a Combine subscription on $screen.
//   Explicit saves are triggered on screen switch (saveCurrentScreen) and CRUD ops.
//
// ── loadScreen(id:) ───────────────────────────────────────────────────────────
//   Used by CompositeHMIView to load multiple screens simultaneously without
//   changing `currentScreenId` or the active `screen`. Returns the decoded HMIScreen
//   directly from its UUID.json file without touching any @Published state.
//
// ── Migration ────────────────────────────────────────────────────────────────
//   The app previously stored all objects in a single `hmi_screen.json` file.
//   On first launch with the new multi-screen format, migrateLegacyIfNeeded()
//   detects the old file and imports it as "Screen 1" in the new directory layout.

// MARK: - HMIScreenMeta

/// Lightweight record stored in `screens/index.json` — no objects, just id + name.
/// Sufficient to populate picker menus and the screen list pane without loading all objects.
struct HMIScreenMeta: Codable, Identifiable, Equatable {
    let id:   UUID
    var name: String
}

// MARK: - HMIScreenStore

/// Manages a directory of HMI screens.
/// Each screen is stored as `screens/<uuid>.json` under
/// ~/Library/Application Support/IndustrialHMI/.
/// An `index.json` holds the ordered list of HMIScreenMeta.
@MainActor
class HMIScreenStore: ObservableObject {

    // MARK: - Published

    @Published var allScreenMeta: [HMIScreenMeta] = []
    @Published var currentScreenId: UUID?
    @Published var screen: HMIScreen = HMIScreen()   // currently active screen

    // MARK: - Private

    private let screensDir: URL
    private let indexURL:   URL
    private var saveCancellable: AnyCancellable?

    // MARK: Init

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first!
        let baseDir = appSupport.appendingPathComponent("IndustrialHMI", isDirectory: true)
        screensDir  = baseDir.appendingPathComponent("screens", isDirectory: true)
        indexURL    = screensDir.appendingPathComponent("index.json")

        try? FileManager.default.createDirectory(at: screensDir,
                                                  withIntermediateDirectories: true)

        // One-time migration: if the old single-file exists, import it as "Screen 1"
        let legacyURL = baseDir.appendingPathComponent("hmi_screen.json")
        migrateLegacyIfNeeded(legacyURL: legacyURL)

        loadIndex()

        if allScreenMeta.isEmpty {
            // First launch: create a default screen
            let meta = HMIScreenMeta(id: UUID(), name: "Screen 1")
            allScreenMeta = [meta]
            saveIndex()
            screen = HMIScreen(name: "Screen 1")
            currentScreenId = meta.id
            saveCurrentScreen()
        } else {
            currentScreenId = allScreenMeta.first?.id
            loadCurrentScreen()
        }

        // Debounced auto-save: 0.5 s after any change
        saveCancellable = $screen
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.saveCurrentScreen() }
    }

    // MARK: - Screen Navigation

    func switchToScreen(id: UUID) {
        guard id != currentScreenId,
              allScreenMeta.contains(where: { $0.id == id }) else { return }
        saveCurrentScreen()
        currentScreenId = id
        loadCurrentScreen()
    }

    // MARK: - Screen CRUD

    func createScreen(name: String = "New Screen") {
        let meta = HMIScreenMeta(id: UUID(), name: name)
        allScreenMeta.append(meta)
        saveIndex()
        saveCurrentScreen()          // persist what we have now
        currentScreenId = meta.id
        screen = HMIScreen(name: name)
        saveCurrentScreen()
        Logger.shared.info("Created HMI screen: \(name)")
    }

    func deleteScreen(id: UUID) {
        guard allScreenMeta.count > 1 else {
            Logger.shared.warning("Cannot delete the last HMI screen")
            return
        }
        // If deleting the current screen, switch to first available
        let switchTarget = allScreenMeta.first(where: { $0.id != id })?.id
        allScreenMeta.removeAll { $0.id == id }
        saveIndex()
        // Remove the file
        let fileURL = screensDir.appendingPathComponent("\(id.uuidString).json")
        try? FileManager.default.removeItem(at: fileURL)
        if currentScreenId == id, let target = switchTarget {
            currentScreenId = target
            loadCurrentScreen()
        }
    }

    func duplicateScreen(id: UUID) {
        guard let meta = allScreenMeta.first(where: { $0.id == id }) else { return }
        // Load the source screen from disk
        let srcURL = screensDir.appendingPathComponent("\(id.uuidString).json")
        guard let data = try? Data(contentsOf: srcURL),
              var srcScreen = try? JSONDecoder().decode(HMIScreen.self, from: data) else { return }

        let newId   = UUID()
        let newName = "\(meta.name) Copy"

        // Remap all object IDs to fresh UUIDs to avoid collisions in the canvas
        srcScreen.name    = newName
        srcScreen.objects = srcScreen.objects.map { obj in
            var o = obj; o.id = UUID(); return o
        }

        let newMeta = HMIScreenMeta(id: newId, name: newName)
        allScreenMeta.append(newMeta)
        saveIndex()

        // Save the duplicated screen to disk
        if let encoded = try? JSONEncoder().encode(srcScreen) {
            let destURL = screensDir.appendingPathComponent("\(newId.uuidString).json")
            try? encoded.write(to: destURL, options: .atomic)
        }

        // Switch to the new screen
        saveCurrentScreen()
        currentScreenId = newId
        screen = srcScreen
        Logger.shared.info("HMIScreenStore: duplicated '\(meta.name)' → '\(newName)'")
    }

    func renameScreen(id: UUID, newName: String) {
        guard let i = allScreenMeta.firstIndex(where: { $0.id == id }) else { return }
        allScreenMeta[i].name = newName
        saveIndex()
        if currentScreenId == id {
            screen.name = newName
            saveCurrentScreen()
        }
    }

    // MARK: - CRUD (objects in current screen)

    func addObject(_ obj: HMIObject) {
        screen.objects.append(obj)
        screen.modifiedAt = Date()
    }

    func updateObject(_ obj: HMIObject) {
        guard let idx = screen.objects.firstIndex(where: { $0.id == obj.id }) else { return }
        screen.objects[idx] = obj
        screen.modifiedAt = Date()
    }

    func deleteObject(id: UUID) {
        screen.objects.removeAll { $0.id == id }
        screen.modifiedAt = Date()
    }

    func bringToFront(id: UUID) {
        guard let idx = screen.objects.firstIndex(where: { $0.id == id }) else { return }
        let maxZ = screen.objects.map { $0.zIndex }.max() ?? 0
        screen.objects[idx].zIndex = maxZ + 1
        screen.modifiedAt = Date()
    }

    func sendToBack(id: UUID) {
        guard let idx = screen.objects.firstIndex(where: { $0.id == id }) else { return }
        let minZ = screen.objects.map { $0.zIndex }.min() ?? 0
        screen.objects[idx].zIndex = minZ - 1
        screen.modifiedAt = Date()
    }

    // MARK: - Load / Save (private)

    private func loadIndex() {
        guard FileManager.default.fileExists(atPath: indexURL.path),
              let data = try? Data(contentsOf: indexURL),
              let meta = try? JSONDecoder().decode([HMIScreenMeta].self, from: data)
        else { return }
        allScreenMeta = meta
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(allScreenMeta) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private func loadCurrentScreen() {
        guard let id = currentScreenId else { return }
        let fileURL = screensDir.appendingPathComponent("\(id.uuidString).json")
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            screen = HMIScreen(name: allScreenMeta.first(where: { $0.id == id })?.name ?? "Screen")
            return
        }
        do {
            screen = try JSONDecoder().decode(HMIScreen.self, from: data)
            Logger.shared.info("HMIScreenStore: loaded screen '\(screen.name)' (\(screen.objects.count) objects)")
        } catch {
            Logger.shared.error("HMIScreenStore: failed to decode screen — \(error)")
            screen = HMIScreen()
        }
    }

    /// Loads any screen from disk by ID without changing global state.
    /// Returns the currently active screen directly if IDs match (avoids a file read).
    func loadScreen(id: UUID) -> HMIScreen? {
        if id == currentScreenId { return screen }
        let fileURL = screensDir.appendingPathComponent("\(id.uuidString).json")
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(HMIScreen.self, from: data)
    }

    func saveCurrentScreen() {
        guard let id = currentScreenId else { return }
        let fileURL = screensDir.appendingPathComponent("\(id.uuidString).json")
        do {
            let data = try JSONEncoder().encode(screen)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Logger.shared.error("HMIScreenStore: save failed — \(error)")
        }
    }

    // MARK: - Legacy migration

    private func migrateLegacyIfNeeded(legacyURL: URL) {
        guard FileManager.default.fileExists(atPath: legacyURL.path),
              !FileManager.default.fileExists(atPath: indexURL.path) else { return }
        do {
            let data   = try Data(contentsOf: legacyURL)
            var legacy = try JSONDecoder().decode(HMIScreen.self, from: data)
            let id     = UUID()
            legacy.name = "Screen 1"
            let destURL = screensDir.appendingPathComponent("\(id.uuidString).json")
            try JSONEncoder().encode(legacy).write(to: destURL, options: .atomic)
            let meta = [HMIScreenMeta(id: id, name: "Screen 1")]
            try JSONEncoder().encode(meta).write(to: indexURL, options: .atomic)
            try FileManager.default.removeItem(at: legacyURL)
            Logger.shared.info("HMIScreenStore: migrated legacy hmi_screen.json")
        } catch {
            Logger.shared.warning("HMIScreenStore: legacy migration failed — \(error)")
        }
    }
}
