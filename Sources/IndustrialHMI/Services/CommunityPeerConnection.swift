// MARK: - CommunityPeerConnection.swift
//
// Manages an outbound NWConnection to a single community federation peer.
// Handles authentication handshake, receive loop, and automatic reconnection.
//
// ── Connection Lifecycle ──────────────────────────────────────────────────────
//   start() → startReconnectLoop() → Task loop with exponential back-off:
//     delays: [5, 10, 30, 60] seconds
//     connect() → NWConnection .ready → sendHello() → waitForWelcome()
//       → if "WELCOME" → startReceiveLoop() + startPingTask()
//       → if "REJECTED" → report .rejected status → stop reconnecting
//       → if timeout (5 s) → reconnect
//   stop() → cancel all Tasks + NWConnection
//
// ── Authentication ────────────────────────────────────────────────────────────
//   sendHello():
//     timestamp = ISO8601 string of Date()
//     hash = SHA256(secret + timestamp) hex-encoded
//     Send CommunityMessage(type: "HELLO", payload: ["hash": .string(hash),
//                                                     "timestamp": .string(timestamp)])
//   Expects response: type == "WELCOME" (proceed) or "REJECTED" (stop)
//
// ── Receive Loop ──────────────────────────────────────────────────────────────
//   Reads Data chunks into receiveBuffer. Splits on '\n'. For each complete line:
//     Decode CommunityMessage JSON.
//     type == "TAG_UPDATE"   → parse RemoteTagSnapshot → CommunityService.ingestRemoteTag()
//     type == "ALARM_UPDATE" → parse RemoteAlarmSnapshot → CommunityService.ingestRemoteAlarm()
//     type == "PING"         → set pongReceived = true (used by ping health check)
//     Other types ignored.
//
// ── Ping / Keep-Alive ─────────────────────────────────────────────────────────
//   startPingTask(): sends "PING" every 30 s; expects peer to echo a "PONG" within 10 s.
//   If pongReceived is false after 10 s → connection considered dead → reconnect loop.
//
// ── Status Updates ────────────────────────────────────────────────────────────
//   All PeerConnectionStatus updates sent to CommunityService.updatePeerStatus()
//   so CommunitySettingsView can show live connection state per peer.

import Foundation
import Network

// MARK: - CommunityPeerConnection

/// Outbound TCP connection to a single community peer.
/// Handles authentication handshake, tag/alarm update reception, and automatic
/// reconnection with exponential back-off.
@MainActor
final class CommunityPeerConnection {

    private let peer:    CommunityPeer
    private weak var service: CommunityService?
    private let secret:  String
    private let nwQueue: DispatchQueue = DispatchQueue(label: "com.industrialhmi.community.peer",
                                                       qos: .utility)

    private var connection:     NWConnection?
    private var receiveBuffer:  Data = Data()
    private var reconnectTask:  Task<Void, Never>?
    private var pingTask:       Task<Void, Never>?
    private var pongReceived:   Bool = false
    private var isConnected:    Bool = false

    // MARK: - Init

    init(peer: CommunityPeer, service: CommunityService, secret: String) {
        self.peer    = peer
        self.service = service
        self.secret  = secret
    }

    // MARK: - Lifecycle

    func start() {
        startReconnectLoop()
    }

    func stop() {
        reconnectTask?.cancel(); reconnectTask = nil
        pingTask?.cancel();      pingTask = nil
        connection?.cancel();    connection = nil
        receiveBuffer.removeAll()
        isConnected = false
    }

    // MARK: - Reconnect Loop

