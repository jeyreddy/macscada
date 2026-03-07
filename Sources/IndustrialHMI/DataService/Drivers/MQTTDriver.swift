// MARK: - MQTTDriver.swift
//
// MQTT 3.1.1 client driver built on Network.framework with zero external dependencies.
// Subscribes to configured MQTT topics and maps incoming messages to HMI tag values.
//
// ── Protocol ──────────────────────────────────────────────────────────────────
//   MQTT 3.1.1 implemented from spec (ISO/IEC 20922:2016).
//   Packet types implemented: CONNECT, CONNACK, SUBSCRIBE, SUBACK, PUBLISH,
//   PINGREQ, PINGRESP, DISCONNECT.
//   QoS 0 only (fire-and-forget publish) — adequate for HMI telemetry.
//
// ── Lifecycle ─────────────────────────────────────────────────────────────────
//   DataService creates one MQTTDriver per enabled MQTT DriverConfig.
//   connect() → load MQTTBrokerConfig + subscriptions from ConfigDatabase
//            → NWConnection TCP to broker host:port (default 1883)
//            → send CONNECT packet → await CONNACK (5 s timeout)
//            → send SUBSCRIBE for all MQTTSubscription topics
//            → start receive loop + keep-alive ping task
//   disconnect() → send DISCONNECT → cancel NWConnection → mark tags uncertain
//
// ── Connection Resilience ─────────────────────────────────────────────────────
//   reconnectTask retries with exponential back-off [5, 10, 30, 60 s].
//   pingTask sends PINGREQ every keepaliveSeconds; expects PINGRESP within 10 s.
//   If PINGRESP is missing → connection considered stale → reconnect loop.
//
// ── Topic → Tag Mapping ───────────────────────────────────────────────────────
//   Each MQTTSubscription maps topic → tagName + optional jsonPath.
//   On PUBLISH receive:
//     1. Match topic against all subscriptions (supports + and # wildcards).
//     2. If jsonPath is nil: parse payload as raw Double.
//     3. If jsonPath is set: JSON decode → traverse dot-separated path → extract Double.
//     4. Call tagEngine.updateTagFromDriver(name:, value: .analog(d), quality: .good).
//   Unrecognised payload or missing JSON path → quality = .uncertain.
//
// ── Wire Frame ────────────────────────────────────────────────────────────────
//   MQTT fixed header: byte0 = packetType<<4 | flags; then remaining length (varint).
//   All packet building via Data-building helper methods (appendMQTT*).
//   Receive loop accumulates chunks in receiveBuffer; parses complete packets
//   by decoding the remaining-length varint before consuming the packet.

import Foundation
import Network
import Combine

// MARK: - MQTTBrokerConfig

/// Runtime broker parameters parsed from a DriverConfig record.
struct MQTTBrokerConfig {
    var host: String
    var port: UInt16
    var clientId: String
    var username: String?
    var password: String?
    var keepaliveSeconds: UInt16

    /// Parse from a DriverConfig.
    /// endpoint = "host" or "host:port"  (default port 1883)
    /// parameters keys: clientId, username, password, keepaliveSeconds
    init(driverConfig cfg: DriverConfig) throws {
        let ep = cfg.endpoint
        if ep.contains(":"), let sep = ep.lastIndex(of: ":") {
            host = String(ep[ep.startIndex..<sep])
            port = UInt16(ep[ep.index(after: sep)...]) ?? 1883
        } else {
            host = ep
            port = 1883
        }
        guard !host.isEmpty else {
            throw DriverError.connectionFailed("MQTT broker host is empty — set it in Settings.")
        }
        let p = cfg.parameters
        clientId         = p["clientId"] ?? "IndustrialHMI-\(UUID().uuidString.prefix(8))"
        username         = p["username"].flatMap { $0.isEmpty ? nil : $0 }
        password         = p["password"].flatMap { $0.isEmpty ? nil : $0 }
        keepaliveSeconds = UInt16(p["keepaliveSeconds"] ?? "60") ?? 60
    }
}

// MARK: - MQTTDriver

/// MQTT 3.1.1 client driver built on Network.framework — no external dependencies.
///
/// Lifecycle (driven by DataService):
///   connect()    → load config from ConfigDatabase → TCP → CONNECT → CONNACK → SUBSCRIBE
///   disconnect() → DISCONNECT → cancel connection → mark tags uncertain
///
/// After connect() returns the driver self-manages reconnect with exponential back-off.
@MainActor
final class MQTTDriver: ObservableObject, DataDriver {

    var driverType: DriverType { .mqtt }
    var driverName: String     { "MQTT" }
    @Published private(set) var isConnected = false

