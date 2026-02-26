import Foundation
import SQLite

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

    // MARK: - alarm_history table

    private let alarmHistory = Table("alarm_history")
    private let ahId         = Expression<String>("id")
    private let ahTagName    = Expression<String>("tag_name")
    private let ahMessage    = Expression<String>("message")
    private let ahSeverity   = Expression<String>("severity")
    private let ahState      = Expression<String>("state")
    private let ahTrigger    = Expression<Double>("trigger_time")
    private let ahAckTime    = Expression<Double?>("ack_time")
    private let ahAckBy      = Expression<String?>("ack_by")
    private let ahRtnTime    = Expression<Double?>("rtn_time")
    private let ahValue      = Expression<Double?>("value")

    // MARK: - Initialization

    init() throws {
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
        })

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

        Logger.shared.info("Database tables created successfully")
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
        try db.run(tagConfigs.insert(
            or: .replace,
            tcName     <- tag.name,
            tcNodeId   <- tag.nodeId,
            tcDataType <- tag.dataType.rawValue,
            tcUnit     <- tag.unit,
            tcDesc     <- tag.description,
            tcAddedAt  <- tsMs
        ))
    }

    func loadTagConfigs() throws -> [Tag] {
        try db.prepare(tagConfigs).map { row in
            Tag(
                name:        row[tcName],
                nodeId:      row[tcNodeId],
                unit:        row[tcUnit],
                description: row[tcDesc],
                dataType:    TagDataType(rawValue: row[tcDataType]) ?? .analog
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
            acId       <- config.id.uuidString,
            acTagName  <- config.tagName,
            acHighHigh <- config.highHigh,
            acHigh     <- config.high,
            acLow      <- config.low,
            acLowLow   <- config.lowLow,
            acDeadband <- config.deadband,
            acPriority <- config.priority.rawValue,
            acEnabled  <- config.enabled ? 1 : 0
        ))
    }

    func loadAlarmConfigs() throws -> [AlarmConfig] {
        try db.prepare(alarmConfigs).map { row in
            AlarmConfig(
                id:       UUID(uuidString: row[acId]) ?? UUID(),
                tagName:  row[acTagName],
                highHigh: row[acHighHigh],
                high:     row[acHigh],
                low:      row[acLow],
                lowLow:   row[acLowLow],
                priority: AlarmPriority(rawValue: row[acPriority]) ?? .medium,
                deadband: row[acDeadband],
                enabled:  row[acEnabled] != 0
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
            ahId      <- alarm.id.uuidString,
            ahTagName <- alarm.tagName,
            ahMessage <- alarm.message,
            ahSeverity <- alarm.severity.rawValue,
            ahState   <- alarm.state.rawValue,
            ahTrigger <- alarm.triggerTime.timeIntervalSince1970,
            ahAckTime <- alarm.acknowledgedTime?.timeIntervalSince1970,
            ahAckBy   <- alarm.acknowledgedBy,
            ahRtnTime <- alarm.returnToNormalTime?.timeIntervalSince1970,
            ahValue   <- alarm.value
        ))
    }

    func updateAlarmEvent(_ alarm: Alarm) throws {
        let row = alarmHistory.filter(ahId == alarm.id.uuidString)
        try db.run(row.update(
            ahState   <- alarm.state.rawValue,
            ahAckTime <- alarm.acknowledgedTime?.timeIntervalSince1970,
            ahAckBy   <- alarm.acknowledgedBy,
            ahRtnTime <- alarm.returnToNormalTime?.timeIntervalSince1970
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

    func loadActiveAlarms() throws -> [Alarm] {
        let visible = ["Unack Active", "Ack Active", "Unack RTN"]
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
            return alarm
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
}

// MARK: - Supporting Types

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
