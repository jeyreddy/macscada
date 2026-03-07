// MARK: - OPCUAClientService.swift
//
// Wraps the open62541 C OPC-UA client library (COPC Swift package) in an
// @MainActor-observable service. All OPC-UA C API calls are dispatched onto
// a dedicated serial `opcuaQueue` so the UI thread never blocks on I/O.
//
// ── Thread Safety Model ───────────────────────────────────────────────────────
//   OPCUAHandle wraps OpaquePointer as @unchecked Sendable so it can be
//   captured by value in opcuaQueue async blocks. The @MainActor class never
//   dereferences the pointer — only the queue blocks do. This makes the
//   pattern safe: one actor manages metadata; one queue owns the C pointer.
//
// ── Connection Lifecycle ──────────────────────────────────────────────────────
//   connect(to:) → stops any pending reconnect → saves URL → connect()
//   connect() → guard disconnected/error → set .connecting → opcuaQueue:
//     UA_Client_new() → UA_ClientConfig_setDefault() → UA_Client_connect()
//     → success: set .connected, start polling timer
//     → failure: set .error, start auto-reconnect loop
//   disconnect() → pollingTimer.invalidate() → opcuaQueue: UA_Client_disconnect()
//   Auto-reconnect: exponential back-off Task, 5 retries max
//
// ── Polling ───────────────────────────────────────────────────────────────────
//   pollingTimer fires every Configuration.pollingInterval (default 500 ms) on @MainActor.
//   isPollInFlight flag prevents a slow poll from stacking on top of itself.
//   Each poll:
//     For each registered nodeId → UA_Client_readValueAttribute_sync() on opcuaQueue
//     → decode UA_Variant → TagValue + TagQuality
//     → call all tagCallbacks[nodeId] (received on @MainActor)
//
// ── Tag Subscriptions ─────────────────────────────────────────────────────────
//   TagEngine registers callbacks via subscribeToTag(nodeId:callback:) and
//   unsubscribeFromTag(nodeId:). The tagCallbacks dict maps nodeId → [callback].
//   Multiple tags with the same nodeId share a single read per poll.
//
// ── Write ─────────────────────────────────────────────────────────────────────
//   writeValue(nodeId:value:) → UA_Client_writeValueAttribute_sync() on opcuaQueue.
//   Returns true/false based on UA_StatusCode_isGood.
//
// ── Discovery ─────────────────────────────────────────────────────────────────
//   browseAddressSpace(root:) does a recursive BrowseRequest from the specified
//   node on `discoveryQueue` (separate from polling queue so discovery never
//   delays live tag reads). Returns [OPCUANode] on @MainActor.
//   findServers(on:) uses UA_Client_findServers() for endpoint discovery.
//
// ── Errors ────────────────────────────────────────────────────────────────────
//   OPCUAError: connectionFailed, readFailed, writeFailed, browseFailed, notConnected

import Foundation
import Darwin
import COPC

/// Thread-safety for OPC-UA C client pointers is enforced by `opcuaQueue` (serial DispatchQueue).
private struct OPCUAHandle: @unchecked Sendable { let ptr: OpaquePointer }

@MainActor
class OPCUAClientService: ObservableObject {
    @Published var connectionState: ConnectionState = .disconnected
    @Published var isPolling: Bool = false
    @Published var serverURL: String = Configuration.opcuaServerURL

    // Accessed only on @MainActor for the nil-guard; the captured OpaquePointer
    // *value* is then passed into opcuaQueue blocks by value — never re-read from
    // self inside those blocks.
    private var client: OpaquePointer?

    private var pollingTimer: Timer?
    // Prevents a slow poll cycle from stacking a second one on top of itself.
    private var isPollInFlight = false

    // Single serial queue — every C library call goes here, nothing else.
    private let opcuaQueue = DispatchQueue(label: "com.industrialhmi.opcua", qos: .userInitiated)
    // Separate queue for discovery so it never delays polling.
    private let discoveryQueue = DispatchQueue(label: "com.industrialhmi.discovery", qos: .userInitiated)

