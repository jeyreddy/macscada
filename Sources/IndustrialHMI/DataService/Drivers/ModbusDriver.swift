// MARK: - ModbusDriver.swift
//
// Modbus protocol driver supporting all three physical transport modes:
//   TCP — MBAP framing over TCP/IP (default port 502)
//   RTU — binary framing with CRC-16 over RS-485/RS-232 serial port
//   ASCII — colon-delimited hex framing with LRC over serial port
//
// ── Architecture ──────────────────────────────────────────────────────────────
//   ModbusDriver implements DataDriver. DataService creates one instance per
//   enabled Modbus DriverConfig row and calls connect() / disconnect().
//   The driver self-polls every `pollInterval` seconds for all register maps
//   assigned to it (loaded from ConfigDatabase.loadModbusRegisterMaps()).
//
// ── Endpoint Format ───────────────────────────────────────────────────────────
//   TCP:   "192.168.1.10" or "192.168.1.10:502"
//   RTU:   "rtu:/dev/cu.usbserial-0001"
//   ASCII: "ascii:/dev/cu.usbserial-0001"
//   ModbusDeviceConfig.init(driverConfig:) parses the endpoint and throws
//   DriverError.connectionFailed if the format is invalid.
//
// ── Register Mapping ──────────────────────────────────────────────────────────
//   Each ModbusRegisterMap defines one tag: slaveId, functionCode, address,
//   dataType, and linear scaling (tagValue = rawValue * scale + valueOffset).
//   Function codes: 1=Coil, 2=DiscreteInput, 3=HoldingRegister, 4=InputRegister.
//   Data types: uint16, int16, uint32, int32, float32, coil.
//   Float32 and 32-bit integers read two consecutive registers (big-endian word order).
//
// ── TCP Connection ────────────────────────────────────────────────────────────
//   NWConnection on nwQueue (background serial). MBAP header: transactionId (2B),
//   protocolId=0 (2B), length (2B), unitId (1B). PDU follows (functionCode + data).
//   Each request uses a monotonically increasing transactionId; responses are
//   matched by transactionId. Timeout per request: 3 seconds.
//
// ── Serial Port (RTU/ASCII) ───────────────────────────────────────────────────
//   ModbusSerialPort wraps POSIX termios. RTU uses CRC-16/ARC for error detection.
//   ASCII uses LRC (sum of hex nibble pairs, two's complement). Inter-frame delay
//   enforced via interFrameDelay (3.5 character times, min 1.75 ms per spec §2.5.1.1).
//
// ── Tag Updates ───────────────────────────────────────────────────────────────
//   After decoding each register, the driver calls:
//   tagEngine.updateTagFromDriver(name: map.tagName, value: .analog(scaled), quality: .good)
//   Failed reads set quality = .uncertain; connection loss sets all mapped tags = .bad.

import Foundation
import Network
import Combine

// MARK: - ModbusMode

/// Physical transport + framing used by a Modbus device.
enum ModbusMode: String, Codable, CaseIterable {
    /// Modbus TCP — MBAP framing over TCP/IP (RFC 6188).
    case tcp   = "TCP"
    /// Modbus RTU — binary serial framing with CRC-16.
    case rtu   = "RTU"
    /// Modbus ASCII — colon-delimited hex serial framing with LRC.
    case ascii = "ASCII"

    var isSerial: Bool { self == .rtu || self == .ascii }
}

// MARK: - ModbusDeviceConfig

/// Runtime parameters parsed from a DriverConfig record.
///
/// Endpoint formats:
///   TCP:   `"host"` or `"host:502"`
///   RTU:   `"rtu:/dev/cu.usbserial-0001"`
///   ASCII: `"ascii:/dev/cu.usbserial-0001"`
///
/// DriverConfig.parameters keys (serial only):
///   baud=9600 | databits=8 | parity=N | stopbits=1
///
/// DriverConfig.parameters keys (all modes):
///   pollInterval=1.0
struct ModbusDeviceConfig {
    var mode:         ModbusMode
    var host:         String           // TCP
    var port:         UInt16           // TCP
    var serialParams: ModbusSerialParams?  // RTU / ASCII
    var pollInterval: Double

