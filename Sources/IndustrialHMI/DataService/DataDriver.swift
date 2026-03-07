import Foundation

// MARK: - DataDriver.swift
//
// Protocol and error types shared by all data driver implementations.
//
// ── Driver architecture ───────────────────────────────────────────────────────
//   Each driver handles communication with one type of industrial protocol:
//     OPCUAClientService — OPC-UA TCP (DA/UA subscriptions, certificate auth)
//     MQTTDriver         — MQTT broker subscriptions mapped to tag names
//     ModbusDriver       — Modbus TCP/RTU register polling
//
//   Drivers are owned by DataService.drivers and started/stopped together
//   via startDataCollection() / stopDataCollection().
//   They all conform to @MainActor DataDriver, but their internal I/O typically
//   runs on background actors/threads and posts results back to @MainActor.
//
// ── DriverError.notImplemented ────────────────────────────────────────────────
//   Thrown by drivers whose connect() is not yet fully implemented (MQTT, Modbus).
//   DataService catches this and logs a warning instead of showing an error alert —
//   it is a known "coming soon" state, not a runtime failure.

// MARK: - Driver Types

enum DriverType: String, Codable, CaseIterable {
    case opcua     = "OPC-UA"
    case mqtt      = "MQTT"
    case modbus    = "Modbus"
    case ethernetip = "EtherNet/IP"
}

// MARK: - DataDriver Protocol

@MainActor
protocol DataDriver: AnyObject {
    var driverType: DriverType { get }
    var driverName: String { get }
    var isConnected: Bool { get }
    func connect() async throws
    func disconnect() async
}

// MARK: - Driver Errors

enum DriverError: LocalizedError {
    case notImplemented(String)
    case connectionFailed(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .notImplemented(let msg):   return "Not implemented: \(msg)"
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .notConnected:              return "Driver is not connected"
        }
    }
}
