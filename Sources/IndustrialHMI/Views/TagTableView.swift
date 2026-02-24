import SwiftUI

struct TagTableView: View {
    @EnvironmentObject var tagEngine: TagEngine
    @EnvironmentObject var opcuaService: OPCUAClientService
    @EnvironmentObject var alarmManager: AlarmManager

    @State private var searchText = ""
    @State private var selectedQuality: TagQuality? = nil
    @State private var sortOrder = [KeyPathComparator(\Tag.name)]
    @State private var alarmConfigTag: Tag? = nil
    @State private var showAlarmConfig = false

    var body: some View {
        let _ = { diagLog("DIAG [TagTableView] body evaluated — \(tagEngine.getAllTags().count) tags") }()
        VStack(spacing: 0) {
            // Header with filters and polling control
            HStack {
                TextField("Search tags...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)

                Spacer()

                Picker("Quality", selection: $selectedQuality) {
                    Text("All").tag(nil as TagQuality?)
                    Text("Good").tag(TagQuality.good as TagQuality?)
                    Text("Bad").tag(TagQuality.bad as TagQuality?)
                    Text("Uncertain").tag(TagQuality.uncertain as TagQuality?)
                }
                .pickerStyle(.segmented)
                .frame(width: 300)

                Divider()
                    .frame(height: 20)
                    .padding(.horizontal, 4)

                // Polling toggle button
                Button {
                    if opcuaService.isPolling {
                        opcuaService.pausePolling()
                    } else {
                        opcuaService.startPolling()
                    }
                } label: {
                    Label(
                        opcuaService.isPolling ? "Pause Polling" : "Resume Polling",
                        systemImage: opcuaService.isPolling ? "pause.circle.fill" : "play.circle.fill"
                    )
                }
                .buttonStyle(.bordered)
                .tint(opcuaService.isPolling ? .orange : .green)
                .disabled(opcuaService.connectionState != .connected)
            }
            .padding()

            Divider()

            // Tag table
            Table(filteredTags, sortOrder: $sortOrder) {
                TableColumn("Tag Name", value: \.name) { tag in
                    HStack {
                        Text(tag.name)
                            .font(.system(.body, design: .monospaced))
                        if alarmManager.alarmConfigs.contains(where: { $0.tagName == tag.name }) {
                            Image(systemName: "bell.fill")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    }
                    .contextMenu {
                        Button {
                            alarmConfigTag = tag
                            showAlarmConfig = true
                        } label: {
                            Label("Configure Alarm...", systemImage: "bell.badge")
                        }
                    }
                }

                TableColumn("Value") { tag in
                    Text(tag.formattedValue)
                        .font(.system(.body, design: .monospaced))
                        .bold()
                }
                .width(min: 120)

                TableColumn("Quality") { tag in
                    HStack {
                        Circle()
                            .fill(qualityColor(tag.quality))
                            .frame(width: 8, height: 8)
                        Text(tag.quality.description)
                            .font(.caption)
                    }
                }
                .width(min: 100)

                TableColumn("Timestamp") { tag in
                    Text(tag.timestamp, style: .time)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .width(min: 100)

                TableColumn("Description") { tag in
                    Text(tag.description ?? "—")
                        .foregroundColor(.secondary)
                }
            }
            .onChange(of: sortOrder) { _, _ in }
        }
        .navigationTitle("Tags (\(filteredTags.count))")
        .sheet(isPresented: $showAlarmConfig) {
            if let tag = alarmConfigTag {
                AlarmConfigSheet(tag: tag)
                    .environmentObject(alarmManager)
            }
        }
    }

    // MARK: - Computed Properties

    private var filteredTags: [Tag] {
        tagEngine.getAllTags()
            .filter { tag in
                let matchesSearch = searchText.isEmpty ||
                    tag.name.localizedCaseInsensitiveContains(searchText) ||
                    (tag.description?.localizedCaseInsensitiveContains(searchText) ?? false)
                let matchesQuality = selectedQuality == nil || tag.quality == selectedQuality
                return matchesSearch && matchesQuality
            }
    }

    private func qualityColor(_ quality: TagQuality) -> Color {
        switch quality {
        case .good: return .green
        case .bad: return .red
        case .uncertain: return .yellow
        }
    }
}

// MARK: - Alarm Config Sheet

private struct AlarmConfigSheet: View {
    @EnvironmentObject var alarmManager: AlarmManager
    @Environment(\.dismiss) var dismiss

    let tag: Tag

    @State private var highHigh: String = ""
    @State private var high: String = ""
    @State private var low: String = ""
    @State private var lowLow: String = ""
    @State private var deadband: String = "0.5"

    private var existingConfig: AlarmConfig? {
        alarmManager.alarmConfigs.first(where: { $0.tagName == tag.name })
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Alarm Configuration")
                        .font(.headline)
                    Text(tag.name)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .fontDesign(.monospaced)
                }
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // High limits
                    GroupBox {
                        VStack(spacing: 12) {
                            LimitRow(label: "High-High (Critical)", value: $highHigh,
                                     placeholder: "e.g. 95", color: .red)
                            LimitRow(label: "High (Warning)", value: $high,
                                     placeholder: "e.g. 80", color: .orange)
                        }
                    } label: {
                        Label("High Limits", systemImage: "arrow.up.circle.fill")
                            .foregroundColor(.red)
                    }

                    // Low limits
                    GroupBox {
                        VStack(spacing: 12) {
                            LimitRow(label: "Low (Warning)", value: $low,
                                     placeholder: "e.g. 20", color: .orange)
                            LimitRow(label: "Low-Low (Critical)", value: $lowLow,
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
                            Text("(hysteresis to prevent flapping)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } label: {
                        Label("Settings", systemImage: "slider.horizontal.3")
                    }

                    if existingConfig != nil {
                        Text("An alarm configuration already exists for this tag. Saving will replace it.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
            }

            Divider()

            // Buttons
            HStack {
                if existingConfig != nil {
                    Button(role: .destructive) {
                        if let config = existingConfig {
                            alarmManager.removeAlarmConfig(config)
                        }
                        dismiss()
                    } label: {
                        Label("Remove Alarm", systemImage: "trash")
                    }
                }

                Spacer()

                Button("Cancel") { dismiss() }

                Button("Save") {
                    saveConfig()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(width: 520, height: 480)
        .onAppear { prefillFromExisting() }
    }

    private var isValid: Bool {
        // At least one limit must be set
        !highHigh.isEmpty || !high.isEmpty || !low.isEmpty || !lowLow.isEmpty
    }

    private func prefillFromExisting() {
        guard let config = existingConfig else { return }
        highHigh = config.highHigh.map { String($0) } ?? ""
        high     = config.high.map     { String($0) } ?? ""
        low      = config.low.map      { String($0) } ?? ""
        lowLow   = config.lowLow.map   { String($0) } ?? ""
        deadband = String(config.deadband)
    }

    private func saveConfig() {
        // Remove existing if present
        if let config = existingConfig {
            alarmManager.removeAlarmConfig(config)
        }

        let newConfig = AlarmConfig(
            tagName:  tag.name,
            highHigh: Double(highHigh),
            high:     Double(high),
            low:      Double(low),
            lowLow:   Double(lowLow),
            deadband: Double(deadband) ?? 0.5
        )
        alarmManager.addAlarmConfig(newConfig)
    }
}

// MARK: - Limit Row

private struct LimitRow: View {
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
                .frame(width: 160, alignment: .leading)
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