    init(driverConfig cfg: DriverConfig) throws {
        pollInterval = Double(cfg.parameters["pollInterval"] ?? "1.0") ?? 1.0
        let ep = cfg.endpoint

        if ep.lowercased().hasPrefix("rtu:") {
            mode = .rtu
            let path = String(ep.dropFirst("rtu:".count))
            guard !path.isEmpty else {
                throw DriverError.connectionFailed("Modbus RTU endpoint missing path (use rtu:/dev/cu.xxx)")
            }
            serialParams = ModbusSerialParams(path: path, parameters: cfg.parameters)
            host = ""; port = 0

        } else if ep.lowercased().hasPrefix("ascii:") {
            mode = .ascii
            let path = String(ep.dropFirst("ascii:".count))
            guard !path.isEmpty else {
                throw DriverError.connectionFailed("Modbus ASCII endpoint missing path (use ascii:/dev/cu.xxx)")
            }
            serialParams = ModbusSerialParams(path: path, parameters: cfg.parameters)
            host = ""; port = 0

        } else {
            // TCP — existing "host" or "host:port" format
            mode = .tcp
            serialParams = nil
            if ep.contains(":"), let sep = ep.lastIndex(of: ":") {
                host = String(ep[ep.startIndex..<sep])
                port = UInt16(ep[ep.index(after: sep)...]) ?? 502
            } else {
                host = ep
                port = 502
            }
            guard !host.isEmpty else {
                throw DriverError.connectionFailed("Modbus TCP host is empty — set it in Settings.")
            }
        }
    }
}

// MARK: - ModbusDriver

/// Multi-mode Modbus client driver.
///
/// **Transport modes**
/// | Mode  | Transport      | Framing                              |
/// |-------|----------------|--------------------------------------|
/// | TCP   | Network.framework NWConnection | MBAP header (7 bytes) + PDU  |
/// | RTU   | POSIX serial (termios)         | [SlaveId][PDU][CRC16 LE]     |
/// | ASCII | POSIX serial (termios)         | :[ADDR][PDU][LRC]\r\n (hex)  |
///
/// All three modes share the same:
/// - Register map storage (`ModbusRegisterMap`) and tag decode logic
/// - Polling / batching loop (max 125 registers per request)
/// - Auto-reconnect with exponential back-off
///
/// **Endpoint syntax in DriverConfig:**
/// ```
///   TCP:   "192.168.1.100:502"
///   RTU:   "rtu:/dev/cu.usbserial-0001"
///   ASCII: "ascii:/dev/cu.usbserial-0001"
/// ```
@MainActor
final class ModbusDriver: ObservableObject, DataDriver {

    var driverType: DriverType { .modbus }
    var driverName: String     { "Modbus" }
    @Published private(set) var isConnected = false

    private let tagEngine:      TagEngine
    private let configDatabase: ConfigDatabase
    private let configId:       String?   // nil = load first enabled Modbus config

    // MARK: Config

    private var deviceConfig: ModbusDeviceConfig?
    private var registerMaps: [ModbusRegisterMap] = []
    private var mode:         ModbusMode = .tcp

    // MARK: TCP transport

    private var connection:     NWConnection?
    private var receiveBuffer:  Data   = Data()
    private var pendingRequest: (transId: UInt16, cont: CheckedContinuation<Data, Error>)?
    private var transactionId:  UInt16 = 1
    private let nwQueue = DispatchQueue(label: "com.industrialhmi.modbus.tcp", qos: .utility)

    // MARK: Serial transport (RTU + ASCII)

    private var serialPort:    ModbusSerialPort?
    private var serialBuffer:  Data   = Data()
    /// Active serial request: continuation + expected RTU response byte count (ignored for ASCII).
    private var serialPending: (cont: CheckedContinuation<Data, Error>, expectedLen: Int)?

    // MARK: Background tasks

    private var pollTask:      Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    // MARK: - Init

    init(tagEngine: TagEngine, configDatabase: ConfigDatabase, configId: String? = nil) {
        self.tagEngine      = tagEngine
        self.configDatabase = configDatabase
        self.configId       = configId
    }

