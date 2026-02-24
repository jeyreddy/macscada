import SwiftUI

// MARK: - Section Enum

private enum AlarmSection: String, CaseIterable {
    case active         = "Active Alarms"
    case configurations = "Configurations"
}

// MARK: - AlarmListView

struct AlarmListView: View {
    @EnvironmentObject var alarmManager: AlarmManager
    @EnvironmentObject var tagEngine: TagEngine

    @State private var activeSection: AlarmSection = .active
    @State private var selectedSeverity: AlarmSeverity? = nil
    @State private var showOnlyUnacknowledged = false
    @State private var showAddSheet = false
    @State private var editingConfig: AlarmConfig? = nil

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ────────────────────────────────────────────────────
            HStack(spacing: 12) {
                // Section picker
                Picker("Section", selection: $activeSection) {
                    ForEach(AlarmSection.allCases, id: \.self) { section in
                        Text(sectionLabel(section)).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)

                if activeSection == .active {
                    Toggle("Unack Only", isOn: $showOnlyUnacknowledged)
                        .toggleStyle(.switch)

                    Picker("Severity", selection: $selectedSeverity) {
                        Text("All").tag(nil as AlarmSeverity?)
                        ForEach(AlarmSeverity.allCases, id: \.self) { s in
                            Text(s.rawValue).tag(s as AlarmSeverity?)
                        }
                    }
                    .frame(maxWidth: 160)
                }

                Spacer()

                if activeSection == .active {
                    Button("Acknowledge All") {
                        alarmManager.acknowledgeAllAlarms()
                    }
                    .disabled(alarmManager.unacknowledgedCount == 0)

                    Button("Clear History") {
                        alarmManager.clearAlarmHistory()
                    }
                } else {
                    Button {
                        editingConfig = nil
                        showAddSheet = true
                    } label: {
                        Label("Add Alarm", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()

            Divider()

            // ── Content ───────────────────────────────────────────────────
            switch activeSection {
            case .active:
                activeAlarmsContent
            case .configurations:
                configurationsContent
            }
        }
        .navigationTitle("Alarms")
        .sheet(isPresented: $showAddSheet) {
            AddAlarmSheet(editingConfig: editingConfig)
                .environmentObject(alarmManager)
                .environmentObject(tagEngine)
        }
    }

    // MARK: - Active Alarms

    @ViewBuilder
    private var activeAlarmsContent: some View {
        if filteredAlarms.isEmpty {
            ContentUnavailableView(
                "No Alarms",
                systemImage: "checkmark.circle",
                description: Text("All systems operating normally")
            )
        } else {
            List(filteredAlarms) { alarm in
                AlarmRow(alarm: alarm)
                    .contextMenu {
                        Button("Acknowledge") {
                            alarmManager.acknowledgeAlarm(alarm)
                        }
                        .disabled(alarm.state != .active)
                    }
            }
        }
    }

    private var filteredAlarms: [Alarm] {
        alarmManager.activeAlarms
            .filter { alarm in
                let matchesSeverity = selectedSeverity == nil || alarm.severity == selectedSeverity
                let matchesAck      = !showOnlyUnacknowledged || alarm.state == .active
                return matchesSeverity && matchesAck
            }
            .sorted { $0.triggerTime > $1.triggerTime }
    }

    // MARK: - Configurations

    @ViewBuilder
    private var configurationsContent: some View {
        if alarmManager.alarmConfigs.isEmpty {
            ContentUnavailableView {
                Label("No Alarm Configurations", systemImage: "bell.slash")
            } description: {
                Text("Add limit thresholds for any tag.\nAlarms fire automatically when a tag value crosses a limit.")
            } actions: {
                Button {
                    editingConfig = nil
                    showAddSheet = true
                } label: {
                    Label("Add Alarm Configuration", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            List {
                ForEach(alarmManager.alarmConfigs) { config in
                    AlarmConfigRow(config: config) {
                        editingConfig = config
                        showAddSheet = true
                    } onDelete: {
                        alarmManager.removeAlarmConfig(config)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func sectionLabel(_ section: AlarmSection) -> String {
        switch section {
        case .active:
            let count = alarmManager.activeAlarms.count
            return count > 0 ? "Active (\(count))" : "Active Alarms"
        case .configurations:
            let count = alarmManager.alarmConfigs.count
            return count > 0 ? "Configs (\(count))" : "Configurations"
        }
    }
}

// MARK: - Alarm Config Row

private struct AlarmConfigRow: View {
    let config: AlarmConfig
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Tag name
            VStack(alignment: .leading, spacing: 4) {
                Text(config.tagName)
                    .font(.system(.body, design: .monospaced))
                    .bold()

                // Limit summary
                HStack(spacing: 10) {
                    if let hh = config.highHigh {
                        limitBadge("HH: \(formatted(hh))", color: .red)
                    }
                    if let h = config.high {
                        limitBadge("H: \(formatted(h))", color: .orange)
                    }
                    if let l = config.low {
                        limitBadge("L: \(formatted(l))", color: .orange)
                    }
                    if let ll = config.lowLow {
                        limitBadge("LL: \(formatted(ll))", color: .red)
                    }
                }
                Text("Deadband: \(formatted(config.deadband))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Edit button
            Button("Edit") { onEdit() }
                .buttonStyle(.bordered)
                .controlSize(.small)

            // Delete button
            Button(role: .destructive) { onDelete() } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.red)
        }
        .padding(.vertical, 4)
    }

    private func limitBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(4)
    }

    private func formatted(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(v))
            : String(format: "%.2f", v)
    }
}

// MARK: - Add / Edit Alarm Sheet

private struct AddAlarmSheet: View {
    @EnvironmentObject var alarmManager: AlarmManager
    @EnvironmentObject var tagEngine: TagEngine
    @Environment(\.dismiss) var dismiss

    var editingConfig: AlarmConfig?   // nil → new config

    @State private var selectedTag: String = ""
    @State private var highHigh = ""
    @State private var high     = ""
    @State private var low      = ""
    @State private var lowLow   = ""
    @State private var deadband = "0.5"

    private var isEditing: Bool { editingConfig != nil }
    private var tagNames: [String] { tagEngine.getAllTags().map { $0.name } }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isEditing ? "Edit Alarm Configuration" : "Add Alarm Configuration")
                        .font(.headline)
                    if isEditing {
                        Text(editingConfig!.tagName)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .fontDesign(.monospaced)
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // Tag selector (only when adding new)
                    if !isEditing {
                        GroupBox {
                            HStack {
                                Text("Tag")
                                    .frame(width: 130, alignment: .leading)
                                if tagNames.isEmpty {
                                    Text("No tags loaded")
                                        .foregroundColor(.secondary)
                                } else {
                                    Picker("", selection: $selectedTag) {
                                        Text("— Select a tag —").tag("")
                                        ForEach(tagNames, id: \.self) { name in
                                            Text(name).tag(name)
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                            }
                        } label: {
                            Label("Tag", systemImage: "tag")
                        }
                    }

                    // High limits
                    GroupBox {
                        VStack(spacing: 12) {
                            AlarmLimitRow(label: "High-High (Critical)", value: $highHigh,
                                          placeholder: "e.g. 95", color: .red)
                            AlarmLimitRow(label: "High (Warning)", value: $high,
                                          placeholder: "e.g. 80", color: .orange)
                        }
                    } label: {
                        Label("High Limits", systemImage: "arrow.up.circle.fill")
                            .foregroundColor(.red)
                    }

                    // Low limits
                    GroupBox {
                        VStack(spacing: 12) {
                            AlarmLimitRow(label: "Low (Warning)", value: $low,
                                          placeholder: "e.g. 20", color: .orange)
                            AlarmLimitRow(label: "Low-Low (Critical)", value: $lowLow,
                                          placeholder: "e.g. 5", color: .red)
                        }
                    } label: {
                        Label("Low Limits", systemImage: "arrow.down.circle.fill")
                            .foregroundColor(.blue)
                    }

                    // Deadband
                    GroupBox {
                        HStack {
                            Text("Deadband")
                                .frame(width: 130, alignment: .leading)
                            TextField("0.5", text: $deadband)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 120)
                            Text("(prevents repeated alarm flapping)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } label: {
                        Label("Hysteresis", systemImage: "slider.horizontal.3")
                    }

                    // Helper text
                    Text("Set at least one limit. Leave a field empty to disable that level.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
            }

            Divider()

            // Action buttons
            HStack {
                if isEditing {
                    Button(role: .destructive) {
                        if let cfg = editingConfig {
                            alarmManager.removeAlarmConfig(cfg)
                        }
                        dismiss()
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    saveConfig()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(width: 540, height: 520)
        .onAppear { prefill() }
    }

    private var canSave: Bool {
        let tagOK = isEditing || !selectedTag.isEmpty
        let hasLimit = !highHigh.isEmpty || !high.isEmpty || !low.isEmpty || !lowLow.isEmpty
        return tagOK && hasLimit
    }

    private func prefill() {
        guard let cfg = editingConfig else {
            // Pre-select first tag if available
            if let first = tagNames.first { selectedTag = first }
            return
        }
        selectedTag = cfg.tagName
        highHigh    = cfg.highHigh.map { formatDouble($0) } ?? ""
        high        = cfg.high.map     { formatDouble($0) } ?? ""
        low         = cfg.low.map      { formatDouble($0) } ?? ""
        lowLow      = cfg.lowLow.map   { formatDouble($0) } ?? ""
        deadband    = formatDouble(cfg.deadband)
    }

    private func saveConfig() {
        // Remove existing (either editing or previous config for same tag)
        if let existing = editingConfig {
            alarmManager.removeAlarmConfig(existing)
        } else {
            // Remove any existing config for the chosen tag
            if let prev = alarmManager.alarmConfigs.first(where: { $0.tagName == selectedTag }) {
                alarmManager.removeAlarmConfig(prev)
            }
        }

        let tagName = isEditing ? (editingConfig?.tagName ?? selectedTag) : selectedTag
        let newConfig = AlarmConfig(
            tagName:  tagName,
            highHigh: Double(highHigh),
            high:     Double(high),
            low:      Double(low),
            lowLow:   Double(lowLow),
            deadband: Double(deadband) ?? 0.5
        )
        alarmManager.addAlarmConfig(newConfig)
    }

    private func formatDouble(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(v)) : String(format: "%.4g", v)
    }
}

// MARK: - Alarm Limit Row (reusable field + clear button)

private struct AlarmLimitRow: View {
    let label: String
    @Binding var value: String
    let placeholder: String
    let color: Color

    var body: some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .frame(width: 170, alignment: .leading)
            TextField(placeholder, text: $value)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 120)
            if !value.isEmpty {
                Button {
                    value = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}

// MARK: - Alarm Row

struct AlarmRow: View {
    @EnvironmentObject var alarmManager: AlarmManager
    let alarm: Alarm

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 4)
                .fill(severityColor)
                .frame(width: 6)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(alarm.tagName)
                        .font(.system(.body, design: .monospaced))
                        .bold()
                    Spacer()
                    Text(alarm.severity.rawValue.uppercased())
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(severityColor.opacity(0.2))
                        .foregroundColor(severityColor)
                        .cornerRadius(4)
                }

                Text(alarm.message)
                    .font(.body)

                HStack(spacing: 16) {
                    Text(alarm.triggerTime, style: .relative)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let value = alarm.value {
                        Text("Value: \(String(format: "%.2f", value))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Text(alarm.state.rawValue)
                        .font(.caption)
                        .foregroundColor(stateColor)
                    if alarm.state == .acknowledged, let by = alarm.acknowledgedBy {
                        Text("by \(by)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            if alarm.state == .active {
                Button {
                    alarmManager.acknowledgeAlarm(alarm)
                } label: {
                    Image(systemName: "checkmark.circle")
                        .font(.title3)
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
                .help("Acknowledge alarm")
            }
        }
        .padding(.vertical, 8)
    }

    private var severityColor: Color {
        switch alarm.severity {
        case .critical: return .red
        case .warning:  return .orange
        case .info:     return .blue
        }
    }

    private var stateColor: Color {
        switch alarm.state {
        case .active:          return .red
        case .acknowledged:    return .yellow
        case .returnToNormal:  return .green
        case .suppressed:      return .gray
        }
    }
}
