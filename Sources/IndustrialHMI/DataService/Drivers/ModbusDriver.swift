import Foundation
import Combine

@MainActor
final class ModbusDriver: ObservableObject, DataDriver {
    var driverType: DriverType { .modbus }
    var driverName: String { "Modbus" }
    @Published private(set) var isConnected = false

    func connect() async throws {
        throw DriverError.notImplemented("Modbus driver is not yet available")
    }

    func disconnect() async {}
}
