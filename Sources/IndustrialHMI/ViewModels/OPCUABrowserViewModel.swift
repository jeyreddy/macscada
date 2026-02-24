import Foundation
import Combine

@MainActor
class OPCUABrowserViewModel: ObservableObject {
    // MARK: - Published Properties

    @Published var rootNodes: [OPCUANode] = []
    @Published var flattenedNodes: [OPCUANode] = []
    @Published var selectedNode: OPCUANode?
    @Published var searchText: String = ""
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var isConnected: Bool = false
    @Published var serverConfig: ServerConfiguration = .default

    // MARK: - Private Properties

    private let opcuaService: OPCUAClientService
    private let tagEngine: TagEngine
    private let alarmManager: AlarmManager
    private var cancellables = Set<AnyCancellable>()
    private var loadedNodes: [String: [OPCUANode]] = [:]   // browse cache
    private var isBrowsing: Bool = false

    // Internal subscription registry (no UI — selected nodes go to TagEngine)
    private var subscribedNodeIds: Set<String> = []

    // MARK: - Initialization

    init(opcuaService: OPCUAClientService, tagEngine: TagEngine, alarmManager: AlarmManager) {
        self.opcuaService = opcuaService
        self.tagEngine = tagEngine
        self.alarmManager = alarmManager

        // Mirror connection state
        opcuaService.$connectionState
            .map { $0 == .connected }
            .assign(to: &$isConnected)

        if Configuration.simulationMode {
            // Simulation: build virtual tree from TagEngine tags.
            // Rebuild whenever tags are added/removed.
            tagEngine.$tagCount
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.loadSimulatedNodes()
                }
                .store(in: &cancellables)
            loadSimulatedNodes()
        } else {
            // Real OPC-UA: load root nodes on every (re)connect
            opcuaService.$connectionState
                .removeDuplicates()
                .filter { $0 == .connected }
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in
                        print("DEBUG BROWSER: Connection ready, loading nodes")
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        await self?.loadRootNodes()
                        await self?.resubscribeTags()
                    }
                }
                .store(in: &cancellables)
        }
    }

    // MARK: - Simulation Mode

    /// Build a virtual OPC-UA address space from the TagEngine's current tags.
    /// Shows a "Simulation" folder (expanded by default) containing all tags as variable nodes.
    func loadSimulatedNodes() {
        let allTags = tagEngine.getAllTags()
        guard !allTags.isEmpty else {
            // Show empty-but-connected state: single placeholder folder
            var folder = OPCUANode(
                nodeId: "sim:root",
                browseName: "Simulation",
                displayName: "Simulation",
                nodeClass: .object,
                hasChildren: false,
                parentId: nil,
                level: 0
            )
            folder.isExpanded = true
            rootNodes = [folder]
            updateFlattenedNodes()
            return
        }

        let children: [OPCUANode] = allTags.map { tag in
            OPCUANode(
                nodeId: tag.nodeId,
                browseName: tag.name,
                displayName: tag.name,
                nodeClass: .variable,
                hasChildren: false,
                parentId: "sim:root",
                level: 1
            )
        }

        var folder = OPCUANode(
            nodeId: "sim:root",
            browseName: "Simulation",
            displayName: "Simulation",
            nodeClass: .object,
            hasChildren: true,
            parentId: nil,
            level: 0
        )
        folder.isExpanded = true
        folder.children = children
        rootNodes = [folder]
        updateFlattenedNodes()
    }

    // MARK: - Browse Operations (real OPC-UA)

    func loadRootNodes() async {
        guard !isBrowsing else {
            diagLog("DIAG [ViewModel] Browse already in progress, skipping")
            return
        }
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
        // Toggle the expanded flag on the matching node
        rootNodes = rootNodes.map { updateNodeRecursive($0, targetId: node.id) }

        // If the node is now expanded and has no children loaded yet,
        // fetch them (real OPC-UA only — simulation children are pre-loaded)
        if !Configuration.simulationMode,
           let updatedNode = findNode(withNodeId: node.nodeId, in: rootNodes),
           updatedNode.isExpanded && updatedNode.children.isEmpty {
            await loadChildren(for: updatedNode)
        }
        updateFlattenedNodes()
    }

    private func updateNodeRecursive(_ node: OPCUANode, targetId: String) -> OPCUANode {
        var updated = node
        if node.id == targetId {
            updated.isExpanded.toggle()
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
            updateNodeChildren(nodeId: node.id, children: cached)
            return
        }
        do {
            let children = try await opcuaService.browseNode(nodeId: node.nodeId)
            loadedNodes[node.nodeId] = children
            updateNodeChildren(nodeId: node.id, children: children)
        } catch {
            errorMessage = "Failed to load children: \(error.localizedDescription)"
        }
    }

    private func updateNodeChildren(nodeId: String, children: [OPCUANode]) {
        rootNodes = rootNodes.map { updateNodeChildrenRecursive($0, targetId: nodeId, children: children) }
        updateFlattenedNodes()
    }

    private func updateNodeChildrenRecursive(_ node: OPCUANode, targetId: String,
                                             children: [OPCUANode]) -> OPCUANode {
        var updated = node
        if node.id == targetId {
            updated.children = children
        } else if !updated.children.isEmpty {
            updated.children = updated.children.map {
                updateNodeChildrenRecursive($0, targetId: targetId, children: children)
            }
        }
        return updated
    }

    // MARK: - Add Node as Tag

    /// Double-click (or context menu) on a variable node → add it to TagEngine + subscribe.
    func addTagFromNode(_ node: OPCUANode) async {
        guard node.nodeClass == .variable else { return }

        // Avoid duplicates
        guard !tagEngine.getAllTags().contains(where: { $0.nodeId == node.nodeId }) else { return }

        let tag = Tag(
            name: node.displayName,
            nodeId: node.nodeId,
            value: .none,
            quality: .uncertain,
            description: node.browseName
        )
        tagEngine.addTag(tag)

        // In simulation mode, TagEngine's simulation timer will drive updates — no OPC-UA sub needed.
        guard !Configuration.simulationMode else { return }

        // Real mode: subscribe via OPC-UA for live updates
        guard !subscribedNodeIds.contains(node.nodeId) else { return }
        subscribedNodeIds.insert(node.nodeId)

        let tagName    = node.displayName
        let tagEngine  = self.tagEngine
        let alarmMgr   = self.alarmManager

        do {
            try await opcuaService.subscribe(to: [node.nodeId]) { [weak self] nodeId, value, quality, timestamp in
                Task { @MainActor in
                    tagEngine.updateTag(name: tagName, value: value, quality: quality, timestamp: timestamp)
                    if let updatedTag = tagEngine.getTag(named: tagName) {
                        alarmMgr.checkAlarms(for: updatedTag)
                    }
                    _ = self  // retain self weakly
                }
            }
            Logger.shared.info("Browser: subscribed \(tagName)")
        } catch {
            // Roll back if subscription failed
            tagEngine.removeTag(named: node.displayName)
            subscribedNodeIds.remove(node.nodeId)
            errorMessage = "Failed to subscribe: \(error.localizedDescription)"
        }
    }

    // MARK: - Reconnect Recovery

    /// Re-subscribe all previously-added tags after a Stop → Start cycle.
    private func resubscribeTags() async {
        guard !subscribedNodeIds.isEmpty else { return }
        Logger.shared.info("Browser: re-subscribing \(subscribedNodeIds.count) tag(s)")

        let tagEngine = self.tagEngine
        let alarmMgr  = self.alarmManager

        for nodeId in subscribedNodeIds {
            guard let tag = tagEngine.getAllTags().first(where: { $0.nodeId == nodeId }) else { continue }
            let tagName = tag.name
            do {
                try await opcuaService.subscribe(to: [nodeId]) { nodeId, value, quality, timestamp in
                    Task { @MainActor in
                        tagEngine.updateTag(name: tagName, value: value, quality: quality, timestamp: timestamp)
                        if let updatedTag = tagEngine.getTag(named: tagName) {
                            alarmMgr.checkAlarms(for: updatedTag)
                        }
                    }
                }
            } catch {
                Logger.shared.error("Re-subscribe failed for \(tagName): \(error)")
            }
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
