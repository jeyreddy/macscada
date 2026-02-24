import SwiftUI
import Charts

// MARK: - TrendView  (Stocks-app style)

struct TrendView: View {
    @EnvironmentObject var tagEngine:    TagEngine
    @EnvironmentObject var alarmManager: AlarmManager

    // Persisted state
    @AppStorage("trend.selectedTags")  private var persistedTagNames:  String = ""
    @AppStorage("trend.timeRange")     private var persistedTimeRange: String = TimeRange.last1Hour.rawValue
    @AppStorage("trend.focusedTag")    private var persistedFocusedTag: String = ""

    @State private var monitoredTags:  Set<String>                    = []
    @State private var focusedTagName: String?                        = nil
    @State private var timeRange:      TimeRange                      = .last1Hour
    @State private var historicalData: [String: [HistoricalDataPoint]] = [:]
    @State private var isLoading:      Bool                           = false
    @State private var lastRefresh:    Date?                          = nil
    @State private var chartStart:     Date                           = Date().addingTimeInterval(-3600)
    @State private var chartEnd:       Date                           = Date()
    @State private var searchText:     String                         = ""
    @State private var refreshTimer:   Timer?                         = nil

    var body: some View {
        HSplitView {
            // ── Left: monitored-tag list ────────────────────────────────
            tagListPanel
                .frame(minWidth: 200, idealWidth: 240)

            // ── Right: detail trend for focused tag ─────────────────────
            detailPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { setupOnAppear() }
        .onChange(of: tagEngine.tagCount)     { _, _ in syncMonitoredTags() }
        .onChange(of: persistedTagNames)      { _, _ in syncMonitoredTags() }
        .onChange(of: persistedFocusedTag)    { _, new in
            // "View in Trends" from MonitorView has updated the focus
            if !new.isEmpty && monitoredTags.contains(new) {
                focusedTagName = new
            }
        }
    }

    // MARK: - Left Panel (Stocks-style list)

    private var tagListPanel: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Monitored Tags")
                    .font(.headline)
                Spacer()
                let unack = unacknowledgedCount
                if unack > 0 {
                    Text("\(unack)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.red.opacity(0.85))
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.caption)
                TextField("Search…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)

            Divider()

            // Tag rows
            if monitoredTags.isEmpty {
                ContentUnavailableView {
                    Label("No Tags", systemImage: "chart.line.uptrend.xyaxis")
                } description: {
                    Text("Use the + button to add tags")
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredMonitoredTags, id: \.self) { name in
                            tagListRow(tagName: name)
                            Divider()
                        }
                    }
                }
            }

            Divider()

            // Add-tag picker
            addTagPicker
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Tag Row

    @ViewBuilder
    private func tagListRow(tagName: String) -> some View {
        let tag       = tagEngine.getTag(named: tagName)
        let state     = worstAlarmState(for: tagName)
        let rowColor  = alarmStateColor(state)
        let isSelected = focusedTagName == tagName
        let sparkData = (historicalData[tagName] ?? []).suffix(80)

        Button {
            focusedTagName      = tagName
            persistedFocusedTag = tagName
        } label: {
            HStack(spacing: 10) {
                // Alarm / status dot
                Circle()
                    .fill(rowColor)
                    .frame(width: 9, height: 9)

                // Name + description
                VStack(alignment: .leading, spacing: 2) {
                    Text(tagName)
                        .font(.system(.caption, design: .monospaced).bold())
                        .lineLimit(1)
                        .foregroundColor(.primary)
                    if let desc = tag?.description, !desc.isEmpty {
                        Text(desc)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                // Value + mini sparkline
                VStack(alignment: .trailing, spacing: 3) {
                    Text(tag?.formattedValue ?? "—")
                        .font(.system(.caption, design: .monospaced).bold())
                        .foregroundColor(rowColor)
                        .lineLimit(1)

                    if sparkData.count > 2 {
                        Chart {
                            ForEach(Array(sparkData)) { pt in
                                LineMark(
                                    x: .value("T", pt.timestamp),
                                    y: .value("V", pt.value)
                                )
                                .foregroundStyle(rowColor)
                                .lineStyle(StrokeStyle(lineWidth: 1.5))
                                .interpolationMethod(.catmullRom)
                            }
                        }
                        .chartXAxis(.hidden)
                        .chartYAxis(.hidden)
                        .frame(width: 64, height: 24)
                    } else {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.15))
                            .frame(width: 64, height: 24)
                            .overlay(Text("—").font(.caption2).foregroundColor(.secondary))
                    }
                }

                // Remove button
                Button {
                    removeTag(tagName)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Color.secondary.opacity(0.5))
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.12)
                    : (state != nil ? rowColor.opacity(0.07) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .overlay(
            Rectangle()
                .frame(width: 3)
                .foregroundColor(isSelected ? .accentColor : .clear),
            alignment: .leading
        )
    }

    // MARK: - Add-tag picker

    private var addTagPicker: some View {
        let available = tagEngine.getAllTags().filter { !monitoredTags.contains($0.name) }
        return Group {
            if available.isEmpty && !monitoredTags.isEmpty {
                Text("All available tags are monitored")
                    .font(.caption2).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(8)
            } else if !available.isEmpty {
                Menu {
                    ForEach(available, id: \.name) { tag in
                        Button {
                            addTag(tag.name)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(tag.name)
                                if let d = tag.description, !d.isEmpty {
                                    Text(d).foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                } label: {
                    Label("Add Tag…", systemImage: "plus.circle")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .menuStyle(.borderlessButton)
                .padding(8)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Right Panel (detail chart)

    private var detailPanel: some View {
        Group {
            if let name = focusedTagName, monitoredTags.contains(name) {
                tagDetailChart(tagName: name)
            } else if !monitoredTags.isEmpty {
                // Nothing focused yet — show the first one
                let first = monitoredTags.sorted().first!
                tagDetailChart(tagName: first)
                    .onAppear { focusedTagName = first }
            } else {
                ContentUnavailableView(
                    "No Tags Monitored",
                    systemImage: "chart.xyaxis.line",
                    description: Text("Add tags from the list on the left to see trends")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tagDetailChart(tagName: String) -> some View {
        let tag         = tagEngine.getTag(named: tagName)
        let data        = historicalData[tagName] ?? []
        let state       = worstAlarmState(for: tagName)
        let lineColor   = alarmStateColor(state)
        let alarmEvents = alarmEventsInRange(for: tagName)

        return VStack(spacing: 0) {
            // ── Toolbar ────────────────────────────────────────────────
            HStack(spacing: 12) {
                // Tag identity
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle().fill(lineColor).frame(width: 10, height: 10)
                        Text(tagName)
                            .font(.system(.headline, design: .monospaced))
                        if let u = tag?.unit, !u.isEmpty {
                            Text("(\(u))")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    if let d = tag?.description, !d.isEmpty {
                        Text(d).font(.caption).foregroundColor(.secondary)
                    }
                }

                Spacer()

                if let t = lastRefresh {
                    Text("Updated \(t, style: .relative) ago")
                        .font(.caption2).foregroundColor(.secondary)
                }

                Picker("Range", selection: $timeRange) {
                    ForEach(TimeRange.allCases) { r in Text(r.title).tag(r) }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 150)
                .onChange(of: timeRange) { _, _ in
                    persistedTimeRange = timeRange.rawValue
                    Task { await loadData() }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // ── Chart ─────────────────────────────────────────────────
            if isLoading && data.isEmpty {
                ProgressView("Loading historical data…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if data.isEmpty {
                ContentUnavailableView(
                    "No Data Yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Data will appear as values are recorded")
                )
            } else {
                let mid = midY(data)
                Chart {
                    // ── Area fill ──────────────────────────────────────
                    ForEach(data) { pt in
                        AreaMark(
                            x: .value("Time",  pt.timestamp),
                            y: .value("Value", pt.value)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [lineColor.opacity(0.22), lineColor.opacity(0.02)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.linear)
                    }

                    // ── Main line ──────────────────────────────────────
                    ForEach(data) { pt in
                        LineMark(
                            x: .value("Time",  pt.timestamp),
                            y: .value("Value", pt.value)
                        )
                        .foregroundStyle(lineColor)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.linear)
                    }

                    // ── Alarm markers at actual (time, value) ──────────
                    ForEach(alarmEvents) { alarm in
                        if let yVal = alarm.value {
                            // Dashed rule at the alarm time (X axis guide)
                            RuleMark(x: .value("Alarm", alarm.triggerTime))
                                .foregroundStyle(alarmSeverityColor(alarm.severity).opacity(0.25))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

                            // Horizontal reference at the alarm value (Y axis guide)
                            RuleMark(y: .value("Threshold", yVal))
                                .foregroundStyle(alarmSeverityColor(alarm.severity).opacity(0.12))
                                .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [2, 4]))

                            // Point at the exact (time, value) coordinate
                            PointMark(
                                x: .value("Time",  alarm.triggerTime),
                                y: .value("Value", yVal)
                            )
                            .foregroundStyle(alarmSeverityColor(alarm.severity))
                            .symbolSize(140)
                            .symbol(.circle)
                            .annotation(
                                position: yVal >= mid ? .bottom : .top,
                                alignment: .center,
                                spacing: 4
                            ) {
                                VStack(spacing: 1) {
                                    Text(alarm.severity.rawValue.prefix(4).uppercased())
                                        .font(.system(size: 8, weight: .black))
                                        .foregroundColor(alarmSeverityColor(alarm.severity))
                                    Text(fmtVal(yVal))
                                        .font(.system(size: 8, weight: .regular, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
                .chartXScale(domain: chartStart...chartEnd)
                .chartYScale(domain: yDomain(for: tagName))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        AxisTick()
                        AxisValueLabel(format: xAxisFormat)
                    }
                }
                .chartYAxis {
                    AxisMarks { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        AxisTick()
                        AxisValueLabel()
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            // ── Stats bar ─────────────────────────────────────────────
            statsBar(tagName: tagName, data: data)
        }
    }

    // MARK: - Stats Bar

    private func statsBar(tagName: String, data: [HistoricalDataPoint]) -> some View {
        let vals = data.map(\.value)
        let mn   = vals.min()
        let mx   = vals.max()
        let avg  = vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count)
        let last = vals.last
        let unackAlarms = alarmManager.activeAlarms.filter {
            $0.tagName == tagName && $0.state.requiresAction
        }

        return HStack(spacing: 20) {
            statChip("Min",  mn.map   { fmtVal($0) } ?? "—", .blue)
            statChip("Max",  mx.map   { fmtVal($0) } ?? "—", .red)
            statChip("Avg",  avg.map  { fmtVal($0) } ?? "—", .secondary)
            statChip("Last", last.map { fmtVal($0) } ?? "—", .primary)

            if !unackAlarms.isEmpty {
                Divider().frame(height: 20)
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red).font(.caption)
                    Text("\(unackAlarms.count) unack alarm\(unackAlarms.count == 1 ? "" : "s")")
                        .font(.caption.bold()).foregroundColor(.red)
                }
            }

            Spacer()
            Text("\(data.count) pts · \(timeRange.title)")
                .font(.caption2).foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func statChip(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(.caption, design: .monospaced).bold())
                .foregroundColor(color)
            Text(label)
                .font(.caption2).foregroundColor(.secondary)
        }
    }

    // MARK: - Data Loading

    private func loadData() async {
        guard !monitoredTags.isEmpty else { historicalData = [:]; return }
        isLoading = true
        let end = Date()
        let start = end.addingTimeInterval(-timeRange.seconds)
        chartStart = start
        chartEnd   = end
        historicalData = await tagEngine.getHistoricalData(
            for: Array(monitoredTags), from: start, to: end, maxPoints: 1000)
        lastRefresh = Date()
        isLoading   = false
    }

    private func startAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in
                if !self.monitoredTags.isEmpty { await self.loadData() }
            }
        }
    }

    // MARK: - Setup & Sync

    private func setupOnAppear() {
        timeRange = TimeRange(rawValue: persistedTimeRange) ?? .last1Hour
        syncMonitoredTags()
        let focused = persistedFocusedTag
        if !focused.isEmpty, monitoredTags.contains(focused) {
            focusedTagName = focused
        } else {
            focusedTagName = monitoredTags.sorted().first
        }
        if !monitoredTags.isEmpty { Task { await loadData() } }
        startAutoRefresh()
    }

    private func syncMonitoredTags() {
        let available = Set(tagEngine.getAllTags().map(\.name))
        let wanted    = Set(persistedTagNames.split(separator: ",").map(String.init))
        let synced    = wanted.intersection(available)
        if synced != monitoredTags {
            monitoredTags = synced
            // Keep focus valid
            if let f = focusedTagName, !synced.contains(f) {
                focusedTagName = synced.sorted().first
            }
        }
    }

    private func addTag(_ name: String) {
        monitoredTags.insert(name)
        persistedTagNames = monitoredTags.sorted().joined(separator: ",")
        if focusedTagName == nil { focusedTagName = name }
        Task { await loadData() }
    }

    private func removeTag(_ name: String) {
        monitoredTags.remove(name)
        historicalData.removeValue(forKey: name)
        persistedTagNames = monitoredTags.sorted().joined(separator: ",")
        if focusedTagName == name {
            focusedTagName = monitoredTags.sorted().first
        }
    }

    // MARK: - Computed Helpers

    private var filteredMonitoredTags: [String] {
        let sorted = monitoredTags.sorted()
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    private var unacknowledgedCount: Int {
        alarmManager.activeAlarms.filter {
            monitoredTags.contains($0.tagName) && $0.state.requiresAction
        }.count
    }

    private func alarmEventsInRange(for tagName: String) -> [Alarm] {
        alarmManager.alarmHistory.filter {
            $0.tagName == tagName &&
            $0.triggerTime >= chartStart &&
            $0.triggerTime <= chartEnd &&
            $0.value != nil
        }
    }

    private func worstAlarmState(for tagName: String) -> AlarmState? {
        let active = alarmManager.activeAlarms.filter { $0.tagName == tagName }
        if active.contains(where: { $0.state == .unacknowledgedActive }) { return .unacknowledgedActive }
        if active.contains(where: { $0.state == .acknowledgedActive   }) { return .acknowledgedActive   }
        if active.contains(where: { $0.state == .unacknowledgedRTN    }) { return .unacknowledgedRTN    }
        return nil
    }

    private func alarmStateColor(_ state: AlarmState?) -> Color {
        switch state {
        case .unacknowledgedActive: return .red
        case .acknowledgedActive:   return .orange
        case .unacknowledgedRTN:    return .green
        default:                    return .blue
        }
    }

    private func alarmSeverityColor(_ sev: AlarmSeverity) -> Color {
        switch sev {
        case .critical: return .red
        case .warning:  return .orange
        case .info:     return .blue
        }
    }

    private func yDomain(for tagName: String) -> ClosedRange<Double> {
        let vals = historicalData[tagName]?.map(\.value) ?? []
        guard !vals.isEmpty, let mn = vals.min(), let mx = vals.max() else { return 0...100 }
        if mn == mx { let p = abs(mn) * 0.1 + 1; return (mn - p)...(mx + p) }
        let pad = (mx - mn) * 0.15
        return (mn - pad)...(mx + pad)
    }

    private func midY(_ data: [HistoricalDataPoint]) -> Double {
        let vals = data.map(\.value)
        guard let mn = vals.min(), let mx = vals.max() else { return 0 }
        return (mn + mx) / 2
    }

    private func fmtVal(_ v: Double) -> String {
        if abs(v) >= 10000 { return String(format: "%.0f", v) }
        if abs(v) >= 100   { return String(format: "%.1f", v) }
        return String(format: "%.2f", v)
    }

    private var xAxisFormat: Date.FormatStyle {
        switch timeRange {
        case .last15Minutes, .last1Hour: return .dateTime.hour().minute().second()
        case .last4Hours, .last24Hours:  return .dateTime.hour().minute()
        case .last7Days:                 return .dateTime.month().day().hour()
        }
    }
}

// MARK: - TimeRange

enum TimeRange: String, CaseIterable, Identifiable {
    case last15Minutes = "15min"
    case last1Hour     = "1hour"
    case last4Hours    = "4hours"
    case last24Hours   = "24hours"
    case last7Days     = "7days"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .last15Minutes: return "15 Min"
        case .last1Hour:     return "1 Hour"
        case .last4Hours:    return "4 Hours"
        case .last24Hours:   return "24 Hours"
        case .last7Days:     return "7 Days"
        }
    }

    var seconds: TimeInterval {
        switch self {
        case .last15Minutes: return 15 * 60
        case .last1Hour:     return 60 * 60
        case .last4Hours:    return 4  * 60 * 60
        case .last24Hours:   return 24 * 60 * 60
        case .last7Days:     return 7  * 24 * 60 * 60
        }
    }
}
