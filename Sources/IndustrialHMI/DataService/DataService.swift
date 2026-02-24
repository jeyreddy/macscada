import Foundation
import Combine

/// Central service orchestrator.
/// Owns all drivers and database objects; exposes individual services as properties
/// so existing EnvironmentObject injections continue to work unchanged.
@MainActor
class DataService: ObservableObject {
    let opcuaService: OPCUAClientService
    let tagEngine: TagEngine
    let alarmManager: AlarmManager
    let configDatabase: ConfigDatabase
    let timeSeriesDatabase: TimeSeriesDatabase
    let hmiScreenStore: HMIScreenStore
    private(set) var drivers: [any DataDriver] = []

    @Published var isRunning: Bool = false

    init() {
        let opcua  = OPCUAClientService()
        let engine = TagEngine()
        let alarms = AlarmManager()

        self.opcuaService       = opcua
        self.tagEngine          = engine
        self.alarmManager       = alarms
        self.configDatabase     = ConfigDatabase()
        self.timeSeriesDatabase = TimeSeriesDatabase(tagEngine: engine)
        self.hmiScreenStore     = HMIScreenStore()
        self.drivers            = [opcua, MQTTDriver(), ModbusDriver()]

        Logger.shared.info("DataService initialized with \(self.drivers.count) drivers")
    }

    // MARK: - Data Collection

    func startDataCollection() async {
        isRunning = true
        tagEngine.onTagUpdated = { [weak alarmManager] tag in
            alarmManager?.checkAlarms(for: tag)
        }
        if Configuration.simulationMode {
            Logger.shared.info("Starting simulation mode")
            tagEngine.startSimulation()
        } else {
            do {
                try await opcuaService.connect()
                Logger.shared.info("OPC-UA connection ready")
            } catch {
                isRunning = false
                Logger.shared.error("Connection failed: \(error)")
            }
        }
    }

    func stopDataCollection() async {
        isRunning = false
        tagEngine.onTagUpdated = nil
        if Configuration.simulationMode {
            tagEngine.stopSimulation()
        } else {
            await opcuaService.disconnect()
        }
    }

    /// Returns the first driver matching the given type, or nil.
    func driver(ofType type: DriverType) -> (any DataDriver)? {
        drivers.first { $0.driverType == type }
    }
}
