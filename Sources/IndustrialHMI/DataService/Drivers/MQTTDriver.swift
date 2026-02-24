import Foundation
import Combine

@MainActor
final class MQTTDriver: ObservableObject, DataDriver {
    var driverType: DriverType { .mqtt }
    var driverName: String { "MQTT" }
    @Published private(set) var isConnected = false

    func connect() async throws {
        throw DriverError.notImplemented("MQTT driver is not yet available")
    }

    func disconnect() async {}
}
