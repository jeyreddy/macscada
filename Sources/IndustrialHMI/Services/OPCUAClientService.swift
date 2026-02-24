import Foundation
import COPC

@MainActor
class OPCUAClientService: ObservableObject {
    @Published var connectionState: ConnectionState = .disconnected
    @Published var isPolling: Bool = false

    // Accessed only on @MainActor for the nil-guard; the captured OpaquePointer
    // *value* is then passed into opcuaQueue blocks by value — never re-read from
    // self inside those blocks.
    private var client: OpaquePointer?

    private var pollingTimer: Timer?
    // Prevents a slow poll cycle from stacking a second one on top of itself.
    private var isPollInFlight = false

    // Single serial queue — every C library call goes here, nothing else.
    private let opcuaQueue = DispatchQueue(label: "com.industrialhmi.opcua", qos: .userInitiated)

    private var tagCallbacks: [String: [(String, TagValue, TagQuality, Date) -> Void]] = [:]

    enum ConnectionState: String {
        case disconnected = "Disconnected"
        case connecting   = "Connecting"
        case connected    = "Connected"
        case error        = "Error"
    }

    init() {
        Logger.shared.info("OPC-UA Client Service initialized")
    }

    deinit {
        // Capture the raw pointer value; opcuaQueue outlives self (the block
        // retains the queue through GCD's internal reference counting).
        if let c = client {
            opcuaQueue.async {
                UA_Client_disconnect(c)
                UA_Client_delete(c)
            }
        }
    }

    // MARK: - Connection Management

    func connect() async throws {
        // Bail out if already connected OR if a connect is already in flight (.connecting).
        guard connectionState == .disconnected || connectionState == .error else { return }
        connectionState = .connecting

        // Single dispatch to opcuaQueue — ALL C work happens there.
        try await withCheckedThrowingContinuation { continuation in
            self.opcuaQueue.async { [weak self] in
                let newClient = UA_Client_new()
                let config    = UA_Client_getConfig(newClient)
                UA_ClientConfig_setDefault(config)

                let retval = UA_Client_connect(newClient, Configuration.opcuaServerURL)

                if retval == UA_STATUSCODE_GOOD {
                    DispatchQueue.main.async {
                        self?.client = newClient
                        self?.connectionState = .connected
                        Logger.shared.info("OPC-UA connected successfully")
                        continuation.resume()
                    }
                } else {
                    // Delete happens here, on opcuaQueue — correct.
                    UA_Client_delete(newClient)
                    DispatchQueue.main.async {
                        self?.connectionState = .error
                    }
                    continuation.resume(throwing: OPCUAError.connectionFailed(
                        "Connection failed with status code \(retval)"))
                }
            }
        }
    }

    func disconnect() async {
        pollingTimer?.invalidate()
        pollingTimer = nil
        isPolling = false
        tagCallbacks.removeAll()

        guard let clientToDisconnect = client else {
            connectionState = .disconnected
            return
        }

        // Nil self.client *before* queuing teardown.
        // Any pollTags() or browseNode() called after this point will find
        // client == nil and return early without touching opcuaQueue.
        // Any opcuaQueue block that was *already queued* holds a captured copy
        // of the old pointer and will finish before the block below runs,
        // because opcuaQueue is serial.
        client = nil
        connectionState = .disconnected

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.opcuaQueue.async {
                UA_Client_disconnect(clientToDisconnect)
                UA_Client_delete(clientToDisconnect)
                continuation.resume()
            }
        }