    // MARK: - DataDriver

    func connect() async throws {
        guard !isConnected else { return }

        let cfgs: [DriverConfig]
        if let id = configId {
            let all = (try? await configDatabase.fetchAll()) ?? []
            cfgs = all.filter { $0.id == id }
        } else {
            cfgs = (try? await configDatabase.fetch(type: .modbus)) ?? []
        }
        guard let cfg = cfgs.first(where: { $0.enabled }) ?? cfgs.first else {
            throw DriverError.notImplemented("No Modbus device configured — add one in Settings.")
        }

        let devCfg = try ModbusDeviceConfig(driverConfig: cfg)
        deviceConfig = devCfg
        mode         = devCfg.mode

        if let id = configId {
            let perDriver = (try? await configDatabase.fetchModbusRegisterMaps(forDriverId: id)) ?? []
            registerMaps = perDriver.isEmpty
                ? ((try? await configDatabase.fetchModbusRegisterMaps()) ?? [])
                : perDriver
        } else {
            registerMaps = (try? await configDatabase.fetchModbusRegisterMaps()) ?? []
        }
        guard !registerMaps.isEmpty else {
            throw DriverError.notImplemented("No Modbus register maps — add them in Settings.")
        }

        switch devCfg.mode {
        case .tcp:
            try await openTCPConnection(to: devCfg)
        case .rtu, .ascii:
            try openSerialPort(params: devCfg.serialParams!)
            isConnected = true
            startPollLoop()
        }

        startAutoReconnect()
        Logger.shared.info("Modbus \(devCfg.mode.rawValue): connected — \(registerMaps.count) register map(s)")
    }

    func disconnect() async {
        stopTasks()

        // Cancel in-flight TCP request
        if let p = pendingRequest {
            pendingRequest = nil
            p.cont.resume(throwing: DriverError.connectionFailed("Driver disconnecting"))
        }
        // Cancel in-flight serial request
        if let p = serialPending {
            serialPending = nil
            p.cont.resume(throwing: DriverError.connectionFailed("Driver disconnecting"))
        }

        if mode.isSerial {
            serialPort?.close()
            serialPort = nil
            serialBuffer.removeAll()
        } else {
            connection?.cancel()
            connection = nil
            receiveBuffer.removeAll()
        }

        isConnected = false
        markTagsUncertain()
        Logger.shared.info("Modbus \(mode.rawValue): disconnected")
    }

    // MARK: - TCP Open

