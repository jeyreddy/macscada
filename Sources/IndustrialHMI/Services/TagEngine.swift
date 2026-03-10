import Foundation
import Combine

// MARK: - TagEngine.swift
//
// Central in-memory store and update engine for all live process tags.
// TagEngine is the @MainActor single source of truth for tag values, quality,
// and metadata during a running session.
//
// ── Tag update flow ───────────────────────────────────────────────────────────
//   OPC-UA subscription callback
//     ↓ TagEngine.updateTag(name:value:quality:)
//   1. LKG (Last-Known-Good) holdoff check:
//      If quality is bad/uncertain AND consecutiveBadPolls < lkgHoldoffPolls,
//      hold the previous good value and suppress the UI + historian write.
//      This prevents single-poll glitches from flashing red and polluting history.
//   2. Analog deadband check:
//      If |newValue - lastGoodValue| < Configuration.analogDeadband,
//      skip the historian write (value hasn't changed enough to record).
//   3. Update tags[name] with new value/quality/timestamp.
//   4. Re-evaluate dependent calculated tags via expression dependency graph.
//   5. Update totalizer accumulators.
//   6. Call onTagUpdated(tag) → AlarmManager.checkAlarms + CommunityService.broadcast.
//   7. Append to historianBatch (flushed every 5 s or 100 entries).
//
// ── Expression dependency graph ───────────────────────────────────────────────
//   When a calculated tag "{A} + {B}" is created:
//     expressionDeps["calcTag"]      = {"A", "B"}
//     expressionDependents["A"]      += {"calcTag"}
//     expressionDependents["B"]      += {"calcTag"}
//   On every update to "A" or "B", TagEngine re-evaluates "calcTag".
//   ExpressionEvaluator resolves "{tagName}" references from the tags dictionary.
//
// ── Totalizer state machine ───────────────────────────────────────────────────
//   A totalizer tag accumulates: total += sourceValue × Δt (seconds)
//   On each update to the source tag:
//     Δt = now - lastTimestamp (capped at 5 s to handle gaps)
//     total += sourceValue × Δt
//   resetTotalizer(tagName:) sets accumulated = 0 and increments resetCount.
//   The current total is published as an analog TagValue.
//
// ── Historian batch flush ─────────────────────────────────────────────────────
//   historianBatch accumulates writes between flush cycles.
//   startBatchFlushTimer() fires every Configuration.historianWriteInterval (5 s).
//   Flush is also triggered immediately when batch size reaches
//   Configuration.historianBatchSize (100).
//   Each flush is a single SQLite transaction in the Historian actor.
//
// ── Simulation mode ───────────────────────────────────────────────────────────
//   startSimulation() starts a 1-second timer that generates sinusoidal values
//   for all analog tags and toggles digital tags, populating the UI without hardware.
//   Useful for development and demos when no OPC-UA server is available.
//
// ── Write confirmation pattern ────────────────────────────────────────────────
//   Operator write requests follow a two-phase pattern:
//     1. TagEngine.requestWrite() → creates WriteRequest, appends to pendingWriteRequests
//     2. DataService.confirmWrite() → executes OPC-UA write, calls resolveWrite()
//   resolveWrite(request, success: true) removes the request from pendingWriteRequests.
//   resolveWrite(request, success: false) also removes it (caller shows error alert).

/// Central tag engine managing real-time process data.
@MainActor
class TagEngine: ObservableObject {
    // MARK: - Published Properties

    @Published var tags: [String: Tag] = [:]
    @Published var tagCount: Int = 0
    /// Operator write requests awaiting confirmation.
    @Published var pendingWriteRequests: [WriteRequest] = []
    
    // MARK: - Callbacks

    /// Called on the main actor whenever a tag value is updated (simulation or OPC-UA).
    var onTagUpdated: ((Tag) -> Void)?

    // MARK: - Private Properties

    private var subscriptions = Set<AnyCancellable>()
    var historian: Historian?          // internal — AlarmManager borrows this reference
    private var simulationTimer: Timer?

