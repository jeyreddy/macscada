// MARK: - TrendExportSheet.swift
//
// Export sheet for historical tag data from the Historian SQLite database.
// Presented from TrendView's toolbar export button.
// Pre-populated with the currently monitored tags and selected time range.
//
// ── Configuration ─────────────────────────────────────────────────────────────
//   Tags selection: multi-toggle list of availableTags, pre-checked = preselectedTags.
//   Time range: TimeRange picker (.last15Min through .last7Days).
//   Aggregated toggle: when true, fetches hour-averaged samples instead of raw.
//     CSVBuilder.aggregatedTagHistoryCSV(tagHistory:intervalMinutes: 60)
//     Raw mode: CSVBuilder.tagHistoryCSV(tagName:points:)
//
// ── Export Flow ───────────────────────────────────────────────────────────────
//   1. For each selected tag:
//      historian.queryTagHistory(tagName:from:to:) → [HistoricalDataPoint]
//   2. Build CSV string: columns = timestamp (ISO 8601), value
//   3. NSSavePanel with suggested filename: "<tagName>_<dateRange>.csv"
//   4. Write UTF-8 Data to disk; exportError shown on failure.
//
// ── Multi-tag Export ──────────────────────────────────────────────────────────
//   Each tag generates a separate CSV file (one NSSavePanel per tag).
//   This keeps CSV files simple — no multi-column alignment needed.
//   Future: could offer a merged multi-tag CSV with timestamp interpolation.
//
// ── TimeRange ────────────────────────────────────────────────────────────────
//   TimeRange enum defined in TrendView.swift (same file domain).
//   .last15Min → from = now - 900s, .last7Days → from = now - 604800s.

import SwiftUI

// MARK: - TrendExportSheet

/// Sheet for exporting tag history to CSV.
/// Presented from TrendView; pre-populated with the currently monitored tags and time range.
struct TrendExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var dataService: DataService

    let availableTags:    [String]
    let preselectedTags:  Set<String>
    let currentTimeRange: TimeRange

    @State private var selectedTags:  Set<String>
    @State private var timeRange:     TimeRange
    @State private var useAggregated: Bool    = false
    @State private var isExporting:   Bool    = false
    @State private var exportError:   String? = nil

    init(availableTags: [String], preselectedTags: Set<String>, currentTimeRange: TimeRange) {
        self.availableTags   = availableTags.sorted()
        self.preselectedTags = preselectedTags
        self.currentTimeRange = currentTimeRange
        _selectedTags = State(initialValue: preselectedTags)
        _timeRange    = State(initialValue: currentTimeRange)
    }

    private var canExport: Bool { !isExporting && !selectedTags.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "Export Trend Data", icon: "square.and.arrow.up")
            Divider()

            Form {
                Section("Tags") {
                    if availableTags.isEmpty {
                        Label("No tags are being monitored.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundColor(.orange)
                    } else {
                        List(availableTags, id: \.self) { tag in
                            Toggle(tag, isOn: Binding(
                                get: { selectedTags.contains(tag) },
                                set: { on in
                                    if on { selectedTags.insert(tag) }
                                    else  { selectedTags.remove(tag) }
                                }
                            ))
                            .font(.system(.body, design: .monospaced))
                        }
                        .listStyle(.bordered)
                        .frame(minHeight: 120, maxHeight: 240)
                    }
                }

                Section("Time Range") {
                    Picker("Range", selection: $timeRange) {
                        ForEach(TimeRange.allCases) { r in Text(r.title).tag(r) }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Format") {
                    Toggle("Use 1-minute averages (smaller file)", isOn: $useAggregated)
                    Text(useAggregated
                         ? "Exports Min, Average, Max per 1-minute bucket."
                         : "Exports every raw data point (up to 50,000 per tag).")
                        .font(.caption).foregroundColor(.secondary)
                }

                if let err = exportError {
                    Section {
                        HStack(spacing: 6) {
                            Image(systemName: "xmark.octagon.fill").foregroundColor(.red)
                            Text(err).font(.caption).foregroundColor(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                if isExporting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Exporting…").font(.body)
                    }
                } else {
                    Button("Export CSV") { Task { await export() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canExport)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding()
        }
        .frame(width: 460)
    }

    // MARK: - Export

    private func export() async {
        guard canExport, let historian = dataService.historian else { return }
        isExporting = true
        exportError = nil

        let endDate   = Date()
        let startDate = endDate.addingTimeInterval(-timeRange.seconds)
        let tags      = selectedTags.sorted()
        let dateStr   = CSVBuilder.filenameDate()

        do {
            if useAggregated {
                var aggData: [String: [AggregatedDataPoint]] = [:]
                for tag in tags {
                    let pts = try await historian.getAggregatedHistory(
                        for: tag, from: startDate, to: endDate, bucketSeconds: 60)
                    aggData[tag] = pts
                }
                let csv = try CSVBuilder.buildAggregatedHistory(tags: tags, data: aggData)
                await MainActor.run {
                    _ = CSVBuilder.saveToFile(csv, suggestedName: "trend_export_agg_\(dateStr).csv")
                }
            } else {
                var rawData: [String: [HistoricalDataPoint]] = [:]
                for tag in tags {
                    let pts = try await historian.getHistory(
                        for: tag, from: startDate, to: endDate, maxPoints: 50_000)
                    rawData[tag] = pts
                }
                let csv = try CSVBuilder.buildTagHistory(tags: tags, data: rawData)
                await MainActor.run {
                    _ = CSVBuilder.saveToFile(csv, suggestedName: "trend_export_\(dateStr).csv")
                }
            }
            dismiss()
        } catch {
            exportError = error.localizedDescription
        }

        isExporting = false
    }
}
