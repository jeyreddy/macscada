// MARK: - CommunityServer.swift
//
// NWListener-based TCP server that receives community peer connections.
// Handles the per-session authentication handshake and then relays broadcast
// messages to all authenticated clients.
//
// ── Protocol ──────────────────────────────────────────────────────────────────
//   Wire format: newline-delimited JSON (one CommunityMessage per line).
//   Each NWConnection reads data in a loop, splitting on '\n'.
//
// ── Session Lifecycle ─────────────────────────────────────────────────────────
//   1. accept(conn) — start NWConnection on nwQueue
//   2. Expect first message: type == "HELLO" with payload["hash"] and payload["timestamp"]
//   3. Validate HMAC: SHA256(secret + timestamp) == hash
//   4. If valid → send "WELCOME" + full snapshot (all tags + all alarms)
//      If invalid → send "REJECTED", close connection
//   5. Start receive loop — forward all subsequent messages to CommunityService
//      (clients don't normally send after HELLO, but this allows future extensions)
//   6. Subscribe to broadcastSubject — write each Data line to the NWConnection
//
// ── Thread Model ──────────────────────────────────────────────────────────────
//   NWListener and NWConnection callbacks arrive on nwQueue (background).
//   All @MainActor work (CommunityService calls) is dispatched via Task { @MainActor in }.
//   Session tasks tracked in sessionTasks[ObjectIdentifier(conn)] for cleanup.
//
// ── Broadcast ─────────────────────────────────────────────────────────────────
//   broadcastSub receives CommunityService.broadcastSubject emissions (Data).
//   Each authenticated session writes the Data to its NWConnection.
//   Closed connections are detected via NWConnection stateUpdateHandler → cleanup.

import Foundation
import Network
import Combine

// MARK: - CommunityServer

/// Inbound TCP server that accepts connections from community peers.
/// Each authenticated client receives a full tag+alarm snapshot on connect,
/// then streams live updates via the CommunityService.broadcastSubject.
@MainActor
final class CommunityServer {

    private weak var service: CommunityService?
    private let config:  CommunityConfig
    private let nwQueue: DispatchQueue = DispatchQueue(label: "com.industrialhmi.community.server",
                                                       qos: .utility)
    private var listener: NWListener?
    /// Active client session tasks keyed by connection object identity
    private var sessionTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var broadcastSub: AnyCancellable?

    init(service: CommunityService, config: CommunityConfig) {
        self.service = service
        self.config  = config
    }

    // MARK: - Lifecycle

    func start() {
        let portValue = UInt16(clamping: config.listenPort)
        guard portValue > 0 else {
            Logger.shared.error("CommunityServer: invalid port \(config.listenPort)")
            return
        }
        let port = NWEndpoint.Port(rawValue: portValue)!
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        do {
            listener = try NWListener(using: params, on: port)
        } catch {
            Logger.shared.error("CommunityServer: could not create listener — \(error.localizedDescription)")
            return
        }

        listener?.stateUpdateHandler = { state in
            Task { @MainActor in
                switch state {
                case .ready:
                    Logger.shared.info("CommunityServer: listening on port \(self.config.listenPort)")
                case .failed(let err):
                    Logger.shared.error("CommunityServer: listener failed — \(err.localizedDescription)")
                default: break
                }
            }
        }

        listener?.newConnectionHandler = { [weak self] conn in
            Task { @MainActor [weak self] in
                self?.accept(conn)
            }
        }

        listener?.start(queue: nwQueue)
    }

    func stop() {
        broadcastSub?.cancel()
        broadcastSub = nil
        listener?.cancel()
        listener = nil
        for task in sessionTasks.values { task.cancel() }
        sessionTasks.removeAll()
        Logger.shared.info("CommunityServer: stopped")
    }

    // MARK: - Accept

