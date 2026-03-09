// MARK: - AlarmListView.swift
//
// Consolidated alarm management screen combining active alarms, shelved alarms,
// alarm history, and remote alarms from community federation peers.
//
// ── Layout ────────────────────────────────────────────────────────────────────
//   VStack:
//     headerBar      — filter chips (All/Active/Historical), severity filter,
//                      unack-only toggle, "Ack All" button, config + export buttons
//     alarmTable     — sortable Table<Alarm> with columns: severity icon, tag name,
//                      message, state badge, trigger time, acknowledged by
//     remoteAlarmsSection — shown only when communityService.remoteAlarms non-empty;
//                           compact list of alarms from federated peers
//
// ── Alarm Filter ──────────────────────────────────────────────────────────────
//   AlarmFilter: .all, .active, .historical
//   .all:       alarmManager.activeAlarms + alarmHistory combined, deduped by id
//   .active:    alarmManager.activeAlarms + alarmManager.shelvedAlarms
//   .historical: alarmManager.alarmHistory
//   selectedSeverity: further filters by AlarmSeverity (nil = show all severities)
//   showOnlyUnacknowledged: filters to state.requiresAction = true
//
// ── Alarm Table ───────────────────────────────────────────────────────────────
//   Sortable by trigger time (default: newest first), severity, state, tag name.
//   Row context menu: Acknowledge, Shelve (with duration picker), Unshelve, Details.
//   "Ack All" button: alarmManager.acknowledgeAllAlarms(by: username).
//   Role guard: acknowledge/shelve only shown for sessionManager.currentOperator.canAcknowledgeAlarms.
//
// ── Alarm Configuration Sheet ─────────────────────────────────────────────────
//   AlarmConfigSheet (configTag + showConfigSheet) — lets engineers add/edit alarm
//   thresholds for a specific tag. Accessed via the "Configure" button in the header
//   or tag row context menu.
//
// ── Remote Alarms ─────────────────────────────────────────────────────────────
//   communityService.remoteAlarms: [Alarm] — received from peer sites.
//   Shown in a separate section below the main table with a "Remote Site" badge.
//   Remote alarms cannot be acknowledged locally (read-only display).
//
// ── Export ────────────────────────────────────────────────────────────────────
//   AlarmExportSheet: date range + filter → CSV via CSVBuilder.alarmCSV().

import SwiftUI

// MARK: - Filter

private enum AlarmFilter: String, CaseIterable {
    case all        = "All"
    case active     = "Active"
    case historical = "Historical"
}

// MARK: - AlarmListView

struct AlarmListView: View {
    @EnvironmentObject var alarmManager:    AlarmManager
    @EnvironmentObject var tagEngine:       TagEngine
    @EnvironmentObject var sessionManager:  SessionManager
    @EnvironmentObject var dataService:     DataService
    @EnvironmentObject var communityService: CommunityService