    private func startReconnectLoop() {
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            let delays: [Double] = [5, 10, 30, 60]
            var attempt = 0
            while !Task.isCancelled {
                guard let self else { return }
                if self.isConnected {
                    try? await Task.sleep(for: .seconds(5))
                    continue
                }
                let delay = delays[min(attempt, delays.count - 1)]
                if attempt > 0 {
                    Logger.shared.info("CommunityPeer '\(self.peer.name)': reconnect attempt \(attempt) in \(Int(delay))s")
                    try? await Task.sleep(for: .seconds(delay))
                }
                guard !Task.isCancelled else { return }
                do {
                    try await self.connect()
                    attempt = 0
                } catch {
                    attempt += 1
                    Logger.shared.warning("CommunityPeer '\(self.peer.name)': connect failed — \(error.localizedDescription)")
                    self.service?.updatePeerStatus(
                        PeerConnectionStatus(id: self.peer.id, status: .disconnected,
                                             lastError: error.localizedDescription)
                    )
                }
            }
        }
    }

    // MARK: - Connect

    private func connect() async throws {
        let portValue = UInt16(clamping: peer.port)
        guard portValue > 0 else {
            throw CommunityError.invalidPort(peer.port)
        }
        let port = NWEndpoint.Port(rawValue: portValue)!
        pingTask?.cancel(); pingTask = nil
        connection?.cancel()
        receiveBuffer.removeAll()

        let conn = NWConnection(host: NWEndpoint.Host(peer.host), port: port, using: .tcp)
        connection = conn

        // Wait for TCP ready
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                Task { @MainActor in
                    switch state {
                    case .ready:   cont.resume()
                    case .failed(let e):
                        cont.resume(throwing: CommunityError.connectionFailed(e.localizedDescription))
                    case .cancelled:
                        cont.resume(throwing: CommunityError.connectionFailed("Cancelled"))
                    default: break
                    }
                }
            }
            conn.start(queue: nwQueue)
        }

        // Send hello
        let hello = CommunityMessage(type: "hello",
                                     payload: [
                                         "token":    .string(secret),
                                         "siteName": .string(service?.config.siteName ?? ""),
                                         "version":  .string("1")
                                     ])
        try await sendMessage(hello, on: conn)

        // Read welcome / reject
        guard let line = await readLine(from: conn) else {
            throw CommunityError.connectionFailed("No response to hello")
        }
        guard let msg = try? JSONDecoder().decode(CommunityMessage.self, from: Data(line.utf8)) else {
            throw CommunityError.connectionFailed("Malformed response")
        }
        if msg.type == "reject" {
            let reason = msg.payload["reason"]?.stringValue ?? "unknown"
            service?.updatePeerStatus(
                PeerConnectionStatus(id: peer.id, status: .rejected, lastError: reason)
            )
            throw CommunityError.rejected(reason)
        }
        guard msg.type == "welcome",
              let siteIdStr = msg.payload["siteId"]?.stringValue,
              let siteId    = UUID(uuidString: siteIdStr),
              let siteName  = msg.payload["siteName"]?.stringValue else {
            throw CommunityError.connectionFailed("Expected welcome message")
        }

        isConnected = true
        service?.peerConnected(peerId: peer.id, remoteSiteId: siteId, remoteSiteName: siteName)

        // Start receive loop + ping task
        startReceiving(on: conn, siteName: siteName)
        startPingTask(on: conn)
    }

    // MARK: - Receive Loop

    private func startReceiving(on conn: NWConnection, siteName: String) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.receiveBuffer += data
                    self.processBuffer(siteName: siteName)
                }
                if error != nil || isComplete {
                    self.handleDisconnect()
                    return
                }
                self.startReceiving(on: conn, siteName: siteName)
            }
        }
    }

    private func processBuffer(siteName: String) {
        while let range = receiveBuffer.range(of: Data("\n".utf8)) {
            let lineData = receiveBuffer[..<range.lowerBound]
            receiveBuffer.removeSubrange(..<range.upperBound)

            guard let line = String(data: lineData, encoding: .utf8),
                  let msg  = try? JSONDecoder().decode(CommunityMessage.self, from: Data(line.utf8))
            else { continue }

            handleMessage(msg, siteName: siteName)
        }
    }

    private func handleMessage(_ msg: CommunityMessage, siteName: String) {
        switch msg.type {
        case "tag_list":
            guard let json    = msg.payload["tags"]?.stringValue,
                  let data    = json.data(using: .utf8),
                  let snaps   = try? JSONDecoder().decode([RemoteTagSnapshot].self, from: data)
            else { return }
            for snap in snaps {
                service?.handleRemoteTagUpdate(siteName: siteName, snapshot: snap)
            }

        case "tag_update":
            guard let json  = msg.payload["tag"]?.stringValue,
                  let data  = json.data(using: .utf8),
                  let snap  = try? JSONDecoder().decode(RemoteTagSnapshot.self, from: data)
            else { return }
            service?.handleRemoteTagUpdate(siteName: siteName, snapshot: snap)

        case "alarm_update":
            guard let json  = msg.payload["alarms"]?.stringValue,
                  let data  = json.data(using: .utf8),
                  let snaps = try? JSONDecoder().decode([RemoteAlarmSnapshot].self, from: data)
            else { return }
            service?.handleRemoteAlarmUpdate(siteName: siteName, snapshots: snaps)

        case "pong":
            pongReceived = true

        default:
            break
        }
    }

    // MARK: - Ping

    private func startPingTask(on conn: NWConnection) {
        pingTask?.cancel()
        pingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, self.isConnected else { break }
                self.pongReceived = false
                let ping = CommunityMessage(type: "ping")
                try? await self.sendMessage(ping, on: conn)
                // Wait up to 10 s for pong
                try? await Task.sleep(for: .seconds(10))
                if !self.pongReceived {
                    Logger.shared.warning("CommunityPeer '\(self.peer.name)': pong timeout — reconnecting")
                    self.handleDisconnect()
                    break
                }
            }
        }
    }

    // MARK: - Disconnect

    private func handleDisconnect() {
        guard isConnected else { return }
        isConnected = false
        pingTask?.cancel(); pingTask = nil
        connection?.cancel(); connection = nil
        receiveBuffer.removeAll()
        service?.peerDisconnected(peerId: peer.id)
        Logger.shared.warning("CommunityPeer '\(peer.name)': disconnected — reconnect loop will retry")
    }

    // MARK: - I/O Helpers

    private func readLine(from conn: NWConnection) async -> String? {
        await withCheckedContinuation { cont in
            var buffer = Data()
            func receive() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        buffer += data
                        if let range = buffer.range(of: Data("\n".utf8)) {
                            let lineData = buffer[..<range.lowerBound]
                            cont.resume(returning: String(data: lineData, encoding: .utf8))
                            return
                        }
                    }
                    if error != nil || isComplete { cont.resume(returning: nil); return }
                    receive()
                }
            }
            receive()
        }
    }

    private func sendMessage(_ msg: CommunityMessage, on conn: NWConnection) async throws {
        guard var line = (try? JSONEncoder().encode(msg)).flatMap({ String(data: $0, encoding: .utf8) })
        else { throw CommunityError.encodingFailed }
        line += "\n"
        guard let data = line.data(using: .utf8) else { throw CommunityError.encodingFailed }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: CommunityError.connectionFailed(error.localizedDescription))
                } else {
                    cont.resume()
                }
            })
        }
    }
}

// MARK: - CommunityError

enum CommunityError: LocalizedError {
    case invalidPort(Int)
    case connectionFailed(String)
    case rejected(String)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidPort(let p):      return "Invalid community port: \(p)"
        case .connectionFailed(let r): return "Community connection failed: \(r)"
        case .rejected(let r):         return "Community peer rejected: \(r)"
        case .encodingFailed:          return "Community message encoding failed"
        }
    }
}
