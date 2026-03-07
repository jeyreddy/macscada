// MARK: - ConfigDatabase.swift
//
// SQLite-backed actor for all driver configuration data.
// Separate from Historian.swift to avoid mixing real-time process data with
// static configuration. Historian handles tag history, alarms, recipes, and
// scheduled jobs; ConfigDatabase handles protocol driver configuration only.
//
// ── File Location ─────────────────────────────────────────────────────────────
//   ~/Library/Application Support/IndustrialHMI/config.db
//   Created on first access; schema auto-migrated via createTablesIfNeeded().
//
// ── Tables ────────────────────────────────────────────────────────────────────
//   driver_configs       — one row per DriverConfig (Modbus or MQTT driver)
//   modbus_register_maps — N ModbusRegisterMap rows per driver_configs row
//   mqtt_subscriptions   — N MQTTSubscription rows per driver_configs row
//
// ── Models ────────────────────────────────────────────────────────────────────
//   DriverConfig        — protocol driver: type (modbus|mqtt), endpoint, parameters
//   ModbusRegisterMap   — maps register (slaveId, FC, address, dataType, scale) → tagName
//   MQTTSubscription    — maps topic (with optional jsonPath) → tagName
//   ModbusDataType      — uint16, int16, uint32, int32, float32, coil
//
// ── Concurrency ───────────────────────────────────────────────────────────────
//   All methods are `async` on the actor's implicit serial executor.
//   DataService and Modbus/MQTTDriver call these methods via `await` from @MainActor.
//   SQLite.swift Connection is not Sendable — isolation inside the actor ensures
//   only one operation runs at a time, preventing database corruption.
//
// ── Usage ─────────────────────────────────────────────────────────────────────
//   DataService.setupDrivers() → configDatabase.loadDriverConfigs()
//     → for each config: create driver instance, call driver.connect()
//   ModbusDriver.connect() → configDatabase.loadModbusRegisterMaps(driverConfigId:)
//   MQTTDriver.connect()   → configDatabase.loadMQTTSubscriptions(driverConfigId:)

import Foundation
import SQLite

// MARK: - Modbus Models

enum ModbusDataType: String, Codable, CaseIterable {
    case uint16  = "uint16"
    case int16   = "int16"
    case uint32  = "uint32"
    case int32   = "int32"
    case float32 = "float32"
    case coil    = "coil"
}

/// Maps a single Modbus register (or coil) to a tag name.
struct ModbusRegisterMap: Identifiable, Codable {
    var id:           String         = UUID().uuidString
    /// TagEngine tag name to update on each poll cycle.
    var tagName:      String
    /// Modbus slave / unit ID (1–247). Use 255 for Modbus TCP gateways that ignore unit ID.
    var slaveId:      UInt8          = 1
    /// Function code: 1=Coil, 2=DiscreteInput, 3=HoldingRegister, 4=InputRegister.
    var functionCode: UInt8          = 3
    /// 0-based register/coil address.
    var address:      UInt16         = 0
    /// How the 16/32-bit raw value is interpreted.
    var dataType:     ModbusDataType = .uint16
    /// Linear scaling: tagValue = rawValue * scale + valueOffset
    var scale:        Double         = 1.0
    var valueOffset:  Double         = 0.0
}

// MARK: - MQTTSubscription Model

/// Maps a single MQTT topic to a tag name, with an optional JSON path for structured payloads.
struct MQTTSubscription: Identifiable, Codable {
    var id: String = UUID().uuidString
    /// MQTT topic filter — supports + and # wildcards (e.g. "sensors/+/temperature")
    var topic: String
    /// TagEngine tag name to update when a message arrives on this topic
    var tagName: String
    /// Dot-separated path into a JSON payload (e.g. "data.value"). Nil = treat whole payload as a number.
    var jsonPath: String?
}

// MARK: - DriverConfig Model

struct DriverConfig: Identifiable, Codable {
    var id: String = UUID().uuidString
    var type: DriverType
    var name: String
    var endpoint: String
    var enabled: Bool = true
    var parameters: [String: String] = [:]
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
}