    /// Called on @MainActor once the Historian finishes async init.
    /// DataService uses this to wire historian into AlarmManager/RecipeStore/Scheduler
    /// and trigger their loadFromDB() — ensuring they run after the DB is ready.
    var onHistorianReady: ((Historian) -> Void)?

    // MARK: - Expression Dependency Graph

    /// calcTag → set of tag names it reads from.
    private var expressionDeps: [String: Set<String>] = [:]
    /// inputTag → set of calc tags that must be re-evaluated when it changes.
    private var expressionDependents: [String: Set<String>] = [:]

    // MARK: - Totalizer State

    private struct TotalizerState {
        var sourceTagName:    String
        var accumulatedValue: Double = 0.0
        var lastTimestamp:    Date?  = nil
        var resetCount:       Int    = 0
    }

    /// totalizerTagName → state. Rebuilt from persisted tags on boot.
    private var totalizerStates: [String: TotalizerState] = [:]

    // MARK: - Composite Tag Dependencies

    /// sourceTagName → set of composite tag names that include it as a member.
    private var compositeSources: [String: Set<String>] = [:]

    // MARK: - Cache Layer

    /// Per-tag cache entry tracking the last confirmed good value and bad-poll streak.
    private struct CacheEntry {
        var lastGoodValue: Double
        var lastGoodTimestamp: Date
        var consecutiveBadPolls: Int = 0
    }

    /// In-memory value cache keyed by tag name.
    private var valueCache: [String: CacheEntry] = [:]

    /// Pending historian writes accumulated between flush cycles.
    private var historianBatch: [(tagName: String, value: Double, timestamp: Date)] = []

    // MARK: - Initialization

