// MARK: - CommunityService.swift
//
// Orchestrates the Community Federation feature — peer-to-peer tag and alarm
// sharing across multiple IndustrialHMI instances on the same LAN.
//
// ── Role ──────────────────────────────────────────────────────────────────────
//   CommunityService is the @MainActor hub that:
//     • Manages CommunityServer (inbound WebSocket server)
//     • Creates/destroys CommunityPeerConnection objects (outbound clients)
//     • Publishes peerStatuses and remoteAlarms to SwiftUI views
//     • Owns broadcastSubject — fires pre-encoded JSON Data lines to all
//       authenticated inbound clients whenever a local tag or alarm changes
//
// ── Data Flow ─────────────────────────────────────────────────────────────────
//   Outbound (publishing local data to peers):
//     DataService.broadcastTagUpdate(tag) → CommunityService.broadcastTagUpdate()
//       → encode RemoteTagSnapshot → broadcastSubject.send()
//       → CommunityServer distributes to all authenticated sessions
//     alarmManager.$activeAlarms → alarmSub Combine subscription
//       → delta-encodes changed alarms → broadcastSubject.send()
//
//   Inbound (receiving remote data from peers):
//     CommunityPeerConnection receives JSON line → parseMessage()
//       → TAG_UPDATE: tagEngine.ingestRemoteTag(name: "SiteName/tagName", ...)
//       → ALARM_UPDATE: decode RemoteAlarmSnapshot → add/update remoteAlarmsBySite
//         → rebuild remoteAlarms from all sites → publish
//
// ── Authentication ────────────────────────────────────────────────────────────
//   HELLO message includes hash = SHA256(secret + timestamp).
//   CommunityServer validates hash before promoting connection to active session.
//
// ── Config Persistence ────────────────────────────────────────────────────────
//   CommunityConfig is JSON-encoded into UserDefaults["communityConfig"].
//   applyNewConfig() stops all connections, applies config, restarts if enabled.
//
// ── Remote Alarm Aggregation ──────────────────────────────────────────────────
//   remoteAlarmsBySite: [siteName → [Alarm]] accumulates alarms from each peer.
//   remoteAlarms = remoteAlarmsBySite.values.flatMap { $0 } — published to AlarmListView.
//   lastAlarmStates tracks last seen state per alarm UUID for delta computation.

import Foundation
import Network
import Combine

// MARK: - CommunityService

/// @MainActor orchestrator for the community federation feature.
/// Manages CommunityServer (inbound) and CommunityPeerConnection (outbound) instances.
/// Publishes peer statuses and aggregated remote alarms to SwiftUI views.
@MainActor
final class CommunityService: ObservableObject {

    // MARK: - Published

    @Published var peerStatuses: [UUID: PeerConnectionStatus] = [:]
    @Published var remoteAlarms: [Alarm] = []

    // MARK: - Config

    private(set) var config: CommunityConfig {
        didSet { persistConfig() }
    }

    // MARK: - Broadcast Subject

    /// Pre-encoded newline-terminated JSON data lines; CommunityServer subscribes to this
    /// to forward messages to all authenticated client sessions.
    let broadcastSubject = PassthroughSubject<Data, Never>()

    // MARK: - Private

    private weak var tagEngine:    TagEngine?
    private weak var alarmManager: AlarmManager?

    private var server:     CommunityServer?
    private var peerConns:  [UUID: CommunityPeerConnection] = [:]

    /// Per-site alarm cache: sitePrefix → alarms from that site
    private var remoteAlarmsBySite: [String: [Alarm]] = [:]

    /// Last-seen AlarmState per alarm ID for delta computation
    private var lastAlarmStates: [UUID: AlarmState] = [:]

    private var alarmSub: AnyCancellable?

    // MARK: - Init

    init(tagEngine: TagEngine, alarmManager: AlarmManager) {
        self.tagEngine    = tagEngine
        self.alarmManager = alarmManager
        self.config       = Self.loadConfig()
    }

    // MARK: - Lifecycle

    func start() {
        guard config.enabled else { return }
        startServer()
        connectPeers()
        subscribeToAlarms()
        Logger.shared.info("CommunityService: started (site='\(config.siteName)', port=\(config.listenPort))")
    }

    func stop() {
        server?.stop()
        server = nil
        for conn in peerConns.values { conn.stop() }
        peerConns.removeAll()
        peerStatuses.removeAll()
        alarmSub?.cancel()
        alarmSub = nil
        Logger.shared.info("CommunityService: stopped")
    }

    // MARK: - Config Management

