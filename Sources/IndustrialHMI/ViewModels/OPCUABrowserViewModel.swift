// MARK: - OPCUABrowserViewModel.swift
//
// ViewModel for OPCUABrowserView — manages the OPC-UA address space tree state,
// node browsing, search filtering, and tag creation from selected nodes.
//
// ── Architecture ──────────────────────────────────────────────────────────────
//   @MainActor class — all @Published updates on main thread.
//   OPCUABrowserView uses @StateObject to hold the VM; never recreated on tab switch
//   (view is in MonitorView's ZStack always-alive pattern).
//
// ── Simulation Mode ───────────────────────────────────────────────────────────
//   Configuration.simulationMode = true:
//     loadSimulatedNodes() builds a virtual tree from TagEngine.tags.
//     Subscribed to tagEngine.$tagCount to rebuild when tags added/removed.
//     Allows browsing without a real OPC-UA server.
//   Configuration.simulationMode = false:
//     Subscribes to opcuaService.$connectionState → loads root on .connected.
//     300 ms delay after connect before browse (server init settle time).
//
// ── Node Tree ─────────────────────────────────────────────────────────────────
//   rootNodes: top-level browse results (Objects folder children).
//   loadedNodes: [nodeId → [child]] browse cache (avoid re-browsing expanded nodes).
//   flattenedNodes: depth-first flattened array for List rendering.
//   OPCUANode.level: indent depth (0 = root). OPCUANode.isExpanded / hasChildren.
//   toggleExpansion(_ node:):
//     If not yet loaded: call opcuaService.browseAddressSpace(root: nodeId) → cache.
//     Toggle node.isExpanded → rebuild flattenedNodes via flattenTree().
//
// ── Search ────────────────────────────────────────────────────────────────────
//   searchText: String published; OPCUABrowserView filters flattenedNodes using
//   case-insensitive contains on displayName or nodeId.
//
// ── Tag Creation ──────────────────────────────────────────────────────────────
//   createTagFromNode(_ node:):
//     Only for Variable nodes (node.nodeClass == .variable).
//     name = node.displayName, nodeId = node.nodeId.
//     dataType inferred from node.dataType (UA_NS0ID → TagDataType mapping).
//     tagEngine.addTag(newTag) → persists + subscribes to OPC-UA.
//     alarmManager.alarmConfigs checked: if no config yet, creates a default one.
//
// ── ServerConfiguration ───────────────────────────────────────────────────────
//   Lightweight struct holding browse root nodeId, max depth, timeout.
//   serverConfig.default = {rootNodeId: "ns=0;i=85", maxDepth: 5, timeout: 10s}

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

        // If the tag is already in TagEngine (e.g. restored from DB), don't re-add it —
        // but DO subscribe if it isn't being polled yet (handles the "can't re-add" case).
        let alreadyInEngine = tagEngine.getAllTags().contains(where: { $0.nodeId == node.nodeId })
        if !alreadyInEngine {
            let tag = Tag(
                name: node.displayName,
                nodeId: node.nodeId,
                value: .none,
                quality: .uncertain,
                description: node.browseName
            )
            tagEngine.addTag(tag)
        }

        // In simulation mode, TagEngine's simulation timer will drive updates — no OPC-UA sub needed.
        guard !Configuration.simulationMode else { return }

        // Real mode: subscribe if not already subscribed this session.
        guard !subscribedNodeIds.contains(node.nodeId) else { return }
        subscribedNodeIds.insert(node.nodeId)

        // Resolve tag name from engine in case the node display name differs from stored tag name.
        let tagName   = tagEngine.getAllTags().first(where: { $0.nodeId == node.nodeId })?.name ?? node.displayName
        let tagEngine = self.tagEngine
        let alarmMgr  = self.alarmManager

        do {
            try await opcuaService.subscribe(to: [node.nodeId]) { [weak self] _, value, quality, timestamp in
                Task { @MainActor in
                    tagEngine.updateTag(name: tagName, value: value, quality: quality, timestamp: timestamp)
                    if let updatedTag = tagEngine.getTag(named: tagName) {
                        alarmMgr.checkAlarms(for: updatedTag)
                    }
                    _ = self
                }
            }
            Logger.shared.info("Browser: subscribed \(tagName)")
        } catch {
            if !alreadyInEngine { tagEngine.removeTag(named: node.displayName) }
            subscribedNodeIds.remove(node.nodeId)
            errorMessage = "Failed to subscribe: \(error.localizedDescription)"
        }
    }

    // MARK: - Reconnect Recovery

    /// Re-subscribe all tags currently in TagEngine after a (re)connect.
    /// This covers both tags browsed in the current session AND tags restored from the
    /// historian DB on startup — fixing the "lost link after reconnect" bug.
    private func resubscribeTags() async {
        // All real OPC-UA tags (skip simulation nodeIds).
        let allTags = tagEngine.getAllTags().filter {
            !$0.nodeId.isEmpty && !$0.nodeId.hasPrefix("sim:")
        }
        guard !allTags.isEmpty else { return }
        Logger.shared.info("Browser: re-subscribing \(allTags.count) tag(s) after (re)connect")

        // Sync session tracking set to exactly the current live tag set.
        subscribedNodeIds = Set(allTags.map { $0.nodeId })

        let tagEngine = self.tagEngine
        let alarmMgr  = self.alarmManager

        for tag in allTags {
            let tagName = tag.name
            let nodeId  = tag.nodeId
            do {
                try await opcuaService.subscribe(to: [nodeId]) { _, value, quality, timestamp in
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
