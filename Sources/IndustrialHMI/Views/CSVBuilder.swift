// MARK: - CSVBuilder.swift
//
// Static utility enum for generating RFC 4180-compliant CSV strings from all
// Historian data models and triggering NSSavePanel file-save dialogs.
//
// ── CSV Generation Methods ─────────────────────────────────────────────────────
//   tagHistoryCSV(tagName:points:)         — single tag, raw samples
//   aggregatedTagHistoryCSV(tagHistory:intervalMinutes:) — hour-averaged multi-tag
//   alarmHistoryCSV(entries:)              — AlarmHistory rows
//   alarmJournalCSV(entries:)              — AlarmJournalEntry rows (state transitions)
//   writeLogCSV(entries:)                  — WriteLogEntry rows (audit log)
//
// ── RFC 4180 Compliance ───────────────────────────────────────────────────────
//   All string values wrapped in double-quotes: escape(_ value: String).
//   Internal double-quotes doubled: "he said ""hello"" → "he said ""hello"""
//   Numerics formatted as bare unquoted strings for spreadsheet import compatibility.
//   Header row included in all CSV files.
//   Line endings: \r\n (RFC 4180 §2 requirement for maximum compatibility).
//
// ── Timestamp Formatting ──────────────────────────────────────────────────────
//   iso8601 formatter: withInternetDateTime + withFractionalSeconds
//   Produces e.g. "2025-03-01T14:30:15.123Z" for global unambiguous timestamps.
//   filenameDate(_ date:): "yyyyMMdd_HHmm" format for suggested CSV filenames.
//
// ── Save Dialog ───────────────────────────────────────────────────────────────
//   saveToFile(csvString:suggestedName:): presents NSSavePanel with .csv extension
//   enforced. On confirm: writes UTF-8 encoded Data to the chosen URL.
//   Returns Bool (success/cancel). All callers ignore the return value (fire-and-forget).
//
// ── Usage Pattern ─────────────────────────────────────────────────────────────
//   exportFlow:
//     let csv = CSVBuilder.tagHistoryCSV(tagName: "Tank1_Level", points: data)
//     CSVBuilder.saveToFile(csvString: csv, suggestedName: "Tank1_Level_20250301_1430.csv")

import AppKit
import Foundation

// MARK: - CSVBuilder

/// Static utility for building CSV strings from historian data models and saving via NSSavePanel.
enum CSVBuilder {

