import Foundation

// MARK: - OPCUANode.swift
//
// Data models for the OPC-UA address space browser (OPCUABrowserView).
//
// ── OPC-UA address space ──────────────────────────────────────────────────────
//   An OPC-UA server exposes all its data as a tree of Nodes.
//   Each node has a NodeId (e.g. "ns=2;s=Tank1.Level") and a NodeClass.
//   OPCUABrowserViewModel fetches children lazily from the server via browse() calls.
//
// ── Node classes ─────────────────────────────────────────────────────────────
//   Object   — container for other nodes (e.g. a device or folder)
//   Variable — a node with a live value (temperature, pressure, etc.)
//   Method   — callable procedure on the server
//   ObjectType/VariableType — type definitions
//   DataType — describes the data format (Int32, Float, String, …)
//   View     — custom subset of the address space
//
// ── Relationship to Tag ───────────────────────────────────────────────────────
//   OPCUANode is browse-time metadata — it is NOT the same as Tag.
//   When the operator drags an OPCUANode (Variable class) to the tag list,
//   TagEngine creates a new Tag with nodeId = node.nodeId and name = node.displayName.
//   After that, TagEngine polls the nodeId via OPC-UA subscriptions.

/// Represents a node in the OPC-UA address space.
struct OPCUANode: Identifiable, Hashable {
    let id: String  // NodeId as string
    let nodeId: String
    let browseName: String
    let displayName: String
    let nodeClass: NodeClass
    let hasChildren: Bool
    var isExpanded: Bool = false
    var children: [OPCUANode] = []
    
    // For tree view
    let parentId: String?
    var level: Int
    
    init(
        nodeId: String,
        browseName: String,
        displayName: String,
        nodeClass: NodeClass,
        hasChildren: Bool,
        parentId: String? = nil,
        level: Int = 0
    ) {
        self.id = nodeId
        self.nodeId = nodeId
        self.browseName = browseName
        self.displayName = displayName
        self.nodeClass = nodeClass
        self.hasChildren = hasChildren
        self.parentId = parentId
        self.level = level
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: OPCUANode, rhs: OPCUANode) -> Bool {
        lhs.id == rhs.id
    }
}

/// OPC-UA Node Classes
enum NodeClass: String, Codable, CaseIterable {
    case object = "Object"
    case variable = "Variable"
    case method = "Method"
    case objectType = "ObjectType"
    case variableType = "VariableType"
    case referenceType = "ReferenceType"
    case dataType = "DataType"
    case view = "View"
    
    var icon: String {
        switch self {
        case .object: return "cube.box"
        case .variable: return "v.circle"
        case .method: return "function"
        case .objectType: return "cube"
        case .variableType: return "v.square"
        case .referenceType: return "arrow.triangle.branch"
        case .dataType: return "123.rectangle"
        case .view: return "eye"
        }
    }
    
    var color: String {
        switch self {
        case .object: return "blue"
        case .variable: return "green"
        case .method: return "purple"
        case .objectType: return "cyan"
        case .variableType: return "mint"
        case .referenceType: return "orange"
        case .dataType: return "yellow"
        case .view: return "pink"
        }
    }
}

/// Detailed node attributes
struct NodeAttributes: Identifiable {
    let id: String  // NodeId
    let nodeId: String
    let browseName: String
    let displayName: String
    let nodeClass: NodeClass
    let description: String?
    
    // Variable-specific
    let dataType: String?
    let valueRank: Int?
    let accessLevel: AccessLevel?
    let userAccessLevel: AccessLevel?
    let currentValue: TagValue?
    let timestamp: Date?
    
    // Object-specific
    let eventNotifier: UInt8?
}

/// Access level flags
struct AccessLevel: OptionSet, Codable {
    let rawValue: UInt8
    
    static let currentRead = AccessLevel(rawValue: 1 << 0)
    static let currentWrite = AccessLevel(rawValue: 1 << 1)
    static let historyRead = AccessLevel(rawValue: 1 << 2)
    static let historyWrite = AccessLevel(rawValue: 1 << 3)
    static let semanticChange = AccessLevel(rawValue: 1 << 4)
    
    var description: String {
        var parts: [String] = []
        if contains(.currentRead) { parts.append("Read") }
        if contains(.currentWrite) { parts.append("Write") }
        if contains(.historyRead) { parts.append("HistRead") }
        if contains(.historyWrite) { parts.append("HistWrite") }
        return parts.isEmpty ? "None" : parts.joined(separator: ", ")
    }
}

/// Monitored item
struct MonitoredItem: Identifiable, Codable {
    let id: String  // NodeId
    let nodeId: String
    let displayName: String
    let dataType: String?
    var currentValue: TagValue
    var quality: TagQuality
    var timestamp: Date
    let samplingInterval: TimeInterval
    
    init(
        nodeId: String,
        displayName: String,
        dataType: String? = nil,
        currentValue: TagValue = .none,
        quality: TagQuality = .uncertain,
        timestamp: Date = Date(),
        samplingInterval: TimeInterval = 1.0
    ) {
        self.id = nodeId
        self.nodeId = nodeId
        self.displayName = displayName
        self.dataType = dataType
        self.currentValue = currentValue
        self.quality = quality
        self.timestamp = timestamp
        self.samplingInterval = samplingInterval
    }
}

/// Server connection configuration
struct ServerConfiguration: Codable, Equatable {
    var url: String
    var authMode: AuthenticationMode
    var username: String?
    var password: String?
    var securityPolicy: SecurityPolicy
    var timeout: TimeInterval
    
    static let `default` = ServerConfiguration(
        url: "opc.tcp://mac:4840",
        authMode: .anonymous,
        securityPolicy: .none,
        timeout: 5.0
    )
}

enum AuthenticationMode: String, Codable, CaseIterable {
    case anonymous = "Anonymous"
    case usernamePassword = "Username/Password"
    
    var displayName: String { rawValue }
}

enum SecurityPolicy: String, Codable, CaseIterable {
    case none = "None"
    case basic128Rsa15 = "Basic128Rsa15"
    case basic256 = "Basic256"
    case basic256Sha256 = "Basic256Sha256"
    
    var displayName: String { rawValue }
}
