import SwiftUI

// MARK: - Filter

private enum AlarmFilter: String, CaseIterable {
    case all        = "All"
    case active     = "Active"
    case historical = "Historical"
}

// MARK: - AlarmListView

struct AlarmListView: View {
    @EnvironmentObject var alarmManager: AlarmManager
    @EnvironmentObject var tagEngine: TagEngine

    @State private var activeFilter: AlarmFilter  = .active
    @State private var selectedSeverity: AlarmSeverity? = nil
    @State private var showOnlyUnacknowledged = false
    @State private var sortOrder: [KeyPathComparator<Alarm>] = [
        KeyPathComparator(\.triggerTime, order: .reverse)
    ]
    @State private var showConfigSheet = false
    @State private var configTag: Tag? = nil

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            alarmTable
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Alarms")
        .sheet(isPresented: $showConfigSheet) {
            if let tag = configTag {
                AlarmConfigSheet(tag: tag).environmentObject(alarmManager)
            }
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
                alarmManager.acknowledgeAllAlarms()
            }
            .disabled(alarmManager.unacknowledgedCount == 0)

            Button("Clear History") {
                alarmManager.clearAlarmHistory()
            }
        }
        .padding(10)
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
                        Circle().fill(severityColor(alarm.severity)).frame(width: 8, height: 8)
                        Text(alarm.severity.rawValue)
                            .font(.caption)
                            .foregroundColor(severityColor(alarm.severity))
                    }
                }
                .width(90)

                // Tag
                TableColumn("Tag", value: \.tagName) { alarm in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(alarm.tagName)
                            .font(.system(.caption, design: .monospaced))
                        // Occurrence count badge
                        let count = occurrenceCount(alarm)
                        if count > 1 {
                            Text("\(count)× occurrences")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .width(min: 120)

                // Message
                TableColumn("Message") { alarm in
                    Text(alarm.message).font(.caption).lineLimit(2)
                }
                .width(min: 180)

                // Value at trigger
                TableColumn("Value") { alarm in
                    if let v = alarm.value {
                        Text(String(format: "%.2f", v))
                            .font(.system(.caption, design: .monospaced))
                    } else {
                        Text("—").foregroundColor(.secondary).font(.caption)
                    }
                }
                .width(70)

                // Trigger time
                TableColumn("Triggered", value: \.triggerTime) { alarm in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(alarm.triggerTime, style: .time).font(.caption)
                        Text(alarm.triggerTime, format: .dateTime.month().day())
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
                .width(90)

                // State
                TableColumn("State", value: \.state.rawValue) { alarm in
                    Text(alarm.state.rawValue)
                        .font(.caption.bold())
                        .foregroundColor(stateColor(alarm.state))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(stateColor(alarm.state).opacity(0.12))
                        .cornerRadius(4)
                }
                .width(110)

                // Acknowledged by
                TableColumn("Ack By") { alarm in
                    if let by = alarm.acknowledgedBy {
                        Text(by).font(.caption).foregroundColor(.secondary)
                    } else {
                        Text("—").font(.caption).foregroundColor(.secondary)
                    }
                }
                .width(80)

                // Action
                TableColumn("") { alarm in
                    if alarm.state.requiresAction {
                        Button("Ack") { alarmManager.acknowledgeAlarm(alarm) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(alarm.state == .unacknowledgedRTN ? .green : .orange)
                    }
                }
                .width(50)
            }
        }
    }

    // MARK: - Supporting Views

    private func countBadge(_ label: String, _ count: Int, _ color: Color) -> some View {
        VStack(spacing: 1) {
            Text("\(count)").font(.caption.bold()).foregroundColor(color)
            Text(label).font(.caption2).foregroundColor(.secondary)
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

    // MARK: - Colours

    private func severityColor(_ s: AlarmSeverity) -> Color {
        switch s { case .critical: return .red; case .warning: return .orange; case .info: return .blue }
    }

    private func stateColor(_ s: AlarmState) -> Color {
        switch s {
        case .unacknowledgedActive: return .red
        case .acknowledgedActive:   return .yellow
        case .unacknowledgedRTN:    return .green
        case .normal:               return .secondary
        case .suppressed:           return .gray
        }
    }
}
