// MARK: - AuditLogView.swift
//
// Compliance audit log viewer showing two Historian tables:
//   write_log     — every value write to a tag (who, when, old value, new value, status)
//   alarm_journal — every ISA-18.2 alarm state transition (who, when, from→to state)
//
// ── Purpose ───────────────────────────────────────────────────────────────────
//   Provides a searchable, filterable, exportable record of all operator actions
//   for regulatory compliance (FDA 21 CFR Part 11, ISA-18.2, IEC 62443).
//   Every write and alarm state change is recorded by Historian even if the
//   operator never opens this view.
//
// ── Layout ────────────────────────────────────────────────────────────────────
//   VStack:
//     segmentedPicker — "Write Log" | "Alarm Journal" (AuditPanel)
//     filterBar — tag name search field + status filter (all/success/failed)
//     Table<WriteLogEntry> or Table<AlarmJournalEntry> based on selectedPanel
//     exportButton — CSV export via CSVBuilder
//
// ── Write Log Table ───────────────────────────────────────────────────────────
//   Columns: timestamp (desc default), tag name, operator, old value, new value, status.
//   statusFilter: .all / .success / .failed — maps to WriteLogEntry.status == "success".
//   tagFilter: case-insensitive contains on tagName.
//   Loaded on .task via dataService.historian.loadWriteLog(limit: 500).
//
// ── Alarm Journal Table ───────────────────────────────────────────────────────
//   Columns: timestamp (desc default), tag name, changedBy, prevState→newState, reason.
//   tagFilter: case-insensitive contains on tagName.
//   Loaded on .task via dataService.historian.loadAlarmJournal(limit: 500).
//
// ── Export ────────────────────────────────────────────────────────────────────
//   CSVBuilder.writeLogCSV(entries:) → comma-separated with header row.
//   CSVBuilder.alarmJournalCSV(entries:) → comma-separated with header row.
//   NSSavePanel lets operator choose filename and location.

import SwiftUI

// MARK: - Local Enums

private enum AuditPanel: String, CaseIterable {
    case writeLog     = "Write Log"
    case alarmJournal = "Alarm Journal"
}

private enum WriteStatusFilter: String, CaseIterable {
    case all     = "All"
    case success = "Success"
    case failed  = "Failed"
}

// MARK: - AuditLogView

/// Compliance audit log viewer: shows the write_log and alarm_journal tables
/// with filtering and one-click CSV export (reusing CSVBuilder from Phase 10).
struct AuditLogView: View {
    @EnvironmentObject var dataService: DataService

    @State private var selectedPanel:  AuditPanel          = .writeLog
    @State private var writeEntries:   [WriteLogEntry]     = []
    @State private var journalEntries: [AlarmJournalEntry] = []
    @State private var isLoading:      Bool                = false
    @State private var tagFilter:      String              = ""
    @State private var statusFilter:   WriteStatusFilter   = .all

    @State private var writeSortOrder:   [KeyPathComparator<WriteLogEntry>]     = [
        KeyPathComparator(\.timestamp, order: .reverse)
    ]
    @State private var journalSortOrder: [KeyPathComparator<AlarmJournalEntry>] = [
        KeyPathComparator(\.timestamp, order: .reverse)
    ]

    // MARK: - Computed Filters

    private var filteredWriteEntries: [WriteLogEntry] {
        writeEntries.filter { entry in
            (tagFilter.isEmpty || entry.tagName.localizedCaseInsensitiveContains(tagFilter))
            && (statusFilter == .all
                || (statusFilter == .success && entry.status == "success")
                || (statusFilter == .failed  && entry.status != "success"))
        }
    }

