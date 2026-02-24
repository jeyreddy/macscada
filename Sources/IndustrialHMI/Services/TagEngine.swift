import Foundation
import Combine

/// Central tag engine managing real-time process data
@MainActor
class TagEngine: ObservableObject {
    // MARK: - Published Properties
    
    @Published var tags: [String: Tag] = [:]
    @Published var tagCount: Int = 0
    
    // MARK: - Callbacks

    /// Called on the main actor whenever a tag value is updated (simulation or OPC-UA).
    var onTagUpdated: ((Tag) -> Void)?

    // MARK: - Private Properties

    private var subscriptions = Set<AnyCancellable>()
    private let historian: Historian?
    private var simulationTimer: Timer?
    
    // MARK: - Initialization
    
    init() {
        // Initialize historian for data logging
        do {
            self.historian = try Historian()
            Logger.shared.info("Tag engine initialized with historian")
        } catch {
            Logger.shared.error("Failed to initialize historian: \(error)")
            self.historian = nil
        }
        
        // Load sample tags for development
        loadSampleTags()
    }
    
    private func loadSampleTags() {
        // Tags are populated dynamically from the OPC-UA Browser.
        // Double-click any variable node in the Browser to add it here.
        Logger.shared.info("Tag engine ready — add tags from the OPC-UA Browser")
    }
    
    // MARK: - Tag Management
    
    /// Add a new tag to the engine
    func addTag(_ tag: Tag) {
        tags[tag.name] = tag
        tagCount = tags.count
        Logger.shared.debug("Added tag: \(tag.name)")
    }
    
    /// Remove a tag from the engine
    func removeTag(named name: String) {
        tags.removeValue(forKey: name)
        tagCount = tags.count
        Logger.shared.debug("Removed tag: \(name)")
    }
    
    /// Update tag value
    func updateTag(
        name: String,
        value: TagValue,
        quality: TagQuality = .good,
        timestamp: Date = Date()
    ) {
        if var tag = tags[name] {
            tag.value = value
            tag.quality = quality
            tag.timestamp = timestamp
            tags[name] = tag
            
            // Log to historian if enabled
            if let historian = historian, quality == .good {
                Task {
                    try? await historian.logValue(
                        tagName: name,
                        value: value,
                        timestamp: timestamp
                    )
                }
            }

            // Notify observers (e.g. AlarmManager in simulation mode)
            onTagUpdated?(tags[name]!)

            Logger.shared.debug("Updated tag: \(name)")
        }
    }
    
    // MARK: - Tag Queries
    
    /// Get tag by name
    func getTag(named name: String) -> Tag? {
        return tags[name]
    }
    
    /// Get all tags as array
    func getAllTags() -> [Tag] {
        return Array(tags.values).sorted { $0.name < $1.name }
    }
    
    /// Get tags filtered by quality
    func getTags(withQuality quality: TagQuality) -> [Tag] {
        return tags.values.filter { $0.quality == quality }
    }
    
    /// Get tags by data type
    func getTags(ofType dataType: TagDataType) -> [Tag] {
        return tags.values.filter { $0.dataType == dataType }
    }
    
    // MARK: - Bulk Operations
    
    /// Clear all tags
    func clearAllTags() {
        tags.removeAll()
        tagCount = 0
        Logger.shared.info("Cleared all tags")
    }
    
    /// Export current tag values as dictionary
    func exportTagSnapshot() -> [String: Any] {
        var snapshot: [String: Any] = [:]
        for (name, tag) in tags {
            snapshot[name] = [
                "value": tag.value,
                "quality": tag.quality.rawValue,
                "timestamp": tag.timestamp
            ]
        }
        return snapshot
    }
    
    /// Get tag statistics
    func getStatistics() -> TagStatistics {
        let goodTags = tags.values.filter { $0.quality == .good }.count
        let badTags = tags.values.filter { $0.quality == .bad }.count
        let uncertainTags = tags.values.filter { $0.quality == .uncertain }.count
        
        return TagStatistics(
            totalTags: tags.count,
            goodTags: goodTags,
            badTags: badTags,
            uncertainTags: uncertainTags
        )
    }
    
    // MARK: - Development Helpers
    
    /// Simulate tag value changes for development
    func startSimulation() {
        guard simulationTimer == nil else { return }

        // Seed default tags if none exist (no OPC-UA tags loaded yet)
        if tags.isEmpty {
            let seeds: [(String, TagValue, String)] = [
                ("Temperature",  .analog(25.0),  "Simulated temperature sensor (°C)"),
                ("Pressure",     .analog(101.3), "Simulated pressure sensor (kPa)"),
                ("FlowRate",     .analog(45.0),  "Simulated flow meter (L/min)"),
                ("Level",        .analog(60.0),  "Simulated tank level (%)"),
                ("MotorSpeed",   .analog(1500.0),"Simulated motor speed (RPM)"),
            ]
            for (name, value, desc) in seeds {
                addTag(Tag(name: name, nodeId: "sim:\(name)", value: value,
                           quality: .good, description: desc))
            }
            Logger.shared.info("Simulation: seeded \(seeds.count) default tags")
        }

        simulationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                
                // Update random tags with new values
                let tagNames = Array(self.tags.keys)
                guard !tagNames.isEmpty else { return }
                
                let randomTagName = tagNames.randomElement()!
                guard let tag = self.tags[randomTagName] else { return }
                
                // Generate new value based on type
                switch tag.value {
                case .analog(let current):
                    // Add some noise to current value
                    let newValue = current + Double.random(in: -2.0...2.0)
                    self.updateTag(
                        name: tag.name,
                        value: .analog(max(0, min(100, newValue)))
                    )
                case .digital:
                    // Randomly flip digital values
                    if Bool.random() {
                        let newValue = !((tag.value.numericValue ?? 0) > 0.5)
                        self.updateTag(
                            name: tag.name,
                            value: .digital(newValue)
                        )
                    }
                case .string:
                    break
                case .none:
                    break
                }
            }
        }
    }

    func stopSimulation() {
        simulationTimer?.invalidate()
        simulationTimer = nil
        Logger.shared.info("Simulation stopped")
    }

    // MARK: - Historian Query Bridge

    func getHistoricalData(
        for tagNames: [String],
        from startTime: Date,
        to endTime: Date,
        maxPoints: Int = 500
    ) async -> [String: [HistoricalDataPoint]] {
        guard let historian else { return [:] }
        var result: [String: [HistoricalDataPoint]] = [:]
        for name in tagNames {
            let points = try? await historian.getHistory(
                for: name, from: startTime, to: endTime, maxPoints: maxPoints)
            result[name] = points ?? []
        }
        return result
    }
}

// MARK: - Tag Statistics

struct TagStatistics {
    let totalTags: Int
    let goodTags: Int
    let badTags: Int
    let uncertainTags: Int
}
