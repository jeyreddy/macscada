import Foundation

// MARK: - CommunityModels.swift
//
// Data models for the Community Federation feature.
//
// ── What is Community Federation? ────────────────────────────────────────────
//   Community Federation allows multiple IndustrialHMI instances on the same
//   network to share live tag values with each other over WebSocket connections.
//   This creates a "site network" where each instance can monitor remote sites
//   without duplicating OPC-UA or Modbus connections.
//
// ── Architecture ─────────────────────────────────────────────────────────────
//   Each instance runs:
//     • CommunityServer — WebSocket server listening on listenPort (default 9001)
//     • CommunityPeerConnection — one outbound WebSocket client per configured peer
//   Both use CommunityMessage as the wire protocol.
//
// ── Tag naming for remote tags ────────────────────────────────────────────────
//   Remote tags arrive with a site prefix: "<SiteName>/<tagName>"
//   e.g. "Site2/Tank1_Level" — the "/" is the delimiter.
//   DataService.startDataCollection() uses this prefix to filter broadcast:
//     if !tag.name.contains("/") { communityService.broadcastTagUpdate(tag) }
//   This prevents forwarding already-remote tags, avoiding infinite loops.
//
// ── Authentication ────────────────────────────────────────────────────────────
//   The `secret` in CommunityConfig is a shared HMAC key.
//   Peers include a hash of (secret + timestamp) in their HELLO message.
//   CommunityServer verifies this before accepting the connection.
//
// ── Persistence ───────────────────────────────────────────────────────────────
//   CommunityConfig is persisted to UserDefaults under key "communityConfig"
//   so server port, peer list, and enabled state survive app restarts.

// MARK: - CommunityConfig

/// Persisted configuration for the community federation feature.
/// Stored as JSON in UserDefaults under the key "communityConfig".
struct CommunityConfig: Codable {
    var siteName:   String = "Site1"
    var listenPort: Int    = 9001
    var secret:     String = ""
    var enabled:    Bool   = false
    var peers:      [CommunityPeer] = []
}

// MARK: - CommunityPeer

/// A remote peer that this instance should connect to.
struct CommunityPeer: Identifiable, Codable, Equatable {
    var id:      UUID   = UUID()
    var name:    String          // displayed as the SiteName prefix on remote tags
    var host:    String
    var port:    Int    = 9001
    var enabled: Bool   = true
}

// MARK: - PeerStatus

enum PeerStatus: String, Equatable {
    case disconnected
    case connecting
    case connected
    case rejected
}

// MARK: - PeerConnectionStatus

struct PeerConnectionStatus: Identifiable {
    var id:           UUID          // matches CommunityPeer.id
    var status:       PeerStatus    = .disconnected
    var lastError:    String?       = nil
    var remoteSiteId: UUID?         = nil
}

// MARK: - Wire Protocol Messages

/// Codable envelope for every community wire message.
struct CommunityMessage: Codable {
    var type:    String
    var payload: [String: CommunityValue]

    init(type: String, payload: [String: CommunityValue] = [:]) {
        self.type    = type
        self.payload = payload
    }
}

/// A simple sum type that can hold the JSON value types we need.
enum CommunityValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([CommunityValue])
    case object([String: CommunityValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil()                       { self = .null; return }
        if let v = try? c.decode(Bool.self)    { self = .bool(v);   return }
        if let v = try? c.decode(Double.self)  { self = .number(v); return }
        if let v = try? c.decode(String.self)  { self = .string(v); return }
        if let v = try? c.decode([CommunityValue].self)         { self = .array(v);  return }
        if let v = try? c.decode([String: CommunityValue].self) { self = .object(v); return }
        self = .null
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:          try c.encodeNil()
        case .bool(let v):   try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v):  try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    // MARK: Convenience Accessors

    var stringValue:  String? { if case .string(let v)  = self { return v } else { return nil } }
    var numberValue:  Double? { if case .number(let v)  = self { return v } else { return nil } }
    var boolValue:    Bool?   { if case .bool(let v)    = self { return v } else { return nil } }
    var arrayValue:   [CommunityValue]?         { if case .array(let v)  = self { return v } else { return nil } }
    var objectValue:  [String: CommunityValue]? { if case .object(let v) = self { return v } else { return nil } }
}

// MARK: - RemoteTagSnapshot

/// Compact representation of a tag sent over the wire.
struct RemoteTagSnapshot: Codable {
    var name:      String
    var value:     Double?
    var quality:   Int          // TagQuality.rawValue (Int)
    var unit:      String?
    var dataType:  String       // TagDataType.rawValue
    var timestamp: TimeInterval // Date.timeIntervalSince1970
}

// MARK: - RemoteAlarmSnapshot

/// Compact representation of an alarm event sent over the wire.
struct RemoteAlarmSnapshot: Codable {
    var id:          String       // UUID string
    var tagName:     String
    var severity:    String       // AlarmSeverity.rawValue
    var state:       String       // AlarmState.rawValue
    var message:     String
    var value:       Double?
    var triggerTime: TimeInterval // Date.timeIntervalSince1970
}