// MARK: - ConfigDatabase

/// SQLite-backed actor for storing and retrieving driver configurations.
/// File: ~/Library/Application Support/IndustrialHMI/config.db
actor ConfigDatabase {
    private var db: Connection? = nil

    // driver_configs table
    private let driverConfigs = Table("driver_configs")

    // driver_configs columns
    private let colId         = Expression<String>("id")
    private let colType       = Expression<String>("type")
    private let colName       = Expression<String>("name")
    private let colEndpoint   = Expression<String>("endpoint")
    private let colEnabled    = Expression<Int>("enabled")
    private let colParameters = Expression<String>("parameters")
    private let colCreatedAt  = Expression<Double>("created_at")
    private let colUpdatedAt  = Expression<Double>("updated_at")

    // mqtt_subscriptions table
    private let mqttSubs   = Table("mqtt_subscriptions")
    private let msId       = Expression<String>("id")
    private let msTopic    = Expression<String>("topic")
    private let msTagName  = Expression<String>("tag_name")
    private let msJsonPath = Expression<String?>("json_path")
    private let msDCId     = Expression<String?>("driver_config_id")   // FK to driver_configs

    // modbus_register_maps table
    private let modbusRegs  = Table("modbus_register_maps")
    private let mrId          = Expression<String>("id")
    private let mrTagName     = Expression<String>("tag_name")
    private let mrSlaveId     = Expression<Int>("slave_id")
    private let mrFunctionCode = Expression<Int>("function_code")
    private let mrAddress     = Expression<Int>("address")
    private let mrDataType    = Expression<String>("data_type")
    private let mrScale       = Expression<Double>("scale")
    private let mrOffset      = Expression<Double>("value_offset")
    private let mrDCId        = Expression<String?>("driver_config_id")  // FK to driver_configs

    init() {
        do {
            let fileManager = FileManager.default
            let appSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let appDir = appSupport.appendingPathComponent("IndustrialHMI", isDirectory: true)
            try fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
            let dbPath = appDir.appendingPathComponent("config.db").path

            let connection = try Connection(dbPath)
            try connection.execute("PRAGMA journal_mode=WAL")

            // Capture column expressions in locals so the closure below
            // does not capture `self`, which would prevent the subsequent
            // `self.db = connection` in a nonisolated actor init context.
            let table      = Table("driver_configs")
            let cId        = Expression<String>("id")
            let cType      = Expression<String>("type")
            let cName      = Expression<String>("name")
            let cEndpoint  = Expression<String>("endpoint")
            let cEnabled   = Expression<Int>("enabled")
            let cParams    = Expression<String>("parameters")
            let cCreatedAt = Expression<Double>("created_at")
            let cUpdatedAt = Expression<Double>("updated_at")

            try connection.run(table.create(ifNotExists: true) { t in
                t.column(cId, primaryKey: true)
                t.column(cType)
                t.column(cName)
                t.column(cEndpoint)
                t.column(cEnabled)
                t.column(cParams)
                t.column(cCreatedAt)
                t.column(cUpdatedAt)
            })

            // mqtt_subscriptions table (use locals to avoid capturing self before self.db is set)
            let msTable    = Table("mqtt_subscriptions")
            let mSId       = Expression<String>("id")
            let mSTopic    = Expression<String>("topic")
            let mSTagName  = Expression<String>("tag_name")
            let mSJsonPath = Expression<String?>("json_path")
            try connection.run(msTable.create(ifNotExists: true) { t in
                t.column(mSId, primaryKey: true)
                t.column(mSTopic, unique: true)
                t.column(mSTagName)
                t.column(mSJsonPath)
            })

            // modbus_register_maps table
            let mrTable    = Table("modbus_register_maps")
            let mRId       = Expression<String>("id")
            let mRTagName  = Expression<String>("tag_name")
            let mRSlaveId  = Expression<Int>("slave_id")
            let mRFC       = Expression<Int>("function_code")
            let mRAddress  = Expression<Int>("address")
            let mRDataType = Expression<String>("data_type")
            let mRScale    = Expression<Double>("scale")
            let mROffset   = Expression<Double>("value_offset")
            try connection.run(mrTable.create(ifNotExists: true) { t in
                t.column(mRId, primaryKey: true)
                t.column(mRTagName)
                t.column(mRSlaveId)
                t.column(mRFC)
                t.column(mRAddress)
                t.column(mRDataType)
                t.column(mRScale)
                t.column(mROffset)
            })

            // Migration: add driver_config_id FK columns (idempotent — error = already exists)
            try? connection.execute("ALTER TABLE mqtt_subscriptions ADD COLUMN driver_config_id TEXT")
            try? connection.execute("ALTER TABLE modbus_register_maps ADD COLUMN driver_config_id TEXT")

            self.db = connection
            Logger.shared.info("ConfigDatabase initialized at: \(dbPath)")
        } catch {
            Logger.shared.error("Failed to initialize ConfigDatabase: \(error)")
        }
    }

    // MARK: - Write

    func save(_ config: DriverConfig) throws {
        guard let db else { return }
        let paramsJSON = (try? JSONEncoder().encode(config.parameters))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        try db.run(driverConfigs.insert(or: .replace,
            colId         <- config.id,
            colType       <- config.type.rawValue,
            colName       <- config.name,
            colEndpoint   <- config.endpoint,
            colEnabled    <- config.enabled ? 1 : 0,
            colParameters <- paramsJSON,
            colCreatedAt  <- config.createdAt.timeIntervalSince1970,
            colUpdatedAt  <- config.updatedAt.timeIntervalSince1970
        ))
    }

    func delete(id: String) throws {
        guard let db else { return }
        try db.run(driverConfigs.filter(colId == id).delete())
    }

    // MARK: - Read

    func fetchAll() throws -> [DriverConfig] {
        guard let db else { return [] }
        return try db.prepare(driverConfigs).compactMap { row in
            decodeRow(row)
        }
    }

    func fetch(type driverType: DriverType) throws -> [DriverConfig] {
        guard let db else { return [] }
        let query = driverConfigs.filter(colType == driverType.rawValue)
        return try db.prepare(query).compactMap { row in
            decodeRow(row)
        }
    }

    // MARK: - Driver cascade delete

    func deleteDriver(id: String) throws {
        try delete(id: id)
        guard let db else { return }
        try db.run(mqttSubs.filter(msDCId == id).delete())
        try db.run(modbusRegs.filter(mrDCId == id).delete())
    }

    // MARK: - MQTT Subscriptions

    func saveMQTTSubscription(_ sub: MQTTSubscription, forDriverId driverConfigId: String) throws {
        guard let db else { return }
        try db.run(mqttSubs.insert(or: .replace,
            msId       <- sub.id,
            msTopic    <- sub.topic,
            msTagName  <- sub.tagName,
            msJsonPath <- sub.jsonPath,
            msDCId     <- driverConfigId
        ))
    }

    func deleteMQTTSubscriptions(forDriverId driverConfigId: String) throws {
        guard let db else { return }
        try db.run(mqttSubs.filter(msDCId == driverConfigId).delete())
    }

    func fetchMQTTSubscriptions(forDriverId driverConfigId: String) throws -> [MQTTSubscription] {
        guard let db else { return [] }
        return try db.prepare(mqttSubs.filter(msDCId == driverConfigId)).map { row in
            MQTTSubscription(id: row[msId], topic: row[msTopic], tagName: row[msTagName], jsonPath: row[msJsonPath])
        }
    }

    func saveMQTTSubscription(_ sub: MQTTSubscription) throws {
        guard let db else { return }
        try db.run(mqttSubs.insert(or: .replace,
            msId       <- sub.id,
            msTopic    <- sub.topic,
            msTagName  <- sub.tagName,
            msJsonPath <- sub.jsonPath
        ))
    }

    func deleteMQTTSubscription(id: String) throws {
        guard let db else { return }
        try db.run(mqttSubs.filter(msId == id).delete())
    }

    func fetchMQTTSubscriptions() throws -> [MQTTSubscription] {
        guard let db else { return [] }
        return try db.prepare(mqttSubs).map { row in
            MQTTSubscription(
                id:       row[msId],
                topic:    row[msTopic],
                tagName:  row[msTagName],
                jsonPath: row[msJsonPath]
            )
        }
    }

    // MARK: - Modbus Register Maps (per-driver)

    func saveModbusRegisterMap(_ map: ModbusRegisterMap, forDriverId driverConfigId: String) throws {
        guard let db else { return }
        try db.run(modbusRegs.insert(or: .replace,
            mrId           <- map.id,
            mrTagName      <- map.tagName,
            mrSlaveId      <- Int(map.slaveId),
            mrFunctionCode <- Int(map.functionCode),
            mrAddress      <- Int(map.address),
            mrDataType     <- map.dataType.rawValue,
            mrScale        <- map.scale,
            mrOffset       <- map.valueOffset,
            mrDCId         <- driverConfigId
        ))
    }

    func deleteModbusRegisterMaps(forDriverId driverConfigId: String) throws {
        guard let db else { return }
        try db.run(modbusRegs.filter(mrDCId == driverConfigId).delete())
    }

    func fetchModbusRegisterMaps(forDriverId driverConfigId: String) throws -> [ModbusRegisterMap] {
        guard let db else { return [] }
        return try db.prepare(modbusRegs.filter(mrDCId == driverConfigId)).compactMap { row in
            guard let dt = ModbusDataType(rawValue: row[mrDataType]) else { return nil }
            return ModbusRegisterMap(
                id:           row[mrId],
                tagName:      row[mrTagName],
                slaveId:      UInt8(clamping: row[mrSlaveId]),
                functionCode: UInt8(clamping: row[mrFunctionCode]),
                address:      UInt16(clamping: row[mrAddress]),
                dataType:     dt,
                scale:        row[mrScale],
                valueOffset:  row[mrOffset]
            )
        }
    }

    func saveModbusRegisterMap(_ map: ModbusRegisterMap) throws {
        guard let db else { return }
        try db.run(modbusRegs.insert(or: .replace,
            mrId           <- map.id,
            mrTagName      <- map.tagName,
            mrSlaveId      <- Int(map.slaveId),
            mrFunctionCode <- Int(map.functionCode),
            mrAddress      <- Int(map.address),
            mrDataType     <- map.dataType.rawValue,
            mrScale        <- map.scale,
            mrOffset       <- map.valueOffset
        ))
    }

    func deleteModbusRegisterMap(id: String) throws {
        guard let db else { return }
        try db.run(modbusRegs.filter(mrId == id).delete())
    }

    func fetchModbusRegisterMaps() throws -> [ModbusRegisterMap] {
        guard let db else { return [] }
        return try db.prepare(modbusRegs).compactMap { row in
            guard let dt = ModbusDataType(rawValue: row[mrDataType]) else { return nil }
            return ModbusRegisterMap(
                id:           row[mrId],
                tagName:      row[mrTagName],
                slaveId:      UInt8(clamping: row[mrSlaveId]),
                functionCode: UInt8(clamping: row[mrFunctionCode]),
                address:      UInt16(clamping: row[mrAddress]),
                dataType:     dt,
                scale:        row[mrScale],
                valueOffset:  row[mrOffset]
            )
        }
    }

    // MARK: - Private

    private func decodeRow(_ row: Row) -> DriverConfig? {
        guard let type = DriverType(rawValue: row[colType]) else { return nil }
        let paramsData = row[colParameters].data(using: .utf8) ?? Data()
        let params = (try? JSONDecoder().decode([String: String].self, from: paramsData)) ?? [:]
        return DriverConfig(
            id:         row[colId],
            type:       type,
            name:       row[colName],
            endpoint:   row[colEndpoint],
            enabled:    row[colEnabled] != 0,
            parameters: params,
            createdAt:  Date(timeIntervalSince1970: row[colCreatedAt]),
            updatedAt:  Date(timeIntervalSince1970: row[colUpdatedAt])
        )
    }
}