        Logger.shared.info("OPC-UA disconnected safely")
    }

    // MARK: - Subscription Management

    func subscribe(to nodeIds: [String],
                   callback: @escaping (String, TagValue, TagQuality, Date) -> Void) async throws {
        guard connectionState == .connected else {
            throw OPCUAError.notConnected
        }

        for nodeId in nodeIds {
            if tagCallbacks[nodeId] == nil {
                tagCallbacks[nodeId] = []
            }
            tagCallbacks[nodeId]?.append(callback)
        }

        if pollingTimer == nil {
            startPolling()
        }
    }

    func startPolling() {
        guard pollingTimer == nil else { return }
        print("DEBUG: Starting polling timer")
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.pollTags()
            }
        }
        isPolling = true
    }

    func pausePolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        isPolling = false
        Logger.shared.info("Polling paused")
    }

    // All tag reads are batched into a single opcuaQueue block — one dispatch
    // per poll cycle regardless of how many tags are subscribed.
    private func pollTags() async {
        guard let capturedClient = client, !isPollInFlight else { return }
        isPollInFlight = true
        defer { isPollInFlight = false }

        // Snapshot keys on MainActor before yielding into the queue.
        let nodeIds = Array(tagCallbacks.keys)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.opcuaQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }

                // Process any pending network events (keepalives, incoming data).
                // This is required to prevent the OPC-UA secure channel from expiring
                // when the client sits idle between polls. Timeout = 0 → non-blocking.
                UA_Client_run_iterate(capturedClient, 0)

                var results: [(nodeId: String, value: TagValue, quality: TagQuality, timestamp: Date)] = []

                for nodeId in nodeIds {
                    var ns: UInt16 = 0
                    var id: UInt32 = 0
                    for part in nodeId.split(separator: ";") {
                        if part.hasPrefix("ns=") { ns = UInt16(part.dropFirst(3)) ?? 0 }
                        else if part.hasPrefix("i=")  { id = UInt32(part.dropFirst(2)) ?? 0 }
                    }

                    let nodeIdC = UA_NODEID_NUMERIC(ns, id)
                    var variant = UA_Variant()
                    if UA_Client_readValueAttribute(capturedClient, nodeIdC, &variant) == UA_STATUSCODE_GOOD {
                        let tagValue = self.convertVariantToTagValue(&variant)
                        UA_Variant_clear(&variant)
                        results.append((nodeId, tagValue, .good, Date()))
                    }
                }

                // Deliver results on MainActor; resume continuation only after
                // delivery so isPollInFlight stays true until we're really done.
                DispatchQueue.main.async { [weak self] in
                    guard let self else {
                        continuation.resume()
                        return
                    }
                    for r in results {
                        for cb in self.tagCallbacks[r.nodeId] ?? [] {
                            cb(r.nodeId, r.value, r.quality, r.timestamp)
                        }
                    }
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Read/Write Operations

    private func readTag(nodeId: String) async throws -> (TagValue, TagQuality, Date) {
        guard let capturedClient = client else {
            throw OPCUAError.notConnected
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.opcuaQueue.async {
                var ns: UInt16 = 0
                var id: UInt32 = 0
                for part in nodeId.split(separator: ";") {
                    if part.hasPrefix("ns=") { ns = UInt16(part.dropFirst(3)) ?? 0 }
                    else if part.hasPrefix("i=")  { id = UInt32(part.dropFirst(2)) ?? 0 }
                }

                let nodeIdC = UA_NODEID_NUMERIC(ns, id)
                var value  = UA_Variant()
                let retval = UA_Client_readValueAttribute(capturedClient, nodeIdC, &value)

                if retval == UA_STATUSCODE_GOOD {
                    let tagValue = self.convertVariantToTagValue(&value)
                    UA_Variant_clear(&value)
                    continuation.resume(returning: (tagValue, .good, Date()))
                } else {
                    continuation.resume(throwing: OPCUAError.readError(
                        "Read failed with status \(retval)"))
                }
            }
        }
    }

    private nonisolated func convertVariantToTagValue(_ variant: UnsafeMutablePointer<UA_Variant>) -> TagValue {
        guard let typePtr = variant.pointee.type else {
            return .none
        }

        let typeName = String(cString: typePtr.pointee.typeName)

        if typeName == "Double" {
            let value = variant.pointee.data.assumingMemoryBound(to: Double.self).pointee
            return .analog(value)
        } else if typeName == "Float" {
            let value = Double(variant.pointee.data.assumingMemoryBound(to: Float.self).pointee)
            return .analog(value)
        } else if typeName == "Int32" {
            let value = Double(variant.pointee.data.assumingMemoryBound(to: Int32.self).pointee)
            return .analog(value)
        } else if typeName == "UInt32" {
            let value = Double(variant.pointee.data.assumingMemoryBound(to: UInt32.self).pointee)
            return .analog(value)
        } else if typeName == "Boolean" {
            let value = variant.pointee.data.assumingMemoryBound(to: Bool.self).pointee
            return .digital(value)
        }

        return .none
    }

    // MARK: - Browse Operations

    func browseNode(nodeId: String) async throws -> [OPCUANode] {
        guard let capturedClient = client else {
            throw OPCUAError.notConnected
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.opcuaQueue.async {
                // Parse NodeId
                var nodeIdC = UA_NODEID_NULL

                if nodeId.contains("i=") {
                    var ns: UInt16 = 0
                    var id: UInt32 = 0
                    for part in nodeId.split(separator: ";") {
                        if part.hasPrefix("ns=") { ns = UInt16(part.dropFirst(3)) ?? 0 }
                        else if part.hasPrefix("i=")  { id = UInt32(part.dropFirst(2)) ?? 0 }
                    }
                    nodeIdC = UA_NODEID_NUMERIC(ns, id)

                } else if nodeId.contains("s=") {
                    var ns: UInt16 = 0
                    var stringId = ""
                    for part in nodeId.split(separator: ";") {
                        if part.hasPrefix("ns=") { ns = UInt16(part.dropFirst(3)) ?? 0 }
                        else if part.hasPrefix("s=")  { stringId = String(part.dropFirst(2)) }
                    }
                    print("DEBUG PARSE: String NodeId - ns=\(ns), string='\(stringId)'")
                    nodeIdC = UA_NODEID_STRING_ALLOC(ns, stringId)

                } else {
                    nodeIdC = UA_NODEID_STRING_ALLOC(0, nodeId)
                }
                // FIX: nodeIdC may own heap memory (string NodeIds); always release it.
                defer { UA_NodeId_clear(&nodeIdC) }

                // Build browse request.
                // FIX: Allocate UA_BrowseDescription through the C library's allocator
                // (UA_malloc) so that UA_BrowseRequest_clear can safely free it with
                // UA_free — avoids the shallow bit-copy / mismatched-allocator bug.
                var browseRequest = UA_BrowseRequest()
                UA_BrowseRequest_init(&browseRequest)
                browseRequest.requestedMaxReferencesPerNode = 0

                guard let descPtr = UA_BrowseDescription_new() else {
                    continuation.resume(throwing: OPCUAError.browseError("Memory allocation failed"))
                    return
                }
                UA_NodeId_copy(&nodeIdC, &descPtr.pointee.nodeId)
                descPtr.pointee.resultMask      = UInt32(UA_BROWSERESULTMASK_ALL.rawValue)
                descPtr.pointee.browseDirection = UA_BROWSEDIRECTION_FORWARD
                descPtr.pointee.referenceTypeId = UA_NODEID_NUMERIC(0, UInt32(UA_NS0ID_HIERARCHICALREFERENCES))
                descPtr.pointee.includeSubtypes = true

                // descPtr is now owned by browseRequest; UA_BrowseRequest_clear will free it.
                browseRequest.nodesToBrowse     = descPtr
                browseRequest.nodesToBrowseSize = 1

                var browseResponse = UA_Client_Service_browse(capturedClient, browseRequest)
                defer {
                    UA_BrowseRequest_clear(&browseRequest)
                    UA_BrowseResponse_clear(&browseResponse)
                }

                print("DEBUG BROWSE: Status code = \(browseResponse.responseHeader.serviceResult)")
                guard browseResponse.responseHeader.serviceResult == UA_STATUSCODE_GOOD else {
                    print("DEBUG BROWSE: Status not GOOD!")
                    continuation.resume(throwing: OPCUAError.browseError("Browse failed"))
                    return
                }

                print("DEBUG BROWSE: resultsSize = \(browseResponse.resultsSize)")
                guard browseResponse.resultsSize > 0 else {
                    print("DEBUG BROWSE: No results!")
                    continuation.resume(returning: [])
                    return
                }

                // Parse results
                let result = browseResponse.results.pointee
                print("DEBUG BROWSE: referencesSize = \(result.referencesSize)")
                print("DEBUG BROWSE: statusCode = \(result.statusCode)")

                var nodes: [OPCUANode] = []
                for i in 0..<Int(result.referencesSize) {
                    let ref         = result.references.advanced(by: i).pointee
                    let nodeIdStr   = self.nodeIdToString(ref.nodeId.nodeId)
                    let displayName = String(cString: ref.displayName.text.data)
                    let browseName  = String(cString: ref.browseName.name.data)
                    let nodeClass   = self.convertNodeClass(ref.nodeClass)
                    let hasChildren = (nodeClass == .object || nodeClass == .objectType)

                    let node = OPCUANode(
                        nodeId:      nodeIdStr,
                        browseName:  browseName,
                        displayName: displayName,
                        nodeClass:   nodeClass,
                        hasChildren: hasChildren,
                        parentId:    nodeId,
                        level:       1
                    )
                    print("DEBUG NODE: \(displayName) - nodeClass=\(nodeClass), hasChildren=\(hasChildren)")
                    nodes.append(node)
                }

                continuation.resume(returning: nodes)
            }
        }
    }

    // MARK: - Helper Methods

    private nonisolated func nodeIdToString(_ nodeId: UA_NodeId) -> String {
        switch nodeId.identifierType {
        case UA_NODEIDTYPE_NUMERIC:
            let result = "ns=\(nodeId.namespaceIndex);i=\(nodeId.identifier.numeric)"
            print("DEBUG NODEID: Numeric -> \(result)")
            return result
        case UA_NODEIDTYPE_STRING:
            let str    = String(cString: nodeId.identifier.string.data)
            let result = "ns=\(nodeId.namespaceIndex);s=\(str)"
            print("DEBUG NODEID: String -> \(result)")
            return result
        default:
            print("DEBUG NODEID: Unknown type, defaulting to ns=\(nodeId.namespaceIndex);i=0")
            return "ns=\(nodeId.namespaceIndex);i=0"
        }
    }

    private nonisolated func convertNodeClass(_ uaNodeClass: UA_NodeClass) -> NodeClass {
        switch uaNodeClass {
        case UA_NODECLASS_OBJECT:        return .object
        case UA_NODECLASS_VARIABLE:      return .variable
        case UA_NODECLASS_METHOD:        return .method
        case UA_NODECLASS_OBJECTTYPE:    return .objectType
        case UA_NODECLASS_VARIABLETYPE:  return .variableType
        case UA_NODECLASS_REFERENCETYPE: return .referenceType
        case UA_NODECLASS_DATATYPE:      return .dataType
        case UA_NODECLASS_VIEW:          return .view
        default:                         return .object
        }
    }
}

// MARK: - DataDriver Conformance

extension OPCUAClientService: DataDriver {
    var driverType: DriverType { .opcua }
    var driverName: String { "OPC-UA" }
    var isConnected: Bool { connectionState == .connected }
}

// MARK: - Error Types

enum OPCUAError: Error, LocalizedError {
    case notConnected
    case connectionFailed(String)
    case readError(String)
    case writeError(String)
    case browseError(String)
    case subscriptionError(String)
    case invalidNodeId

    var errorDescription: String? {
        switch self {
        case .notConnected:               return "Not connected to OPC-UA server"
        case .connectionFailed(let msg):  return "Connection failed: \(msg)"
        case .readError(let msg):         return "Read error: \(msg)"
        case .writeError(let msg):        return "Write error: \(msg)"
        case .browseError(let msg):       return "Browse error: \(msg)"
        case .subscriptionError(let msg): return "Subscription error: \(msg)"
        case .invalidNodeId:              return "Invalid NodeId"
        }
    }
}