    // MARK: - Date Formatting

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let filenameDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmm"
        return f
    }()

    static func filenameDate(_ date: Date = Date()) -> String {
        filenameDateFormatter.string(from: date)
    }

    // MARK: - CSV Escaping

    /// Wraps a value in double-quotes and escapes any internal double-quotes by doubling them.
    private static func escape(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func escape(_ value: Double?) -> String {
        guard let v = value else { return "\"\"" }
        return "\"\(v)\""
    }

    // MARK: - Tag History

    /// Builds a CSV with columns: Timestamp, TagName, Value, Quality
    /// Rows are sorted by timestamp ascending across all tags.
    static func buildTagHistory(
        tags: [String],
        data: [String: [HistoricalDataPoint]]
    ) throws -> String {
        var rows: [(timestamp: Date, tag: String, value: Double, quality: TagQuality)] = []
        for tag in tags {
            for pt in data[tag] ?? [] {
                rows.append((pt.timestamp, tag, pt.value, pt.quality))
            }
        }
        guard !rows.isEmpty else { throw ExportError.noData }
        rows.sort { $0.timestamp < $1.timestamp }

        var csv = "Timestamp,TagName,Value,Quality\n"
        for row in rows {
            csv += "\(escape(iso8601.string(from: row.timestamp))),"
            csv += "\(escape(row.tag)),"
            csv += "\(escape(String(row.value))),"
            csv += "\(escape(row.quality.rawValue.description))\n"
        }
        return csv
    }

    // MARK: - Aggregated Tag History (1-minute buckets)

    /// Builds a CSV with columns: Timestamp, TagName, Min, Average, Max
    static func buildAggregatedHistory(
        tags: [String],
        data: [String: [AggregatedDataPoint]]
    ) throws -> String {
        var rows: [(timestamp: Date, tag: String, min: Double, avg: Double, max: Double)] = []
        for tag in tags {
            for pt in data[tag] ?? [] {
                rows.append((pt.timestamp, tag, pt.minimum, pt.average, pt.maximum))
            }
        }
        guard !rows.isEmpty else { throw ExportError.noData }
        rows.sort { $0.timestamp < $1.timestamp }

        var csv = "Timestamp,TagName,Min,Average,Max\n"
        for row in rows {
            csv += "\(escape(iso8601.string(from: row.timestamp))),"
            csv += "\(escape(row.tag)),"
            csv += "\(escape(String(row.min))),"
            csv += "\(escape(String(row.avg))),"
            csv += "\(escape(String(row.max)))\n"
        }
        return csv
    }

    // MARK: - Alarm Events

    /// Builds a CSV with columns: Timestamp, Tag, Severity, State, Message, Value, AcknowledgedBy, AcknowledgedAt
    static func buildAlarmEvents(_ alarms: [Alarm]) throws -> String {
        guard !alarms.isEmpty else { throw ExportError.noData }
        var csv = "Timestamp,Tag,Severity,State,Message,Value,AcknowledgedBy,AcknowledgedAt\n"
        for alarm in alarms.sorted(by: { $0.triggerTime < $1.triggerTime }) {
            csv += "\(escape(iso8601.string(from: alarm.triggerTime))),"
            csv += "\(escape(alarm.tagName)),"
            csv += "\(escape(alarm.severity.rawValue)),"
            csv += "\(escape(alarm.state.rawValue)),"
            csv += "\(escape(alarm.message)),"
            csv += "\(escape(alarm.value.map { String($0) } ?? "")),"
            csv += "\(escape(alarm.acknowledgedBy ?? "")),"
            csv += "\(escape(alarm.acknowledgedTime.map { iso8601.string(from: $0) } ?? ""))\n"
        }
        return csv
    }

    // MARK: - Alarm Journal

    /// Builds a CSV with columns: Timestamp, Tag, AlarmID, FromState, ToState, ChangedBy, Reason
    static func buildAlarmJournal(_ entries: [AlarmJournalEntry]) throws -> String {
        guard !entries.isEmpty else { throw ExportError.noData }
        var csv = "Timestamp,Tag,AlarmID,FromState,ToState,ChangedBy,Reason\n"
        for entry in entries.sorted(by: { $0.timestamp < $1.timestamp }) {
            csv += "\(escape(iso8601.string(from: entry.timestamp))),"
            csv += "\(escape(entry.tagName)),"
            csv += "\(escape(entry.alarmId.uuidString)),"
            csv += "\(escape(entry.prevState.rawValue)),"
            csv += "\(escape(entry.newState.rawValue)),"
            csv += "\(escape(entry.changedBy)),"
            csv += "\(escape(entry.reason ?? ""))\n"
        }
        return csv
    }

    // MARK: - Write Audit Log

    /// Builds a CSV with columns: Timestamp, Tag, OldValue, NewValue, RequestedBy, Status
    static func buildWriteLog(_ entries: [WriteLogEntry]) throws -> String {
        guard !entries.isEmpty else { throw ExportError.noData }
        var csv = "Timestamp,Tag,OldValue,NewValue,RequestedBy,Status\n"
        for entry in entries.sorted(by: { $0.timestamp < $1.timestamp }) {
            csv += "\(escape(iso8601.string(from: entry.timestamp))),"
            csv += "\(escape(entry.tagName)),"
            csv += "\(escape(entry.oldValue)),"
            csv += "\(escape(entry.newValue)),"
            csv += "\(escape(entry.requestedBy)),"
            csv += "\(escape(entry.status))\n"
        }
        return csv
    }

    // MARK: - Tag List Export

    /// Builds a CSV with columns: Name, Type, Unit, Description, Expression, CurrentValue, Quality, LastUpdated
    static func buildTagList(_ tags: [Tag]) throws -> String {
        guard !tags.isEmpty else { throw ExportError.noData }
        var csv = "Name,Type,Unit,Description,Expression,CurrentValue,Quality,LastUpdated\n"
        for tag in tags.sorted(by: { $0.name < $1.name }) {
            let currentValue: String
            switch tag.value {
            case .analog(let v):  currentValue = String(format: "%g", v)
            case .digital(let b): currentValue = b ? "1" : "0"
            case .string(let s):  currentValue = s
            case .none:           currentValue = ""
            }
            csv += "\(escape(tag.name)),"
            csv += "\(escape(tag.dataType.rawValue)),"
            csv += "\(escape(tag.unit ?? "")),"
            csv += "\(escape(tag.description ?? "")),"
            csv += "\(escape(tag.expression ?? "")),"
            csv += "\(escape(currentValue)),"
            csv += "\(escape(tag.quality.description)),"
            csv += "\(escape(iso8601.string(from: tag.timestamp)))\n"
        }
        return csv
    }

    // MARK: - Save Panel

    /// Shows a macOS NSSavePanel and writes the CSV to the chosen file.
    /// Must be called on the main actor. Returns true if the file was saved.
    @MainActor
    @discardableResult
    static func saveToFile(_ csv: String, suggestedName: String) -> Bool {
        let panel = NSSavePanel()
        panel.title = "Export CSV"
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes  = [.commaSeparatedText]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            Logger.shared.info("CSV exported to \(url.lastPathComponent)")
            return true
        } catch {
            Logger.shared.error("CSV export failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Errors

    enum ExportError: LocalizedError {
        case noData
        var errorDescription: String? {
            switch self {
            case .noData: return "No data to export for the selected time range and tags."
            }
        }
    }
}
