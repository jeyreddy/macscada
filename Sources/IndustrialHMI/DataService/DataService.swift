import Foundation
import Combine

// MARK: - DataService.swift
//
// Central application services orchestrator.  DataService is the single object
// created at app startup that owns every service, driver, and database handle.
// All services are exposed as properties so they can be injected into the SwiftUI
// environment as individual EnvironmentObjects.
//
// ── Service ownership ─────────────────────────────────────────────────────────
//   DataService creates and holds strong references to:
//     TagEngine         — live tag value store, OPC-UA subscription manager, historian
//     OPCUAClientService — OPC-UA TCP connection layer
//     AlarmManager      — ISA-18.2 alarm evaluation and state management
//     ConfigDatabase    — SQLite store for tags, alarms, Modbus/MQTT configs
//     HMIScreenStore    — HMI screen JSON files on disk
//     AgentService      — Claude AI integration with 40 HMI tool calls
//     SessionManager    — operator authentication, roles, inactivity timeout
//     RecipeStore       — recipe definitions and execution engine
//     CommunityService  — peer-to-peer federation (WebSocket server)
//     SchedulerService  — time-based job scheduler
//     HMI3DSceneStore   — SceneKit 3D scene persistence per HMI screen
//     ProcessCanvasStore— infinite canvas document persistence
//     drivers           — [OPCUAClientService, MQTTDriver, ModbusDriver]
//
// ── Historian sharing ─────────────────────────────────────────────────────────
//   TagEngine creates the single Historian instance (SQLite connection).
//   AlarmManager and RecipeStore receive the same `historian` reference so all
//   historical writes (tag values, alarm events, recipe runs) go to one database
//   without connection contention.
//
// ── Cross-service wiring in init() ───────────────────────────────────────────
//   Some services need references to each other but cannot receive them in their
//   own init() due to circular initialization ordering.  Post-init property
//   injection is used for:
//     agentService.recipeStore       — available after RecipeStore is created
//     agentService.confirmWrite      — closure injected after DataService.self is ready
//     schedulerService.recipeStore   — available after both are created
//
// ── startDataCollection() ─────────────────────────────────────────────────────
//   Called from MonitorView's "Start" toolbar button.
//   Behaviour depends on Configuration:
//     simulationMode = true  → TagEngine.startSimulation() (no hardware needed)
//     opcuaServerURL set     → connect OPC-UA, retry on failure
//     otherwise              → idle; operator uses Settings to configure server
//   All non-OPC-UA drivers (MQTT, Modbus) are also started.
//
// ── confirmWrite() ────────────────────────────────────────────────────────────
//   Executes operator write requests (value changes via WriteValueSheet or AI agent).
//   Writes to OPC-UA, records to the audit log, and updates the tag in TagEngine.
//   Throws on failure — the caller shows an error alert.

// MARK: - DriverInstance

/// Wraps a running driver with its persisted configuration.
struct DriverInstance: Identifiable {
    let id: String           // = config.id
    var config: DriverConfig
    let driver: any DataDriver
}

/// Central service orchestrator.
/// Owns all drivers and database objects; exposes individual services as properties
/// so existing EnvironmentObject injections continue to work unchanged.
@MainActor
class DataService: ObservableObject {
    let opcuaService:    OPCUAClientService
    let tagEngine:       TagEngine
    let alarmManager:    AlarmManager
    let configDatabase:  ConfigDatabase
    let hmiScreenStore:  HMIScreenStore
    let agentService:    AgentService
    let sessionManager:  SessionManager
    let recipeStore:     RecipeStore
    let communityService: CommunityService
    let schedulerService: SchedulerService
    let hmi3DSceneStore:      HMI3DSceneStore
    let processCanvasStore:   ProcessCanvasStore
    @Published private(set) var driverInstances: [DriverInstance] = []

    /// Flat list of all drivers — derived from driverInstances for backward compat.
    var drivers: [any DataDriver] { driverInstances.map(\.driver) }

    private var alarmBroadcastSub: AnyCancellable?
    private var cancellables: Set<AnyCancellable> = []

    @Published var isRunning: Bool = false