    private var tagCallbacks: [String: [(String, TagValue, TagQuality, Date) -> Void]] = [:]
    private var reconnectTask: Task<Void, Never>?

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
            let handle = OPCUAHandle(ptr: c)
            opcuaQueue.async {
                UA_Client_disconnect(handle.ptr)
                UA_Client_delete(handle.ptr)
            }
        }
    }

    // MARK: - Connection Management

    /// Connect to a specific URL — stops any pending reconnect loop, saves URL, connects.
    func connect(to url: String) async throws {
        stopAutoReconnect()              // cancel reconnect loop before manual attempt
        serverURL = url
        Configuration.opcuaServerURL = url
        try await connect()
    }

    func connect() async throws {
        let url = serverURL
        guard !url.isEmpty else {
            throw OPCUAError.connectionFailed("No server URL configured. Set one in Settings.")
        }
        // Bail out if already connected OR if a connect is already in flight (.connecting).
        guard connectionState == .disconnected || connectionState == .error else { return }
        connectionState = .connecting

        // Single dispatch to opcuaQueue — ALL C work happens there.
        try await withCheckedThrowingContinuation { continuation in
            self.opcuaQueue.async { [weak self] in
                let newClient = UA_Client_new()
                let config    = UA_Client_getConfig(newClient)
                UA_ClientConfig_setDefault(config)

                let retval = UA_Client_connect(newClient, url)

                if retval == UA_STATUSCODE_GOOD {
                    DispatchQueue.main.async {
                        self?.client = newClient
                        self?.connectionState = .connected
                        Logger.shared.info("OPC-UA connected successfully")
                        continuation.resume()
                    }
                } else {
                    UA_Client_delete(newClient)
                    let desc = self?.statusCodeMessage(retval) ?? "Status 0x\(String(retval, radix: 16, uppercase: true))"
                    DispatchQueue.main.async {
                        self?.connectionState = .error
                    }
                    continuation.resume(throwing: OPCUAError.connectionFailed(desc))
                }
            }
        }
    }

    func disconnect() async {
        pollingTimer?.invalidate()
        pollingTimer = nil
        isPolling = false

        // Notify all subscribed tags that data is no longer current.
        let now = Date()
        for (nodeId, callbacks) in tagCallbacks {
            for cb in callbacks { cb(nodeId, .none, .uncertain, now) }
        }
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

        let handle = OPCUAHandle(ptr: clientToDisconnect)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.opcuaQueue.async {
                UA_Client_disconnect(handle.ptr)
                UA_Client_delete(handle.ptr)
                continuation.resume()
            }
        }

        Logger.shared.info("OPC-UA disconnected safely")
    }

    // MARK: - Auto-Reconnect

    /// Start an exponential-backoff reconnect loop.
    /// Safe to call multiple times — cancels any existing loop first.
    func startAutoReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            let delays: [Double] = [5, 10, 30, 60, 120]
            var attempt = 0
            while !Task.isCancelled {
                // Wait for .disconnected or .error state before trying
                guard let self else { return }
                if self.connectionState == .connected {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)  // check every 5 s
                    continue
                }
                let delay = delays[min(attempt, delays.count - 1)]
                Logger.shared.info("OPC-UA reconnect attempt \(attempt + 1) in \(Int(delay))s")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                do {
                    try await self.connect()
                    attempt = 0   // reset backoff on success
                    Logger.shared.info("OPC-UA auto-reconnect succeeded")
                } catch {
                    attempt += 1
                    Logger.shared.warning("OPC-UA reconnect failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func stopAutoReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    // MARK: - Subscription Management

    func subscribe(to nodeIds: [String],
                   callback: @escaping (String, TagValue, TagQuality, Date) -> Void) async throws {
        guard connectionState == .connected else {
            throw OPCUAError.notConnected
        }

        for nodeId in nodeIds {
            // Replace (not append) to prevent duplicate callbacks across reconnect cycles.
            tagCallbacks[nodeId] = [callback]
        }

        if pollingTimer == nil {
            startPolling()
        }
    }

    /// Remove a single nodeId from the poll list (called when a tag is deleted).
    func unsubscribe(nodeId: String) {
        tagCallbacks.removeValue(forKey: nodeId)
        if tagCallbacks.isEmpty { pausePolling() }
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

        let handle = OPCUAHandle(ptr: capturedClient)
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
                UA_Client_run_iterate(handle.ptr, 0)

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
                    let readStatus = UA_Client_readValueAttribute(handle.ptr, nodeIdC, &variant)
                    if readStatus == UA_STATUSCODE_GOOD {
                        let tagValue = self.convertVariantToTagValue(&variant)
                        UA_Variant_clear(&variant)
                        results.append((nodeId, tagValue, .good, Date()))
                    } else {
                        // Read failed (node gone, session issue, etc.) — mark tag uncertain
                        // so the operator sees data is no longer live, rather than stale-good.
                        results.append((nodeId, .none, .uncertain, Date()))
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

    /// Write a value to an OPC-UA variable node.
    /// Dispatches on opcuaQueue (same serial queue as all other C calls).
    func writeTag(nodeId: String, value: TagValue) async throws {
        guard let capturedClient = client, connectionState == .connected else {
            throw OPCUAError.notConnected
        }

        let handle = OPCUAHandle(ptr: capturedClient)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.opcuaQueue.async {
                // --- Parse NodeId (same logic as read/poll paths) ---
                var nodeIdC = UA_NODEID_NULL
                if nodeId.contains("i=") {
                    var ns: UInt16 = 0; var id: UInt32 = 0
                    for part in nodeId.split(separator: ";") {
                        if part.hasPrefix("ns=") { ns = UInt16(part.dropFirst(3)) ?? 0 }
                        else if part.hasPrefix("i=") { id = UInt32(part.dropFirst(2)) ?? 0 }
                    }
                    nodeIdC = UA_NODEID_NUMERIC(ns, id)
                } else if nodeId.contains("s=") {
                    var ns: UInt16 = 0; var stringId = ""
                    for part in nodeId.split(separator: ";") {
                        if part.hasPrefix("ns=") { ns = UInt16(part.dropFirst(3)) ?? 0 }
                        else if part.hasPrefix("s=") { stringId = String(part.dropFirst(2)) }
                    }
                    nodeIdC = UA_NODEID_STRING_ALLOC(ns, stringId)
                } else {
                    nodeIdC = UA_NODEID_STRING_ALLOC(0, nodeId)
                }
                defer { UA_NodeId_clear(&nodeIdC) }

                // --- Build UA_Variant from TagValue ---
                // copc_type_*() helpers resolve UA_TYPES[index] in C (avoids Swift tuple-subscript).
                var variant = UA_Variant()
                UA_Variant_init(&variant)
                defer { UA_Variant_clear(&variant) }

                switch value {
                case .analog(let d):
                    var v = d
                    UA_Variant_setScalarCopy(&variant, &v, copc_type_double())
                case .digital(let b):
                    var v: UA_Boolean = b   // UA_Boolean maps to Swift Bool
                    UA_Variant_setScalarCopy(&variant, &v, copc_type_boolean())
                case .string, .none:
                    continuation.resume(throwing: OPCUAError.writeError(
                        "Cannot write \(value) — only analog and digital values are supported"))
                    return
                }

                // --- Execute write ---
                let status = UA_Client_writeValueAttribute(handle.ptr, nodeIdC, &variant)
                if status == UA_STATUSCODE_GOOD {
                    continuation.resume()
                } else {
                    let hex = "0x\(String(format: "%08X", status))"
                    continuation.resume(throwing: OPCUAError.writeError("Write failed: \(hex)"))
                }
            }
        }
    }

    private func readTag(nodeId: String) async throws -> (TagValue, TagQuality, Date) {
        guard let capturedClient = client else {
            throw OPCUAError.notConnected
        }

        let handle = OPCUAHandle(ptr: capturedClient)
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
                let retval = UA_Client_readValueAttribute(handle.ptr, nodeIdC, &value)

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

    /// Human-readable description for common UA_StatusCode values.
    private nonisolated func statusCodeMessage(_ code: UA_StatusCode) -> String {
        let hex = "0x\(String(format: "%08X", code))"
        switch code {
        case 0x80AE0000:
            return "Server closed the connection (\(hex)) — hostname may be wrong or server is down. Use 'Scan Network' to rediscover."
        case 0x80AC0000:
            return "Connection rejected (\(hex)) — server is running but refused the connection."
        case 0x800A0000:
            return "Connection timed out (\(hex)) — check the IP/hostname and port (default: 4840)."
        case 0x808A0000:
            return "Not connected (\(hex))."
        case 0x80120000:
            return "Certificate invalid (\(hex)) — server requires a trusted certificate."
        case 0x80160000:
            return "Certificate hostname invalid (\(hex))."
        case 0x801F0000:
            return "Access denied (\(hex)) — check username/password."
        default:
            return "OPC-UA error \(hex) — verify the server URL and that the server is running."
        }
    }

    /// Safely convert a UA_String (length + non-null-terminated data) to Swift String.
    private nonisolated func uaStr(_ s: UA_String) -> String {
        guard s.length > 0, let data = s.data else { return "" }
        return String(bytes: UnsafeRawBufferPointer(start: data, count: s.length),
                      encoding: .utf8) ?? ""
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

    // MARK: - Discovery

    /// Query a URL for all available endpoints (security modes, server type, etc.).
    /// Uses a temporary client on discoveryQueue — never blocks polling.
    func getEndpoints(at url: String) async -> [OPCUAEndpointInfo] {
        await withCheckedContinuation { continuation in
            self.discoveryQueue.async {
                let tmp = UA_Client_new()
                UA_ClientConfig_setDefault(UA_Client_getConfig(tmp))
                defer { UA_Client_delete(tmp) }

                var count: Int = 0
                var eps: UnsafeMutablePointer<UA_EndpointDescription>? = nil

                let status = UA_Client_getEndpoints(tmp, url, &count, &eps)
                guard status == UA_STATUSCODE_GOOD, count > 0, let ep = eps else {
                    Logger.shared.warning("getEndpoints failed at \(url): \(status)")
                    continuation.resume(returning: [])
                    return
                }

                var infos: [OPCUAEndpointInfo] = []
                for i in 0..<count {
                    let desc  = ep[i]
                    let epUrl = self.uaStr(desc.endpointUrl)
                    let srvName = self.uaStr(desc.server.applicationName.text)
                    let appType = OPCUAApplicationType(rawValue: desc.server.applicationType.rawValue)
                    let secMode = OPCUASecurityMode(rawMode: desc.securityMode.rawValue)
                    let policy  = self.uaStr(desc.securityPolicyUri)
                    infos.append(OPCUAEndpointInfo(
                        endpointUrl:    epUrl.isEmpty ? url : epUrl,
                        serverName:     srvName.isEmpty ? "OPC-UA Server" : srvName,
                        applicationType: appType,
                        securityMode:   secMode,
                        securityPolicy: policy
                    ))
                }

                // Cleanup — clear each element then free the C array
                for i in 0..<count {
                    var ep = eps!.advanced(by: i).pointee
                    UA_EndpointDescription_clear(&ep)
                }
                Darwin.free(eps)

                continuation.resume(returning: infos)
            }
        }
    }

    /// Query a URL for registered application descriptions.
    func findServers(at url: String) async -> [OPCUAServerInfo] {
        await withCheckedContinuation { continuation in
            self.discoveryQueue.async {
                let tmp = UA_Client_new()
                UA_ClientConfig_setDefault(UA_Client_getConfig(tmp))
                defer { UA_Client_delete(tmp) }

                var count: Int = 0
                var apps: UnsafeMutablePointer<UA_ApplicationDescription>? = nil

                let status = UA_Client_findServers(tmp, url, 0, nil, 0, nil, &count, &apps)
                guard status == UA_STATUSCODE_GOOD, count > 0, let ap = apps else {
                    Logger.shared.warning("findServers failed at \(url): \(status)")
                    continuation.resume(returning: [])
                    return
                }

                var infos: [OPCUAServerInfo] = []
                for i in 0..<count {
                    let desc = ap[i]
                    let name = self.uaStr(desc.applicationName.text)
                    let uri  = self.uaStr(desc.applicationUri)
                    let type = OPCUAApplicationType(rawValue: desc.applicationType.rawValue)
                    var urls: [String] = []
                    for j in 0..<Int(desc.discoveryUrlsSize) {
                        let u = self.uaStr(desc.discoveryUrls[j])
                        if !u.isEmpty { urls.append(u) }
                    }
                    infos.append(OPCUAServerInfo(
                        applicationName: name.isEmpty ? "OPC-UA Server" : name,
                        applicationUri:  uri,
                        applicationType: type,
                        discoveryUrls:   urls
                    ))
                }

                for i in 0..<count {
                    var app = apps!.advanced(by: i).pointee
                    UA_ApplicationDescription_clear(&app)
                }
                Darwin.free(apps)

                continuation.resume(returning: infos)
            }
        }
    }

    /// Convenience: run getEndpoints + findServers together.
    func discoverAt(url: String) async -> (endpoints: [OPCUAEndpointInfo], servers: [OPCUAServerInfo]) {
        async let eps = getEndpoints(at: url)
        async let srvs = findServers(at: url)
        return await (eps, srvs)
    }

    // MARK: - Browse Operations

    func browseNode(nodeId: String) async throws -> [OPCUANode] {
        guard let capturedClient = client else {
            throw OPCUAError.notConnected
        }

        let handle = OPCUAHandle(ptr: capturedClient)
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

                var browseResponse = UA_Client_Service_browse(handle.ptr, browseRequest)
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