    private let tagEngine:      TagEngine
    private let configDatabase: ConfigDatabase
    private let configId:       String?   // nil = load first enabled MQTT config

    // Network layer
    private var connection:    NWConnection?
    private var receiveBuffer: Data = Data()
    private let nwQueue = DispatchQueue(label: "com.industrialhmi.mqtt", qos: .utility)

    // MQTT session state
    private var brokerConfig:  MQTTBrokerConfig?
    private var subscriptions: [MQTTSubscription] = []
    private var packetId:      UInt16 = 1

    // Pending CONNACK continuation + its timeout task
    private var connackCont:    CheckedContinuation<Void, Error>?
    private var connackTimeout: Task<Void, Never>?

    // Background tasks
    private var reconnectTask: Task<Void, Never>?
    private var pingTask:      Task<Void, Never>?

    // MARK: - Init

    init(tagEngine: TagEngine, configDatabase: ConfigDatabase, configId: String? = nil) {
        self.tagEngine      = tagEngine
        self.configDatabase = configDatabase
        self.configId       = configId
    }

    // MARK: - DataDriver

    func connect() async throws {
        guard !isConnected else { return }

        // Load broker config for this specific instance (or first enabled if no configId)
        let cfgs: [DriverConfig]
        if let id = configId {
            let all = (try? await configDatabase.fetchAll()) ?? []
            cfgs = all.filter { $0.id == id }
        } else {
            cfgs = (try? await configDatabase.fetch(type: .mqtt)) ?? []
        }
        guard let driverCfg = cfgs.first(where: { $0.enabled }) ?? cfgs.first else {
            throw DriverError.notImplemented("No MQTT broker configured — add one in Settings.")
        }

        // Load subscriptions for this driver instance
        if let id = configId {
            let perDriver = (try? await configDatabase.fetchMQTTSubscriptions(forDriverId: id)) ?? []
            subscriptions = perDriver.isEmpty
                ? ((try? await configDatabase.fetchMQTTSubscriptions()) ?? [])
                : perDriver
        } else {
            subscriptions = (try? await configDatabase.fetchMQTTSubscriptions()) ?? []
        }

        let cfg = try MQTTBrokerConfig(driverConfig: driverCfg)
        brokerConfig = cfg

        try await openConnection(to: cfg)
    }

    func disconnect() async {
        stopTasks()
        sendPacket(Data([0xE0, 0x00]))   // DISCONNECT
        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll()
        isConnected = false
        markTagsUncertain()
        Logger.shared.info("MQTT: disconnected")
    }

    // MARK: - Open Connection