    init() {
        // Clear stale short hostnames (e.g. "mac") before any service reads the URL.
        Configuration.migrateServerURLIfNeeded()

        let opcua  = OPCUAClientService()
        let engine = TagEngine()
        let alarms = AlarmManager()

        // Wire historian from TagEngine into AlarmManager so both share the same DB.
        alarms.historian = engine.historian

        self.opcuaService   = opcua
        self.tagEngine      = engine
        self.alarmManager   = alarms
        let configDB        = ConfigDatabase()
        self.configDatabase = configDB
        let store           = HMIScreenStore()
        self.hmiScreenStore = store
        self.agentService   = AgentService(
            tagEngine:      engine,
            alarmManager:   alarms,
            hmiScreenStore: store,
            opcuaService:   opcua)
        self.sessionManager = SessionManager()
        let recipes         = RecipeStore(tagEngine: engine, opcuaService: opcua)
        recipes.historian   = engine.historian
        self.recipeStore    = recipes

        // Phase 13: Community federation service (must be before any [weak self] closure)
        self.communityService = CommunityService(tagEngine: engine, alarmManager: alarms)

        // Phase 15: Scheduler
        let scheduler = SchedulerService(tagEngine: engine, opcuaService: opcua)
        scheduler.historian  = engine.historian
        self.schedulerService = scheduler

        // Phase 16: 3D scene store
        self.hmi3DSceneStore = HMI3DSceneStore()

        // Infinite canvas store
        self.processCanvasStore = ProcessCanvasStore()

        // Wire Phase 12 agent power tools — property injection avoids circular init.
        self.agentService.recipeStore  = recipes
        // Wire scheduler → recipeStore after both are created
        self.schedulerService.recipeStore = recipes
        self.agentService.confirmWrite = { [weak self] req in
            guard let self else { return }
            try await self.confirmWrite(req)
        }

        // Default instances (one per type) — replaced by setupDriversFromDB() on first start.
        let defaultMQTT    = MQTTDriver(tagEngine: engine, configDatabase: configDB)
        let defaultModbus  = ModbusDriver(tagEngine: engine, configDatabase: configDB)
        let defaultEIP     = EtherNetIPDriver(tagEngine: engine, configDatabase: configDB)
        self.driverInstances = [
            DriverInstance(id: "default-opcua",   config: DriverConfig(id: "default-opcua",   type: .opcua,      name: "OPC-UA",      endpoint: ""), driver: opcua),
            DriverInstance(id: "default-mqtt",    config: DriverConfig(id: "default-mqtt",    type: .mqtt,       name: "MQTT",        endpoint: ""), driver: defaultMQTT),
            DriverInstance(id: "default-modbus",  config: DriverConfig(id: "default-modbus",  type: .modbus,     name: "Modbus",      endpoint: ""), driver: defaultModbus),
            DriverInstance(id: "default-enip",    config: DriverConfig(id: "default-enip",    type: .ethernetip, name: "EtherNet/IP", endpoint: ""), driver: defaultEIP)
        ]

        Logger.shared.info("DataService initialized with \(self.driverInstances.count) default drivers")

        // Restore alarm configs, history, recipes, and scheduled jobs from SQLite
        Task { await alarms.loadFromDB() }
        Task { await recipes.loadFromDB() }
        Task { await scheduler.loadFromDB() }

        // Phase 16: When the active HMI screen changes, load its paired 3D scene.
        // Using a local reference to avoid [weak self] capture issues in init.
        let sceneStore = self.hmi3DSceneStore
        store.$currentScreenId
            .compactMap { $0 }
            .sink { id in sceneStore.loadScene(for: id) }
            .store(in: &cancellables)
    }

    // MARK: - Data Collection