    private var filteredJournalEntries: [AlarmJournalEntry] {
        journalEntries.filter { entry in
            tagFilter.isEmpty || entry.tagName.localizedCaseInsensitiveContains(tagFilter)
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            Group {
                switch selectedPanel {
                case .writeLog:    writeLogTable
                case .alarmJournal: alarmJournalTable
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Audit Log")
        .task { await loadData() }
        .onChange(of: selectedPanel) { _, _ in tagFilter = ""; statusFilter = .all }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 10) {
            Picker("Panel", selection: $selectedPanel) {
                ForEach(AuditPanel.allCases, id: \.self) { p in
                    Text(p.rawValue).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)

            TextField("Filter by tag…", text: $tagFilter)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)

            if selectedPanel == .writeLog {
                Picker("Status", selection: $statusFilter) {
                    ForEach(WriteStatusFilter.allCases, id: \.self) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .frame(maxWidth: 140)
            }

            Spacer()

            if isLoading { ProgressView().controlSize(.small) }

            Button {
                Task { await loadData() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                exportCSV()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(selectedPanel == .writeLog
                      ? filteredWriteEntries.isEmpty
                      : filteredJournalEntries.isEmpty)
        }
        .padding(10)
    }

    // MARK: - Write Log Table

    private var writeLogTable: some View {
        Group {
            if filteredWriteEntries.isEmpty && !isLoading {
                ContentUnavailableView(
                    "No Write Records",
                    systemImage: "pencil.slash",
                    description: Text("Tag write operations will appear here after operators write values.")
                )
            } else {
                Table(filteredWriteEntries, sortOrder: $writeSortOrder) {
                    TableColumn("Timestamp", value: \.timestamp) { entry in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.timestamp, style: .time).font(.caption)
                            Text(entry.timestamp, format: .dateTime.month().day().year())
                                .font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    .width(110)

                    TableColumn("Tag", value: \.tagName) { entry in
                        Text(entry.tagName)
                            .font(.system(.caption, design: .monospaced))
                    }
                    .width(min: 130)

                    TableColumn("Old Value") { entry in
                        Text(entry.oldValue.map { String(format: "%g", $0) } ?? "—")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .width(80)

                    TableColumn("New Value") { entry in
                        Text(entry.newValue.map { String(format: "%g", $0) } ?? "—")
                            .font(.system(.caption, design: .monospaced))
                    }
                    .width(80)

                    TableColumn("Requested By", value: \.requestedBy) { entry in
                        Text(entry.requestedBy).font(.caption)
                    }
                    .width(min: 100)

                    TableColumn("Status", value: \.status) { entry in
                        let isSuccess = entry.status == "success"
                        Text(isSuccess ? "Success" : "Failed")
                            .font(.caption.bold())
                            .foregroundColor(isSuccess ? .green : .red)
                    }
                    .width(70)
                }
            }
        }
    }

    // MARK: - Alarm Journal Table

    private var alarmJournalTable: some View {
        Group {
            if filteredJournalEntries.isEmpty && !isLoading {
                ContentUnavailableView(
                    "No Journal Entries",
                    systemImage: "list.clipboard",
                    description: Text("Alarm state transitions (acknowledge, RTN, shelve) will appear here.")
                )
            } else {
                Table(filteredJournalEntries, sortOrder: $journalSortOrder) {
                    TableColumn("Timestamp", value: \.timestamp) { entry in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.timestamp, style: .time).font(.caption)
                            Text(entry.timestamp, format: .dateTime.month().day().year())
                                .font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    .width(110)

                    TableColumn("Tag", value: \.tagName) { entry in
                        Text(entry.tagName)
                            .font(.system(.caption, design: .monospaced))
                    }
                    .width(min: 130)

                    TableColumn("From State") { entry in
                        Text(entry.prevState.rawValue)
                            .font(.caption)
                            .foregroundColor(stateColor(entry.prevState))
                    }
                    .width(min: 110)

                    TableColumn("To State") { entry in
                        Text(entry.newState.rawValue)
                            .font(.caption.bold())
                            .foregroundColor(stateColor(entry.newState))
                    }
                    .width(min: 110)

                    TableColumn("Changed By", value: \.changedBy) { entry in
                        Text(entry.changedBy).font(.caption)
                    }
                    .width(min: 100)

                    TableColumn("Reason") { entry in
                        Text(entry.reason ?? "—")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    .width(min: 80)
                }
            }
        }
    }

    // MARK: - Data Loading

    private func loadData() async {
        isLoading = true
        if let h = dataService.historian {
            writeEntries   = (try? await h.loadWriteLog(limit: 500))              ?? []
            journalEntries = (try? await h.loadAlarmJournal(forTag: nil, limit: 500)) ?? []
        }
        isLoading = false
    }

    // MARK: - Export

    private func exportCSV() {
        let dateStr = CSVBuilder.filenameDate()
        switch selectedPanel {
        case .writeLog:
            guard let csv = try? CSVBuilder.buildWriteLog(filteredWriteEntries) else { return }
            _ = CSVBuilder.saveToFile(csv, suggestedName: "write_log_\(dateStr).csv")
        case .alarmJournal:
            guard let csv = try? CSVBuilder.buildAlarmJournal(filteredJournalEntries) else { return }
            _ = CSVBuilder.saveToFile(csv, suggestedName: "alarm_journal_\(dateStr).csv")
        }
    }

    // MARK: - Colours

    private func stateColor(_ state: AlarmState) -> Color {
        switch state {
        case .unacknowledgedActive: return .red
        case .acknowledgedActive:   return .yellow
        case .unacknowledgedRTN:    return .green
        case .normal:               return .secondary
        case .suppressed:           return .gray
        case .shelved:              return .purple
        case .outOfService:         return .gray
        }
    }
}
