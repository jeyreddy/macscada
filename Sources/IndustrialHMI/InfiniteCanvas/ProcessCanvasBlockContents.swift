import SwiftUI

// MARK: - Block Content Views
//
// Each struct in this file is the *content* rendered inside one kind of CanvasBlock
// when the canvas zoom is ≥ 0.25 (full LOD).
//
// All content views receive live data exclusively through @EnvironmentObject injection:
//   • TagEngine      — current tag values and quality
//   • AlarmManager   — active alarm list
//
// Content views must NOT perform any disk I/O or network requests — they are rendered
// at 60 fps alongside potentially hundreds of other blocks.

// MARK: - Tag Monitor Block
//
// Displays a scrollable table with one row per tag:
//   [Tag Name / Unit]   [Formatted Value]   [Quality dot]
// Quality dot:  green = good, red = bad, yellow = uncertain.
// Value colour: red = bad quality, green = digital ON, white = analog.

/// Live tag-value table for selected tags.
struct TagMonitorContent: View {
    /// Ordered list of tag names to display (matched against TagEngine.tags by name key).
    let tagIDs: [String]
    @EnvironmentObject var tagEngine: TagEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Column headers ────────────────────────────────────────────
            HStack {
                Text("Tag").font(.caption2).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                Text("Value").font(.caption2).foregroundColor(.secondary).frame(width: 70, alignment: .trailing)
                Circle().frame(width: 8).foregroundColor(.clear)   // spacer for quality dot column
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.05))

            Divider().background(Color.white.opacity(0.1))

            // ── Tag rows ─────────────────────────────────────────────────
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(tagIDs, id: \.self) { id in
                        TagMonitorRow(tagID: id)
                        Divider().background(Color.white.opacity(0.06))
                    }
                    if tagIDs.isEmpty {
                        Text("No tags configured")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding()
                    }
                }
            }
        }
    }
}

/// One row in the TagMonitorContent table.
private struct TagMonitorRow: View {
    let tagID: String
    @EnvironmentObject var tagEngine: TagEngine

    /// Resolves the tag from TagEngine using the stored name key.
    var tag: Tag? { tagEngine.tags[tagID] }

