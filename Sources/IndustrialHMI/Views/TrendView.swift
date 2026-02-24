import SwiftUI
import Charts

struct TrendView: View {
    @EnvironmentObject var tagEngine: TagEngine

    @State private var selectedTags: Set<String> = []
    @State private var timeRange: TimeRange = .last1Hour
    @State private var historicalData: [String: [HistoricalDataPoint]] = [:]
    @State private var isLoading = false
    @State private var refreshTimer: Timer?
    @State private var lastRefreshTime: Date? = nil

    // Colors for multi-tag display (cycles if more than 6 tags)
    private let tagColors: [Color] = [.blue, .green, .orange, .red, .purple, .teal]

    var body: some View {
        HSplitView {
            // Left sidebar: tag selection + time range
            VStack(alignment: .leading, spacing: 0) {
                Text("Select Tags")
                    .font(.headline)
                    .padding([.horizontal, .top])
                    .padding(.bottom, 8)

                List(tagEngine.getAllTags(), id: \.name, selection: $selectedTags) { tag in
                    HStack {
                        // Color swatch if selected
                        let sortedSelected = selectedTags.sorted()
                        let idx = sortedSelected.firstIndex(of: tag.name) ?? 0
                        RoundedRectangle(cornerRadius: 2)
                            .fill(selectedTags.contains(tag.name)
                                  ? tagColors[idx % tagColors.count]
                                  : Color.clear)
                            .frame(width: 12, height: 12)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tag.name)
                                .font(.caption)
                            if let desc = tag.description, !desc.isEmpty {
                                Text(desc)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        if let unit = tag.unit, !unit.isEmpty {
                            Text(unit)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .tag(tag.name)
                }
                .listStyle(.bordered)
                .onChange(of: selectedTags) { _, _ in
                    Task { await loadData() }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Time Range")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 8)

                    Picker("", selection: $timeRange) {
                        ForEach(TimeRange.allCases) { range in
                            Text(range.title).tag(range)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: timeRange) { _, _ in
                        Task { await loadData() }
                    }

                    Button("Clear Selection") {
                        selectedTags.removeAll()
                        historicalData = [:]
                    }
                    .disabled(selectedTags.isEmpty)
                    .padding(.bottom, 8)
                }
                .padding(.horizontal)
            }
            .frame(minWidth: 200, idealWidth: 240)

            // Right: chart area
            VStack(spacing: 0) {
                if selectedTags.isEmpty {
                    ContentUnavailableView(
                        "No Tags Selected",
                        systemImage: "chart.xyaxis.line",
                        description: Text("Select one or more tags from the sidebar to display trends")
                    )
                } else if isLoading && historicalData.isEmpty {
                    ProgressView("Loading historical data...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    chartContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Trends")
        .onAppear {
            if !selectedTags.isEmpty {
                Task { await loadData() }
            }
            startAutoRefresh()
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    // MARK: - Chart

    @ViewBuilder
    private var chartContent: some View {
        let hasData = historicalData.values.contains { !$0.isEmpty }

        if !hasData {
            ContentUnavailableView(
                "No Data Available",
                systemImage: "clock.arrow.circlepath",
                description: Text("Data is recorded to the historian as tag values arrive.\nWait a moment then the chart will populate automatically.")
            )
        } else {
            VStack(alignment: .leading, spacing: 0) {
                // Legend + stats bar
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 20) {
                        ForEach(selectedTags.sorted(), id: \.self) { tagName in
                            let sortedSelected = selectedTags.sorted()
                            let idx = sortedSelected.firstIndex(of: tagName) ?? 0
                            let color = tagColors[idx % tagColors.count]
                            let points = historicalData[tagName] ?? []
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(color)
                                    .frame(width: 24, height: 3)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(tagName)
                                        .font(.caption.bold())
                                    if let last = points.last {
                                        Text(String(format: "%.2f", last.value))
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    } else {
                                        Text("—")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                        Spacer()
                        if let refreshed = lastRefreshTime {
                            Text("Updated \(refreshed, style: .relative) ago")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .background(Color(nsColor: .controlBackgroundColor))

                Divider()

                // The chart
                Chart {
                    ForEach(selectedTags.sorted(), id: \.self) { tagName in
                        let sortedSelected = selectedTags.sorted()
                        let idx = sortedSelected.firstIndex(of: tagName) ?? 0
                        let color = tagColors[idx % tagColors.count]
                        ForEach(historicalData[tagName] ?? []) { point in
                            LineMark(
                                x: .value("Time", point.timestamp),
                                y: .value("Value", point.value)
                            )
                            .foregroundStyle(color)
                            .interpolationMethod(.linear)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                        }
                    }
                }
                .chartYScale(domain: yDomain)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel(format: xAxisFormat)
                    }
                }
                .chartYAxis {
                    AxisMarks { _ in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel()
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // Compute Y domain from actual data so the chart zooms to fit,
    // rather than showing a flat line at the bottom of a 0–100 axis.
    private var yDomain: ClosedRange<Double> {
        let allValues = historicalData.values.flatMap { $0.map { $0.value } }
        guard !allValues.isEmpty,
              let minVal = allValues.min(),
              let maxVal = allValues.max() else {
            return 0...100
        }
        if minVal == maxVal {
            let pad = abs(minVal) * 0.1 + 1
            return (minVal - pad)...(maxVal + pad)
        }
        let padding = (maxVal - minVal) * 0.15
        return (minVal - padding)...(maxVal + padding)
    }

    private var xAxisFormat: Date.FormatStyle {
        switch timeRange {
        case .last15Minutes, .last1Hour:
            return .dateTime.hour().minute().second()
        case .last4Hours, .last24Hours:
            return .dateTime.hour().minute()
        case .last7Days:
            return .dateTime.month().day().hour()
        }
    }

    // MARK: - Data Loading

    private func loadData() async {
        guard !selectedTags.isEmpty else {
            historicalData = [:]
            return
        }
        isLoading = true
        let endTime = Date()
        let startTime = endTime.addingTimeInterval(-timeRange.seconds)
        historicalData = await tagEngine.getHistoricalData(
            for: Array(selectedTags),
            from: startTime,
            to: endTime,
            maxPoints: 1000
        )
        lastRefreshTime = Date()
        isLoading = false
    }

    private func startAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            Task { @MainActor in
                if !self.selectedTags.isEmpty {
                    await self.loadData()
                }
            }
        }
    }
}

// MARK: - Time Range

enum TimeRange: String, CaseIterable, Identifiable {
    case last15Minutes = "15min"
    case last1Hour     = "1hour"
    case last4Hours    = "4hours"
    case last24Hours   = "24hours"
    case last7Days     = "7days"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .last15Minutes: return "Last 15 Minutes"
        case .last1Hour:     return "Last 1 Hour"
        case .last4Hours:    return "Last 4 Hours"
        case .last24Hours:   return "Last 24 Hours"
        case .last7Days:     return "Last 7 Days"
        }
    }

    var seconds: TimeInterval {
        switch self {
        case .last15Minutes: return 15 * 60
        case .last1Hour:     return 60 * 60
        case .last4Hours:    return 4 * 60 * 60
        case .last24Hours:   return 24 * 60 * 60
        case .last7Days:     return 7 * 24 * 60 * 60
        }
    }
}
