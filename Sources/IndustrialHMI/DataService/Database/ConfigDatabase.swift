import Foundation
import SQLite

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

    // Table
    private let driverConfigs = Table("driver_configs")

    // Columns
    private let colId         = Expression<String>("id")
    private let colType       = Expression<String>("type")
    private let colName       = Expression<String>("name")
    private let colEndpoint   = Expression<String>("endpoint")
    private let colEnabled    = Expression<Int>("enabled")
    private let colParameters = Expression<String>("parameters")
    private let colCreatedAt  = Expression<Double>("created_at")
    private let colUpdatedAt  = Expression<Double>("updated_at")

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
