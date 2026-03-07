// MARK: - EtherNetIPDriver.swift
//
// Allen-Bradley EtherNet/IP (CIP — Common Industrial Protocol) driver.
// Connects to ControlLogix, CompactLogix, and Micro820 PLCs via TCP port 44818.
//
// ── Protocol overview ─────────────────────────────────────────────────────────
//   EtherNet/IP wraps CIP messages inside a 24-byte encapsulation header.
//   This driver uses Explicit (Class 3) messaging — no I/O connections needed:
//     1. Register Session  (cmd 0x0065) → server returns a session handle.
//     2. Send RR Data      (cmd 0x006F) → unconnected CIP read/write per tag.
//     3. Unregister Session on disconnect.
//
// ── CIP Read Tag Service (0x4C) ───────────────────────────────────────────────
//   Supported Allen-Bradley data types:
//     BOOL  (0xC1) — 1-byte boolean          → TagValue.digital
//     SINT  (0xC2) — 1-byte signed int        → TagValue.analog
//     INT   (0xC3) — 2-byte signed int        → TagValue.analog
//     DINT  (0xC4) — 4-byte signed int        → TagValue.analog
//     REAL  (0xCA) — 4-byte IEEE 754 float    → TagValue.analog
//     DWORD (0xD3) — 4-byte unsigned int      → TagValue.analog
//
// ── Endpoint format ───────────────────────────────────────────────────────────
//   DriverConfig.endpoint: "192.168.1.10" or "192.168.1.10:44818"
//   DriverConfig.parameters:
//     pollInterval = "1.0"  (seconds between full poll cycles)
//
// ── Tag maps ──────────────────────────────────────────────────────────────────
//   Each EIPTagMap defines: cipTag (PLC symbolic name) → tagName (app tag).
//   CIP tag examples:
//     "Motor_Speed"                  — controller-scope tag
//     "Program:MainProgram.PV_Flow"  — program-scope tag
//
// ── Threading ────────────────────────────────────────────────────────────────
//   NWConnection runs on `nwQueue` (background serial DispatchQueue).
//   Tag engine updates are dispatched to @MainActor via Task { @MainActor in }.
//   Poll loop runs as a Swift structured concurrency Task; cancelled on disconnect.

import Foundation
import Network

// MARK: - EtherNetIPDriver

/// EtherNet/IP CIP explicit messaging driver.
/// Polls Allen-Bradley PLCs for tag values and forwards them to TagEngine.
@MainActor
final class EtherNetIPDriver: DataDriver {

    // MARK: - DataDriver conformance

    let driverType: DriverType = .ethernetip
    let driverName: String     = "EtherNet/IP"
    private(set) var isConnected: Bool = false

    // MARK: - Dependencies

    private let tagEngine:      TagEngine
    private let configDatabase: ConfigDatabase
    private let configId:       String

    // MARK: - Runtime state

    private var connection:     NWConnection?
    private var sessionHandle:  UInt32 = 0
    private var tagMaps:        [EIPTagMap] = []
    private var pollTask:       Task<Void, Never>?
    private var pollInterval:   Double = 1.0
    private var host:           String = ""
    private var port:           UInt16 = 44818

    private let nwQueue = DispatchQueue(label: "enip.nw", qos: .utility)

    // MARK: - Init

    init(tagEngine: TagEngine, configDatabase: ConfigDatabase,
         configId: String = "default-enip") {
        self.tagEngine      = tagEngine
        self.configDatabase = configDatabase
        self.configId       = configId
    }

    // MARK: - DataDriver

    func connect() async throws {
        // Load driver config
        let configs = (try? await configDatabase.fetchAll()) ?? []
        guard let cfg = configs.first(where: { $0.id == configId && $0.type == .ethernetip }) else {
            throw DriverError.notImplemented(
                "No EtherNet/IP config for id=\(configId) — add one in Settings > Connections")
        }
        guard !cfg.endpoint.isEmpty else {
            throw DriverError.notImplemented("EtherNet/IP endpoint not configured")
        }

        // Parse host:port
        let parts = cfg.endpoint.split(separator: ":", maxSplits: 1)
        host = String(parts[0])
        port = parts.count > 1 ? UInt16(parts[1]) ?? 44818 : 44818
        pollInterval = Double(cfg.parameters["pollInterval"] ?? "1.0") ?? 1.0

        // Load tag maps
        tagMaps = (try? await configDatabase.fetchEIPTagMaps(forDriverId: configId)) ?? []
        guard !tagMaps.isEmpty else {
            throw DriverError.notImplemented(
                "No EtherNet/IP tag maps configured — add tags in Settings > Connections")
        }

        try await openSession()
        isConnected = true
        Logger.shared.info("EtherNet/IP connected to \(host):\(port), \(tagMaps.count) tag(s)")
        startPollLoop()
    }