    @State private var activeFilter: AlarmFilter  = .active
    @State private var selectedSeverity: AlarmSeverity? = nil
    @State private var showOnlyUnacknowledged = false
    @State private var sortOrder: [KeyPathComparator<Alarm>] = [
        KeyPathComparator(\.triggerTime, order: .reverse)
    ]
    @State private var showConfigSheet  = false
    @State private var configTag:  Tag? = nil
    @State private var showExportSheet  = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            alarmTable
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // ── Remote Alarms (Community Federation) ─────────────────────
            if !communityService.remoteAlarms.isEmpty {
                Divider()
                remoteAlarmsSection
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Alarms")
        .sheet(isPresented: $showConfigSheet) {
            if let tag = configTag {
                AlarmConfigSheet(tag: tag).environmentObject(alarmManager)
            }
        }
        .sheet(isPresented: $showExportSheet) {
            AlarmExportSheet()
                .environmentObject(alarmManager)
                .environmentObject(dataService)
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            // Filter: All / Active / Historical
            Picker("Filter", selection: $activeFilter) {
                ForEach(AlarmFilter.allCases, id: \.self) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)

            // Severity picker
            Picker("Severity", selection: $selectedSeverity) {
                Text("All Severities").tag(nil as AlarmSeverity?)
                ForEach(AlarmSeverity.allCases, id: \.self) { s in
                    Text(s.rawValue).tag(s as AlarmSeverity?)
                }
            }
            .frame(maxWidth: 160)

            Toggle("Unack Only", isOn: $showOnlyUnacknowledged)
                .toggleStyle(.switch)
                .disabled(activeFilter == .historical)

            Spacer()

            // Summary counts
            let stats = alarmManager.getStatistics()
            HStack(spacing: 12) {
                countBadge("Active",    stats.totalActive,   .red)
                countBadge("Unack",     stats.unacknowledged, .orange)
                countBadge("History",   stats.totalHistory,  .secondary)
            }

            Divider().frame(height: 20)

            Button("Acknowledge All") {
                alarmManager.acknowledgeAllAlarms(by: sessionManager.currentUsername)
                sessionManager.recordActivity()
            }
            .disabled(alarmManager.unacknowledgedCount == 0 || !sessionManager.canAcknowledge)

            Button("Clear History") {
                alarmManager.clearAlarmHistory()
            }

            Button {
                showExportSheet = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Export alarm history to CSV")
        }
        .padding(HMIStyle.spacingM)
    }

    // MARK: - Alarm Table

    @ViewBuilder
    private var alarmTable: some View {
        let alarms = filteredAlarms
        if alarms.isEmpty {
            ContentUnavailableView(
                activeFilter == .active ? "No Active Alarms" : "No Alarms",
                systemImage: activeFilter == .active ? "checkmark.circle" : "bell.slash",
                description: Text(activeFilter == .active
                    ? "All systems operating normally"
                    : "No alarm events recorded yet")
            )
        } else {
            Table(alarms, sortOrder: $sortOrder) {
                // Severity
                TableColumn("Severity", value: \.severity.rawValue) { alarm in
                    HStack(spacing: 5) {
                        Circle().fill(HMIStyle.severityColor(alarm.severity))
                            .frame(width: HMIStyle.qualityDotSize, height: HMIStyle.qualityDotSize)
                        Text(alarm.severity.rawValue)
                            .font(HMIStyle.fieldLabelFont.bold())
                            .foregroundColor(HMIStyle.severityColor(alarm.severity))
                            .lineLimit(1)
                    }
                }
                .width(min: 70, ideal: 90)

                // Tag
                TableColumn("Tag", value: \.tagName) { alarm in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(alarm.tagName)
                            .font(HMIStyle.tagNameFont)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        // Occurrence count badge
                        let count = occurrenceCount(alarm)
                        if count > 1 {
                            Text("\(count)× occurrences")
                                .font(HMIStyle.metaFont)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .width(min: 100, ideal: 150)

                // Message
                TableColumn("Message") { alarm in
                    Text(alarm.message)
                        .font(HMIStyle.fieldLabelFont)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .width(min: 130)

                // Value at trigger
                TableColumn("Value") { alarm in
                    if let v = alarm.value {
                        Text(String(format: "%.2f", v))
                            .font(HMIStyle.alarmValueFont)
                            .lineLimit(1)
                    } else {
                        Text("—").foregroundColor(.secondary).font(HMIStyle.fieldLabelFont)
                    }
                }
                .width(min: 55, ideal: 70)

                // Trigger time
                TableColumn("Triggered", value: \.triggerTime) { alarm in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(alarm.triggerTime, style: .time).font(HMIStyle.fieldLabelFont)
                        Text(alarm.triggerTime, format: .dateTime.month().day())
                            .font(HMIStyle.metaFont).foregroundColor(.secondary)
                    }
                }
                .width(min: 70, ideal: 90)

                // State
                TableColumn("State", value: \.state.rawValue) { alarm in
                    Text(alarm.state.rawValue)
                        .font(HMIStyle.fieldLabelFont.bold())
                        .foregroundColor(HMIStyle.alarmStateColor(alarm.state))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(HMIStyle.alarmStateColor(alarm.state).opacity(0.12))
                        .cornerRadius(4)
                }
                .width(min: 90, ideal: 110)

                // Acknowledged by
                TableColumn("Ack By") { alarm in
                    if let by = alarm.acknowledgedBy {
                        Text(by).font(HMIStyle.fieldLabelFont).foregroundColor(.secondary).lineLimit(1)
                    } else {
                        Text("—").font(HMIStyle.fieldLabelFont).foregroundColor(.secondary)
                    }
                }
                .width(min: 60, ideal: 80)

                // Action
                TableColumn("") { alarm in
                    if alarm.state.requiresAction && sessionManager.canAcknowledge {
                        Button("Ack") {
                            alarmManager.acknowledgeAlarm(alarm, by: sessionManager.currentUsername)
                            sessionManager.recordActivity()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(alarm.state == .unacknowledgedRTN ? .green : .orange)
                    }
                }
                .width(min: 44, ideal: 50)
            }
        }
    }

    // MARK: - Supporting Views

    private func countBadge(_ label: String, _ count: Int, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(count)").font(HMIStyle.statusLabelFont).foregroundColor(color)
            Text(label).font(HMIStyle.metaFont).foregroundColor(.secondary)
        }
    }

    // MARK: - Computed

    private var filteredAlarms: [Alarm] {
        // Source: active alarms + history merged, deduplicated by id
        var all: [Alarm]
        switch activeFilter {
        case .all:
            // merge active into history (active may have newer state)
            var seen = Set<UUID>()
            var merged = alarmManager.alarmHistory.filter { seen.insert($0.id).inserted }
            // overlay active alarm states on top
            for active in alarmManager.activeAlarms {
                if let idx = merged.firstIndex(where: { $0.id == active.id }) {
                    merged[idx] = active
                } else {
                    merged.append(active)
                }
            }
            all = merged
        case .active:
            all = alarmManager.activeAlarms
        case .historical:
            // history that is no longer active (returnToNormal / acknowledged+resolved)
            let activeIds = Set(alarmManager.activeAlarms.map { $0.id })
            all = alarmManager.alarmHistory.filter { !activeIds.contains($0.id) }
        }

        // Severity filter
        if let sev = selectedSeverity { all = all.filter { $0.severity == sev } }

        // Unack filter (only meaningful for active)
        if showOnlyUnacknowledged && activeFilter != .historical {
            all = all.filter { $0.state.requiresAction }
        }

        // Sort
        return all.sorted { a, b in
            for comparator in sortOrder {
                switch comparator.compare(a, b) {
                case .orderedAscending:  return true
                case .orderedDescending: return false
                case .orderedSame:       break
                }
            }
            return a.triggerTime > b.triggerTime
        }
    }

    /// How many times has this tag+severity combination appeared in history?
    private func occurrenceCount(_ alarm: Alarm) -> Int {
        alarmManager.alarmHistory.filter {
            $0.tagName == alarm.tagName && $0.severity == alarm.severity
        }.count
    }

    // MARK: - Remote Alarms Section

    private var remoteAlarmsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: HMIStyle.spacingXS) {
                Image(systemName: "network")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("REMOTE ALARMS (\(communityService.remoteAlarms.count))")
                    .font(HMIStyle.fieldLabelFont.bold())
                    .foregroundColor(.secondary)
                    .tracking(0.4)
                Spacer()
                Text("Read-only — ack on source instance")
                    .font(HMIStyle.metaFont)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, HMIStyle.spacingM)
            .padding(.vertical, HMIStyle.spacingXS)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(communityService.remoteAlarms) { alarm in
                        RemoteAlarmRow(alarm: alarm)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 180)
        }
    }
}

// MARK: - RemoteAlarmRow

private struct RemoteAlarmRow: View {
    let alarm: Alarm

    private var siteName: String {
        alarm.tagName.components(separatedBy: "/").first ?? "Remote"
    }
    private var localTagName: String {
        alarm.tagName.components(separatedBy: "/").dropFirst().joined(separator: "/")
    }

    var body: some View {
        HStack(spacing: HMIStyle.spacingS) {
            // Severity bar
            Rectangle()
                .fill(HMIStyle.severityColor(alarm.severity))
                .frame(width: 3)
                .frame(maxHeight: .infinity)

            // Site badge
            Text(siteName)
                .font(HMIStyle.metaFont.bold())
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.15))
                .cornerRadius(4)
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(localTagName)
                    .font(HMIStyle.tagNameFont)
                    .foregroundColor(.primary)
                Text(alarm.message)
                    .font(HMIStyle.metaFont)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(alarm.severity.rawValue)
                    .font(HMIStyle.metaFont.bold())
                    .foregroundColor(HMIStyle.severityColor(alarm.severity))
                Text(alarm.triggerTime, style: .relative)
                    .font(HMIStyle.metaFont)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, HMIStyle.spacingM)
        .padding(.vertical, HMIStyle.spacingXS)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
