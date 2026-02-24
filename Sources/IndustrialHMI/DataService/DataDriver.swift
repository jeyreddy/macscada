import Foundation

// MARK: - Driver Types

enum DriverType: String, Codable, CaseIterable {
    case opcua  = "OPC-UA"
    case mqtt   = "MQTT"
    case modbus = "Modbus"
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
