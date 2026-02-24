import Foundation
import SQLite

/// Historian service for storing and retrieving time-series process data
actor Historian {
    // MARK: - Database Schema
    
    private let db: Connection
    private let tagHistory = Table("tag_history")
    
    // Columns
    private let tagName = Expression<String>("tag_name")
    private let timestamp = Expression<Int64>("timestamp")
    private let value = Expression<Double>("value")
    private let quality = Expression<Int>("quality")
    
    // MARK: - Initialization
    
    init() throws {
        // Get application support directory
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
        
        // Open database connection
        db = try Connection(dbPath)
        
        // Enable WAL mode for better concurrency
        try db.execute("PRAGMA journal_mode=WAL")
        try db.execute("PRAGMA synchronous=NORMAL")
        
        // Create tables
        try createTables()
        
        Logger.shared.info("Historian database initialized successfully")
    }
    
    // MARK: - Database Setup
    
    private func createTables() throws {
        // Create tag_history table
        try db.run(tagHistory.create(ifNotExists: true) { t in
            t.column(tagName)
            t.column(timestamp)
            t.column(value)
            t.column(quality)
            t.primaryKey(tagName, timestamp)
        })
        
        // Create indexes for faster queries
        try db.run(tagHistory.createIndex(
            tagName,
            timestamp,
            ifNotExists: true
        ))
        
        Logger.shared.info("Database tables created successfully")
    }
    
    // MARK: - Write Operations
    
    /// Log a single tag value to historian
    func logValue(tagName: String, value: TagValue, timestamp: Date = Date()) async throws {
        guard let numericValue = value.numericValue else {
            // Skip non-numeric values for now
            return
        }
        
        let timestampMs = Int64(timestamp.timeIntervalSince1970 * 1000)
        
        try db.run(tagHistory.insert(
            or: .replace,
            self.tagName <- tagName,
            self.timestamp <- timestampMs,
            self.value <- numericValue,
            self.quality <- TagQuality.good.rawValue
        ))
    }
    
    /// Batch log multiple tag values (more efficient)
    func logBatch(_ values: [(tagName: String, value: Double, timestamp: Date)]) async throws {
        try db.transaction {
            for item in values {
                let timestampMs = Int64(item.timestamp.timeIntervalSince1970 * 1000)
                
                try db.run(tagHistory.insert(
                    or: .replace,
                    self.tagName <- item.tagName,
                    self.timestamp <- timestampMs,
                    self.value <- item.value,
                    self.quality <- TagQuality.good.rawValue
                ))
            }
        }
    }
    
    // MARK: - Read Operations
    
    /// Get historical values for a tag within time range
    func getHistory(
        for tagName: String,
        from startTime: Date,
        to endTime: Date,
        maxPoints: Int = 1000
    ) async throws -> [HistoricalDataPoint] {
        let startMs = Int64(startTime.timeIntervalSince1970 * 1000)
        let endMs = Int64(endTime.timeIntervalSince1970 * 1000)
        
        let query = tagHistory
            .filter(self.tagName == tagName)
            .filter(timestamp >= startMs && timestamp <= endMs)
            .order(timestamp.asc)
            .limit(maxPoints)
        
        var dataPoints: [HistoricalDataPoint] = []
        
        for row in try db.prepare(query) {
            let point = HistoricalDataPoint(
                timestamp: Date(timeIntervalSince1970: Double(row[timestamp]) / 1000.0),
                value: row[value],
                quality: TagQuality(rawValue: row[quality]) ?? .uncertain
            )
            dataPoints.append(point)
        }
        
        return dataPoints
    }
    
    /// Get latest value for a tag
    func getLatestValue(for tagName: String) async throws -> HistoricalDataPoint? {
        let query = tagHistory
            .filter(self.tagName == tagName)
            .order(timestamp.desc)
            .limit(1)
        
        guard let row = try db.pluck(query) else {
            return nil
        }
        
        return HistoricalDataPoint(
            timestamp: Date(timeIntervalSince1970: Double(row[timestamp]) / 1000.0),
            value: row[value],
            quality: TagQuality(rawValue: row[quality]) ?? .uncertain
        )
    }
    
    /// Get statistical aggregates for a tag
    func getStatistics(
        for tagName: String,
        from startTime: Date,
        to endTime: Date
    ) async throws -> TagHistoryStatistics? {
        let startMs = Int64(startTime.timeIntervalSince1970 * 1000)
        let endMs = Int64(endTime.timeIntervalSince1970 * 1000)
        
        let query = tagHistory
            .filter(self.tagName == tagName)
            .filter(timestamp >= startMs && timestamp <= endMs)
            .select(
                value.min,
                value.max,
                value.average,
                value.count
            )
        
        guard let row = try db.pluck(query),
              let min = row[value.min],
              let max = row[value.max],
              let avg = row[value.average] else {
            return nil
        }
        
        let count = row[value.count]
        
        return TagHistoryStatistics(
            tagName: tagName,
            count: count,
            minimum: min,
            maximum: max,
            average: avg,
            startTime: startTime,
            endTime: endTime
        )
    }
    
    // MARK: - Maintenance Operations
    
    /// Delete old data beyond retention period
    func purgeOldData(olderThan cutoffDate: Date) async throws {
        let cutoffMs = Int64(cutoffDate.timeIntervalSince1970 * 1000)
        
        let query = tagHistory.filter(timestamp < cutoffMs)
        let deletedCount = try db.run(query.delete())
        
        Logger.shared.info("Purged \(deletedCount) old records from historian")
        
        // Vacuum database to reclaim space
        try db.execute("VACUUM")
    }
    
    /// Get database statistics
    func getDatabaseStats() async throws -> DatabaseStatistics {
        let totalRows = try db.scalar(tagHistory.count)
        
        let oldestQuery = tagHistory.select(timestamp.min)
        let newestQuery = tagHistory.select(timestamp.max)
        
        let oldestMs = try db.pluck(oldestQuery)?[timestamp.min] ?? 0
        let newestMs = try db.pluck(newestQuery)?[timestamp.max] ?? 0
        
        let oldestDate = Date(timeIntervalSince1970: Double(oldestMs) / 1000.0)
        let newestDate = Date(timeIntervalSince1970: Double(newestMs) / 1000.0)
        
        // Get database file size
        let fileManager = FileManager.default
        let dbURL = URL(fileURLWithPath: db.description)
        let fileSize = try fileManager.attributesOfItem(atPath: dbURL.path)[.size] as? Int64 ?? 0
        
        return DatabaseStatistics(
            totalRecords: totalRows,
            oldestRecord: oldestDate,
            newestRecord: newestDate,
            fileSizeBytes: fileSize
        )
    }
}

// MARK: - Supporting Types

struct HistoricalDataPoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let value: Double
    let quality: TagQuality
}

struct TagHistoryStatistics {
    let tagName: String
    let count: Int
    let minimum: Double
    let maximum: Double
    let average: Double
    let startTime: Date
    let endTime: Date
    
    var range: Double {
        maximum - minimum
    }
}

struct DatabaseStatistics {
    let totalRecords: Int
    let oldestRecord: Date
    let newestRecord: Date
    let fileSizeBytes: Int64
    
    var fileSizeMB: Double {
        Double(fileSizeBytes) / 1_048_576.0
    }
    
    var timeSpan: TimeInterval {
        newestRecord.timeIntervalSince(oldestRecord)
    }
    
    var timeSpanDays: Double {
        timeSpan / 86400.0
    }
}
