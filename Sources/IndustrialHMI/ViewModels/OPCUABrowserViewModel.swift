import Foundation
import Combine

@MainActor
class OPCUABrowserViewModel: ObservableObject {
    // MARK: - Published Properties

    @Published var rootNodes: [OPCUANode] = []
    @Published var flattenedNodes: [OPCUANode] = []
    @Published var selectedNode: OPCUANode?
    @Published var monitoredItems: [MonitoredItem] = []
    @Published var searchText: String = ""
    @Published var isLoading: Bool = false
    private var isBrowsing: Bool = false
    @Published var errorMessage: String?

    @Published var serverConfig: ServerConfiguration = .default
    @Published var isConnected: Bool = false

    // MARK: - Private Properties

    private let opcuaService: OPCUAClientService
    private let tagEngine: TagEngine
    private let alarmManager: AlarmManager
    private var cancellables = Set<AnyCancellable>()
    private var loadedNodes: [String: [OPCUANode]] = [:]  // Cache

    // MARK: - Initialization

    init(opcuaService: OPCUAClientService, tagEngine: TagEngine, alarmManager: AlarmManager) {
        self.opcuaService = opcuaService
        self.tagEngine = tagEngine
        self.alarmManager = alarmManager

        // Mirror connection state
        opcuaService.$connectionState
            .map { $0 == .connected }
            .assign(to: &$isConnected)

        // Load nodes once when connection becomes active
        opcuaService.$connectionState
            .removeDuplicates()
            .filter { $0 == .connected }
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    print("DEBUG BROWSER: Connection ready, loading nodes")
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    await self?.loadRootNodes()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Connection Management

    func connect() async {
        if opcuaService.connectionState == .connected {
            isConnected = true
            await loadRootNodes()
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            try await opcuaService.connect()
            await loadRootNodes()
            Logger.shared.info("Connected to OPC-UA server")
        } catch {
            errorMessage = "Connection failed: \(error.localizedDescription)"
            Logger.shared.error("Connection failed: \(error)")
        }
        isLoading = false
    }

    func disconnect() async {
        rootNodes = []
        flattenedNodes = []
        selectedNode = nil
        loadedNodes.removeAll()
        isConnected = false
        Logger.shared.info("Browser cleared (connection still active)")
    }

    // MARK: - Browse Operations

    func loadRootNodes() async {
        guard !isBrowsing else { diagLog("DIAG [ViewModel] Browse already in progress, skipping"); return }
        isBrowsing = true
        defer { isBrowsing = false }
        isLoading = true
        diagLog("DIAG [ViewModel] loadRootNodes START — connectionState=\(opcuaService.connectionState.rawValue)")

        do {
            let objectsNode = try await opcuaService.browseNode(nodeId: "ns=0;i=85")
            diagLog("DIAG [ViewModel] loadRootNodes got \(objectsNode.count) nodes")
            rootNodes = objectsNode
            updateFlattenedNodes()
        } catch {
            diagLog("DIAG [ViewModel] loadRootNodes ERROR: \(error)")
            errorMessage = "Failed to load root nodes: \(error.localizedDescription)"
            Logger.shared.error("Browse root failed: \(error)")
        }

        diagLog("DIAG [ViewModel] loadRootNodes END — flattenedNodes=\(flattenedNodes.count)")
        isLoading = false
    }

    func toggleNodeExpansion(_ node: OPCUANode) async {
        print("DEBUG: toggleNodeExpansion called for \(node.displayName), currently expanded=\(node.isExpanded)")
        rootNodes = rootNodes.map { updateNodeRecursive($0, targetId: node.id) }

        if let updatedNode = findNode(withNodeId: node.nodeId, in: rootNodes),
           updatedNode.isExpanded && updatedNode.children.isEmpty {
            print("DEBUG: Loading children for \(node.displayName)")
            await loadChildren(for: updatedNode)
        }
        updateFlattenedNodes()
    }

    private func updateNodeRecursive(_ node: OPCUANode, targetId: String) -> OPCUANode {
        var updated = node
        if node.id == targetId {
            updated.isExpanded.toggle()
            print("DEBUG: Toggled \(node.displayName) to expanded=\(updated.isExpanded)")
        }
        if !updated.children.isEmpty {
            updated.children = updated.children.map { updateNodeRecursive($0, targetId: targetId) }
        }
        return updated
    }

    private func findNode(withNodeId nodeId: String, in nodes: [OPCUANode]) -> OPCUANode? {
        for node in nodes {
            if node.nodeId == nodeId { return node }
            if let found = findNode(withNodeId: nodeId, in: node.children) { return found }
        }
        return nil
    }

    func loadChildren(for node: OPCUANode) async {
        if let cached = loadedNodes[node.nodeId] {
            print("DEBUG: Using cached children for \(node.displayName)")
            updateNodeChildren(nodeId: node.id, children: cached)
            return
        }
        do {
            print("DEBUG: Fetching children for \(node.displayName) with nodeId=\(node.nodeId)")
            let children = try await opcuaService.browseNode(nodeId: node.nodeId)
            print("DEBUG: Fetched \(children.count) children for \(node.displayName)")
            loadedNodes[node.nodeId] = children
            updateNodeChildren(nodeId: node.id, children: children)
        } catch {
            print("DEBUG: Error loading children: \(error)")
            errorMessage = "Failed to load children: \(error.localizedDescription)"
        }
    }

    private func updateNodeChildren(nodeId: String, children: [OPCUANode]) {
        rootNodes = rootNodes.map { updateNodeChildrenRecursive($0, targetId: nodeId, children: children) }
        updateFlattenedNodes()
    }

    private func updateNodeChildrenRecursive(_ node: OPCUANode, targetId: String, children: [OPCUANode]) -> OPCUANode {
        var updated = node
        if node.id == targetId {
            updated.children = children
            print("DEBUG: Updated \(node.displayName) with \(children.count) children")
        } else if !updated.children.isEmpty {
            updated.children = updated.children.map {
                updateNodeChildrenRecursive($0, targetId: targetId, children: children)
            }
        }
        return updated
    }

    // MARK: - Monitored Items (synced to TagEngine + AlarmManager)

    func addToMonitoredItems(_ node: OPCUANode) async {
        print("DEBUG MONITOR: Attempting to add \(node.displayName) with nodeId=\(node.nodeId)")
        guard node.nodeClass == .variable else {
            errorMessage = "Only variables can be monitored"
            return
        }
        if monitoredItems.contains(where: { $0.nodeId == node.nodeId }) {
            errorMessage = "Node already monitored"
            return
        }

        let item = MonitoredItem(nodeId: node.nodeId, displayName: node.displayName)

        // Create a Tag in TagEngine so it appears in Tags, Alarms, and Trends views
        let tag = Tag(
            name: node.displayName,
            nodeId: node.nodeId,
            value: .none,
            quality: .uncertain,
            description: node.browseName
        )
        tagEngine.addTag(tag)

        do {
            print("DEBUG MONITOR: Calling subscribe for \(node.nodeId)")

            // Capture by value to avoid retain cycle
            let tagName = node.displayName
            let tagEngine = self.tagEngine
            let alarmManager = self.alarmManager

            try await opcuaService.subscribe(to: [item.nodeId]) { [weak self] nodeId, value, quality, timestamp in
                Task { @MainActor in
                    // Update the browser's monitored item panel
                    self?.updateMonitoredItem(nodeId: nodeId, value: value, quality: quality, timestamp: timestamp)
                    // Keep TagEngine in sync — this feeds Tags, Trends, and Alarm checking
                    tagEngine.updateTag(name: tagName, value: value, quality: quality, timestamp: timestamp)
                    if let updatedTag = tagEngine.getTag(named: tagName) {
                        alarmManager.checkAlarms(for: updatedTag)
                    }
                }
            }

            monitoredItems.append(item)
            Logger.shared.info("Added monitored item: \(node.displayName)")

        } catch {
            // Roll back the tag we just added if subscription failed
            tagEngine.removeTag(named: node.displayName)
            errorMessage = "Failed to add monitored item: \(error.localizedDescription)"
        }
    }

    func removeMonitoredItem(_ item: MonitoredItem) async {
        monitoredItems.removeAll { $0.id == item.id }
        // Remove the corresponding Tag so it disappears from Tags, Alarms, Trends
        tagEngine.removeTag(named: item.displayName)
        Logger.shared.info("Removed monitored item: \(item.displayName)")
    }

    private func updateMonitoredItem(nodeId: String, value: TagValue, quality: TagQuality, timestamp: Date) {
        if let index = monitoredItems.firstIndex(where: { $0.nodeId == nodeId }) {
            monitoredItems[index].currentValue = value
            monitoredItems[index].quality = quality
            monitoredItems[index].timestamp = timestamp
        }
    }

    // MARK: - Tree Helpers

    private func updateFlattenedNodes() {
        flattenedNodes = flattenTree(nodes: rootNodes)
    }

    private func flattenTree(nodes: [OPCUANode], level: Int = 0) -> [OPCUANode] {
        var result: [OPCUANode] = []
        for node in nodes {
            var nodeWithLevel = node
            nodeWithLevel.level = level
            result.append(nodeWithLevel)
            if node.isExpanded {
                result.append(contentsOf: flattenTree(nodes: node.children, level: level + 1))
            }
        }
        return result
    }

    // MARK: - Search

    func searchNodes(query: String) {
        guard !query.isEmpty else {
            updateFlattenedNodes()
            return
        }
        flattenedNodes = flattenedNodes.filter {
            $0.displayName.localizedCaseInsensitiveContains(query) ||
            $0.browseName.localizedCaseInsensitiveContains(query) ||
            $0.nodeId.localizedCaseInsensitiveContains(query)
        }
    }
}
