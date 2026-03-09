// MARK: - MonitorView.swift
//
// The primary operational screen — combines live tag monitoring, alarm configuration,
// and OPC-UA address space browser in a single always-alive view.
//
// ── Layout ────────────────────────────────────────────────────────────────────
//   VStack:
//     statusToolbar — connection status + data collection Start/Stop + OPC-UA URL
//                     + mic toggle button (multimodal panel) + export actions
//     HSplitView:
//       Left  — tagTablePane (filterable, sortable tag table)
//       Right — rightPane (Tab-switched: Tag Detail | Alarm Limits | OPC Browser)
//
// ── Tag Table Pane ────────────────────────────────────────────────────────────
//   Sortable Table<Tag> with columns: name, value, unit, quality, dataType, nodeId.
//   searchText filters by tag name (case-insensitive contains).
//   selectedQuality filter limits to tags with the chosen quality level.
//   sortOrder: [KeyPathComparator] drives Table.init(sortOrder:) for client-side sort.
//   Selecting a tag sets selectedTagId → right panel shows Tag Detail.
//
// ── Right Panel ───────────────────────────────────────────────────────────────
//   .detail      — TagDetailView: name, description, value, quality badge, tag type,
//                  expression (if calculated), nodeId, last update time, alarm status.
//                  "View in Trends" button: sets trendTagNames/@AppStorage, switches tab.
//                  "Write Value" button: shows WriteValueSheet (engineer+ role only).
//   .alarmLimits — Alarm configuration for selected tag: inline AlarmConfigEditor.
//   .browser     — OPCUABrowserView (always instantiated in ZStack — avoids ViewModel reinit).
//
// ── Status Toolbar ────────────────────────────────────────────────────────────
//   Connection state icon (OPCUAClientService.connectionState).
//   "Start" / "Stop" buttons call dataService.startDataCollection() / stopDataCollection().
//   OPC-UA URL field (editable) bound to opcuaService.serverURL.
//   Simulation mode badge shown when dataService.simulationMode = true.
//
// ── "View in Trends" Integration ──────────────────────────────────────────────
//   trendTagNames: @AppStorage("trend.selectedTags") shared with TrendView.
//   trendFocusedTag: @AppStorage("trend.focusedTag") shared with TrendView.
//   Setting these + selectedTab = .trends causes TrendView to pre-select the tag.
//
// ── MonitorRightPanel ─────────────────────────────────────────────────────────
//   Private enum: .detail, .alarmLimits, .browser — controls rightPane content.
//   Segmented picker in the pane header lets the operator switch panels.

import SwiftUI

// MARK: - Right-panel mode

private enum MonitorRightPanel: String {
    case detail      = "Tag Detail"
    case alarmLimits = "Alarm Limits"
    case browser     = "OPC Browser"
}

// MARK: - MonitorView

/// Single screen combining system status, live tag table, alarm configuration,
/// and the OPC-UA address-space browser.
struct MonitorView: View {
    @EnvironmentObject var dataService:   DataService
    @EnvironmentObject var opcuaService:  OPCUAClientService
    @EnvironmentObject var tagEngine:     TagEngine
    @EnvironmentObject var alarmManager:  AlarmManager
    @EnvironmentObject var sessionManager: SessionManager

    /// Binding to MainView's tab — allows "View in Trends" to navigate directly.
    @Binding var selectedTab: Tab

    // Tag table state
    @State private var searchText:      String         = ""
    @State private var selectedQuality: TagQuality?    = nil
    @State private var sortOrder =      [KeyPathComparator(\Tag.name)]
    @State private var selectedTagId:   UUID?          = nil
    @State private var rightPanel:      MonitorRightPanel = .detail

    // Alarm config sheet (fallback modal for edge cases)
    @State private var alarmConfigTag:  Tag?           = nil
    @State private var showAlarmConfig: Bool           = false

    // Write value sheet
    @State private var showWriteSheet:  Bool           = false

    // "View in Trends" integration
    @AppStorage("trend.selectedTags")  private var trendTagNames:    String = ""
    @AppStorage("trend.focusedTag")    private var trendFocusedTag:  String = ""