    private func openTCPConnection(to cfg: ModbusDeviceConfig) async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: cfg.port) else {
            throw DriverError.connectionFailed("Modbus invalid port: \(cfg.port)")
        }
        let conn = NWConnection(host: NWEndpoint.Host(cfg.host), port: nwPort, using: .tcp)
        connection = conn

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isConnected = true
                        self.startTCPReceive(on: conn)
                        self.startPollLoop()
                        cont.resume()
                    case .failed(let err):
                        cont.resume(throwing: DriverError.connectionFailed(err.localizedDescription))
                    case .cancelled:
                        cont.resume(throwing: DriverError.connectionFailed("Connection cancelled"))
                    default: break
                    }
                }
            }
            conn.start(queue: nwQueue)
        }
    }

    // MARK: - Serial Open

    private func openSerialPort(params: ModbusSerialParams) throws {
        let port = ModbusSerialPort()
        port.onReceive = { [weak self] data in self?.onSerialReceive(data) }
        port.onError   = { [weak self] in self?.handleConnectionLost() }
        try port.open(params: params)
        serialPort   = port
        serialBuffer = Data()
    }

    // MARK: - Auto-Reconnect

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
                Logger.shared.info("Modbus \(self.mode.rawValue): reconnect #\(attempt + 1) in \(Int(delay))s")
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let cfg = self.deviceConfig else { continue }

                self.pollTask?.cancel(); self.pollTask = nil
                self.serialBuffer.removeAll()
                self.receiveBuffer.removeAll()
                self.connection?.cancel(); self.connection = nil

                do {
                    switch cfg.mode {
                    case .tcp:
                        try await self.openTCPConnection(to: cfg)
                    case .rtu, .ascii:
                        self.serialPort?.close(); self.serialPort = nil
                        try self.openSerialPort(params: cfg.serialParams!)
                        self.isConnected = true
                        self.startPollLoop()
                    }
                    attempt = 0
                } catch {
                    attempt += 1
                    Logger.shared.warning("Modbus reconnect failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - TCP Receive Loop

    private func startTCPReceive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.receiveBuffer += data
                    self.processTCPBuffer()
                }
                if error != nil || done {
                    self.handleConnectionLost(); return
                }
                self.startTCPReceive(on: conn)
            }
        }
    }

    // MARK: - MBAP Framing (TCP)

    /// MBAP header: [transId:2][proto:2=0][length:2][unitId:1] → 7 bytes total.
    private func processTCPBuffer() {
        while receiveBuffer.count >= 7 {
            let transId = UInt16(receiveBuffer[0]) << 8 | UInt16(receiveBuffer[1])
            let length  = Int(receiveBuffer[4]) << 8   | Int(receiveBuffer[5])
            let total   = 6 + length
            guard receiveBuffer.count >= total else { break }

            let pdu = Data(receiveBuffer[7..<total])   // PDU after 7-byte MBAP header
            receiveBuffer.removeFirst(total)

            if let p = pendingRequest, p.transId == transId {
                pendingRequest = nil
                p.cont.resume(returning: pdu)
            }
        }
    }

    // MARK: - Serial Receive Callback

    private func onSerialReceive(_ data: Data) {
        serialBuffer += data
        switch mode {
        case .rtu:   processRTUBuffer()
        case .ascii: processASCIIBuffer()
        case .tcp:   break   // shouldn't happen
        }
    }

    // MARK: - RTU Framing

    /// RTU response: [slaveId:1][FC:1][data...][CRC_lo:1][CRC_hi:1]
    ///
    /// Exception response (FC high bit set) is always exactly 5 bytes.
    /// Normal response length is pre-computed from the request PDU.
    private func processRTUBuffer() {
        guard let pending = serialPending else { return }

        // Exception detection: peek at byte[1] high bit after we have ≥5 bytes
        if serialBuffer.count >= 5 && (serialBuffer[1] & 0x80 != 0) {
            completeRTUFrame(byteCount: 5, pending: pending)
            return
        }

        guard serialBuffer.count >= pending.expectedLen else { return }
        completeRTUFrame(byteCount: pending.expectedLen, pending: pending)
    }

    private func completeRTUFrame(
        byteCount: Int,
        pending: (cont: CheckedContinuation<Data, Error>, expectedLen: Int)
    ) {
        let frame = Data(serialBuffer.prefix(byteCount))
        serialBuffer.removeFirst(byteCount)
        serialPending = nil

        // Verify CRC-16 (last 2 bytes little-endian)
        let body        = frame.dropLast(2)
        let rxCRC       = UInt16(frame[byteCount - 2]) | (UInt16(frame[byteCount - 1]) << 8)
        let computedCRC = modbusCRC16(body)
        guard rxCRC == computedCRC else {
            pending.cont.resume(throwing: DriverError.connectionFailed(
                "Modbus RTU CRC error (rx=0x\(String(rxCRC, radix: 16)) vs 0x\(String(computedCRC, radix: 16)))"))
            return
        }

        // Return PDU: skip the slaveId prefix byte
        pending.cont.resume(returning: Data(frame.dropFirst()))   // [FC][data...]
    }

    // MARK: - ASCII Framing

    /// ASCII frame: `:[ADDR:2][PDU_HEX][LRC:2]\r\n`
    private func processASCIIBuffer() {
        guard let pending = serialPending else { return }

        // Scan for \r\n terminator
        guard let crIdx = findCRLF(in: serialBuffer) else { return }

        let frame = Data(serialBuffer[..<crIdx])              // everything before \r
        serialBuffer.removeFirst(crIdx + 2)                   // +2 for \r\n
        serialPending = nil

        do {
            let pdu = try decodeASCIIFrame(frame)
            pending.cont.resume(returning: pdu)
        } catch {
            pending.cont.resume(throwing: error)
        }
    }

    /// Returns the index of `\r` in a `\r\n` sequence, or `nil` if not found.
    private func findCRLF(in data: Data) -> Int? {
        for i in 0..<(data.count - 1) {
            if data[i] == 0x0D && data[i + 1] == 0x0A { return i }
        }
        return nil
    }

    /// Decode an ASCII frame (without leading `:` or trailing `\r\n`).
    ///
    /// Frame (binary view): `[addrByte][fcByte][data...][lrcByte]`
    /// Each binary byte is encoded as 2 uppercase hex ASCII characters.
    private func decodeASCIIFrame(_ frame: Data) throws -> Data {
        // Minimum: `:` + 2-char addr + 2-char FC + 2-char LRC = 8 ASCII chars including colon.
        // We receive without the colon (stripped in processASCIIBuffer).
        // Expect the buffer to start with the leading `:` char (0x3A).
        var hex = frame
        if hex.first == 0x3A { hex = Data(hex.dropFirst()) }   // strip ':'

        guard hex.count >= 6 && hex.count % 2 == 0 else {
            throw DriverError.connectionFailed("Modbus ASCII frame too short or odd length")
        }

        // Decode hex pairs → binary bytes
        var bytes = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex {
            let hi = hexNibble(hex[i])
            let lo = hexNibble(hex[hex.index(after: i)])
            guard hi != 0xFF && lo != 0xFF else {
                throw DriverError.connectionFailed("Modbus ASCII non-hex character in frame")
            }
            bytes.append((hi << 4) | lo)
            hex.formIndex(&i, offsetBy: 2)
        }

        // Verify LRC
        let body   = Array(bytes.dropLast())
        let rxLRC  = bytes.last!
        let calLRC = modbusLRC(body)
        guard rxLRC == calLRC else {
            throw DriverError.connectionFailed(
                "Modbus ASCII LRC error (rx=0x\(String(rxLRC, radix: 16)) vs 0x\(String(calLRC, radix: 16)))")
        }

        // Return PDU: skip slaveId (byte 0), drop trailing LRC
        return Data(body.dropFirst())    // [FC][data...]
    }

    private func hexNibble(_ c: UInt8) -> UInt8 {
        switch c {
        case 0x30...0x39: return c - 0x30           // '0'–'9'
        case 0x41...0x46: return c - 0x41 + 10      // 'A'–'F'
        case 0x61...0x66: return c - 0x61 + 10      // 'a'–'f'
        default:          return 0xFF                // invalid
        }
    }

    // MARK: - Connection Lost

    private func handleConnectionLost() {
        guard isConnected else { return }
        isConnected = false
        pollTask?.cancel(); pollTask = nil

        if let p = pendingRequest { pendingRequest = nil; p.cont.resume(throwing: DriverError.connectionFailed("Connection lost")) }
        if let p = serialPending  { serialPending  = nil; p.cont.resume(throwing: DriverError.connectionFailed("Connection lost")) }

        receiveBuffer.removeAll()
        serialBuffer.removeAll()
        markTagsUncertain()
        Logger.shared.warning("Modbus \(mode.rawValue): connection lost — reconnect loop will retry")
    }

    // MARK: - Poll Loop

    private func startPollLoop() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.isConnected else { break }
                await self.pollAllRegisters()
                let interval = self.deviceConfig?.pollInterval ?? 1.0
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func pollAllRegisters() async {
        let grouped = Dictionary(grouping: registerMaps) { "\($0.slaveId)-\($0.functionCode)" }
        for (_, maps) in grouped {
            let sorted = maps.sorted { $0.address < $1.address }
            for batch in buildBatches(sorted) {
                guard isConnected else { return }
                do {
                    let pdu = try await sendRead(batch: batch)
                    decodeBatch(batch: batch, pdu: pdu)
                } catch {
                    Logger.shared.error("Modbus poll [FC\(batch.functionCode) @\(batch.startAddress)]: \(error.localizedDescription)")
                }
                // RTU inter-frame gap between requests (not needed for TCP or ASCII)
                if mode == .rtu, let delay = deviceConfig?.serialParams?.interFrameDelay {
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        }
    }

    // MARK: - Register Batching

    struct RegisterBatch {
        var slaveId:      UInt8
        var functionCode: UInt8
        var startAddress: UInt16
        var count:        Int         // 16-bit word slots (or coil count)
        var maps:         [ModbusRegisterMap]
    }

    private func buildBatches(_ maps: [ModbusRegisterMap]) -> [RegisterBatch] {
        guard !maps.isEmpty else { return [] }
        let maxCount = 125
        var batches: [RegisterBatch] = []
        var batch = RegisterBatch(
            slaveId: maps[0].slaveId, functionCode: maps[0].functionCode,
            startAddress: maps[0].address, count: wordSizeOf(maps[0]), maps: [maps[0]])

        for map in maps.dropFirst() {
            let nextExpected = UInt16(batch.startAddress) + UInt16(batch.count)
            let words = wordSizeOf(map)
            if map.address == nextExpected && batch.count + words <= maxCount {
                batch.count += words
                batch.maps.append(map)
            } else {
                batches.append(batch)
                batch = RegisterBatch(
                    slaveId: map.slaveId, functionCode: map.functionCode,
                    startAddress: map.address, count: words, maps: [map])
            }
        }
        batches.append(batch)
        return batches
    }

    private func wordSizeOf(_ map: ModbusRegisterMap) -> Int {
        switch map.dataType {
        case .uint16, .int16, .coil: return 1
        case .uint32, .int32, .float32: return 2
        }
    }

    // MARK: - Read Request

    private func sendRead(batch: RegisterBatch) async throws -> Data {
        let pdu = Data([
            batch.functionCode,
            UInt8(batch.startAddress >> 8), UInt8(batch.startAddress & 0xFF),
            UInt8(batch.count >> 8),        UInt8(batch.count & 0xFF)
        ])
        return try await sendRequest(pdu: pdu, slaveId: batch.slaveId)
    }

    // MARK: - Write API (called by DataService / AgentService)

    /// FC05 — Write Single Coil
    func writeCoil(slaveId: UInt8, address: UInt16, value: Bool) async throws {
        let coilValue: UInt16 = value ? 0xFF00 : 0x0000
        let pdu = Data([
            0x05,
            UInt8(address >> 8),   UInt8(address & 0xFF),
            UInt8(coilValue >> 8), UInt8(coilValue & 0xFF)
        ])
        _ = try await sendRequest(pdu: pdu, slaveId: slaveId)
    }

    /// FC06 — Write Single Holding Register
    func writeSingleRegister(slaveId: UInt8, address: UInt16, value: UInt16) async throws {
        let pdu = Data([
            0x06,
            UInt8(address >> 8), UInt8(address & 0xFF),
            UInt8(value >> 8),   UInt8(value & 0xFF)
        ])
        _ = try await sendRequest(pdu: pdu, slaveId: slaveId)
    }

    /// FC16 — Write Multiple Holding Registers (32-bit and float values)
    func writeMultipleRegisters(slaveId: UInt8, address: UInt16, values: [UInt16]) async throws {
        let count = UInt16(values.count)
        var pdu = Data([
            0x10,
            UInt8(address >> 8), UInt8(address & 0xFF),
            UInt8(count >> 8),   UInt8(count & 0xFF),
            UInt8(count * 2)     // byte count
        ])
        for v in values {
            pdu += Data([UInt8(v >> 8), UInt8(v & 0xFF)])
        }
        _ = try await sendRequest(pdu: pdu, slaveId: slaveId)
    }

    // MARK: - Request / Response Engine

    private func sendRequest(pdu: Data, slaveId: UInt8) async throws -> Data {
        switch mode {
        case .tcp:   return try await sendTCPRequest(pdu: pdu, slaveId: slaveId)
        case .rtu:   return try await sendRTURequest(pdu: pdu, slaveId: slaveId)
        case .ascii: return try await sendASCIIRequest(pdu: pdu, slaveId: slaveId)
        }
    }

    // MARK: TCP Request

    private func sendTCPRequest(pdu: Data, slaveId: UInt8) async throws -> Data {
        guard isConnected, let conn = connection else { throw DriverError.notConnected }

        let tId = transactionId
        transactionId = transactionId &+ 1

        // Build MBAP header: [transId:2][proto:2=0][length:2][unitId:1]
        let payloadLen = UInt16(1 + pdu.count)
        var packet = Data(capacity: 7 + pdu.count)
        packet += Data([UInt8(tId >> 8), UInt8(tId & 0xFF)])
        packet += Data([0x00, 0x00])
        packet += Data([UInt8(payloadLen >> 8), UInt8(payloadLen & 0xFF)])
        packet += Data([slaveId])
        packet += pdu

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            self.pendingRequest = (tId, cont)

            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self,
                      let p = self.pendingRequest, p.transId == tId else { return }
                self.pendingRequest = nil
                cont.resume(throwing: DriverError.connectionFailed("TCP timeout (transId \(tId))"))
            }

            conn.send(content: packet, completion: .contentProcessed { [weak self] error in
                if let error {
                    Task { @MainActor [weak self] in
                        guard let self,
                              let p = self.pendingRequest, p.transId == tId else { return }
                        self.pendingRequest = nil
                        cont.resume(throwing: DriverError.connectionFailed(error.localizedDescription))
                    }
                }
            })
        }
    }

    // MARK: RTU Request

    /// Sends a binary Modbus RTU frame and waits for the response.
    ///
    /// Frame sent:   `[slaveId][PDU...][CRC_lo][CRC_hi]`
    /// Frame received: `[slaveId][FC][data...][CRC_lo][CRC_hi]`
    private func sendRTURequest(pdu: Data, slaveId: UInt8) async throws -> Data {
        guard isConnected, let port = serialPort else { throw DriverError.notConnected }

        // Build frame body (without CRC)
        var body = Data([slaveId]) + pdu
        let crc  = modbusCRC16(body)
        body += Data([UInt8(crc & 0xFF), UInt8(crc >> 8)])   // CRC little-endian

        let expectedLen = rtuExpectedLength(pdu: pdu)

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            self.serialPending = (cont, expectedLen)

            // 1-second response timeout
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, let p = self.serialPending else { return }
                self.serialPending = nil
                self.serialBuffer.removeAll()
                p.cont.resume(throwing: DriverError.connectionFailed(
                    "RTU timeout (slaveId \(slaveId), FC \(pdu.first ?? 0))"))
            }

            port.write(body)
        }
    }

    /// Expected total byte count of a Modbus RTU response, including slaveId and CRC.
    private func rtuExpectedLength(pdu: Data) -> Int {
        guard !pdu.isEmpty else { return 5 }
        let fc = pdu[0]
        switch fc {
        case 0x01, 0x02:    // Read Coils / Discrete Inputs
            guard pdu.count >= 5 else { return 5 }
            let count = Int(pdu[3]) << 8 | Int(pdu[4])   // requested coil count
            return 5 + (count + 7) / 8                    // [slaveId][FC][byteCount][data...][CRC×2]
        case 0x03, 0x04:    // Read Holding / Input Registers
            guard pdu.count >= 5 else { return 5 }
            let count = Int(pdu[3]) << 8 | Int(pdu[4])   // requested register count
            return 5 + count * 2                           // [slaveId][FC][byteCount][data...][CRC×2]
        default:            // FC05, FC06, FC16 write responses (echo)
            return 8         // [slaveId][FC][addr×2][val×2][CRC×2]
        }
    }

    // MARK: ASCII Request

    /// Sends a Modbus ASCII frame and waits for the `\r\n`-terminated response.
    ///
    /// Frame sent:     `:[ADDR:2][FC:2][data:N×2][LRC:2]\r\n`
    /// Frame received: `:[ADDR:2][FC:2][data:M×2][LRC:2]\r\n`
    private func sendASCIIRequest(pdu: Data, slaveId: UInt8) async throws -> Data {
        guard isConnected, let port = serialPort else { throw DriverError.notConnected }

        // Binary payload for LRC: slaveId + PDU bytes
        var binaryForLRC = [UInt8]([slaveId]) + pdu
        let lrc = modbusLRC(binaryForLRC)
        binaryForLRC.append(lrc)

        // ASCII-encode: each byte → 2 uppercase hex characters
        let hexBody = binaryForLRC.map { String(format: "%02X", $0) }.joined()
        let frame   = ":\(hexBody)\r\n"
        let txData  = Data(frame.utf8)

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            self.serialPending = (cont, 0)    // expectedLen unused for ASCII

            // 1-second response timeout
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, let p = self.serialPending else { return }
                self.serialPending = nil
                self.serialBuffer.removeAll()
                p.cont.resume(throwing: DriverError.connectionFailed(
                    "ASCII timeout (slaveId \(slaveId), FC \(pdu.first ?? 0))"))
            }

            port.write(txData)
        }
    }

    // MARK: - Response Decoding

    private func decodeBatch(batch: RegisterBatch, pdu: Data) {
        // pdu = [FC, byteCount, data...] for reads, or [FC, addr_hi, addr_lo, val_hi, val_lo] for writes
        guard pdu.count >= 2 else { return }
        let fc = pdu[0]

        if fc & 0x80 != 0 {
            let exCode = pdu.count > 1 ? pdu[1] : 0
            Logger.shared.error("Modbus exception: FC\(batch.functionCode) addr\(batch.startAddress) → ex\(exCode)")
            return
        }

        let byteCount = Int(pdu[1])
        guard pdu.count >= 2 + byteCount else { return }
        let payload = Data(pdu[2..<(2 + byteCount)])

        let isCoil = batch.functionCode == 1 || batch.functionCode == 2
        let now    = Date()

        if isCoil {
            for map in batch.maps {
                let bitIdx  = Int(map.address - batch.startAddress)
                let byteIdx = bitIdx / 8
                let bitPos  = bitIdx % 8
                guard byteIdx < payload.count else { continue }
                let on = (payload[byteIdx] >> bitPos) & 0x01 == 1
                tagEngine.updateTag(name: map.tagName, value: .digital(on),
                                    quality: .good, timestamp: now)
            }
        } else {
            for map in batch.maps {
                let byteOffset = Int(map.address - batch.startAddress) * 2
                let needed     = wordSizeOf(map) * 2
                guard byteOffset + needed <= payload.count else { continue }
                let val = decodeWord(payload: payload, at: byteOffset,
                                     dataType: map.dataType, scale: map.scale,
                                     valueOffset: map.valueOffset)
                tagEngine.updateTag(name: map.tagName, value: val, quality: .good, timestamp: now)
            }
        }
    }

    private func decodeWord(payload: Data, at i: Int,
                            dataType: ModbusDataType,
                            scale: Double, valueOffset: Double) -> TagValue {
        switch dataType {
        case .uint16:
            let raw = UInt16(payload[i]) << 8 | UInt16(payload[i + 1])
            return .analog(Double(raw) * scale + valueOffset)
        case .int16:
            let raw = Int16(bitPattern: UInt16(payload[i]) << 8 | UInt16(payload[i + 1]))
            return .analog(Double(raw) * scale + valueOffset)
        case .uint32:
            let raw = UInt32(payload[i]) << 24 | UInt32(payload[i+1]) << 16
                    | UInt32(payload[i+2]) << 8 | UInt32(payload[i+3])
            return .analog(Double(raw) * scale + valueOffset)
        case .int32:
            let bits = UInt32(payload[i]) << 24 | UInt32(payload[i+1]) << 16
                     | UInt32(payload[i+2]) << 8 | UInt32(payload[i+3])
            return .analog(Double(Int32(bitPattern: bits)) * scale + valueOffset)
        case .float32:
            let bits = UInt32(payload[i]) << 24 | UInt32(payload[i+1]) << 16
                     | UInt32(payload[i+2]) << 8 | UInt32(payload[i+3])
            return .analog(Double(Float(bitPattern: bits)) * scale + valueOffset)
        case .coil:
            return .digital(payload[i] != 0)
        }
    }

    // MARK: - Helpers

    private func stopTasks() {
        pollTask?.cancel();      pollTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
    }

    private func markTagsUncertain() {
        let now = Date()
        for map in registerMaps {
            tagEngine.updateTag(name: map.tagName, value: .none, quality: .uncertain, timestamp: now)
        }
    }
}