    func disconnect() async {
        pollTask?.cancel()
        pollTask = nil
        sendUnregisterSession()
        connection?.cancel()
        connection = nil
        sessionHandle = 0
        isConnected = false
        setAllTagsBad()
    }

    // MARK: - Session management

    private func openSession() async throws {
        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: port),
            using: .tcp
        )
        self.connection = conn

        // Wait for connected state
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        cont.resume()
                    case .failed(let err):
                        cont.resume(throwing: DriverError.connectionFailed(err.localizedDescription))
                    case .cancelled:
                        cont.resume(throwing: DriverError.connectionFailed("Connection cancelled"))
                    default: break
                    }
                }
            }
            conn.start(queue: self.nwQueue)
        }

        // Send Register Session
        let regPacket = buildRegisterSession()
        let response  = try await sendReceive(regPacket, on: conn, expectedMinBytes: 28)
        guard response.count >= 28 else {
            throw DriverError.connectionFailed("Register Session: short response (\(response.count) bytes)")
        }
        // Session handle is at bytes 4–7 (little-endian)
        sessionHandle = response.withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian
        }
        guard sessionHandle != 0 else {
            throw DriverError.connectionFailed("Register Session: server returned session handle 0")
        }
        Logger.shared.info("EtherNet/IP session registered, handle=0x\(String(sessionHandle, radix: 16))")
    }

    // MARK: - Poll loop

    private func startPollLoop() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isConnected else { break }
                await self.pollAllTags()
                try? await Task.sleep(nanoseconds: UInt64(self.pollInterval * 1_000_000_000))
            }
        }
    }

    @MainActor
    private func pollAllTags() async {
        guard let conn = connection, sessionHandle != 0 else { return }
        for map in tagMaps {
            guard !Task.isCancelled else { break }
            do {
                let value = try await readTag(map, on: conn)
                tagEngine.updateTag(name: map.tagName, value: value, quality: .good)
            } catch {
                tagEngine.updateTag(name: map.tagName,
                                               value: TagValue.none, quality: .uncertain)
                Logger.shared.warning("EtherNet/IP read \(map.cipTag) failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - CIP Read Tag

    private func readTag(_ map: EIPTagMap, on conn: NWConnection) async throws -> TagValue {
        let request  = buildReadTagRequest(map)
        let response = try await sendReceive(request, on: conn, expectedMinBytes: 44)

        // EIP header is 24 bytes; Send RR Data adds 6 bytes (interface handle 4 + timeout 2)
        // then 2 bytes item count, then items.
        // Item 1: NULL Address (4 bytes: type 0x0000, length 0x0000)
        // Item 2: Unconnected Data (4 bytes header: type 0x00B2, length N), then CIP reply
        // CIP reply offset = 24 (EIP hdr) + 6 + 4 (item1) + 4 (item2 header) = 38
        let cipOffset = 38
        guard response.count >= cipOffset + 6 else {
            throw DriverError.connectionFailed("Read Tag response too short (\(response.count) bytes)")
        }

        // CIP reply structure:
        //   [0]  service (0x4C | 0x80 = 0xCC for success)
        //   [1]  reserved
        //   [2]  general status (0x00 = success)
        //   [3]  additional status size (in words)
        //   [4+addSize*2] data type (2 bytes LE), then value data
        let service = response[cipOffset]
        guard service == 0xCC else {
            let status = response.count > cipOffset + 2 ? response[cipOffset + 2] : 0xFF
            throw DriverError.connectionFailed(
                "CIP error for \(map.cipTag): service=0x\(String(service, radix:16)), status=0x\(String(status, radix:16))")
        }

        let generalStatus = response[cipOffset + 2]
        guard generalStatus == 0x00 else {
            throw DriverError.connectionFailed(
                "CIP general status 0x\(String(generalStatus, radix:16)) for \(map.cipTag)")
        }

        let addStatusWords = Int(response[cipOffset + 3])
        let dataStart      = cipOffset + 4 + addStatusWords * 2
        guard response.count >= dataStart + 6 else {
            throw DriverError.connectionFailed("CIP response data too short for \(map.cipTag)")
        }

        // Data type (2 bytes LE)
        let cipTypeCode = UInt16(response[dataStart]) | (UInt16(response[dataStart + 1]) << 8)
        let valueOffset  = dataStart + 2

        return try decodeCIPValue(
            response: response,
            at: valueOffset,
            cipType: cipTypeCode,
            map: map
        )
    }

    /// Decodes a CIP value at the given offset using the returned CIP type code.
    private func decodeCIPValue(response: Data, at offset: Int,
                                 cipType: UInt16, map: EIPTagMap) throws -> TagValue {
        switch cipType {
        case 0xC1:  // BOOL
            guard response.count > offset else { throw DriverError.connectionFailed("BOOL truncated") }
            let raw = Double(response[offset] != 0 ? 1 : 0) * map.scale + map.offset
            if map.dataType == .bool {
                return .digital(response[offset] != 0)
            }
            return .analog(raw)

        case 0xC2:  // SINT (1 byte signed)
            guard response.count > offset else { throw DriverError.connectionFailed("SINT truncated") }
            let raw = Double(Int8(bitPattern: response[offset])) * map.scale + map.offset
            return .analog(raw)

        case 0xC3:  // INT (2 bytes signed LE)
            guard response.count >= offset + 2 else { throw DriverError.connectionFailed("INT truncated") }
            let i16 = Int16(bitPattern: UInt16(response[offset]) | (UInt16(response[offset+1]) << 8))
            return .analog(Double(i16) * map.scale + map.offset)

        case 0xC4:  // DINT (4 bytes signed LE)
            guard response.count >= offset + 4 else { throw DriverError.connectionFailed("DINT truncated") }
            let i32 = Int32(bitPattern: UInt32(response[offset])
                | (UInt32(response[offset+1]) << 8)
                | (UInt32(response[offset+2]) << 16)
                | (UInt32(response[offset+3]) << 24))
            return .analog(Double(i32) * map.scale + map.offset)

        case 0xCA:  // REAL (4 bytes IEEE 754 LE)
            guard response.count >= offset + 4 else { throw DriverError.connectionFailed("REAL truncated") }
            let bits = UInt32(response[offset])
                | (UInt32(response[offset+1]) << 8)
                | (UInt32(response[offset+2]) << 16)
                | (UInt32(response[offset+3]) << 24)
            let f = Float(bitPattern: bits)
            return .analog(Double(f) * map.scale + map.offset)

        case 0xD3:  // DWORD (4 bytes unsigned LE)
            guard response.count >= offset + 4 else { throw DriverError.connectionFailed("DWORD truncated") }
            let u32 = UInt32(response[offset])
                | (UInt32(response[offset+1]) << 8)
                | (UInt32(response[offset+2]) << 16)
                | (UInt32(response[offset+3]) << 24)
            return .analog(Double(u32) * map.scale + map.offset)

        default:
            throw DriverError.connectionFailed(
                "Unsupported CIP type 0x\(String(cipType, radix:16)) for \(map.cipTag)")
        }
    }

    // MARK: - Packet builders

    /// CIP Encapsulation Register Session packet (28 bytes).
    private func buildRegisterSession() -> Data {
        var d = Data(count: 28)
        // Command: 0x0065 LE
        d[0] = 0x65; d[1] = 0x00
        // Length: 4 bytes of payload
        d[2] = 0x04; d[3] = 0x00
        // Session Handle, Status, Sender Context, Options: all zeros
        // Payload: Protocol Version = 1, Options = 0
        d[24] = 0x01; d[25] = 0x00
        d[26] = 0x00; d[27] = 0x00
        return d
    }

    /// CIP Encapsulation + Send RR Data + CIP Read Tag Service packet.
    private func buildReadTagRequest(_ map: EIPTagMap) -> Data {
        // Build CIP Read Tag request
        let tagBytes  = Array(map.cipTag.utf8)
        let tagLen    = tagBytes.count
        let padded    = tagLen % 2 == 0   // no padding needed if even length
        let segBytes  = 2 + tagLen + (padded ? 0 : 1)  // 0x91 + length + tag bytes (+ 1 pad if odd)
        let pathWords = UInt8((segBytes + 1) / 2)       // path size in 16-bit words (ceiling)

        var cipMsg = Data()
        cipMsg.append(0x4C)           // Read Tag Service
        cipMsg.append(pathWords)      // Request Path Size (words)
        cipMsg.append(0x91)           // Symbolic Segment type
        cipMsg.append(UInt8(tagLen))  // Tag name length
        cipMsg.append(contentsOf: tagBytes)
        if tagLen % 2 != 0 { cipMsg.append(0x00) }  // pad to 16-bit boundary
        cipMsg.append(0x01); cipMsg.append(0x00)     // Element count: 1

        // Build Send RR Data payload
        var payload = Data()
        payload.append(contentsOf: [0x00, 0x00, 0x00, 0x00])  // Interface Handle (CIP = 0)
        payload.append(contentsOf: [0x0A, 0x00])               // Timeout: 10 seconds
        payload.append(contentsOf: [0x02, 0x00])               // Item Count: 2

        // Item 1: NULL Address Item (type 0x0000, length 0)
        payload.append(contentsOf: [0x00, 0x00, 0x00, 0x00])

        // Item 2: Unconnected Data Item (type 0x00B2, length = CIP message length)
        let cipLen = UInt16(cipMsg.count)
        payload.append(0xB2); payload.append(0x00)             // type 0x00B2
        payload.append(UInt8(cipLen & 0xFF))
        payload.append(UInt8((cipLen >> 8) & 0xFF))
        payload.append(contentsOf: cipMsg)

        // Build EIP encapsulation header
        var header = Data(count: 24)
        let cmd: UInt16 = 0x006F
        header[0] = UInt8(cmd & 0xFF)
        header[1] = UInt8((cmd >> 8) & 0xFF)
        let payLen = UInt16(payload.count)
        header[2] = UInt8(payLen & 0xFF)
        header[3] = UInt8((payLen >> 8) & 0xFF)
        // Session Handle (bytes 4–7)
        withUnsafeBytes(of: sessionHandle.littleEndian) { header.replaceSubrange(4..<8, with: $0) }
        // Status, Sender Context, Options: already zero

        return header + payload
    }

    /// Sends Unregister Session before closing (best-effort, no error if it fails).
    private func sendUnregisterSession() {
        guard let conn = connection, sessionHandle != 0 else { return }
        var hdr = Data(count: 24)
        hdr[0] = 0x66; hdr[1] = 0x00  // Unregister Session command
        withUnsafeBytes(of: sessionHandle.littleEndian) { hdr.replaceSubrange(4..<8, with: $0) }
        conn.send(content: hdr, completion: .idempotent)
    }

    // MARK: - Send / Receive

    /// Sends `data` and waits for at least `expectedMinBytes` of response.
    private func sendReceive(_ data: Data, on conn: NWConnection,
                              expectedMinBytes: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: DriverError.connectionFailed(error.localizedDescription))
                    return
                }
                conn.receive(minimumIncompleteLength: expectedMinBytes,
                             maximumLength: 4096) { data, _, isEOF, error in
                    if let error {
                        cont.resume(throwing: DriverError.connectionFailed(error.localizedDescription))
                    } else if let data, !data.isEmpty {
                        cont.resume(returning: data)
                    } else {
                        cont.resume(throwing: DriverError.connectionFailed(
                            isEOF ? "Connection closed by PLC" : "Empty response from PLC"))
                    }
                }
            })
        }
    }

    // MARK: - Helpers

    private func setAllTagsBad() {
        for map in tagMaps {
            tagEngine.updateTag(name: map.tagName, value: TagValue.none, quality: .bad)
        }
    }
}