    var body: some View {
        VStack(spacing: 0) {
            // ── Status toolbar ─────────────────────────────────────────────
            statusToolbar
            Divider()

            // ── Main split ────────────────────────────────────────────────
            // Left pane: always a full-height tag list.
            // Right pane: Tag Detail | Alarm Limits | OPC Browser.
            // OPCUABrowserView lives permanently in the ZStack so its
            // @StateObject ViewModel is never destroyed.
            HSplitView {
                tagTablePane
                    .frame(minWidth: 150)

                rightPane
                    .frame(minWidth: 200, maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showAlarmConfig) {
            if let tag = alarmConfigTag {
                AlarmConfigSheet(tag: tag).environmentObject(alarmManager)
            }
        }
        .sheet(isPresented: $showWriteSheet) {
            if let tag = selectedTag {
                WriteValueSheet(tag: tag, operatorName: sessionManager.currentUsername)
                    .environmentObject(dataService)
                    .environmentObject(tagEngine)
            }
        }
    }

    // MARK: - Status Toolbar

    private var statusToolbar: some View {
        HStack(spacing: HMIStyle.spacingM) {
            // ── Overall system status ──────────────────────────────────────
            HStack(spacing: 6) {
                Circle().fill(systemStatusColor).frame(width: 10, height: 10)
                Text(systemStatusLabel).font(HMIStyle.statusLabelFont)
            }

            // OPC-UA connection detail — only shown when data service is running
            // and OPC-UA is the active protocol (not disconnected/idle)
            if dataService.isRunning && opcuaService.connectionState != .disconnected {
                HStack(spacing: 4) {
                    Text("OPC-UA:").font(HMIStyle.statusMetaFont).foregroundColor(.secondary)
                    Circle().fill(connectionColor).frame(width: 7, height: 7)
                    Text(opcuaService.connectionState.rawValue)
                        .font(HMIStyle.statusMetaFont).foregroundColor(.secondary)
                }
            }

            Divider().frame(height: 20)

            // Tag statistics
            let ts = tagEngine.getStatistics()
            HStack(spacing: HMIStyle.spacingS) {
                miniStat("\(ts.totalTags)", "Tags",    .primary)
                miniStat("\(ts.goodTags)",  "Good",    HMIStyle.colorNormal)
                if ts.badTags      > 0 { miniStat("\(ts.badTags)",      "Bad",  HMIStyle.colorCritical) }
                if ts.uncertainTags > 0 { miniStat("\(ts.uncertainTags)", "Unc", HMIStyle.colorUncertain) }
            }

            Divider().frame(height: 20)

            // Alarm summary
            let as_ = alarmManager.getStatistics()
            if as_.totalActive > 0 {
                HStack(spacing: HMIStyle.spacingXS) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(as_.critical > 0 ? HMIStyle.colorCritical : HMIStyle.colorWarning)
                        .font(.callout)
                    Text("\(as_.totalActive) alarm\(as_.totalActive == 1 ? "" : "s")")
                        .font(HMIStyle.statusLabelFont)
                        .foregroundColor(as_.critical > 0 ? HMIStyle.colorCritical : HMIStyle.colorWarning)
                }
            } else {
                HStack(spacing: HMIStyle.spacingXS) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(HMIStyle.colorNormal).font(.callout)
                    Text("No Alarms").font(HMIStyle.statusLabelFont).foregroundColor(.secondary)
                }
            }

            Spacer()

            Text(Configuration.opcuaServerURL)
                .font(HMIStyle.statusMetaFont).foregroundColor(.secondary)

            // Polling toggle (OPC-UA live mode only)
            if !Configuration.simulationMode {
                Button {
                    opcuaService.isPolling ? opcuaService.pausePolling() : opcuaService.startPolling()
                } label: {
                    Label(opcuaService.isPolling ? "Pause" : "Poll",
                          systemImage: opcuaService.isPolling ? "pause.circle" : "play.circle")
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .tint(opcuaService.isPolling ? .orange : .green)
                .disabled(opcuaService.connectionState != .connected)
                .help(opcuaService.isPolling ? "Pause Polling" : "Resume Polling")
            }

            // Start / Stop
            if dataService.isRunning {
                Button(role: .destructive) {
                    Task { await dataService.stopDataCollection() }
                } label: {
                    Label("Stop", systemImage: "stop.circle.fill")
                }
                .tint(.red).buttonStyle(.bordered)
            } else {
                Button {
                    Task { await dataService.startDataCollection() }
                } label: {
                    Label("Start", systemImage: "play.circle.fill")
                }
                .tint(.green).buttonStyle(.borderedProminent)
                .disabled(opcuaService.connectionState == .connecting)
            }
        }
        .padding(.horizontal, HMIStyle.toolbarPaddingH)
        .padding(.vertical, HMIStyle.toolbarPaddingV)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func miniStat(_ value: String, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Text(value).font(HMIStyle.statusLabelFont).foregroundColor(color)
            Text(label).font(HMIStyle.statusMetaFont).foregroundColor(.secondary)
        }
    }

    // MARK: - Left Pane: Tag Table

    private var tagTablePane: some View {
        VStack(spacing: 0) {
            // Filter row
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.caption)
                TextField("Search tags…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Picker("Quality", selection: $selectedQuality) {
                    Text("All").tag(nil as TagQuality?)
                    Text("Good").tag(TagQuality.good as TagQuality?)
                    Text("Bad").tag(TagQuality.bad as TagQuality?)
                    Text("Unc").tag(TagQuality.uncertain as TagQuality?)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 180)

                Spacer(minLength: 0)

                Button {
                    if let csv = try? CSVBuilder.buildTagList(tagEngine.getAllTags()) {
                        CSVBuilder.saveToFile(csv,
                            suggestedName: "tags_\(CSVBuilder.filenameDate()).csv")
                    }
                } label: {
                    Label("Export Tags…", systemImage: "square.and.arrow.up.on.square")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Export all tags to CSV")
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Full-height table — fills all remaining vertical space
            Table(filteredTags, selection: $selectedTagId, sortOrder: $sortOrder) {
                TableColumn("Tag Name", value: \.name) { tag in
                    HStack(spacing: 4) {
                        Text(tag.name)
                            .font(HMIStyle.tagNameFont)
                            .lineLimit(1)
                        if alarmManager.alarmConfigs.contains(where: { $0.tagName == tag.name }) {
                            Image(systemName: "bell.fill").font(.caption2).foregroundColor(HMIStyle.colorWarning)
                        }
                    }
                    .contextMenu {
                        Button { alarmConfigTag = tag; showAlarmConfig = true } label: {
                            Label("Configure Alarm…", systemImage: "bell.badge")
                        }
                        Divider()
                        Button { addToTrends(tag.name) } label: {
                            Label("View in Trends", systemImage: "chart.xyaxis.line")
                        }
                        Divider()
                        Button(role: .destructive) { removeTag(tag) } label: {
                            Label("Remove Tag", systemImage: "trash")
                        }
                    }
                }

                TableColumn("Value") { tag in
                    Text(tag.formattedValue)
                        .font(HMIStyle.inlineValueFont)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .width(min: 70, ideal: 90)

                TableColumn("Quality") { tag in
                    HStack(spacing: 4) {
                        Circle().fill(HMIStyle.qualityColor(tag.quality))
                            .frame(width: HMIStyle.qualityDotSize, height: HMIStyle.qualityDotSize)
                        Text(tag.quality.description)
                            .font(HMIStyle.fieldLabelFont)
                            .foregroundColor(HMIStyle.qualityColor(tag.quality))
                            .lineLimit(1)
                    }
                }
                .width(min: 60, ideal: 80)

                TableColumn("Updated") { tag in
                    Text(tag.timestamp, style: .time)
                        .font(HMIStyle.metaFont).foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .width(min: 55, ideal: 70)
            }
            .onChange(of: sortOrder) { _, _ in }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Right Pane

    private var rightPane: some View {
        VStack(spacing: 0) {
            // Panel mode picker
            Picker("", selection: $rightPanel) {
                Text("Tag Detail").tag(MonitorRightPanel.detail)
                Text("Alarm Limits").tag(MonitorRightPanel.alarmLimits)
                Text("OPC Browser").tag(MonitorRightPanel.browser)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // All three panels live in a ZStack so OPCUABrowserView keeps
            // its @StateObject ViewModel across panel switches.
            ZStack {
                tagDetailPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(rightPanel == .detail ? 1 : 0)
                    .allowsHitTesting(rightPanel == .detail)

                InlineAlarmConfigPanel()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(rightPanel == .alarmLimits ? 1 : 0)
                    .allowsHitTesting(rightPanel == .alarmLimits)

                OPCUABrowserView(opcuaService: opcuaService,
                                 tagEngine:    tagEngine,
                                 alarmManager: alarmManager)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(rightPanel == .browser ? 1 : 0)
                    .allowsHitTesting(rightPanel == .browser)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Tag Detail Panel

    @ViewBuilder
    private var tagDetailPanel: some View {
        if let tag = selectedTag {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Header card
                    VStack(alignment: .leading, spacing: HMIStyle.spacingXS) {
                        Text(tag.name)
                            .font(.system(.title3, design: .monospaced).bold())
                            .lineLimit(2)
                        Text(tag.nodeId)
                            .font(HMIStyle.metaFont).foregroundColor(.secondary).lineLimit(1)
                    }
                    .padding(HMIStyle.spacingM)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .windowBackgroundColor))

                    Divider()

                    // Live values
                    VStack(alignment: .leading, spacing: HMIStyle.spacingL) {
                        valueRow("CURRENT VALUE",
                                 content: Text(tag.formattedValue)
                                    .font(HMIStyle.processValueFont))

                        HStack(spacing: 6) {
                            Circle().fill(HMIStyle.qualityColor(tag.quality))
                                .frame(width: HMIStyle.qualityDotSize, height: HMIStyle.qualityDotSize)
                            Text(tag.quality.description)
                                .font(HMIStyle.fieldLabelFont)
                                .foregroundColor(HMIStyle.qualityColor(tag.quality))
                        }

                        valueRow("LAST UPDATED",
                                 content: Text(tag.timestamp, style: .time).font(HMIStyle.fieldLabelFont))

                        if let desc = tag.description, !desc.isEmpty {
                            valueRow("DESCRIPTION",
                                     content: Text(desc).font(HMIStyle.fieldLabelFont))
                        }

                        // Digital tag: show editable on/off label fields
                        if tag.dataType == .digital {
                            DigitalLabelEditor(tagName: tag.name)
                        }

                        // Composite tag: show member list
                        if tag.dataType == .composite,
                           let members = tag.compositeMembers,
                           let aggregation = tag.compositeAggregation {
                            valueRow("COMPOSITE (\(aggregation.displayName.uppercased()))",
                                content: VStack(alignment: .leading, spacing: 2) {
                                    ForEach(members) { m in
                                        HStack(spacing: 6) {
                                            Text(m.alias.isEmpty ? m.tagName : m.alias)
                                                .font(HMIStyle.metaFont).foregroundColor(.secondary)
                                                .frame(width: 80, alignment: .leading)
                                            Text(m.tagName)
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundColor(.blue)
                                        }
                                    }
                                })
                        }

                        if let config = alarmManager.alarmConfigs.first(where: { $0.tagName == tag.name }) {
                            VStack(alignment: .leading, spacing: HMIStyle.spacingXS) {
                                HStack(spacing: 5) {
                                    Image(systemName: "bell.fill").font(.caption)
                                        .foregroundColor(HMIStyle.colorWarning)
                                    Text("ALARM LIMITS").font(.caption.bold())
                                        .foregroundColor(HMIStyle.colorWarning)
                                }
                                let fmt = { (v: Double) -> String in
                                    v.truncatingRemainder(dividingBy: 1) == 0
                                        ? String(Int(v)) : String(format: "%.4g", v)
                                }
                                if let hh = config.highHigh { alarmLimitRow("HH", fmt(hh), HMIStyle.colorCritical) }
                                if let h  = config.high     { alarmLimitRow("HI", fmt(h),  HMIStyle.colorWarning) }
                                if let l  = config.low      { alarmLimitRow("LO", fmt(l),  HMIStyle.colorWarning) }
                                if let ll = config.lowLow   { alarmLimitRow("LL", fmt(ll), HMIStyle.colorCritical) }
                            }
                        }
                    }
                    .padding(HMIStyle.spacingM)

                    Divider()

                    // Actions
                    VStack(spacing: 8) {
                        if sessionManager.canWrite && tag.dataType != .calculated
            && tag.dataType != .totalizer && tag.dataType != .composite {
                            Button {
                                showWriteSheet = true
                            } label: {
                                Label("Write Value…", systemImage: "pencil.line")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                        }

                        Button {
                            addToTrends(tag.name)
                            selectedTab = .trends
                        } label: {
                            Label("View in Trends", systemImage: "chart.xyaxis.line")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            alarmConfigTag = tag; showAlarmConfig = true
                        } label: {
                            Label("Configure Alarm…", systemImage: "bell.badge")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button(role: .destructive) {
                            removeTag(tag)
                        } label: {
                            Label("Remove Tag", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor))
                }
            }
        } else {
            ContentUnavailableView(
                "No Selection",
                systemImage: "tag",
                description: Text("Click a tag row to see details and actions")
            )
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func valueRow<C: View>(_ label: String, content: C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(HMIStyle.fieldLabelFont)
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)
            content
        }
    }

    private func alarmLimitRow(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: HMIStyle.spacingXS) {
            Text(label)
                .font(HMIStyle.metaFont).foregroundColor(.secondary)
                .frame(width: 28, alignment: .leading)
            Text(value)
                .font(HMIStyle.alarmValueFont)
                .foregroundColor(color)
        }
    }

    /// Adds `tagName` to the persisted monitored set and focuses it in TrendView.
    private func addToTrends(_ tagName: String) {
        var names = Set(trendTagNames.split(separator: ",").map(String.init).filter { !$0.isEmpty })
        names.insert(tagName)
        trendTagNames   = names.sorted().joined(separator: ",")
        trendFocusedTag = tagName
    }

    /// Remove a tag from the engine, historian, and OPC-UA poll list.
    private func removeTag(_ tag: Tag) {
        if selectedTagId == tag.id { selectedTagId = nil }
        opcuaService.unsubscribe(nodeId: tag.nodeId)
        tagEngine.removeTag(named: tag.name)
        // Also remove from trend selection if present
        var names = Set(trendTagNames.split(separator: ",").map(String.init).filter { !$0.isEmpty })
        names.remove(tag.name)
        trendTagNames = names.sorted().joined(separator: ",")
        if trendFocusedTag == tag.name { trendFocusedTag = "" }
    }

    private var selectedTag: Tag? {
        guard let id = selectedTagId else { return nil }
        return tagEngine.getAllTags().first { $0.id == id }
    }

    private var filteredTags: [Tag] {
        tagEngine.getAllTags().filter { tag in
            let s = searchText.isEmpty ||
                tag.name.localizedCaseInsensitiveContains(searchText) ||
                (tag.description?.localizedCaseInsensitiveContains(searchText) ?? false)
            let q = selectedQuality == nil || tag.quality == selectedQuality
            return s && q
        }
    }

    /// Overall system status — reflects data collection engine, not just OPC-UA.
    private var systemStatusColor: Color {
        if dataService.isRunning {
            return Configuration.simulationMode ? .blue : .green
        }
        return .gray
    }

    private var systemStatusLabel: String {
        if dataService.isRunning {
            return Configuration.simulationMode ? "Simulation" : "Running"
        }
        return "Stopped"
    }

    /// OPC-UA specific connection color (used in the secondary detail badge).
    private var connectionColor: Color {
        switch opcuaService.connectionState {
        case .connected: return .green; case .connecting: return .yellow
        case .disconnected: return .gray; case .error: return .red
        }
    }
}

// MARK: - DigitalLabelEditor
// Inline editor for a digital tag's custom on/off label strings.
// Changes are committed on Return or focus-loss; saved directly to TagEngine.tags.

private struct DigitalLabelEditor: View {
    @EnvironmentObject var tagEngine: TagEngine
    let tagName: String

    @State private var onText:  String = ""
    @State private var offText: String = ""

    private var tag: Tag? { tagEngine.tags[tagName] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("STATUS LABELS")
                .font(HMIStyle.fieldLabelFont)
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ON label").font(.caption2).foregroundColor(.secondary)
                    TextField("e.g. Running", text: $onText)
                        .textFieldStyle(.roundedBorder)
                        .font(HMIStyle.fieldLabelFont)
                        .onSubmit { commit() }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("OFF label").font(.caption2).foregroundColor(.secondary)
                    TextField("e.g. Stopped", text: $offText)
                        .textFieldStyle(.roundedBorder)
                        .font(HMIStyle.fieldLabelFont)
                        .onSubmit { commit() }
                }
            }
        }
        .onAppear  { load() }
        .onChange(of: tagName) { _, _ in load() }
    }

    private func load() {
        onText  = tag?.onLabel  ?? ""
        offText = tag?.offLabel ?? ""
    }

    private func commit() {
        guard var t = tagEngine.tags[tagName] else { return }
        t.onLabel  = onText.trimmingCharacters(in: .whitespaces).isEmpty
            ? nil : onText.trimmingCharacters(in: .whitespaces)
        t.offLabel = offText.trimmingCharacters(in: .whitespaces).isEmpty
            ? nil : offText.trimmingCharacters(in: .whitespaces)
        tagEngine.tags[tagName] = t
        if let h = tagEngine.historian {
            Task { try? await h.saveTagConfig(t) }
        }
    }
}

// MARK: - InlineAlarmConfigPanel
// Lets operators set Hi-Hi / High / Low / Lo-Lo limits directly in the tag row.
// Same concept as the old AlarmListView "Configurations" tab.

private struct InlineAlarmConfigPanel: View {
    @EnvironmentObject var tagEngine:    TagEngine
    @EnvironmentObject var alarmManager: AlarmManager

    var body: some View {
        let allTags = tagEngine.getAllTags()
        if allTags.isEmpty {
            ContentUnavailableView {
                Label("No Tags Available", systemImage: "tag.slash")
            } description: {
                Text("Start data collection or browse OPC nodes to load tags.")
            }
        } else {
            VStack(spacing: 0) {
                // Column header
                HStack(spacing: 6) {
                    Text("Tag")
                        .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
                    Group {
                        Text("HH").foregroundColor(HMIStyle.colorCritical)
                        Text("HI").foregroundColor(HMIStyle.colorWarning)
                        Text("LO").foregroundColor(HMIStyle.colorWarning)
                        Text("LL").foregroundColor(HMIStyle.colorCritical)
                    }
                    .frame(width: 72)
                    .multilineTextAlignment(.center)
                    Spacer().frame(width: 28)     // trash icon
                }
                .font(.caption.bold())
                .foregroundColor(.secondary)
                .padding(.horizontal, HMIStyle.spacingM)
                .padding(.vertical, HMIStyle.spacingS)
                .background(Color(nsColor: .controlBackgroundColor))

                Divider()

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(allTags) { tag in
                            InlineAlarmRow(tag: tag)
                                .padding(.horizontal, 14)
                            Divider()
                        }
                    }
                }

                Divider()

                Text("Type a value and press ⏎ to save.  Leave a field empty to disable that limit.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))
            }
        }
    }
}

// MARK: - InlineAlarmRow

private struct InlineAlarmRow: View {
    @EnvironmentObject var alarmManager: AlarmManager
    let tag: Tag

    @State private var hhText  = ""
    @State private var hText   = ""
    @State private var lText   = ""
    @State private var llText  = ""
    @State private var isDirty = false

    private var existingConfig: AlarmConfig? {
        alarmManager.alarmConfigs.first { $0.tagName == tag.name }
    }

    var body: some View {
        HStack(spacing: 6) {
            // Tag name + "alarm set" badge
            VStack(alignment: .leading, spacing: 1) {
                Text(tag.name)
                    .font(HMIStyle.tagNameFont)
                    .lineLimit(1)
                if existingConfig != nil {
                    Text("alarm set").font(HMIStyle.metaFont).foregroundColor(HMIStyle.colorNormal)
                }
            }
            .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)

            limitField("Hi-Hi", text: $hhText, color: .red)
            limitField("High",  text: $hText,  color: .orange)
            limitField("Low",   text: $lText,  color: .orange)
            limitField("Lo-Lo", text: $llText, color: .red)

            // Trash — clears config
            Button {
                if let cfg = existingConfig { alarmManager.removeAlarmConfig(cfg) }
                hhText = ""; hText = ""; lText = ""; llText = ""; isDirty = false
            } label: {
                Image(systemName: "trash")
                    .foregroundColor(existingConfig != nil ? .red : Color.secondary.opacity(0.35))
            }
            .buttonStyle(.plain)
            .disabled(existingConfig == nil)
            .frame(width: 22)
        }
        .padding(.vertical, HMIStyle.spacingXS)
        .onAppear   { loadValues() }
        .onDisappear { if isDirty { commitConfig() } }
    }

    @ViewBuilder
    private func limitField(_ placeholder: String, text: Binding<String>, color: Color) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.center)
            .frame(width: 72)
            .foregroundColor(text.wrappedValue.isEmpty ? .secondary : color)
            .onChange(of: text.wrappedValue) { _, _ in isDirty = true }
            .onSubmit { commitConfig(); isDirty = false }
    }

