import Foundation

// MARK: - ProcessCanvasStore
//
// Persistence layer for the Process Canvas feature.
//
// Storage location:
//   ~/Library/Application Support/IndustrialHMI/processcanvases.json
//   (a JSON array of ProcessCanvas objects — all canvases in one file)
//
// Design decisions:
//   • In-memory source of truth: `canvases` array, `activeID` pointer.
//   • Every mutating operation calls save() immediately (no debounce needed —
//     the JSON file is small and writes are infrequent compared to tag polling).
//   • `active` computed property gives a convenient read/write handle to the
//     currently selected canvas without exposing its index.
//   • `navigateToHMIScreen` is a closure injected by MainView.onAppear so that
//     tapping an hmiScreen block in Operate mode can switch the app tab without
//     creating a direct dependency on the navigation hierarchy.

/// Owns all ProcessCanvas documents and persists them to disk.
/// Exposed as an EnvironmentObject so any view can read and mutate the canvas list.
@MainActor
final class ProcessCanvasStore: ObservableObject {

    // MARK: - Published state

    /// All canvases in the app. Order preserved from disk.
    @Published var canvases:  [ProcessCanvas] = []

    /// ID of the canvas currently shown in ProcessCanvasView.
    @Published var activeID:  UUID?

    // MARK: - Navigation callback

    /// Injected by MainView.onAppear. Called when the operator taps an hmiScreen block
    /// in Operate mode — switches the HMI tab to the referenced screen.
    /// Signature: (hmiScreenID: UUID) -> Void
    var navigateToHMIScreen: ((UUID) -> Void)?

    // MARK: - Active canvas accessor

    /// Computed read/write handle for the currently active canvas.
    ///
    /// - get: returns the canvas whose id == activeID, or nil.
    /// - set: writes the new value back into the canvases array at the same index.
    ///        Does NOT call save() — callers must call save() or use one of the
    ///        mutation helpers (addBlock, updateBlock, etc.) that do so automatically.
    var active: ProcessCanvas? {
        get { canvases.first { $0.id == activeID } }
        set {
            guard let v = newValue,
                  let i = canvases.firstIndex(where: { $0.id == v.id })
            else { return }
            canvases[i] = v
        }
    }

    // MARK: - Persistence

    /// File URL: ~/Library/Application Support/IndustrialHMI/processcanvases.json
    private let fileURL: URL = {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IndustrialHMI")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("processcanvases.json")
    }()

    init() { load() }

    /// Load all canvases from disk. On first launch (file absent / empty), seeds a default canvas.
    func load() {
        if let data    = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([ProcessCanvas].self, from: data),
           !decoded.isEmpty {
            canvases = decoded
            activeID = canvases.first?.id
        } else {
            seedDefaultCanvas()
        }
    }

    /// Persist the current canvases array to disk atomically.
    func save() {
        if let data = try? JSONEncoder().encode(canvases) {
            try? data.write(to: fileURL)
        }
    }

    // MARK: - Canvas CRUD

    /// Create a new empty canvas with the given name and switch to it.
    func newCanvas(name: String = "New Canvas") {
        let c = ProcessCanvas(name: name)
        canvases.append(c)
        activeID = c.id
        save()
    }

    /// Rename an existing canvas without switching to it.
    func renameCanvas(_ id: UUID, to name: String) {
        guard let i = canvases.firstIndex(where: { $0.id == id }) else { return }
        canvases[i].name = name
        save()
    }

    /// Delete a canvas. Switches activeID to the first remaining canvas.
    func deleteCanvas(_ id: UUID) {
        canvases.removeAll { $0.id == id }
        if activeID == id { activeID = canvases.first?.id }
        save()
    }

    // MARK: - Block CRUD (all operate on the active canvas)

    /// Append a new block to the active canvas and persist immediately.
    func addBlock(_ block: CanvasBlock) {
        guard let i = canvases.firstIndex(where: { $0.id == activeID }) else { return }
        canvases[i].blocks.append(block)
        save()
    }

    /// Replace an existing block (matched by id) in the active canvas and persist.
    func updateBlock(_ block: CanvasBlock) {
        guard let ci = canvases.firstIndex(where: { $0.id == activeID }),
              let bi = canvases[ci].blocks.firstIndex(where: { $0.id == block.id })
        else { return }
        canvases[ci].blocks[bi] = block
        save()
    }

    /// Remove a block from the active canvas by its id and persist.
    func deleteBlock(_ id: UUID) {
        guard let ci = canvases.firstIndex(where: { $0.id == activeID }) else { return }
        canvases[ci].blocks.removeAll { $0.id == id }
        save()
    }

    /// Replace the canvas-level settings (name, bgHex, gridSize, gridVisible) and persist.
    func updateCanvasSettings(_ canvas: ProcessCanvas) {
        if let i = canvases.firstIndex(where: { $0.id == canvas.id }) {
            canvases[i] = canvas
            save()
        }
    }

    // MARK: - Default content

    /// Called on first launch to give the user something to look at.
    /// Creates a "Plant Overview" canvas with a few placeholder blocks.
    private func seedDefaultCanvas() {
        var c = ProcessCanvas(name: "Plant Overview")
        c.blocks = [
            // Area label blocks across the top row
            CanvasBlock(title: "Utilities",     x: 50,  y: 50,  w: 280, h: 180,
                        bgHex: "#0D2137", borderHex: "#1E6B9B",
                        content: .label("Utilities", size: 30)),
            CanvasBlock(title: "Mixing Area",   x: 380, y: 50,  w: 280, h: 180,
                        bgHex: "#0D2137", borderHex: "#1E6B9B",
                        content: .label("Mixing", size: 30)),
            CanvasBlock(title: "Reaction Area", x: 710, y: 50,  w: 280, h: 180,
                        bgHex: "#0D2137", borderHex: "#1E6B9B",
                        content: .label("Reaction", size: 30)),
            // Alarm panel spanning the lower left
            CanvasBlock(title: "Active Alarms", x: 50,  y: 290, w: 360, h: 180,
                        bgHex: "#1A0A0A", borderHex: "#7F1D1D",
                        content: .alarmPanel(max: 4)),
            // Navigation button demonstrating the viewport-jump feature
            CanvasBlock(title: "→ Mixing Detail", x: 460, y: 290, w: 220, h: 80,
                        bgHex: "#0A1628", borderHex: "#1D4ED8",
                        content: .navButton(label: "Mixing Detail", x: 380, y: 50, scale: 2)),
        ]
        canvases = [c]
        activeID = c.id
        save()
    }
}
