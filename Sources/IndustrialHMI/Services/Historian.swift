import Foundation
import SQLite

// MARK: - Historian.swift
//
// SQLite-backed time-series data historian and configuration store.
//
// ── Storage location ──────────────────────────────────────────────────────────
//   ~/Library/Application Support/IndustrialHMI/historian.db
//   Uses the swift-sqlite package for type-safe queries.
//
// ── Database tables ───────────────────────────────────────────────────────────
//
//   tag_history      — time-series process values (main historian data)
//     tag_name       TEXT
//     timestamp      INTEGER  (Unix ms)
//     value          REAL
//     quality        INTEGER  (TagQuality raw value: 0=good,1=bad,2=uncertain)
//
//   tag_configs      — persisted tag definitions (survives app restart without OPC-UA)
//     name           TEXT PK
//     node_id        TEXT
//     data_type      TEXT
//     unit           TEXT?
//     description    TEXT?
//     added_at       INTEGER
//     expression     TEXT?   (non-null for calculated tags)
//
//   alarm_configs    — ISA-18.2 alarm setpoint configuration
//     id, tag_name, high_high, high, low, low_low, deadband, priority, enabled
//
//   alarm_history    — historical alarm records (one row per alarm instance)
//     id, tag_name, message, severity, state, trigger_time, ack_time, ack_by, rtn_time, value
//     + ISA-18.2 shelve columns: shelved_by, shelved_at, shelved_until, shelve_reason
//
//   alarm_journal    — immutable ISA-18.2 state-transition audit log
//     id, alarm_id, tag_name, prev_state, new_state, changed_by, reason, timestamp
//
//   write_log        — operator write audit trail
//     id, tag_name, old_value, new_value, requested_by, timestamp, status
//
//   recipes          — JSON-encoded Recipe structs
//   scheduled_jobs   — JSON-encoded ScheduledJob structs
//
// ── Concurrency model ─────────────────────────────────────────────────────────
//   Historian is a Swift actor — all database operations are serialized automatically.
//   TagEngine and AlarmManager call historian methods via async/await from their
//   @MainActor context.  The actor dispatcher ensures thread safety for SQLite.
//
// ── Batch writing ─────────────────────────────────────────────────────────────
//   Tag value writes are NOT written individually — they are accumulated in
//   TagEngine.historianBatch and flushed every 5 s (or when 100 entries accumulate)
//   via Historian.batchInsert(_:).  Each flush is a single SQLite transaction for
//   performance (thousands of writes per second under high tag count).
//
// ── Schema migration ──────────────────────────────────────────────────────────
//   Migrations add columns to existing tables without dropping data.
//   addColumnIfMissing(_:_:) checks the PRAGMA table_info before ALTER TABLE.
//   Current migrations: alarm_history shelve columns, alarm_journal table.
//
// ── Data retention ────────────────────────────────────────────────────────────
//   pruneOldHistory(olderThan:) deletes rows from tag_history older than
//   Configuration.historianRetentionDays (default 90 days).
//   Called by TagEngine on each batch flush.

