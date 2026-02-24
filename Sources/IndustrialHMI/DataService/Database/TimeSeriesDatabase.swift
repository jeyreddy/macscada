import Foundation

/// Thin facade over TagEngine's Historian for time-series data access.
/// Delegates all queries to the existing TagEngine — no second SQLite connection.
@MainActor
class TimeSeriesDatabase {
    private let tagEngine: TagEngine

    init(tagEngine: TagEngine) {
        self.tagEngine = tagEngine
    }

    func getHistory(
        for tagNames: [String],
        from startTime: Date,
        to endTime: Date,
        maxPoints: Int = 1000
    ) async -> [String: [HistoricalDataPoint]] {
        await tagEngine.getHistoricalData(
            for: tagNames,
            from: startTime,
            to: endTime,
            maxPoints: maxPoints
        )
    }
}