    private func loadValues() {
        guard let cfg = existingConfig else {
            hhText = ""; hText = ""; lText = ""; llText = ""; return
        }
        hhText = cfg.highHigh.map { fmt($0) } ?? ""
        hText  = cfg.high.map     { fmt($0) } ?? ""
        lText  = cfg.low.map      { fmt($0) } ?? ""
        llText = cfg.lowLow.map   { fmt($0) } ?? ""
    }

    private func commitConfig() {
        let hh = Double(hhText); let h  = Double(hText)
        let l  = Double(lText);  let ll = Double(llText)
        let deadband = existingConfig?.deadband ?? 0.5
        if let cfg = existingConfig { alarmManager.removeAlarmConfig(cfg) }
        if hh != nil || h != nil || l != nil || ll != nil {
            alarmManager.addAlarmConfig(AlarmConfig(
                tagName: tag.name, highHigh: hh, high: h, low: l, lowLow: ll, deadband: deadband))
        }
    }

    private func fmt(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(v)) : String(format: "%.4g", v)
    }
}

// MARK: - AlarmConfigSheet  (modal fallback, used from context-menu / detail panel)

struct AlarmConfigSheet: View {
    @EnvironmentObject var alarmManager: AlarmManager
    @Environment(\.dismiss) var dismiss