    init() {
        // Historian uses async init (actor-isolated); initialize it asynchronously.
        self.historian = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let h = try await Historian()
                self.historian = h
                Logger.shared.info("Tag engine initialized with historian")
                self.onHistorianReady?(h)   // wire AlarmManager/Recipes/Scheduler
                await self.loadPersistedTags(historian: h)
            } catch {
                Logger.shared.error("Failed to initialize historian: \(error)")
            }
        }

        // Start the periodic historian-batch flush timer.
        startBatchFlushTimer()
    }

    private func loadPersistedTags(historian: Historian) async {
        do {
            let savedTags = try await historian.loadTagConfigs()
            for tag in savedTags {
                if tags[tag.name] == nil {   // don't overwrite live values
                    tags[tag.name] = tag
                }
            }
            tagCount = tags.count
            // Rebuild expression dependency graph for all persisted calculated tags.
            for tag in savedTags where tag.dataType == .calculated {
                if let expr = tag.expression {
                    let deps = ExpressionParser.extractTagRefs(from: expr)
                    expressionDeps[tag.name] = deps
                    for dep in deps {
                        expressionDependents[dep, default: []].insert(tag.name)
                    }
                }
            }

            // Rebuild totalizer states for persisted totalizer tags.
            for tag in savedTags where tag.dataType == .totalizer {
                if let sourceTagName = tag.expression {
                    totalizerStates[tag.name] = TotalizerState(sourceTagName: sourceTagName)
                }
            }

            // Rebuild composite source map for persisted composite tags.
            for tag in savedTags where tag.dataType == .composite {
                if let members = tag.compositeMembers {
                    for member in members {
                        compositeSources[member.tagName, default: []].insert(tag.name)
                    }
                }
            }
            Logger.shared.info("Restored \(savedTags.count) tag configs from database")
        } catch {
            Logger.shared.error("Failed to load tag configs: \(error)")
        }
    }
    
    // MARK: - Tag Management
    
    /// Add a new tag to the engine and persist its config.
    func addTag(_ tag: Tag) {
        tags[tag.name] = tag
        tagCount = tags.count
        Logger.shared.debug("Added tag: \(tag.name)")
        if let h = historian {
            Task { try? await h.saveTagConfig(tag) }
        }
    }

    /// Remove a tag from the engine and delete its persisted config.
    func removeTag(named name: String) {
        tags.removeValue(forKey: name)
        valueCache.removeValue(forKey: name)
        tagCount = tags.count
        Logger.shared.debug("Removed tag: \(name)")
        if let h = historian {
            Task { try? await h.deleteTagConfig(name: name) }
        }
    }
    
    // MARK: - Remote Tags (Community Federation)

    /// Add or update a tag received from a remote community peer.
    /// Remote tags are stored in-memory only — they are NOT persisted to SQLite and
    /// NOT fanned out via `onTagUpdated` (to prevent echo back to the community).
    func addRemoteTag(_ tag: Tag) {
        if tags[tag.name] == nil {
            tags[tag.name] = tag
            tagCount = tags.count
        } else {
            tags[tag.name]?.value     = tag.value
            tags[tag.name]?.quality   = tag.quality
            tags[tag.name]?.timestamp = tag.timestamp
        }
    }

    /// Remove all remote tags for a given site prefix (e.g., "SiteA").
    func removeRemoteTags(sitePrefix: String) {
        let prefix = "\(sitePrefix)/"
        let remoteNames = tags.keys.filter { $0.hasPrefix(prefix) }
        for name in remoteNames {
            tags.removeValue(forKey: name)
        }
        tagCount = tags.count
    }

    // MARK: - Calculated Tags

    /// Register a calculated tag whose value is derived from an expression over other tags.
    ///
    /// Expression syntax:
    ///   - Tag references:  `{TagName}`
    ///   - Arithmetic:      `+  -  *  /`
    ///   - Comparison:      `>  <  >=  <=  ==  !=`  (result is 1.0 or 0.0)
    ///   - Logical:         `&&  ||  !`
    ///   - Ternary:         `condition ? valueA : valueB`
    ///   - IF/THEN/ELSE:    `IF {A} > 80 THEN 1 ELSE 0`
    ///   - Functions:       `abs  sqrt  round  floor  ceil  sign  min  max  avg  sum  clamp  if`
    ///
    /// Throws `ExprError.syntaxError` if the expression is invalid,
    /// or `ExprError.circularDependency` if registering would create a cycle.
    func addCalculatedTag(
        name: String,
        expression: String,
        unit: String? = nil,
        description: String? = nil,
        dataType: TagDataType = .analog
    ) throws {
        // Validate syntax up-front
        _ = try ExpressionParser.parse(expression)

        // Extract dependency set
        let deps = ExpressionParser.extractTagRefs(from: expression)

        // Cycle detection: can we reach `name` from any of its deps through existing graph?
        if hasCycle(from: name, newDeps: deps) {
            throw ExprError.circularDependency(name)
        }

        // Remove old registration if this is an update
        unregisterCalcTag(name)

        // Create the tag
        let tag = Tag(
            name:        name,
            nodeId:      "calc:\(name)",
            value:       .analog(0),
            quality:     .uncertain,
            unit:        unit,
            description: description,
            dataType:    dataType,
            expression:  expression
        )
        addTag(tag)

        // Register in dependency graph
        expressionDeps[name] = deps
        for dep in deps {
            expressionDependents[dep, default: []].insert(name)
        }

        // Evaluate immediately with current tag values
        evaluateCalcTag(name)
        Logger.shared.info("Calculated tag '\(name)' registered: \(expression)")
    }

    /// Update the expression on an existing calculated tag.
    func updateCalculatedTag(name: String, expression: String) throws {
        guard let existing = tags[name] else { return }
        try addCalculatedTag(
            name:        name,
            expression:  expression,
            unit:        existing.unit,
            description: existing.description,
            dataType:    existing.dataType
        )
    }

    /// Remove a calculated tag and clean up its dependency graph entries.
    func removeCalculatedTag(name: String) {
        unregisterCalcTag(name)
        removeTag(named: name)
    }

    // MARK: - Expression Evaluation (private)

    private func unregisterCalcTag(_ name: String) {
        if let deps = expressionDeps.removeValue(forKey: name) {
            for dep in deps {
                expressionDependents[dep]?.remove(name)
                if expressionDependents[dep]?.isEmpty == true {
                    expressionDependents.removeValue(forKey: dep)
                }
            }
        }
    }

    /// Re-evaluate all calculated tags that list `tagName` as a direct dependency.
    private func reevaluateExpressionsDepending(on tagName: String) {
        guard let dependents = expressionDependents[tagName] else { return }
        for calcName in dependents {
            evaluateCalcTag(calcName)
        }
    }

    /// Evaluate the expression for one calculated tag and update its value in-place.
    private func evaluateCalcTag(_ name: String) {
        guard let tag = tags[name], let expr = tag.expression else { return }
        let result = ExpressionEvaluator.evaluate(expr, tags: tags)
        // Convert Double result to .digital when the tag was registered as digital
        let finalValue: TagValue
        if tag.dataType == .digital, case .analog(let d) = result.value {
            finalValue = .digital(d != 0)
        } else {
            finalValue = result.value
        }
        // Directly update without going through the LKG/deadband cache for calc tags
        var updated = tag
        updated.value   = finalValue
        updated.quality = result.quality
        updated.timestamp = Date()
        tags[name] = updated
        // Cascade to calc tags that depend on this one (no cycle possible by construction)
        reevaluateExpressionsDepending(on: name)
        onTagUpdated?(updated)
    }

    /// Returns true if adding edges `name → newDeps` would create a cycle
    /// in the existing expression dependency graph.
    private func hasCycle(from name: String, newDeps: Set<String>) -> Bool {
        var visited = Set<String>()
        func canReach(_ node: String) -> Bool {
            if node == name { return true }
            guard visited.insert(node).inserted else { return false }
            return expressionDeps[node]?.contains(where: canReach) ?? false
        }
        return newDeps.contains(where: canReach)
    }

    // MARK: - Composite Tags

    /// Register a composite tag that aggregates values from multiple source tags,
    /// potentially spanning different drivers (OPC-UA, MQTT, Modbus, EtherNet/IP).
    /// The result is historised just like any other tag.
    func addCompositeTag(
        name: String,
        members: [CompositeMember],
        aggregation: CompositeAggregation,
        unit: String? = nil,
        description: String? = nil
    ) throws {
        guard !members.isEmpty else {
            throw ExprError.syntaxError("Composite tag '\(name)' requires at least one member.")
        }
        // Remove previous registration if updating
        if tags[name]?.dataType == .composite { removeCompositeTag(name: name) }

        var tag = Tag(
            name:                name,
            nodeId:              "composite:\(name)",
            value:               aggregation == .andAll || aggregation == .orAny
                                     ? .digital(false) : .analog(0),
            quality:             .uncertain,
            unit:                unit,
            description:         description,
            dataType:            .composite,
            compositeMembers:    members,
            compositeAggregation: aggregation
        )
        addTag(tag)

        // Register source dependencies
        for member in members {
            compositeSources[member.tagName, default: []].insert(name)
        }

        // Compute initial value
        evaluateCompositeTag(name)
        Logger.shared.info("Composite tag '\(name)' registered (\(aggregation.rawValue), \(members.count) members)")
    }

    /// Remove a composite tag and clean up source dependency entries.
    func removeCompositeTag(name: String) {
        if let tag = tags[name], let members = tag.compositeMembers {
            for member in members {
                compositeSources[member.tagName]?.remove(name)
                if compositeSources[member.tagName]?.isEmpty == true {
                    compositeSources.removeValue(forKey: member.tagName)
                }
            }
        }
        removeTag(named: name)
    }

    /// Evaluate a composite tag from its current member values.
    /// Called whenever any member source tag updates.
    private func evaluateCompositeTag(_ name: String) {
        guard let tag = tags[name],
              tag.dataType == .composite,
              let members     = tag.compositeMembers,
              let aggregation = tag.compositeAggregation else { return }

        let values: [Double] = members.compactMap { tags[$0.tagName]?.value.numericValue }
        guard !values.isEmpty else { return }

        let result: TagValue
        switch aggregation {
        case .average: result = .analog(values.reduce(0, +) / Double(values.count))
        case .sum:     result = .analog(values.reduce(0, +))
        case .minimum: result = .analog(values.min()!)
        case .maximum: result = .analog(values.max()!)
        case .andAll:  result = .digital(values.allSatisfy { $0 != 0 })
        case .orAny:   result = .digital(values.contains   { $0 != 0 })
        }

        var updated = tag
        updated.value     = result
        updated.quality   = .good
        updated.timestamp = Date()
        tags[name] = updated
        if let num = result.numericValue, historian != nil, tag.historianEnabled {
            historianBatch.append((tagName: name, value: num, timestamp: updated.timestamp))
        }
        onTagUpdated?(updated)
    }

    // MARK: - Operator Write Model

    /// Stage a write request for operator confirmation.
    /// Returns nil if the tag doesn't exist.
    @discardableResult
    func requestWrite(tagName: String, newValue: TagValue, requestedBy: String = "Operator") -> WriteRequest? {
        guard let tag = tags[tagName] else { return nil }
        let req = WriteRequest(
            tagName: tagName,
            nodeId: tag.nodeId,
            currentValue: tag.value,
            newValue: newValue,
            requestedBy: requestedBy
        )
        pendingWriteRequests.append(req)
        return req
    }

    /// Cancel a staged request without writing.
    func cancelWrite(_ request: WriteRequest) {
        pendingWriteRequests.removeAll { $0.id == request.id }
    }

    /// Called by DataService after the OPC-UA write completes (or fails).
    /// On success the tag value is updated immediately; on failure the pending entry is just removed.
    func resolveWrite(_ request: WriteRequest, success: Bool) {
        pendingWriteRequests.removeAll { $0.id == request.id }
        if success {
            updateTag(name: request.tagName, value: request.newValue, quality: .good, timestamp: Date())
        }
    }

    /// Update tag value — applies LKG holdoff, analog deadband, and historian batching.
    func updateTag(
        name: String,
        value: TagValue,
        quality: TagQuality = .good,
        timestamp: Date = Date()
    ) {
        guard var tag = tags[name] else { return }

        // ── LKG (Last-Known-Good) Holdoff ─────────────────────────────────────
        // Absorb single-poll quality blips: only propagate uncertain/bad to the UI
        // after lkgHoldoffPolls consecutive bad reads.
        if quality != .good {
            var entry = valueCache[name] ?? CacheEntry(
                lastGoodValue: tag.value.numericValue ?? 0,
                lastGoodTimestamp: timestamp
            )
            entry.consecutiveBadPolls += 1
            valueCache[name] = entry
            guard entry.consecutiveBadPolls >= Configuration.lkgHoldoffPolls else {
                return  // hold last-good value in UI until threshold is reached
            }
            // Threshold reached — fall through and propagate uncertain to UI.

        } else {
            // Good quality: reset bad-poll streak.
            if valueCache[name] != nil { valueCache[name]!.consecutiveBadPolls = 0 }

            // ── Analog Deadband ───────────────────────────────────────────────
            // Suppress SwiftUI update + historian write when the new value has not
            // moved enough to matter.  Digital / string values always pass through.
            if case .analog(let newNum) = value {
                if let entry = valueCache[name],
                   abs(newNum - entry.lastGoodValue) < Configuration.analogDeadband {
                    return  // within deadband — skip update entirely
                }
                valueCache[name] = CacheEntry(
                    lastGoodValue: newNum,
                    lastGoodTimestamp: timestamp,
                    consecutiveBadPolls: 0
                )
            }
        }

        // ── Update in-memory tag store (triggers SwiftUI) ─────────────────────
        tag.value   = value
        tag.quality = quality
        tag.timestamp = timestamp
        tags[name] = tag

        // ── Batch historian write ──────────────────────────────────────────────
        if quality == .good, let num = value.numericValue, historian != nil, tag.historianEnabled {
            historianBatch.append((tagName: name, value: num, timestamp: timestamp))
            if historianBatch.count >= Configuration.historianBatchSize {
                flushHistorianBatch()   // flush immediately when batch is full
            }
        }

        // Re-evaluate any calculated tags that depend on this one.
        reevaluateExpressionsDepending(on: name)

        // Re-evaluate composite tags that include this tag as a member.
        if let dependentComposites = compositeSources[name] {
            for compName in dependentComposites {
                evaluateCompositeTag(compName)
            }
        }

        // Accumulate into any totalizer tags that use this tag as their source.
        if let v = value.numericValue {
            for (totName, var state) in totalizerStates where state.sourceTagName == name {
                if let lastTs = state.lastTimestamp {
                    let dt = max(0, timestamp.timeIntervalSince(lastTs))
                    state.accumulatedValue += v * dt
                }
                state.lastTimestamp      = timestamp
                totalizerStates[totName] = state
                if tags[totName] != nil {
                    tags[totName]?.value     = .analog(state.accumulatedValue)
                    tags[totName]?.timestamp = timestamp
                    tags[totName]?.quality   = quality
                    onTagUpdated?(tags[totName]!)
                }
            }
        }

        // Notify observers (e.g. AlarmManager).
        onTagUpdated?(tags[name]!)
        Logger.shared.debug("Updated tag: \(name)")
    }

    // MARK: - Totalizer Management

    /// Register a totalizer tag whose value is the running integral of a source tag over time.
    /// `expression` field stores the source tag name for persistence/reload.
    func addTotalizerTag(
        name: String,
        sourceTagName: String,
        unit: String? = nil,
        description: String? = nil
    ) throws {
        guard tags[name] == nil else {
            throw ExprError.syntaxError("A tag named '\(name)' already exists.")
        }
        guard tags[sourceTagName] != nil else {
            throw ExprError.syntaxError("Source tag '\(sourceTagName)' not found.")
        }
        let tag = Tag(
            name:        name,
            nodeId:      "totalizer:\(name)",
            value:       .analog(0),
            quality:     .good,
            unit:        unit,
            description: description,
            dataType:    .totalizer,
            expression:  sourceTagName     // stored for DB round-trip
        )
        addTag(tag)
        totalizerStates[name] = TotalizerState(sourceTagName: sourceTagName)
        Logger.shared.info("Totalizer tag '\(name)' registered (source: \(sourceTagName))")
    }

    /// Reset a totalizer's accumulated value to zero.
    func resetTotalizer(name: String) {
        guard totalizerStates[name] != nil else { return }
        totalizerStates[name]!.accumulatedValue = 0.0
        totalizerStates[name]!.lastTimestamp    = nil
        totalizerStates[name]!.resetCount      += 1
        // Update live tag value to zero
        if tags[name] != nil {
            tags[name]!.value     = .analog(0)
            tags[name]!.timestamp = Date()
            onTagUpdated?(tags[name]!)
        }
        Logger.shared.info("Totalizer '\(name)' reset to 0 (resets: \(totalizerStates[name]!.resetCount))")
    }

    /// Remove a totalizer tag from the engine.
    func removeTotalizerTag(name: String) {
        totalizerStates.removeValue(forKey: name)
        removeTag(named: name)
        Logger.shared.info("Totalizer tag '\(name)' removed")
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
        flushHistorianBatch()   // drain any pending writes before stopping
        Logger.shared.info("Simulation stopped")
    }

    // MARK: - Historian Batch Flush

    /// Write all pending historian entries in a single SQLite transaction and clear the queue.
    private func flushHistorianBatch() {
        guard !historianBatch.isEmpty, let historian else { return }
        let batch = historianBatch
        historianBatch.removeAll(keepingCapacity: true)
        Task { try? await historian.logBatch(batch) }
    }

    /// Start a repeating Task that flushes the historian batch every `historianWriteInterval` seconds.
    private func startBatchFlushTimer() {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Configuration.historianWriteInterval))
                self?.flushHistorianBatch()
            }
        }
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
            let points = try? await historian.getHistory(for: name, from: startTime, to: endTime, maxPoints: maxPoints)
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