    func startDataCollection() async {
        isRunning = true
        tagEngine.onTagUpdated = { [weak alarmManager, weak communityService] tag in
            alarmManager?.checkAlarms(for: tag)
            if !tag.name.contains("/") {
                communityService?.broadcastTagUpdate(tag)
            }
        }
        communityService.start()
        schedulerService.start()

        // Rebuild driver list from persisted configs (replaces defaults if any exist)
        await setupDriversFromDB()

        // Connect all driver instances
        for instance in driverInstances {
            let driver = instance.driver
            if let svc = driver as? OPCUAClientService {
                if Configuration.simulationMode {
                    Logger.shared.info("Starting simulation mode")
                    tagEngine.startSimulation()
                } else {
                    let url = instance.config.endpoint.isEmpty ? Configuration.opcuaServerURL : instance.config.endpoint
                    guard !url.isEmpty else {
                        Logger.shared.info("No OPC-UA server configured — go to Settings > Connections to add one")
                        continue
                    }
                    do {
                        try await svc.connect(to: url)
                        Logger.shared.info("OPC-UA connected: \(url)")
                        svc.startAutoReconnect()
                    } catch {
                        Logger.shared.error("OPC-UA initial connect failed: \(error.localizedDescription)")
                        svc.startAutoReconnect()
                    }
                }
            } else {
                do {
                    try await driver.connect()
                    Logger.shared.info("\(instance.config.name) driver started")
                } catch DriverError.notImplemented(let reason) {
                    Logger.shared.info("\(instance.config.name) not configured: \(reason)")
                } catch {
                    Logger.shared.error("\(instance.config.name) failed to start: \(error.localizedDescription)")
                }
            }
        }
    }

    func stopDataCollection() async {
        isRunning = false
        tagEngine.onTagUpdated = nil
        communityService.stop()
        schedulerService.stop()
        alarmBroadcastSub?.cancel()
        alarmBroadcastSub = nil
        if Configuration.simulationMode {
            tagEngine.stopSimulation()
        }
        for instance in driverInstances {
            if let svc = instance.driver as? OPCUAClientService {
                svc.stopAutoReconnect()
            }
            await instance.driver.disconnect()
        }
    }

    // MARK: - Driver Management

    /// Convenience accessor — the historian lives in TagEngine but sheets use it via DataService.
    var historian: Historian? { tagEngine.historian }

    /// Returns the first driver matching the given type, or nil.
    func driver(ofType type: DriverType) -> (any DataDriver)? {
        drivers.first { $0.driverType == type }
    }

    /// Returns the driver for a specific config ID.
    func driver(configId id: String) -> (any DataDriver)? {
        driverInstances.first { $0.id == id }?.driver
    }

    /// Rebuilds the driver list from persisted DriverConfig entries in ConfigDatabase.
    /// Called at the start of startDataCollection(). If no DB configs exist, keeps the defaults.
    private func setupDriversFromDB() async {
        let configs = (try? await configDatabase.fetchAll()) ?? []
        guard !configs.isEmpty else { return }

        var instances: [DriverInstance] = []
        var primaryOpcuaAssigned = false

        for config in configs where config.enabled {
            let driver: any DataDriver
            switch config.type {
            case .opcua:
                if !primaryOpcuaAssigned {
                    primaryOpcuaAssigned = true
                    driver = opcuaService
                } else {
                    driver = OPCUAClientService()
                }
            case .mqtt:
                driver = MQTTDriver(tagEngine: tagEngine, configDatabase: configDatabase, configId: config.id)
            case .modbus:
                driver = ModbusDriver(tagEngine: tagEngine, configDatabase: configDatabase, configId: config.id)
            case .ethernetip:
                driver = EtherNetIPDriver(tagEngine: tagEngine, configDatabase: configDatabase, configId: config.id)
            }
            instances.append(DriverInstance(id: config.id, config: config, driver: driver))
        }

        if !instances.isEmpty {
            driverInstances = instances
            Logger.shared.info("DataService: loaded \(instances.count) driver(s) from DB")
        }
    }