    var body: some View {
        HStack {
            // Tag name + optional unit on a second micro-line
            VStack(alignment: .leading, spacing: 1) {
                Text(tag?.name ?? tagID).font(.caption2).lineLimit(1)
                if let unit = tag?.unit, !unit.isEmpty {
                    Text(unit).font(.system(size: 9)).foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Formatted value (monospaced for stable column width)
            Text(tag?.formattedValue ?? "—")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(valueColor)
                .frame(width: 70, alignment: .trailing)

            // Quality indicator dot
            Circle()
                .fill(tag?.quality.dot ?? .secondary)
                .frame(width: 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    /// Value text colour:
    ///   red   = bad quality
    ///   green = digital tag that is ON
    ///   white = analog value (good quality)
    private var valueColor: Color {
        guard let t = tag else { return .secondary }
        if t.quality == .bad { return .red }
        if case .digital(let b) = t.value { return b ? .green : .secondary }
        return .white
    }
}

// MARK: - Status Grid Block
//
// Displays tags as coloured tiles in a lazy grid.
// Tile colour logic (priority order):
//   orange = tag has at least one active alarm
//   red    = tag quality is bad
//   green  = digital tag value is ON (or analog > 0)
//   cyan   = analog tag with good quality (running/healthy)
//   gray   = default / digital OFF

/// Coloured status tile grid for quick equipment status at a glance.
struct StatusGridContent: View {
    let tagIDs: [String]
    @EnvironmentObject var tagEngine:   TagEngine
    @EnvironmentObject var alarmManager: AlarmManager

    private let cols = [GridItem(.adaptive(minimum: 90, maximum: 140), spacing: 6)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: cols, spacing: 6) {
                ForEach(tagIDs, id: \.self) { id in
                    StatusTile(tagID: id)
                }
            }
            .padding(8)
        }
    }
}

/// One tile in the StatusGridContent grid.
private struct StatusTile: View {
    let tagID: String
    @EnvironmentObject var tagEngine:   TagEngine
    @EnvironmentObject var alarmManager: AlarmManager

    var tag: Tag? { tagEngine.tags[tagID] }

    var body: some View {
        VStack(spacing: 3) {
            Circle().fill(tileColor).frame(width: 10, height: 10)
            Text(tag?.name ?? tagID)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(tag?.formattedValue ?? "—")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(tileColor.opacity(0.12))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(tileColor.opacity(0.4), lineWidth: 1))
        .cornerRadius(6)
    }

    /// Tile background and indicator colour — see colour priority table in section header.
    private var tileColor: Color {
        guard let t = tag else { return .secondary }
        if !alarmManager.getAlarms(forTag: t.name).isEmpty { return .orange }
        if t.quality == .bad { return .red }
        if case .digital(let b) = t.value { return b ? .green : .secondary }
        if t.quality == .good { return .cyan }
        return .secondary
    }
}

// MARK: - Alarm Panel Block
//
// Shows the ISA-18.2 active alarm list capped at `maxAlarms` rows.
// Header badge shows total active + unacknowledged count.
// Each row: coloured severity bar | alarm message | tag name.

/// Active alarm list widget showing up to `maxAlarms` alarms.
struct AlarmPanelContent: View {
    /// Maximum number of alarm rows to display (oldest overflow silently dropped).
    let maxAlarms: Int
    @EnvironmentObject var alarmManager: AlarmManager

    /// Most-recent-first slice of active alarms capped at maxAlarms.
    private var shown: [Alarm] {
        Array(alarmManager.activeAlarms.prefix(maxAlarms))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ────────────────────────────────────────────────────
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(alarmManager.unacknowledgedCount > 0 ? .red : .orange)
                Text("\(alarmManager.activeAlarms.count) Active")
                    .font(.caption.bold())
                Spacer()
                if alarmManager.unacknowledgedCount > 0 {
                    Text("\(alarmManager.unacknowledgedCount) Unacked")
                        .font(.caption2)
                        .foregroundColor(.red)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.red.opacity(0.1))

            // ── Alarm rows or all-clear message ──────────────────────────
            if shown.isEmpty {
                Text("No active alarms")
                    .font(.caption)
                    .foregroundColor(.green)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(shown) { alarm in
                    HStack(spacing: 6) {
                        // Severity colour bar on the left edge
                        RoundedRectangle(cornerRadius: 2)
                            .fill(alarm.severity == .critical ? Color.red : .orange)
                            .frame(width: 3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(alarm.message).font(.caption2).lineLimit(1)
                            Text(alarm.tagName).font(.system(size: 9)).foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    Divider().background(Color.white.opacity(0.06))
                }
            }
        }
    }
}

// MARK: - Label Block
//
// Static text. No live data — purely decorative / informational.
// Font size is pre-multiplied by `scale` in ProcessCanvasBlockView so text
// appears at a consistent visual size regardless of zoom level.

/// Static text label block for area titles, headings, and annotations.
struct LabelContent: View {
    let text:     String
    let fontSize: Double   // already multiplied by canvas scale in ProcessCanvasBlockView

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .bold))
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
    }
}

// MARK: - Navigation Button Block
//
// A tappable block that calls onTap — ProcessCanvasBlockView wires this
// to animateTo(navX, navY, navScale) to animate the canvas viewport.

/// Button that navigates the Process Canvas viewport to a preset location.
struct NavButtonContent: View {
    let label: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.title2)
                    .foregroundColor(.blue)
                Text(label)
                    .font(.headline)
                    .foregroundColor(.white)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Equipment Block
//
// Shows a P&ID-style icon for a piece of industrial equipment.
// The icon and status colour are driven by a single tag bound via equipTagID.
//
// Running state logic:
//   digital tag:  isRunning = (value == true)
//   analog tag:   isRunning = (value > 0)
//
// Colour priority:
//   orange = active alarm on the linked tag
//   green  = running
//   gray   = stopped or no tag bound

/// Industrial equipment icon with live running/alarm/stopped status.
struct EquipmentContent: View {
    /// One of: "pump" | "motor" | "valve" | "tank" | "exchanger" | "compressor"
    let kind:  String
    /// Tag name used to determine running state. Empty string = no tag (static icon).
    let tagID: String
    @EnvironmentObject var tagEngine:   TagEngine
    @EnvironmentObject var alarmManager: AlarmManager

    private var tag: Tag? { tagEngine.tags[tagID] }

    /// Equipment is "running" when the bound tag has a non-zero/true value.
    private var isRunning: Bool {
        if let t = tag, case .digital(let b) = t.value { return b }
        if let t = tag, case .analog(let v)  = t.value { return v > 0 }
        return false
    }

    /// True when the bound tag has at least one active alarm.
    private var hasAlarm: Bool {
        tag.map { !alarmManager.getAlarms(forTag: $0.name).isEmpty } ?? false
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundColor(hasAlarm ? .orange : (isRunning ? .green : .secondary))

            Text(kind.capitalized)
                .font(.caption.bold())

            if let t = tag {
                Text(t.formattedValue)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                HStack(spacing: 4) {
                    Circle().fill(t.quality.dot).frame(width: 6)
                    Text(isRunning ? "Running" : "Stopped")
                        .font(.caption2)
                        .foregroundColor(isRunning ? .green : .secondary)
                }
            } else if !tagID.isEmpty {
                Text("No data").font(.caption2).foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// SF Symbol name for each equipment kind.
    private var icon: String {
        switch kind {
        case "pump":       return "drop.circle.fill"
        case "motor":      return "bolt.circle.fill"
        case "valve":      return "flowchart.fill"
        case "tank":       return "cylinder.fill"
        case "exchanger":  return "arrow.triangle.2.circlepath"
        case "compressor": return "wind"
        default:           return "gearshape.fill"
        }
    }
}

// MARK: - HMI Screen Block
//
// A clickable card that switches the app to the HMI Screens tab and loads
// the screen identified by `screenID`. The card shows the screen name and
// an "Open Screen" sub-label to make the action obvious.

/// Link card that opens a specific HMI screen in the HMI Screens tab.
struct HMIScreenContent: View {
    /// UUID string of the target HMIScreen — passed to HMIScreenStore.switchToScreen.
    let screenID:   String
    /// Cached display name shown in the card (set when the block was created/configured).
    let screenName: String
    /// Called when the card is tapped (wired to HMIScreenStore navigation in ProcessCanvasBlockView).
    let onTap:      () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 10) {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 32))
                    .foregroundColor(.blue)