/// Historian service for storing and retrieving time-series process data,
/// tag configurations, alarm configurations, and alarm history.
actor Historian {
    // MARK: - Database

    private let db: Connection

    // MARK: - tag_history table

    private let tagHistory   = Table("tag_history")
    private let thTagName    = Expression<String>("tag_name")
    private let thTimestamp  = Expression<Int64>("timestamp")
    private let thValue      = Expression<Double>("value")
    private let thQuality    = Expression<Int>("quality")

    // MARK: - tag_configs table

    private let tagConfigs   = Table("tag_configs")
    private let tcName       = Expression<String>("name")
    private let tcNodeId     = Expression<String>("node_id")
    private let tcDataType   = Expression<String>("data_type")
    private let tcUnit       = Expression<String?>("unit")
    private let tcDesc       = Expression<String?>("description")
    private let tcAddedAt    = Expression<Int64>("added_at")
    private let tcExpression          = Expression<String?>("expression")
    private let tcOnLabel             = Expression<String?>("on_label")
    private let tcOffLabel            = Expression<String?>("off_label")
    private let tcCompositeJSON       = Expression<String?>("composite_json")
    /// 1 = log to historian, 0 = skip. Stored as INTEGER for SQLite compatibility.
    private let tcHistorianEnabled    = Expression<Int>("historian_enabled")

    // MARK: - alarm_configs table

    private let alarmConfigs = Table("alarm_configs")
    private let acId         = Expression<String>("id")
    private let acTagName    = Expression<String>("tag_name")
    private let acHighHigh   = Expression<Double?>("high_high")
    private let acHigh       = Expression<Double?>("high")
    private let acLow        = Expression<Double?>("low")
    private let acLowLow     = Expression<Double?>("low_low")
    private let acDeadband   = Expression<Double>("deadband")
    private let acPriority   = Expression<Int>("priority")
    private let acEnabled    = Expression<Int>("enabled")

    // MARK: - write_log table

    private let writeLog   = Table("write_log")
    private let wlId       = Expression<String>("id")
    private let wlTagName  = Expression<String>("tag_name")
    private let wlOldValue = Expression<Double?>("old_value")
    private let wlNewValue = Expression<Double?>("new_value")
    private let wlReqBy    = Expression<String>("requested_by")
    private let wlAt       = Expression<Double>("timestamp")
    private let wlStatus   = Expression<String>("status")

    // MARK: - alarm_history table

    private let alarmHistory    = Table("alarm_history")
    private let ahId            = Expression<String>("id")
    private let ahTagName       = Expression<String>("tag_name")
    private let ahMessage       = Expression<String>("message")
    private let ahSeverity      = Expression<String>("severity")
    private let ahState         = Expression<String>("state")
    private let ahTrigger       = Expression<Double>("trigger_time")
    private let ahAckTime       = Expression<Double?>("ack_time")
    private let ahAckBy         = Expression<String?>("ack_by")
    private let ahRtnTime       = Expression<Double?>("rtn_time")
    private let ahValue         = Expression<Double?>("value")
    // ISA-18.2 shelve columns (added via migration)
    private let ahShelvedBy     = Expression<String?>("shelved_by")
    private let ahShelvedAt     = Expression<Double?>("shelved_at")
    private let ahShelvedUntil  = Expression<Double?>("shelved_until")
    private let ahShelveReason  = Expression<String?>("shelve_reason")

    // MARK: - alarm_journal table  (ISA-18.2 immutable state-transition log)

    private let alarmJournal = Table("alarm_journal")
    private let ajId         = Expression<String>("id")
    private let ajAlarmId    = Expression<String>("alarm_id")
    private let ajTagName    = Expression<String>("tag_name")
    private let ajPrevState  = Expression<String>("prev_state")
    private let ajNewState   = Expression<String>("new_state")
    private let ajChangedBy  = Expression<String>("changed_by")
    private let ajReason     = Expression<String?>("reason")
    private let ajTimestamp  = Expression<Double>("timestamp")

    // OOS columns on alarm_configs (added via migration)
    private let acOOS        = Expression<Int>("out_of_service")
    private let acOOSBy      = Expression<String?>("oos_by")
    private let acOOSReason  = Expression<String?>("oos_reason")

    // MARK: - scheduled_jobs table

    private let scheduledJobs  = Table("scheduled_jobs")
    private let sjId           = Expression<String>("sj_id")
    private let sjJson         = Expression<String>("sj_json")
    private let sjEnabled      = Expression<Int>("sj_enabled")
    private let sjCreatedTs    = Expression<Int64>("sj_created_ts")

    // MARK: - schedule_executions table

    private let scheduleExecutions = Table("schedule_executions")
    private let seId               = Expression<String>("se_id")
    private let seJobId            = Expression<String>("se_job_id")
    private let seJobName          = Expression<String>("se_job_name")
    private let seTs               = Expression<Int64>("se_ts")
    private let seResult           = Expression<String>("se_result")

    // MARK: - recipes table

    private let recipes       = Table("recipes")
    private let rcId          = Expression<String>("id")
    private let rcName        = Expression<String>("name")
    private let rcDesc        = Expression<String>("description")
    /// Setpoints encoded as JSON ([RecipeSetpoint]).
    private let rcSetpoints   = Expression<String>("setpoints_json")
    private let rcVersion     = Expression<Int>("version")
    private let rcCreatedAt   = Expression<Double>("created_at")
    private let rcActivatedAt = Expression<Double?>("last_activated_at")
    private let rcActivatedBy = Expression<String?>("last_activated_by")

    // MARK: - recipe_activations table

    private let recipeActivations = Table("recipe_activations")
    private let raId              = Expression<String>("id")
    private let raRecipeId        = Expression<String>("recipe_id")
    private let raRecipeName      = Expression<String>("recipe_name")
    private let raActivatedAt     = Expression<Double>("activated_at")
    private let raActivatedBy     = Expression<String>("activated_by")
    private let raSucceeded       = Expression<Int>("succeeded_count")
    private let raFailed          = Expression<Int>("failed_count")
    /// JSON array of {tagName, reason} objects for failed writes.
    private let raFailedDetails   = Expression<String>("failed_details")

    // MARK: - Initialization

    // async init runs on the actor's executor — actor-isolated throughout,
    // so createTables() can be called without any concurrency warning.
    init() async throws {
        let fileManager = FileManager.default
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appDir = appSupport.appendingPathComponent("IndustrialHMI", isDirectory: true)
        try fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)

        let dbPath = appDir.appendingPathComponent("historian.db").path
        Logger.shared.info("Initializing historian database at: \(dbPath)")

        db = try Connection(dbPath)

        try db.execute("PRAGMA journal_mode=WAL")
        try db.execute("PRAGMA synchronous=NORMAL")

        try createTables()
        Logger.shared.info("Historian database initialized successfully")
    }

    // MARK: - Schema

    private func createTables() throws {
        // tag_history
        try db.run(tagHistory.create(ifNotExists: true) { t in
            t.column(thTagName)
            t.column(thTimestamp)
            t.column(thValue)
            t.column(thQuality)
            t.primaryKey(thTagName, thTimestamp)
        })
        try db.run(tagHistory.createIndex(thTagName, thTimestamp, ifNotExists: true))

        // tag_configs
        try db.run(tagConfigs.create(ifNotExists: true) { t in
            t.column(tcName, primaryKey: true)
            t.column(tcNodeId)
            t.column(tcDataType)
            t.column(tcUnit)
            t.column(tcDesc)
            t.column(tcAddedAt)
            t.column(tcExpression)
        })
        _ = try? db.run("ALTER TABLE tag_configs ADD COLUMN expression TEXT")
        _ = try? db.run("ALTER TABLE tag_configs ADD COLUMN on_label TEXT")
        _ = try? db.run("ALTER TABLE tag_configs ADD COLUMN off_label TEXT")
        _ = try? db.run("ALTER TABLE tag_configs ADD COLUMN composite_json TEXT")
        // Migration: per-tag historian opt-in flag (DEFAULT 1 = enabled for all existing tags)
        _ = try? db.run("ALTER TABLE tag_configs ADD COLUMN historian_enabled INTEGER NOT NULL DEFAULT 1")

        // alarm_configs
        try db.run(alarmConfigs.create(ifNotExists: true) { t in
            t.column(acId, primaryKey: true)
            t.column(acTagName, unique: true)
            t.column(acHighHigh)
            t.column(acHigh)
            t.column(acLow)
            t.column(acLowLow)
            t.column(acDeadband)
            t.column(acPriority)
            t.column(acEnabled)
        })

        // alarm_history
        try db.run(alarmHistory.create(ifNotExists: true) { t in
            t.column(ahId, primaryKey: true)
            t.column(ahTagName)
            t.column(ahMessage)
            t.column(ahSeverity)
            t.column(ahState)
            t.column(ahTrigger)
            t.column(ahAckTime)
            t.column(ahAckBy)
            t.column(ahRtnTime)
            t.column(ahValue)
        })
        try db.run(alarmHistory.createIndex(ahTagName, ifNotExists: true))
        _ = try? db.run("ALTER TABLE alarm_history ADD COLUMN shelved_by TEXT")
        _ = try? db.run("ALTER TABLE alarm_history ADD COLUMN shelved_at REAL")
        _ = try? db.run("ALTER TABLE alarm_history ADD COLUMN shelved_until REAL")
        _ = try? db.run("ALTER TABLE alarm_history ADD COLUMN shelve_reason TEXT")
        _ = try? db.run("ALTER TABLE alarm_configs ADD COLUMN out_of_service INTEGER NOT NULL DEFAULT 0")
        _ = try? db.run("ALTER TABLE alarm_configs ADD COLUMN oos_by TEXT")
        _ = try? db.run("ALTER TABLE alarm_configs ADD COLUMN oos_reason TEXT")

        // alarm_journal
        try db.run(alarmJournal.create(ifNotExists: true) { t in
            t.column(ajId, primaryKey: true)
            t.column(ajAlarmId)
            t.column(ajTagName)
            t.column(ajPrevState)
            t.column(ajNewState)
            t.column(ajChangedBy)
            t.column(ajReason)
            t.column(ajTimestamp)
        })
        try db.run(alarmJournal.createIndex(ajAlarmId,  ifNotExists: true))
        try db.run(alarmJournal.createIndex(ajTagName,  ifNotExists: true))
        try db.run(alarmJournal.createIndex(ajTimestamp, ifNotExists: true))

        // write_log
        try db.run(writeLog.create(ifNotExists: true) { t in
            t.column(wlId, primaryKey: true)
            t.column(wlTagName)
            t.column(wlOldValue)
            t.column(wlNewValue)
            t.column(wlReqBy)
            t.column(wlAt)
            t.column(wlStatus)
        })
        try db.run(writeLog.createIndex(wlTagName, ifNotExists: true))

        // recipes
        try db.run(recipes.create(ifNotExists: true) { t in
            t.column(rcId, primaryKey: true)
            t.column(rcName)
            t.column(rcDesc)
            t.column(rcSetpoints)
            t.column(rcVersion)
            t.column(rcCreatedAt)
            t.column(rcActivatedAt)
            t.column(rcActivatedBy)
        })

        // recipe_activations
        try db.run(recipeActivations.create(ifNotExists: true) { t in
            t.column(raId, primaryKey: true)
            t.column(raRecipeId)
            t.column(raRecipeName)
            t.column(raActivatedAt)
            t.column(raActivatedBy)
            t.column(raSucceeded)
            t.column(raFailed)
            t.column(raFailedDetails)
        })
        try db.run(recipeActivations.createIndex(raRecipeId, ifNotExists: true))

        // scheduled_jobs
        try db.run(scheduledJobs.create(ifNotExists: true) { t in
            t.column(sjId,        primaryKey: true)
            t.column(sjJson)
            t.column(sjEnabled)
            t.column(sjCreatedTs)
        })

        // schedule_executions
        try db.run(scheduleExecutions.create(ifNotExists: true) { t in
            t.column(seId,      primaryKey: true)
            t.column(seJobId)
            t.column(seJobName)
            t.column(seTs)
            t.column(seResult)
        })
        try db.run(scheduleExecutions.createIndex(seJobId, ifNotExists: true))

        Logger.shared.info("Historian database initialized successfully")
    }

    // MARK: - tag_history: Write

    func logValue(tagName: String, value: TagValue, timestamp: Date = Date()) throws {
        guard let numericValue = value.numericValue else { return }
        let tsMs = Int64(timestamp.timeIntervalSince1970 * 1000)
        try db.run(tagHistory.insert(
            or: .replace,
            thTagName  <- tagName,
            thTimestamp <- tsMs,
            thValue    <- numericValue,
            thQuality  <- TagQuality.good.rawValue
        ))
    }

    func logBatch(_ values: [(tagName: String, value: Double, timestamp: Date)]) throws {
        try db.transaction {
            for item in values {
                let tsMs = Int64(item.timestamp.timeIntervalSince1970 * 1000)
                try db.run(tagHistory.insert(
                    or: .replace,
                    thTagName  <- item.tagName,
                    thTimestamp <- tsMs,
                    thValue    <- item.value,
                    thQuality  <- TagQuality.good.rawValue
                ))
            }
        }
    }

    // MARK: - write_log: Append

    /// Log a confirmed or failed operator write to the immutable audit trail.
    func logWrite(
        tagName: String,
        oldValue: Double?,
        newValue: Double?,
        requestedBy: String,
        status: String
    ) throws {
        try db.run(writeLog.insert(
            wlId      <- UUID().uuidString,
            wlTagName <- tagName,
            wlOldValue <- oldValue,
            wlNewValue <- newValue,
            wlReqBy   <- requestedBy,
            wlAt      <- Date().timeIntervalSince1970,
            wlStatus  <- status
        ))
    }

    // MARK: - tag_history: Read

    func getHistory(
        for tagName: String,
        from startTime: Date,
        to endTime: Date,
        maxPoints: Int = 1000
    ) throws -> [HistoricalDataPoint] {
        let startMs = Int64(startTime.timeIntervalSince1970 * 1000)
        let endMs   = Int64(endTime.timeIntervalSince1970 * 1000)
        let query = tagHistory
            .filter(thTagName == tagName)
            .filter(thTimestamp >= startMs && thTimestamp <= endMs)
            .order(thTimestamp.asc)
            .limit(maxPoints)
        return try db.prepare(query).map { row in
            HistoricalDataPoint(
                timestamp: Date(timeIntervalSince1970: Double(row[thTimestamp]) / 1000.0),
                value: row[thValue],
                quality: TagQuality(rawValue: row[thQuality]) ?? .uncertain
            )
        }
    }

    func getLatestValue(for tagName: String) throws -> HistoricalDataPoint? {
        let query = tagHistory.filter(thTagName == tagName).order(thTimestamp.desc).limit(1)
        guard let row = try db.pluck(query) else { return nil }
        return HistoricalDataPoint(
            timestamp: Date(timeIntervalSince1970: Double(row[thTimestamp]) / 1000.0),
            value: row[thValue],
            quality: TagQuality(rawValue: row[thQuality]) ?? .uncertain
        )
    }

    func getStatistics(
        for tagName: String,
        from startTime: Date,
        to endTime: Date
    ) throws -> TagHistoryStatistics? {
        let startMs = Int64(startTime.timeIntervalSince1970 * 1000)
        let endMs   = Int64(endTime.timeIntervalSince1970 * 1000)
        let query = tagHistory
            .filter(thTagName == tagName)
            .filter(thTimestamp >= startMs && thTimestamp <= endMs)
            .select(thValue.min, thValue.max, thValue.average, thValue.count)
        guard let row = try db.pluck(query),
              let minV = row[thValue.min],
              let maxV = row[thValue.max],
              let avgV = row[thValue.average] else { return nil }
        return TagHistoryStatistics(
            tagName: tagName,
            count: row[thValue.count],
            minimum: minV,
            maximum: maxV,
            average: avgV,
            startTime: startTime,
            endTime: endTime
        )
    }

    /// Return time-bucketed min/max/avg for charting with a fixed number of points.
    func getAggregatedHistory(
        for tagName: String,
        from startTime: Date,
        to endTime: Date,
        bucketSeconds: Int = 60
    ) throws -> [AggregatedDataPoint] {
        let startMs = Int64(startTime.timeIntervalSince1970 * 1000)
        let endMs   = Int64(endTime.timeIntervalSince1970 * 1000)
        let bucketMs = Int64(bucketSeconds) * 1000

        // Raw SQL GROUP BY time bucket
        let sql = """
            SELECT
                (timestamp / \(bucketMs)) * \(bucketMs) AS bucket,
                MIN(value)  AS min_val,
                MAX(value)  AS max_val,
                AVG(value)  AS avg_val,
                COUNT(*)    AS cnt
            FROM tag_history
            WHERE tag_name = ? AND timestamp >= ? AND timestamp <= ?
            GROUP BY bucket
            ORDER BY bucket ASC
            """
        var result: [AggregatedDataPoint] = []
        for row in try db.prepare(sql, tagName, startMs, endMs) {
            guard let bucketRaw = row[0] as? Int64,
                  let minVal   = row[1] as? Double,
                  let maxVal   = row[2] as? Double,
                  let avgVal   = row[3] as? Double else { continue }
            result.append(AggregatedDataPoint(
                timestamp: Date(timeIntervalSince1970: Double(bucketRaw) / 1000.0),
                minimum: minVal,
                maximum: maxVal,
                average: avgVal
            ))
        }
        return result
    }

    // MARK: - tag_configs: Write / Read

    func saveTagConfig(_ tag: Tag) throws {
        let tsMs = Int64(Date().timeIntervalSince1970 * 1000)
        // Encode composite members + aggregation as JSON when present
        let compositeJSON: String? = {
            guard tag.dataType == .composite,
                  let members = tag.compositeMembers,
                  let agg     = tag.compositeAggregation else { return nil }
            struct CompositePayload: Codable {
                let aggregation: String
                let members: [CompositeMember]
            }
            let payload = CompositePayload(aggregation: agg.rawValue, members: members)
            return (try? JSONEncoder().encode(payload)).flatMap { String(data: $0, encoding: .utf8) }
        }()
        try db.run(tagConfigs.insert(
            or: .replace,
            tcName             <- tag.name,
            tcNodeId           <- tag.nodeId,
            tcDataType         <- tag.dataType.rawValue,
            tcUnit             <- tag.unit,
            tcDesc             <- tag.description,
            tcAddedAt          <- tsMs,
            tcExpression       <- tag.expression,
            tcOnLabel          <- tag.onLabel,
            tcOffLabel         <- tag.offLabel,
            tcCompositeJSON    <- compositeJSON,
            tcHistorianEnabled <- (tag.historianEnabled ? 1 : 0)
        ))
    }

    func loadTagConfigs() throws -> [Tag] {
        try db.prepare(tagConfigs).map { row in
            // Decode composite payload if present
            var compositeMembers:     [CompositeMember]?   = nil
            var compositeAggregation: CompositeAggregation? = nil
            if let json = row[tcCompositeJSON], let data = json.data(using: .utf8) {
                struct CompositePayload: Codable {
                    let aggregation: String
                    let members: [CompositeMember]
                }
                if let payload = try? JSONDecoder().decode(CompositePayload.self, from: data) {
                    compositeMembers     = payload.members
                    compositeAggregation = CompositeAggregation(rawValue: payload.aggregation)
                }
            }
            // historian_enabled column defaults to 1 (true) for rows added before migration
            let historianEnabledInt = (try? row.get(tcHistorianEnabled)) ?? 1
            return Tag(
                name:                row[tcName],
                nodeId:              row[tcNodeId],
                unit:                row[tcUnit],
                description:         row[tcDesc],
                dataType:            TagDataType(rawValue: row[tcDataType]) ?? .analog,
                expression:          row[tcExpression],
                onLabel:             row[tcOnLabel],
                offLabel:            row[tcOffLabel],
                compositeMembers:    compositeMembers,
                compositeAggregation: compositeAggregation,
                historianEnabled:    historianEnabledInt != 0
            )
        }
    }

    func deleteTagConfig(name: String) throws {
        try db.run(tagConfigs.filter(tcName == name).delete())
    }

    // MARK: - alarm_configs: Write / Read

    func saveAlarmConfig(_ config: AlarmConfig) throws {
        try db.run(alarmConfigs.insert(
            or: .replace,
            acId        <- config.id.uuidString,
            acTagName   <- config.tagName,
            acHighHigh  <- config.highHigh,
            acHigh      <- config.high,
            acLow       <- config.low,
            acLowLow    <- config.lowLow,
            acDeadband  <- config.deadband,
            acPriority  <- config.priority.rawValue,
            acEnabled   <- config.enabled ? 1 : 0,
            acOOS       <- config.outOfService ? 1 : 0,
            acOOSBy     <- config.outOfServiceBy,
            acOOSReason <- config.outOfServiceReason
        ))
    }

    func loadAlarmConfigs() throws -> [AlarmConfig] {
        try db.prepare(alarmConfigs).map { row in
            AlarmConfig(
                id:                  UUID(uuidString: row[acId]) ?? UUID(),
                tagName:             row[acTagName],
                highHigh:            row[acHighHigh],
                high:                row[acHigh],
                low:                 row[acLow],
                lowLow:              row[acLowLow],
                priority:            AlarmPriority(rawValue: row[acPriority]) ?? .medium,
                deadband:            row[acDeadband],
                enabled:             row[acEnabled] != 0,
                outOfService:        row[acOOS] != 0,
                outOfServiceBy:      row[acOOSBy],
                outOfServiceReason:  row[acOOSReason]
            )
        }
    }

    func deleteAlarmConfig(id: UUID) throws {
        try db.run(alarmConfigs.filter(acId == id.uuidString).delete())
    }

    // MARK: - alarm_history: Write

    func insertAlarmEvent(_ alarm: Alarm) throws {
        try db.run(alarmHistory.insert(
            or: .replace,
            ahId           <- alarm.id.uuidString,
            ahTagName      <- alarm.tagName,
            ahMessage      <- alarm.message,
            ahSeverity     <- alarm.severity.rawValue,
            ahState        <- alarm.state.rawValue,
            ahTrigger      <- alarm.triggerTime.timeIntervalSince1970,
            ahAckTime      <- alarm.acknowledgedTime?.timeIntervalSince1970,
            ahAckBy        <- alarm.acknowledgedBy,
            ahRtnTime      <- alarm.returnToNormalTime?.timeIntervalSince1970,
            ahValue        <- alarm.value,
            ahShelvedBy    <- alarm.shelvedBy,
            ahShelvedAt    <- alarm.shelvedAt?.timeIntervalSince1970,
            ahShelvedUntil <- alarm.shelvedUntil?.timeIntervalSince1970,
            ahShelveReason <- alarm.shelveReason
        ))
    }

    func updateAlarmEvent(_ alarm: Alarm) throws {
        let row = alarmHistory.filter(ahId == alarm.id.uuidString)
        try db.run(row.update(
            ahState        <- alarm.state.rawValue,
            ahAckTime      <- alarm.acknowledgedTime?.timeIntervalSince1970,
            ahAckBy        <- alarm.acknowledgedBy,
            ahRtnTime      <- alarm.returnToNormalTime?.timeIntervalSince1970,
            ahShelvedBy    <- alarm.shelvedBy,
            ahShelvedAt    <- alarm.shelvedAt?.timeIntervalSince1970,
            ahShelvedUntil <- alarm.shelvedUntil?.timeIntervalSince1970,
            ahShelveReason <- alarm.shelveReason
        ))
    }

    func loadAlarmHistory(limit: Int = 500) throws -> [Alarm] {
        let query = alarmHistory.order(ahTrigger.desc).limit(limit)
        return try db.prepare(query).map { row in
            Alarm(
                id:          UUID(uuidString: row[ahId]) ?? UUID(),
                tagName:     row[ahTagName],
                message:     row[ahMessage],
                severity:    AlarmSeverity(rawValue: row[ahSeverity]) ?? .warning,
                state:       AlarmState(rawValue: row[ahState]) ?? .normal,
                triggerTime: Date(timeIntervalSince1970: row[ahTrigger]),
                value:       row[ahValue]
            )
        }
    }

    /// Load all non-normal alarms (active + shelved) for restoring AlarmManager state on startup.
    func loadActiveAlarms() throws -> [Alarm] {
        let visible = ["Unack Active", "Ack Active", "Unack RTN", "Shelved"]
        let query = alarmHistory.filter(visible.contains(ahState)).order(ahTrigger.desc)
        return try db.prepare(query).map { row in
            var alarm = Alarm(
                id:          UUID(uuidString: row[ahId]) ?? UUID(),
                tagName:     row[ahTagName],
                message:     row[ahMessage],
                severity:    AlarmSeverity(rawValue: row[ahSeverity]) ?? .warning,
                state:       AlarmState(rawValue: row[ahState]) ?? .unacknowledgedActive,
                triggerTime: Date(timeIntervalSince1970: row[ahTrigger]),
                value:       row[ahValue]
            )
            if let ackTs = row[ahAckTime] {
                alarm.acknowledgedTime = Date(timeIntervalSince1970: ackTs)
                alarm.acknowledgedBy   = row[ahAckBy]
            }
            if let rtnTs = row[ahRtnTime] {
                alarm.returnToNormalTime = Date(timeIntervalSince1970: rtnTs)
            }
            // Restore shelve fields (may be nil for non-shelved rows)
            if let shelvedBy = row[ahShelvedBy] {
                alarm.shelvedBy    = shelvedBy
                alarm.shelvedAt    = row[ahShelvedAt].map { Date(timeIntervalSince1970: $0) }
                alarm.shelvedUntil = row[ahShelvedUntil].map { Date(timeIntervalSince1970: $0) }
                alarm.shelveReason = row[ahShelveReason]
            }
            return alarm
        }
    }

    // MARK: - alarm_journal: Write / Read

    func logAlarmJournalEntry(_ entry: AlarmJournalEntry) throws {
        try db.run(alarmJournal.insert(
            ajId        <- entry.id.uuidString,
            ajAlarmId   <- entry.alarmId.uuidString,
            ajTagName   <- entry.tagName,
            ajPrevState <- entry.prevState.rawValue,
            ajNewState  <- entry.newState.rawValue,
            ajChangedBy <- entry.changedBy,
            ajReason    <- entry.reason,
            ajTimestamp <- entry.timestamp.timeIntervalSince1970
        ))
    }

    func loadAlarmJournal(forTag tagName: String? = nil, limit: Int = 200) throws -> [AlarmJournalEntry] {
        var query = alarmJournal.order(ajTimestamp.desc).limit(limit)
        if let tagName { query = alarmJournal.filter(ajTagName == tagName).order(ajTimestamp.desc).limit(limit) }
        return try db.prepare(query).compactMap { row in
            guard let prevState = AlarmState(rawValue: row[ajPrevState]),
                  let newState  = AlarmState(rawValue: row[ajNewState]) else { return nil }
            return AlarmJournalEntry(
                id:        UUID(uuidString: row[ajId])      ?? UUID(),
                alarmId:   UUID(uuidString: row[ajAlarmId]) ?? UUID(),
                tagName:   row[ajTagName],
                prevState: prevState,
                newState:  newState,
                changedBy: row[ajChangedBy],
                reason:    row[ajReason],
                timestamp: Date(timeIntervalSince1970: row[ajTimestamp])
            )
        }
    }

    // MARK: - write_log: Read

    func loadWriteLog(
        from startDate: Date = .distantPast,
        to endDate: Date = Date(),
        limit: Int = 1_000
    ) throws -> [WriteLogEntry] {
        let query = writeLog
            .filter(wlAt >= startDate.timeIntervalSince1970 && wlAt <= endDate.timeIntervalSince1970)
            .order(wlAt.desc)
            .limit(limit)
        return try db.prepare(query).map { row in
            WriteLogEntry(
                id:          row[wlId],
                tagName:     row[wlTagName],
                oldValue:    row[wlOldValue],
                newValue:    row[wlNewValue],
                requestedBy: row[wlReqBy],
                timestamp:   Date(timeIntervalSince1970: row[wlAt]),
                status:      row[wlStatus]
            )
        }
    }

    // MARK: - Maintenance

    func purgeOldData(olderThan cutoffDate: Date) throws {
        let cutoffMs = Int64(cutoffDate.timeIntervalSince1970 * 1000)
        let deleted = try db.run(tagHistory.filter(thTimestamp < cutoffMs).delete())
        Logger.shared.info("Purged \(deleted) old records from historian")
        try db.execute("VACUUM")
    }

    func getDatabaseStats() throws -> DatabaseStatistics {
        let totalRows = try db.scalar(tagHistory.count)
        let oldestMs  = try db.pluck(tagHistory.select(thTimestamp.min))?[thTimestamp.min] ?? 0
        let newestMs  = try db.pluck(tagHistory.select(thTimestamp.max))?[thTimestamp.max] ?? 0
        let dbURL     = URL(fileURLWithPath: db.description)
        let fileSize  = (try? FileManager.default.attributesOfItem(atPath: dbURL.path)[.size] as? Int64) ?? 0
        return DatabaseStatistics(
            totalRecords: totalRows,
            oldestRecord: Date(timeIntervalSince1970: Double(oldestMs) / 1000.0),
            newestRecord: Date(timeIntervalSince1970: Double(newestMs) / 1000.0),
            fileSizeBytes: fileSize
        )
    }

    // MARK: - Recipes: CRUD

    /// Insert or replace a recipe (upsert by primary key).
    func saveRecipe(_ recipe: Recipe) throws {
        let spData    = (try? JSONEncoder().encode(recipe.setpoints)) ?? Data()
        let spJSON    = String(data: spData, encoding: .utf8) ?? "[]"
        try db.run(recipes.insert(
            or: .replace,
            rcId          <- recipe.id.uuidString,
            rcName        <- recipe.name,
            rcDesc        <- recipe.description,
            rcSetpoints   <- spJSON,
            rcVersion     <- recipe.version,
            rcCreatedAt   <- recipe.createdAt.timeIntervalSince1970,
            rcActivatedAt <- recipe.lastActivatedAt?.timeIntervalSince1970,
            rcActivatedBy <- recipe.lastActivatedBy
        ))
    }

    func deleteRecipe(id: UUID) throws {
        try db.run(recipes.filter(rcId == id.uuidString).delete())
    }

    func loadRecipes() throws -> [Recipe] {
        var result: [Recipe] = []
        for row in try db.prepare(recipes.order(rcCreatedAt.asc)) {
            let spJSON  = row[rcSetpoints]
            let spData  = Data(spJSON.utf8)
            let setpoints = (try? JSONDecoder().decode([RecipeSetpoint].self, from: spData)) ?? []
            var r = Recipe(
                id:          UUID(uuidString: row[rcId]) ?? UUID(),
                name:        row[rcName],
                description: row[rcDesc],
                setpoints:   setpoints
            )
            r.version         = row[rcVersion]
            r.lastActivatedAt = row[rcActivatedAt].map { Date(timeIntervalSince1970: $0) }
            r.lastActivatedBy = row[rcActivatedBy]
            result.append(r)
        }
        return result
    }

    // MARK: - Recipe Activations: Append-only log

    func logRecipeActivation(_ result: RecipeActivationResult) throws {
        struct FailEntry: Codable { let tagName: String; let reason: String }
        let failEntries = result.failed.map { FailEntry(tagName: $0.tagName, reason: $0.reason) }
        let failJSON    = (try? String(data: JSONEncoder().encode(failEntries), encoding: .utf8)) ?? "[]"

        try db.run(recipeActivations.insert(
            raId          <- UUID().uuidString,
            raRecipeId    <- result.recipe.id.uuidString,
            raRecipeName  <- result.recipe.name,
            raActivatedAt <- result.activatedAt.timeIntervalSince1970,
            raActivatedBy <- result.activatedBy,
            raSucceeded   <- result.successCount,
            raFailed      <- result.failureCount,
            raFailedDetails <- failJSON
        ))
    }

    // MARK: - Scheduled Jobs

    func saveScheduledJob(_ job: ScheduledJob) throws {
        guard let data = try? JSONEncoder().encode(job),
              let json = String(data: data, encoding: .utf8) else { return }
        try db.run(scheduledJobs.insert(or: .replace,
            sjId        <- job.id.uuidString,
            sjJson      <- json,
            sjEnabled   <- job.isEnabled ? 1 : 0,
            sjCreatedTs <- Int64(job.createdAt.timeIntervalSince1970 * 1000)
        ))
    }

    func deleteScheduledJob(id: UUID) throws {
        let row = scheduledJobs.filter(sjId == id.uuidString)
        try db.run(row.delete())
    }

    func loadScheduledJobs() throws -> [ScheduledJob] {
        try db.prepare(scheduledJobs).compactMap { row in
            guard let data = row[sjJson].data(using: .utf8),
                  let job  = try? JSONDecoder().decode(ScheduledJob.self, from: data)
            else { return nil }
            return job
        }
    }

    func logScheduleExecution(jobId: UUID, jobName: String, result: String) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try db.run(scheduleExecutions.insert(
            seId      <- UUID().uuidString,
            seJobId   <- jobId.uuidString,
            seJobName <- jobName,
            seTs      <- now,
            seResult  <- result
        ))
    }

    func loadScheduleExecutions(limit: Int = 50) throws -> [ScheduleExecution] {
        let query = scheduleExecutions.order(seTs.desc).limit(limit)
        return try db.prepare(query).compactMap { row in
            guard let jobId = UUID(uuidString: row[seJobId]),
                  let id    = UUID(uuidString: row[seId]) else { return nil }
            let ts = Date(timeIntervalSince1970: Double(row[seTs]) / 1000)
            return ScheduleExecution(id: id, jobId: jobId, jobName: row[seJobName],
                                     executedAt: ts, result: row[seResult])
        }
    }
}

// MARK: - Supporting Types

struct WriteLogEntry: Identifiable {
    let id:          String
    let tagName:     String
    let oldValue:    Double?
    let newValue:    Double?
    let requestedBy: String
    let timestamp:   Date
    let status:      String
}

struct HistoricalDataPoint: Identifiable {
    let id        = UUID()
    let timestamp: Date
    let value:     Double
    let quality:   TagQuality
}

struct AggregatedDataPoint: Identifiable {
    let id        = UUID()
    let timestamp: Date
    let minimum:   Double
    let maximum:   Double
    let average:   Double
}

struct TagHistoryStatistics {
    let tagName:   String
    let count:     Int
    let minimum:   Double
    let maximum:   Double
    let average:   Double
    let startTime: Date
    let endTime:   Date

    var range: Double { maximum - minimum }
}

struct DatabaseStatistics {
    let totalRecords:  Int
    let oldestRecord:  Date
    let newestRecord:  Date
    let fileSizeBytes: Int64

    var fileSizeMB: Double { Double(fileSizeBytes) / 1_048_576.0 }
    var timeSpan:   TimeInterval { newestRecord.timeIntervalSince(oldestRecord) }
    var timeSpanDays: Double { timeSpan / 86400.0 }
}