    let tag: Tag

    @State private var highHigh: String = ""
    @State private var high:     String = ""
    @State private var low:      String = ""
    @State private var lowLow:   String = ""
    @State private var deadband: String = "0.5"

    private var existingConfig: AlarmConfig? {
        alarmManager.alarmConfigs.first(where: { $0.tagName == tag.name })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Alarm Configuration").font(.headline)
                    Text(tag.name).font(.subheadline).foregroundColor(.secondary).fontDesign(.monospaced)
                }
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    GroupBox {
                        VStack(spacing: 12) {
                            limitRow("High-High (Critical)", $highHigh, "e.g. 95", .red)
                            limitRow("High (Warning)",       $high,     "e.g. 80", .orange)
                        }
                    } label: { Label("High Limits", systemImage: "arrow.up.circle.fill").foregroundColor(.red) }

                    GroupBox {
                        VStack(spacing: 12) {
                            limitRow("Low (Warning)",        $low,    "e.g. 20", .orange)
                            limitRow("Low-Low (Critical)",   $lowLow, "e.g. 5",  .red)
                        }
                    } label: { Label("Low Limits", systemImage: "arrow.down.circle.fill").foregroundColor(.blue) }

                    GroupBox {
                        HStack {
                            Text("Deadband").frame(width: 130, alignment: .leading)
                            TextField("0.5", text: $deadband).textFieldStyle(.roundedBorder).frame(maxWidth: 120)
                            Text("(prevents flapping)").font(.caption).foregroundColor(.secondary)
                        }
                    } label: { Label("Settings", systemImage: "slider.horizontal.3") }
                }
                .padding()
            }

            Divider()

            HStack {
                if existingConfig != nil {
                    Button(role: .destructive) {
                        if let c = existingConfig { alarmManager.removeAlarmConfig(c) }
                        dismiss()
                    } label: { Label("Remove Alarm", systemImage: "trash") }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save(); dismiss() }
                    .buttonStyle(.borderedProminent).disabled(!isValid)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(width: 520, height: 460)
        .onAppear { prefill() }
    }

    private var isValid: Bool { !highHigh.isEmpty || !high.isEmpty || !low.isEmpty || !lowLow.isEmpty }

    private func prefill() {
        guard let c = existingConfig else { return }
        highHigh = c.highHigh.map { String($0) } ?? ""
        high     = c.high.map     { String($0) } ?? ""
        low      = c.low.map      { String($0) } ?? ""
        lowLow   = c.lowLow.map   { String($0) } ?? ""
        deadband = String(c.deadband)
    }

    private func save() {
        if let c = existingConfig { alarmManager.removeAlarmConfig(c) }
        alarmManager.addAlarmConfig(AlarmConfig(
            tagName:  tag.name,
            highHigh: Double(highHigh), high: Double(high),
            low:      Double(low),      lowLow: Double(lowLow),
            deadband: Double(deadband) ?? 0.5
        ))
    }

    @ViewBuilder
    private func limitRow(_ label: String, _ binding: Binding<String>,
                          _ placeholder: String, _ color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).frame(width: 160, alignment: .leading)
            TextField(placeholder, text: binding).textFieldStyle(.roundedBorder).frame(maxWidth: 120)
            if !binding.wrappedValue.isEmpty {
                Button { binding.wrappedValue = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }.buttonStyle(.plain)
            }
            Spacer()
        }
    }
}