    func updateConfig(_ newConfig: CommunityConfig) {
        let wasEnabled = config.enabled
        config = newConfig
        if wasEnabled { stop() }
        if config.enabled { start() }
    }

    func addOrUpdatePeer(_ peer: CommunityPeer) {
        if let idx = config.peers.firstIndex(where: { $0.id == peer.id }) {
            config.peers[idx] = peer
        } else {
            config.peers.append(peer)
        }
        // Restart connection for this peer
        peerConns[peer.id]?.stop()
        peerConns.removeValue(forKey: peer.id)
        if config.enabled && peer.enabled {
            connectSinglePeer(peer)
        }
    }

    func removePeer(id: UUID) {
        peerConns[id]?.stop()
        peerConns.removeValue(forKey: id)
        peerStatuses.removeValue(forKey: id)
        config.peers.removeAll { $0.id == id }
        // Remove remote tags from this peer
        if let peer = config.peers.first(where: { $0.id == id }) {
            tagEngine?.removeRemoteTags(sitePrefix: peer.name)
            remoteAlarmsBySite.removeValue(forKey: peer.name)
            rebuildRemoteAlarms()
        }
    }

    // MARK: - Broadcast (Tag Update)

    /// Encode a local tag update and push it to all connected clients via broadcastSubject.
    /// Guard: skip remote tags (names containing "/") to prevent echo.
    func broadcastTagUpdate(_ tag: Tag) {
        guard !tag.name.contains("/") else { return }
        let snapshot = RemoteTagSnapshot(
            name:      tag.name,
            value:     tag.value.numericValue,
            quality:   tag.quality.rawValue,   // Int
            unit:      tag.unit,
            dataType:  tag.dataType.rawValue,
            timestamp: tag.timestamp.timeIntervalSince1970
        )
        var msg = CommunityMessage(type: "tag_update")
        if let data = try? JSONEncoder().encode(snapshot),
           let json = String(data: data, encoding: .utf8) {
            msg.payload["tag"] = .string(json)
        }
        sendBroadcast(msg)
    }

    /// Compute delta of local alarms and broadcast only if something changed.
    func broadcastAlarmDelta(_ alarms: [Alarm]) {
        // Build snapshot of alarms that changed since last broadcast
        let localAlarms = alarms.filter { !$0.tagName.contains("/") }
        var changed: [RemoteAlarmSnapshot] = []

        for alarm in localAlarms {
            if lastAlarmStates[alarm.id] != alarm.state {
                changed.append(RemoteAlarmSnapshot(
                    id:          alarm.id.uuidString,
                    tagName:     alarm.tagName,
                    severity:    alarm.severity.rawValue,
                    state:       alarm.state.rawValue,
                    message:     alarm.message,
                    value:       alarm.value,
                    triggerTime: alarm.triggerTime.timeIntervalSince1970
                ))
                lastAlarmStates[alarm.id] = alarm.state
            }
        }
        // Detect cleared alarms
        let localIds = Set(localAlarms.map { $0.id })
        for id in lastAlarmStates.keys where !localIds.contains(id) {
            lastAlarmStates.removeValue(forKey: id)
        }

        guard !changed.isEmpty else { return }

        if let data = try? JSONEncoder().encode(changed),
           let json = String(data: data, encoding: .utf8) {
            var msg = CommunityMessage(type: "alarm_update")
            msg.payload["alarms"] = .string(json)
            sendBroadcast(msg)
        }
    }

    // MARK: - Remote Updates (called by CommunityPeerConnection)

    func handleRemoteTagUpdate(siteName: String, snapshot: RemoteTagSnapshot) {
        guard let tagEngine else { return }
        let prefixedName = "\(siteName)/\(snapshot.name)"
        let quality = TagQuality(rawValue: snapshot.quality) ?? .uncertain  // Int rawValue
        let value: TagValue = snapshot.value.map { .analog($0) } ?? .none
        let timestamp = Date(timeIntervalSince1970: snapshot.timestamp)
        let tag = Tag(
            name:      prefixedName,
            nodeId:    "",
            value:     value,
            quality:   quality,
            timestamp: timestamp,
            unit:      snapshot.unit,
            dataType:  .analog
        )
        tagEngine.addRemoteTag(tag)
    }

