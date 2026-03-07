// MARK: - AlarmExportSheet.swift
//
// Export sheet for compliance data from the Historian SQLite database.
// Presented from AlarmListView via the toolbar export button.
//
// ── Export Options ────────────────────────────────────────────────────────────
//   Alarm Events    — all alarm instances (id, tagName, severity, state, message,
//                     value, triggerTime, acknowledgedAt, acknowledgedBy)
//   Alarm Journal   — all state transitions (tagName, prevState, newState, changedBy,
//                     timestamp, reason)
//   Write Audit Log — all write operations (tagName, oldValue, newValue, requestedBy,
//                     timestamp, status)
//   Each selected option produces a separate CSV file via NSSavePanel.
//
// ── Export Flow ───────────────────────────────────────────────────────────────
//   1. exportPressed() fetches data from historian for each selected option:
//      historian.loadAlarmHistory() → CSVBuilder.alarmHistoryCSV(entries:)
//      historian.loadAlarmJournal() → CSVBuilder.alarmJournalCSV(entries:)
//      historian.loadWriteLog()     → CSVBuilder.writeLogCSV(entries:)
//   2. For each populated CSV string: presents NSSavePanel with suggested filename
//      e.g. "alarm_events_20250301_1430.csv"
//   3. User confirms location → write UTF-8 Data to disk.
//   4. exportError shows any failure inline.
//
// ── canExport Guard ───────────────────────────────────────────────────────────
//   Export button disabled when: isExporting = true OR no option is toggled on.
//   This prevents empty exports and double-taps.

import SwiftUI

// MARK: - AlarmExportSheet

/// Sheet for exporting alarm events, journal, and write audit log to CSV files.
/// Presented from AlarmListView.
struct AlarmExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var alarmManager: AlarmManager
    @EnvironmentObject var dataService:  DataService

    @State private var includeEvents:   Bool    = true
    @State private var includeJournal:  Bool    = true
    @State private var includeWriteLog: Bool    = false
    @State private var isExporting:     Bool    = false
    @State private var exportError:     String? = nil

    private var canExport: Bool {
        !isExporting && (includeEvents || includeJournal || includeWriteLog)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "Export Alarm Data", icon: "square.and.arrow.up")
            Divider()

            Form {
                Section("Include") {
                    Toggle("Alarm Events", isOn: $includeEvents)
                    Toggle("Alarm Journal (state transitions)", isOn: $includeJournal)
                    Toggle("Write Audit Log", isOn: $includeWriteLog)
                }

                Section {
                    Text("Each selected option exports to a separate CSV file. You will be prompted to choose a save location for each.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let err = exportError {
                    Section {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "xmark.octagon.fill")
                                .foregroundColor(.red).font(.caption)
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
        .frame(width: 420)
    }

    // MARK: - Export

    private func export() async {
        guard canExport else { return }
        isExporting = true
        exportError = nil

        let dateStr = CSVBuilder.filenameDate()

        do {
            if includeEvents {
                let alarms = alarmManager.alarmHistory
                let csv    = try CSVBuilder.buildAlarmEvents(alarms)
                await MainActor.run {
                    _ = CSVBuilder.saveToFile(csv, suggestedName: "alarm_events_\(dateStr).csv")
                }
            }

            if includeJournal, let historian = dataService.historian {
                let journal = try await historian.loadAlarmJournal(forTag: nil, limit: 10_000)
                let csv     = try CSVBuilder.buildAlarmJournal(journal)
                await MainActor.run {
                    _ = CSVBuilder.saveToFile(csv, suggestedName: "alarm_journal_\(dateStr).csv")
                }
            }

            if includeWriteLog, let historian = dataService.historian {
                let log = try await historian.loadWriteLog(limit: 10_000)
                let csv = try CSVBuilder.buildWriteLog(log)
                await MainActor.run {
                    _ = CSVBuilder.saveToFile(csv, suggestedName: "write_audit_\(dateStr).csv")
                }
            }

            dismiss()
        } catch {
            exportError = error.localizedDescription
        }

        isExporting = false
    }
}
