import SwiftUI
import Charts

// MARK: - HMIFaceplateView

/// Run-mode popover: live value, 15-min mini-trend, and all alarms for a bound tag.
struct HMIFaceplateView: View {
    let object: HMIObject

    @EnvironmentObject var tagEngine: TagEngine
    @EnvironmentObject var alarmManager: AlarmManager

    @State private var historicalData: [HistoricalDataPoint] = []
    @State private var isLoading = false

    private var tagName: String { object.tagBinding?.tagName ?? "" }
    private var liveTag: Tag?   { tagEngine.getTag(named: tagName) }

    /// All alarms associated with this tag (active, acknowledged, RTN, etc.)
    private var tagAlarms: [Alarm] {
        alarmManager.activeAlarms.filter { $0.tagName == tagName }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider()
            valueSection
            Divider()
            miniTrendSection
            if !tagAlarms.isEmpty {
                Divider()
                alarmsSection
            }
        }
        .frame(width: 380)
        .task { await loadHistory() }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 10) {
            // Alarm severity indicator
            if let worst = worstSeverity {
                Circle()
                    .fill(severityColor(worst))
                    .frame(width: 10, height: 10)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(tagName)
                    .font(.system(.headline, design: .monospaced))
                    .lineLimit(1)
                if let tag = liveTag, let desc = tag.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if !object.designerLabel.isEmpty {
                    Text(object.designerLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Value

    private var valueSection: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Current Value")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(liveTag?.formattedValue ?? "—")
                    .font(.system(.title2, design: .monospaced).bold())
                    .foregroundColor(worstSeverity.map { severityColor($0) } ?? .primary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Quality")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 5) {
                    Circle()
                        .fill(qualityColor)
                        .frame(width: 8, height: 8)
                    Text(liveTag?.quality.description ?? "—")
                        .font(.caption)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Last Updated")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let ts = liveTag?.timestamp {
                    Text(ts, style: .time)
                        .font(.caption)
                } else {
                    Text("—").font(.caption)
                }
            }
        }
        .padding()
    }

    // MARK: - Mini Trend (last 15 min)

    @ViewBuilder
    private var miniTrendSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Last 15 Minutes")
                .font(.caption.bold())
                .foregroundColor(.secondary)
                .padding(.horizontal)
                .padding(.top, 8)

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 110)
            } else if historicalData.isEmpty {
                Text("No historical data")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 110)
                    .multilineTextAlignment(.center)
            } else {
                let endTime   = Date()
                let startTime = endTime.addingTimeInterval(-15 * 60)
                Chart(historicalData) { point in
                    LineMark(
                        x: .value("Time",  point.timestamp),
                        y: .value("Value", point.value)
                    )
                    .foregroundStyle(Color.blue)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.linear)
                }
                .chartXScale(domain: startTime...endTime)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour().minute())
                    }
                }
                .chartYAxis {
                    AxisMarks { _ in
                        AxisGridLine()
                        AxisValueLabel()
                    }
                }
                .frame(height: 110)
                .padding(.horizontal)
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: - All Alarms for This Tag

    @ViewBuilder
    private var alarmsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Alarms")
                .font(.caption.bold())
                .foregroundColor(.secondary)
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 4)

            ForEach(tagAlarms) { alarm in
                alarmRow(alarm)
                if alarm.id != tagAlarms.last?.id { Divider().padding(.leading) }
            }
        }
    }

    private func alarmRow(_ alarm: Alarm) -> some View {
        HStack(spacing: 10) {
            // Severity + state color strip
            RoundedRectangle(cornerRadius: 3)
                .fill(severityColor(alarm.severity))
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(alarm.severity.rawValue.uppercased())
                        .font(.caption2.bold())
                        .foregroundColor(severityColor(alarm.severity))
                    Text("·")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(alarm.state.rawValue)
                        .font(.caption2)
                        .foregroundColor(stateColor(alarm.state))
                    Spacer()
                    Text(alarm.triggerTime, style: .relative)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Text(alarm.message)
                    .font(.caption)
                    .foregroundColor(.primary)
                    .lineLimit(2)
            }

            // Ack button — for any alarm that still requires operator action
            if alarm.state.requiresAction {
                Button("Ack") { alarmManager.acknowledgeAlarm(alarm) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(alarm.state == .unacknowledgedRTN ? .green : .orange)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(severityColor(alarm.severity).opacity(0.07))
    }

    // MARK: - Helpers

    private var qualityColor: Color {
        switch liveTag?.quality {
        case .good:      return .green
        case .bad:       return .red
        case .uncertain: return .yellow
        case nil:        return .gray
        }
    }

    private var worstSeverity: AlarmSeverity? {
        // Condition-active alarms take priority for severity indication
        let condActive = tagAlarms.filter { $0.state.conditionActive }
        let pool = condActive.isEmpty ? tagAlarms : condActive
        if pool.contains(where: { $0.severity == .critical }) { return .critical }
        if pool.contains(where: { $0.severity == .warning  }) { return .warning  }
        if !pool.isEmpty                                       { return .info     }
        return nil
    }

    private func severityColor(_ severity: AlarmSeverity) -> Color {
        switch severity {
        case .critical: return .red
        case .warning:  return .orange
        case .info:     return .blue
        }
    }

    private func stateColor(_ state: AlarmState) -> Color {
        switch state {
        case .unacknowledgedActive: return .red
        case .acknowledgedActive:   return .yellow
        case .unacknowledgedRTN:    return .green
        case .normal:               return .secondary
        case .suppressed:           return .gray
        }
    }

    private func loadHistory() async {
        guard !tagName.isEmpty else { return }
        isLoading = true
        let endTime   = Date()
        let startTime = endTime.addingTimeInterval(-15 * 60)
        let result = await tagEngine.getHistoricalData(
            for: [tagName], from: startTime, to: endTime, maxPoints: 200)
        historicalData = result[tagName] ?? []
        isLoading = false
    }
}