    /// Creates, persists, and (if running) connects a new driver connection.
    func addConnection(_ config: DriverConfig) async {
        try? await configDatabase.save(config)
        let driver: any DataDriver
        switch config.type {
        case .opcua:      driver = OPCUAClientService()
        case .mqtt:       driver = MQTTDriver(tagEngine: tagEngine, configDatabase: configDatabase, configId: config.id)
        case .modbus:     driver = ModbusDriver(tagEngine: tagEngine, configDatabase: configDatabase, configId: config.id)
        case .ethernetip: driver = EtherNetIPDriver(tagEngine: tagEngine, configDatabase: configDatabase, configId: config.id)
        }
        driverInstances.append(DriverInstance(id: config.id, config: config, driver: driver))
        if isRunning && config.enabled {
            do {
                try await driver.connect()
                Logger.shared.info("addConnection: \(config.name) connected")
            } catch DriverError.notImplemented(let reason) {
                Logger.shared.info("addConnection: \(config.name) not configured — \(reason)")
            } catch {
                Logger.shared.error("addConnection: \(config.name) failed — \(error.localizedDescription)")
            }
        }
    }

    /// Disconnects and removes a driver connection.
    func removeConnection(id: String) async {
        guard let idx = driverInstances.firstIndex(where: { $0.id == id }) else { return }
        let instance = driverInstances[idx]
        if let svc = instance.driver as? OPCUAClientService { svc.stopAutoReconnect() }
        await instance.driver.disconnect()
        driverInstances.remove(at: idx)
        try? await configDatabase.deleteDriver(id: id)
    }

    /// Disconnects and reconnects the first driver of a given type (reload config from DB).
    func reloadDriver(ofType type: DriverType) async {
        guard let driver = driver(ofType: type) else {
            Logger.shared.warning("reloadDriver: no driver registered for type \(type.rawValue)")
            return
        }
        diagLog("DIAG [DataService] reloadDriver START — \(type.rawValue)")
        await driver.disconnect()
        do {
            try await driver.connect()
            Logger.shared.info("reloadDriver: \(type.rawValue) reconnected successfully")
        } catch DriverError.notImplemented(let reason) {
            Logger.shared.info("reloadDriver: \(type.rawValue) not yet configured — \(reason)")
        } catch {
            Logger.shared.error("reloadDriver: \(type.rawValue) reconnect failed — \(error.localizedDescription)")
        }
        diagLog("DIAG [DataService] reloadDriver END — \(type.rawValue)")
    }

    /// Disconnects and reconnects a specific driver by its config ID.
    func reloadDriver(configId id: String) async {
        guard let instance = driverInstances.first(where: { $0.id == id }) else { return }
        await instance.driver.disconnect()
        do {
            try await instance.driver.connect()
            Logger.shared.info("reloadDriver: \(instance.config.name) reconnected")
        } catch DriverError.notImplemented(let reason) {
            Logger.shared.info("reloadDriver: \(instance.config.name) not configured — \(reason)")
        } catch {
            Logger.shared.error("reloadDriver: \(instance.config.name) failed — \(error.localizedDescription)")
        }
    }

    // MARK: - Operator Write

    /// Execute a confirmed write request.
    /// Calls OPC-UA write, resolves the request in TagEngine, and logs to the audit trail.
    /// Throws if the write fails; the caller is responsible for surfacing the error to the operator.
    /// The request is stamped with the currently logged-in operator's display name.
    func confirmWrite(_ request: WriteRequest) async throws {
        sessionManager.recordActivity()
        let oldValue = tagEngine.tags[request.tagName]?.value.numericValue

        do {
            try await opcuaService.writeTag(nodeId: request.nodeId, value: request.newValue)
            tagEngine.resolveWrite(request, success: true)
            Logger.shared.info("Write confirmed: \(request.tagName) = \(request.newValue) by \(request.requestedBy)")

            if let h = tagEngine.historian {
                Task { try? await h.logWrite(
                    tagName: request.tagName,
                    oldValue: oldValue,
                    newValue: request.newValue.numericValue,
                    requestedBy: request.requestedBy,
                    status: "success"
                )}
            }
        } catch {
            tagEngine.resolveWrite(request, success: false)
            Logger.shared.error("Write failed: \(request.tagName) — \(error.localizedDescription)")

            if let h = tagEngine.historian {
                Task { try? await h.logWrite(
                    tagName: request.tagName,
                    oldValue: oldValue,
                    newValue: request.newValue.numericValue,
                    requestedBy: request.requestedBy,
                    status: "failed: \(error.localizedDescription)"
                )}
            }
            throw error
        }
    }
}