    private func openConnection(to cfg: MQTTBrokerConfig) async throws {
        guard let port = NWEndpoint.Port(rawValue: cfg.port) else {
            throw DriverError.connectionFailed("MQTT invalid port: \(cfg.port)")
        }
        let conn = NWConnection(host: NWEndpoint.Host(cfg.host), port: port, using: .tcp)
        connection = conn

        // Wait for CONNACK (or timeout / failure)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.connackCont = cont

            conn.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        // TCP established — send MQTT CONNECT
                        self.sendPacket(self.buildConnect(cfg))
                        self.startReceiving(on: conn)
                    case .failed(let err):
                        self.resolveConnack(.failure(
                            DriverError.connectionFailed(err.localizedDescription)))
                    case .cancelled:
                        self.resolveConnack(.failure(
                            DriverError.connectionFailed("Connection cancelled")))
                    default: break
                    }
                }
            }
            conn.start(queue: nwQueue)

            // 15-second CONNACK deadline
            connackTimeout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(15))
                self?.resolveConnack(.failure(
                    DriverError.connectionFailed("Timed out waiting for CONNACK (15 s)")))
            }
        }

        // CONNACK received — subscribe and start keepalive
        subscribeAll(on: conn)
        startPingTimer(on: conn)
        startAutoReconnect()
        Logger.shared.info("MQTT: connected to \(cfg.host):\(cfg.port)")
    }

    private func resolveConnack(_ result: Result<Void, Error>) {
        guard let cont = connackCont else { return }
        connackCont = nil
        connackTimeout?.cancel()
        connackTimeout = nil
        switch result {
        case .success:        cont.resume()
        case .failure(let e): cont.resume(throwing: e)
        }
    }

    // MARK: - Reconnect

    private func startAutoReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            let delays: [Double] = [5, 10, 30, 60, 120]
            var attempt = 0
            while !Task.isCancelled {
                guard let self else { return }
                if self.isConnected {
                    try? await Task.sleep(for: .seconds(5))
                    continue
                }
                let delay = delays[min(attempt, delays.count - 1)]
                Logger.shared.info("MQTT: reconnect attempt \(attempt + 1) in \(Int(delay))s")
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let cfg = self.brokerConfig else { continue }
                do {
                    self.pingTask?.cancel(); self.pingTask = nil
                    self.connection?.cancel(); self.connection = nil
                    self.receiveBuffer.removeAll()
                    try await self.openConnection(to: cfg)
                    attempt = 0
                } catch {
                    attempt += 1
                    Logger.shared.warning("MQTT reconnect failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Keepalive

    private func startPingTimer(on conn: NWConnection) {
        pingTask?.cancel()
        let interval = Double(brokerConfig?.keepaliveSeconds ?? 60) * 0.8
        pingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, self.isConnected else { break }
                self.sendPacket(Data([0xC0, 0x00]))  // PINGREQ
            }
        }
    }

    // MARK: - Receive Loop

    private func startReceiving(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.receiveBuffer += data
                    self.processBuffer()
                }
                if let error {
                    Logger.shared.error("MQTT receive: \(error.localizedDescription)")
                    self.handleConnectionLost()
                    return
                }
                if isComplete {
                    self.handleConnectionLost()
                    return
                }
                self.startReceiving(on: conn)  // schedule next read
            }
        }
    }

    // MARK: - Packet Processing

    private func processBuffer() {
        while receiveBuffer.count >= 2 {
            let first      = receiveBuffer[0]
            let packetType = first >> 4
            let flags      = first & 0x0F

            guard let (remaining, varBytes) = decodeVarLen(receiveBuffer, offset: 1) else { break }
            let total = 1 + varBytes + remaining
            guard receiveBuffer.count >= total else { break }

            let body = Data(receiveBuffer.dropFirst(1 + varBytes).prefix(remaining))
            receiveBuffer.removeFirst(total)
            dispatch(type: packetType, flags: flags, body: body)
        }
    }

    private func dispatch(type: UInt8, flags: UInt8, body: Data) {
        switch type {
        case 2:   handleConnack(body)
        case 3:   handlePublish(flags: flags, body: body)
        case 9:   break   // SUBACK  — QoS 0, nothing to do
        case 13:  break   // PINGRESP — keepalive confirmed
        default:  break
        }
    }

    // MARK: - CONNACK

    private func handleConnack(_ body: Data) {
        guard body.count >= 2 else { return }
        if body[1] == 0x00 {
            isConnected = true
            resolveConnack(.success(()))
        } else {
            resolveConnack(.failure(
                DriverError.connectionFailed("Broker rejected CONNECT (code \(body[1]))")))
        }
    }

    // MARK: - PUBLISH → tag update

    private func handlePublish(flags: UInt8, body: Data) {
        var idx = body.startIndex
        guard idx + 2 <= body.endIndex else { return }
        let topicLen = Int(body[idx]) << 8 | Int(body[idx + 1])
        idx = body.index(idx, offsetBy: 2)
        guard idx + topicLen <= body.endIndex else { return }
        let topic = String(data: body[idx..<body.index(idx, offsetBy: topicLen)], encoding: .utf8) ?? ""
        idx = body.index(idx, offsetBy: topicLen)
        let qos = (flags >> 1) & 0x03
        if qos > 0 { idx = body.index(idx, offsetBy: 2) }  // skip packet ID for QoS 1/2
        let payload = Data(body[idx...])

        guard let sub = subscriptions.first(where: { topicMatches($0.topic, incoming: topic) }) else { return }
        let value = parsePayload(payload, jsonPath: sub.jsonPath)
        tagEngine.updateTag(name: sub.tagName, value: value, quality: .good, timestamp: Date())
    }

    // MARK: - Disconnect handling

    private func handleConnectionLost() {
        guard isConnected else { return }
        isConnected = false
        markTagsUncertain()
        Logger.shared.warning("MQTT: connection lost — reconnect loop will retry")
    }

    // MARK: - Subscribe

    private func subscribeAll(on conn: NWConnection) {
        guard !subscriptions.isEmpty else { return }
        let pkt = buildSubscribe(topics: subscriptions.map { $0.topic }, id: packetId)
        packetId = packetId &+ 1
        sendPacket(pkt, on: conn)
        Logger.shared.info("MQTT: subscribed to \(subscriptions.count) topic(s)")
    }

    // MARK: - Send

    private func sendPacket(_ data: Data, on conn: NWConnection? = nil) {
        guard let conn = conn ?? connection else { return }
        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                Task { @MainActor [weak self] in
                    Logger.shared.error("MQTT send error: \(error.localizedDescription)")
                    self?.handleConnectionLost()
                }
            }
        })
    }

    // MARK: - Helpers

    private func stopTasks() {
        reconnectTask?.cancel(); reconnectTask = nil
        pingTask?.cancel();      pingTask = nil
    }

    private func markTagsUncertain() {
        let now = Date()
        for sub in subscriptions {
            tagEngine.updateTag(name: sub.tagName, value: .none, quality: .uncertain, timestamp: now)
        }
    }

    // MARK: - MQTT Variable-Length Encoding/Decoding

    private func encodeVarLen(_ n: Int) -> [UInt8] {
        var x = n, out: [UInt8] = []
        repeat {
            var b = UInt8(x % 128); x /= 128
            if x > 0 { b |= 0x80 }
            out.append(b)
        } while x > 0
        return out
    }

    private func decodeVarLen(_ data: Data, offset: Int) -> (value: Int, bytesConsumed: Int)? {
        var mul = 1, val = 0, i = offset
        repeat {
            guard i < data.count else { return nil }
            let b = Int(data[i]); val += (b & 127) * mul; mul *= 128
            guard mul <= 128 * 128 * 128 else { return nil }
            i += 1
            if b & 0x80 == 0 { break }
        } while true
        return (val, i - offset)
    }

    // MARK: - MQTT Packet Builders

    private func buildConnect(_ cfg: MQTTBrokerConfig) -> Data {
        var body = Data()
        body += mqttStr("MQTT")          // protocol name
        body += Data([0x04])             // protocol level = 3.1.1
        var flags: UInt8 = 0x02          // clean session
        if cfg.username != nil { flags |= 0x80 }
        if cfg.password != nil { flags |= 0x40 }
        body += Data([flags])
        body += uint16BE(cfg.keepaliveSeconds)
        body += mqttStr(cfg.clientId)
        if let u = cfg.username { body += mqttStr(u) }
        if let p = cfg.password { body += mqttStr(p) }
        return Data([0x10]) + Data(encodeVarLen(body.count)) + body
    }

    private func buildSubscribe(topics: [String], id: UInt16) -> Data {
        var body = uint16BE(id)
        for t in topics { body += mqttStr(t) + Data([0x00]) }   // QoS 0
        return Data([0x82]) + Data(encodeVarLen(body.count)) + body
    }

    // MARK: - Payload → TagValue

    private func parsePayload(_ data: Data, jsonPath: String?) -> TagValue {
        guard let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) else { return .none }

        // JSON path extraction
        if let path = jsonPath,
           let jsonData = raw.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            return toTagValue(walkPath(root, path: path)) ?? .none
        }

        // Plain number
        if let d = Double(raw) { return .analog(d) }
        // Boolean string
        switch raw.lowercased() {
        case "true",  "1", "on":  return .digital(true)
        case "false", "0", "off": return .digital(false)
        default: break
        }
        return .string(raw)
    }

    private func walkPath(_ dict: [String: Any], path: String) -> Any? {
        var cur: Any? = dict
        for key in path.split(separator: ".").map(String.init) {
            guard let d = cur as? [String: Any] else { return nil }
            cur = d[key]
        }
        return cur
    }

    private func toTagValue(_ v: Any?) -> TagValue? {
        if let d = v as? Double { return .analog(d) }
        if let i = v as? Int    { return .analog(Double(i)) }
        if let b = v as? Bool   { return .digital(b) }
        if let s = v as? String { return Double(s).map { .analog($0) } ?? .string(s) }
        return nil
    }

    // MARK: - MQTT Topic Wildcard Matching

    /// Matches an MQTT topic filter (+ = single-level wildcard, # = multi-level wildcard)
    /// against an incoming topic string per MQTT 3.1.1 §4.7.
    private func topicMatches(_ filter: String, incoming topic: String) -> Bool {
        let fp = filter.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let tp = topic.split(separator: "/",  omittingEmptySubsequences: false).map(String.init)
        return match(fp, tp)
    }

    private func match(_ f: [String], _ t: [String]) -> Bool {
        if f.isEmpty && t.isEmpty { return true }
        if f.first == "#"         { return true }
        guard !f.isEmpty, !t.isEmpty else { return false }
        if f[0] == "+" || f[0] == t[0] {
            return match(Array(f.dropFirst()), Array(t.dropFirst()))
        }
        return false
    }

    // MARK: - Encoding Helpers

    private func mqttStr(_ s: String) -> Data {
        let b = Array(s.utf8)
        return uint16BE(UInt16(b.count)) + Data(b)
    }

    private func uint16BE(_ v: UInt16) -> Data {
        Data([UInt8(v >> 8), UInt8(v & 0xFF)])
    }
}