    private func accept(_ conn: NWConnection) {
        let key = ObjectIdentifier(conn)
        let task = Task { [weak self] in
            await self?.runSession(conn)
            await MainActor.run { [weak self] in
                _ = self?.sessionTasks.removeValue(forKey: key)
            }
        }
        sessionTasks[key] = task
        conn.start(queue: nwQueue)
    }

    // MARK: - Session

    private func runSession(_ conn: NWConnection) async {
        // 1. Read first line → expect "hello"
        guard let line = await readLine(from: conn) else {
            conn.cancel(); return
        }

        guard let msg = try? JSONDecoder().decode(CommunityMessage.self, from: Data(line.utf8)),
              msg.type == "hello",
              let token    = msg.payload["token"]?.stringValue,
              let siteName = msg.payload["siteName"]?.stringValue else {
            await send(CommunityMessage(type: "reject",
                                       payload: ["reason": .string("Malformed hello")]),
                       on: conn)
            conn.cancel(); return
        }

        // 2. Verify shared secret
        guard token == config.secret else {
            await send(CommunityMessage(type: "reject",
                                       payload: ["reason": .string("Invalid token")]),
                       on: conn)
            Logger.shared.warning("CommunityServer: rejected '\(siteName)' — bad token")
            conn.cancel(); return
        }

        // 3. Send welcome
        let welcome = CommunityMessage(type: "welcome",
                                       payload: [
                                           "siteId":   .string(UUID().uuidString),
                                           "siteName": .string(config.siteName)
                                       ])
        await send(welcome, on: conn)
        Logger.shared.info("CommunityServer: authenticated '\(siteName)'")

        // 4. Send full tag snapshot
        if let svc = service {
            let snapshots = svc.buildTagListSnapshot()
            if !snapshots.isEmpty,
               let data = try? JSONEncoder().encode(snapshots),
               let json = String(data: data, encoding: .utf8) {
                var tagListMsg = CommunityMessage(type: "tag_list")
                tagListMsg.payload["tags"] = .string(json)
                await send(tagListMsg, on: conn)
            }

            // 5. Send alarm snapshot
            let alarmSnaps = svc.buildAlarmSnapshot()
            if !alarmSnaps.isEmpty,
               let data = try? JSONEncoder().encode(alarmSnaps),
               let json = String(data: data, encoding: .utf8) {
                var alarmMsg = CommunityMessage(type: "alarm_update")
                alarmMsg.payload["alarms"] = .string(json)
                await send(alarmMsg, on: conn)
            }
        }

        // 6. Subscribe to broadcast subject and forward to this client
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let sub = service?.broadcastSubject
            .sink { data in continuation.yield(data) }

        // 7. Stream loop: forward broadcasts + handle incoming pings
        await withTaskGroup(of: Void.self) { group in
            // Writer: forward broadcasts
            group.addTask {
                for await data in stream {
                    conn.send(content: data, completion: .contentProcessed { _ in })
                }
            }
            // Reader: handle pings from client
            group.addTask { [weak self] in
                while !Task.isCancelled {
                    guard let line = await self?.readLine(from: conn) else { break }
                    if let msg = try? JSONDecoder().decode(CommunityMessage.self, from: Data(line.utf8)),
                       msg.type == "ping" {
                        let pong = CommunityMessage(type: "pong")
                        await self?.send(pong, on: conn)
                    }
                }
            }
        }

        sub?.cancel()
        continuation.finish()
        conn.cancel()
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
                            let result   = String(data: lineData, encoding: .utf8)
                            cont.resume(returning: result)
                            return
                        }
                    }
                    if error != nil || isComplete {
                        cont.resume(returning: nil)
                        return
                    }
                    receive()
                }
            }
            receive()
        }
    }

    private func send(_ msg: CommunityMessage, on conn: NWConnection) async {
        guard var line = (try? JSONEncoder().encode(msg)).flatMap({ String(data: $0, encoding: .utf8) })
        else { return }
        line += "\n"
        guard let data = line.data(using: .utf8) else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            conn.send(content: data, completion: .contentProcessed { _ in cont.resume() })
        }
    }
}
