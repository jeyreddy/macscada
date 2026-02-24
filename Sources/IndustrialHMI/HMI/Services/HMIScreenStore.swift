import Foundation
import Combine

// MARK: - HMIScreenStore

/// Owns the single HMI screen layout and persists it as JSON under
/// ~/Library/Application Support/IndustrialHMI/hmi_screen.json.
@MainActor
class HMIScreenStore: ObservableObject {
    @Published var screen: HMIScreen = HMIScreen()

    private let saveURL: URL
    private var saveCancellable: AnyCancellable?

    // MARK: Init

    init() {
        // Resolve save path
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("IndustrialHMI", isDirectory: true)
        saveURL = dir.appendingPathComponent("hmi_screen.json")

        // Create directory if needed
        try? FileManager.default.createDirectory(at: dir,
                                                  withIntermediateDirectories: true)
        load()

        // Debounced auto-save: 0.5 s after any change
        saveCancellable = $screen
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }
    }

    // MARK: Load / Save

    func load() {
        guard FileManager.default.fileExists(atPath: saveURL.path),
              let data = try? Data(contentsOf: saveURL) else { return }
        do {
            screen = try JSONDecoder().decode(HMIScreen.self, from: data)
            Logger.shared.info("HMIScreenStore: loaded \(screen.objects.count) objects")
        } catch {
            Logger.shared.error("HMIScreenStore: load failed — \(error)")
            screen = HMIScreen()   // start fresh on decode error
        }
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(screen)
            try data.write(to: saveURL, options: .atomic)
        } catch {
            Logger.shared.error("HMIScreenStore: save failed — \(error)")
        }
    }

    // MARK: CRUD

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
}