    func handleRemoteAlarmUpdate(siteName: String, snapshots: [RemoteAlarmSnapshot]) {
        var siteAlarms: [Alarm] = []
        for snap in snapshots {
            guard let alarmId   = UUID(uuidString: snap.id),
                  let severity  = AlarmSeverity(rawValue: snap.severity),
                  let state     = AlarmState(rawValue: snap.state) else { continue }
            var alarm = Alarm(
                id:          alarmId,
                tagName:     "\(siteName)/\(snap.tagName)",
                message:     snap.message,
                severity:    severity,
                triggerTime: Date(timeIntervalSince1970: snap.triggerTime)
            )
            alarm.value = snap.value
            alarm.state = state
            siteAlarms.append(alarm)
        }
        remoteAlarmsBySite[siteName] = siteAlarms
        rebuildRemoteAlarms()
    }

    // MARK: - Peer Status Updates (called by CommunityPeerConnection)

    func updatePeerStatus(_ status: PeerConnectionStatus) {
        peerStatuses[status.id] = status
    }

    func peerConnected(peerId: UUID, remoteSiteId: UUID, remoteSiteName: String) {
        peerStatuses[peerId] = PeerConnectionStatus(
            id: peerId, status: .connected, remoteSiteId: remoteSiteId
        )
        Logger.shared.info("CommunityService: peer '\(remoteSiteName)' connected (id=\(peerId))")
    }

    func peerDisconnected(peerId: UUID) {
        if var status = peerStatuses[peerId] {
            status.status = .disconnected
            peerStatuses[peerId] = status
        }
        // Clear remote tags and alarms for this peer
        if let peer = config.peers.first(where: { $0.id == peerId }) {
            tagEngine?.removeRemoteTags(sitePrefix: peer.name)
            remoteAlarmsBySite.removeValue(forKey: peer.name)
            rebuildRemoteAlarms()
        }
    }

    // MARK: - Tag Snapshot for New Clients (called by CommunityServer)

    func buildTagListSnapshot() -> [RemoteTagSnapshot] {
        guard let tagEngine else { return [] }
        return tagEngine.tags.values
            .filter { !$0.name.contains("/") }
            .map { tag in
                RemoteTagSnapshot(
                    name:      tag.name,
                    value:     tag.value.numericValue,
                    quality:   tag.quality.rawValue,    // Int
                    unit:      tag.unit,
                    dataType:  tag.dataType.rawValue,
                    timestamp: tag.timestamp.timeIntervalSince1970
                )
            }
    }

    func buildAlarmSnapshot() -> [RemoteAlarmSnapshot] {
        guard let alarmManager else { return [] }
        return alarmManager.activeAlarms
            .filter { !$0.tagName.contains("/") }
            .map { alarm in
                RemoteAlarmSnapshot(
                    id:          alarm.id.uuidString,
                    tagName:     alarm.tagName,
                    severity:    alarm.severity.rawValue,
                    state:       alarm.state.rawValue,
                    message:     alarm.message,
                    value:       alarm.value,
                    triggerTime: alarm.triggerTime.timeIntervalSince1970
                )
            }
    }

    // MARK: - Private Helpers

    private func startServer() {
        server?.stop()
        server = CommunityServer(service: self, config: config)
        server?.start()
    }

    private func connectPeers() {
        for peer in config.peers where peer.enabled {
            connectSinglePeer(peer)
        }
    }

    private func connectSinglePeer(_ peer: CommunityPeer) {
        let conn = CommunityPeerConnection(peer: peer, service: self, secret: config.secret)
        peerConns[peer.id] = conn
        peerStatuses[peer.id] = PeerConnectionStatus(id: peer.id, status: .connecting)
        conn.start()
    }

    private func subscribeToAlarms() {
        guard let alarmManager else { return }
        alarmSub = alarmManager.$activeAlarms
            .receive(on: RunLoop.main)
            .sink { [weak self] alarms in
                self?.broadcastAlarmDelta(alarms)
            }
    }

    private func rebuildRemoteAlarms() {
        remoteAlarms = remoteAlarmsBySite.values.flatMap { $0 }
            .sorted { $0.triggerTime > $1.triggerTime }
    }

    private func sendBroadcast(_ msg: CommunityMessage) {
        guard let data = try? JSONEncoder().encode(msg),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        if let lineData = line.data(using: .utf8) {
            broadcastSubject.send(lineData)
        }
    }

    // MARK: - UserDefaults Persistence

    private static let configKey = "communityConfig"

    private static func loadConfig() -> CommunityConfig {
        guard let data = UserDefaults.standard.data(forKey: configKey),
              let cfg  = try? JSONDecoder().decode(CommunityConfig.self, from: data)
        else { return CommunityConfig() }
        return cfg
    }

    private func persistConfig() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.configKey)
        }
    }
}