                Text(screenName.isEmpty ? "HMI Screen" : screenName)
                    .font(.headline)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)

                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.forward.app").font(.caption)
                    Text("Open Screen").font(.caption)
                }
                .foregroundColor(.blue.opacity(0.8))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Screen Group Block
//
// Shows a mini grid preview of the linked HMI screens (up to 9 visible tiles)
// with a screen count label and an "Open Combined View" prompt.
//
// When tapped (in operate mode), ProcessCanvasView shows a CompositeHMIView:
// a full-screen infinite canvas with all screens rendered side-by-side in
// `cols` columns. See CompositeHMIView.swift for the grid layout math.

/// Preview card for a group of HMI screens that open as one seamless canvas.
struct ScreenGroupContent: View {
    /// Ordered list of screen references in the group.
    let entries: [ScreenGroupEntry]
    /// Number of columns used when rendering the screens side-by-side in CompositeHMIView.
    let cols:    Int
    /// Group title shown in the CompositeHMIView toolbar.
    let title:   String
    /// Called when the card is tapped (opens CompositeHMIView).
    let onTap:   () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 10) {

                // ── Mini grid preview icon ────────────────────────────────
                // Shows up to 9 screen tiles (3 × 3 max) with the first 6 chars
                // of each screen name as a micro label.
                let n = min(entries.count, 9)
                let c = max(1, cols)
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(28), spacing: 4), count: min(c, 3)),
                    spacing: 4
                ) {
                    ForEach(0..<n, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(hex: "#1D4ED8").opacity(0.7))
                            .frame(height: 18)
                            .overlay(
                                Text(entries[i].hmiScreenName.prefix(6))
                                    .font(.system(size: 6, weight: .medium))
                                    .foregroundColor(.white.opacity(0.8))
                                    .lineLimit(1)
                            )
                    }
                }
                .frame(maxWidth: 120)

                // ── Screen count label ────────────────────────────────────
                Text(entries.isEmpty
                     ? "No screens linked"
                     : "\(entries.count) screen\(entries.count == 1 ? "" : "s")")
                    .font(.headline)
                    .foregroundColor(.white)

                // ── Action prompt ─────────────────────────────────────────
                if !entries.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.forward.app").font(.caption)
                        Text("Open Combined View").font(.caption)
                    }
                    .foregroundColor(.blue.opacity(0.85))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Mini Trend Block
//
// Shows sparklines for up to 3 tags using the current tag value as a point.
// The sparkline path is currently a horizontal flat line at 50 % height —
// real historical data would require querying Historian.getHistory() asynchronously.

/// Compact sparkline widget for up to 3 tags.
struct TrendMiniContent: View {
    /// Up to 3 tag names to display (extras are silently dropped with .prefix(3)).
    let tagIDs: [String]
    let minutes: Int   // intended history window — currently unused (future: Historian query)
    @EnvironmentObject var tagEngine: TagEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(tagIDs.prefix(3), id: \.self) { id in
                MiniSparkline(tagID: id)
            }
            if tagIDs.isEmpty {
                Text("No tags").font(.caption2).foregroundColor(.secondary).padding()
            }
        }
        .padding(8)
    }
}

/// One sparkline row: [tag name + live value] [flat line at 50%].
private struct MiniSparkline: View {
    let tagID: String
    @EnvironmentObject var tagEngine: TagEngine

    var tag: Tag? { tagEngine.tags[tagID] }

    var body: some View {
        HStack(spacing: 6) {
            // Tag name and live value
            VStack(alignment: .leading, spacing: 1) {
                Text(tag?.name ?? tagID).font(.system(size: 10)).lineLimit(1)
                Text(tag?.formattedValue ?? "—")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(tag?.quality.dot ?? .secondary)
            }
            .frame(width: 80, alignment: .leading)

            // Sparkline placeholder — flat horizontal line at 50 % height.
            // Replace Path with a real polyline when Historian query is available.
            GeometryReader { geo in
                Path { p in
                    let w = geo.size.width
                    let h = geo.size.height
                    p.move(to:    CGPoint(x: 0, y: h * 0.5))
                    p.addLine(to: CGPoint(x: w, y: h * 0.5))
                }
                .stroke(tag?.quality.dot ?? Color.secondary, lineWidth: 1.5)
                .opacity(0.6)
            }
            .frame(height: 24)
        }
    }
}
