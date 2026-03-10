import SwiftUI
import AppKit

// MARK: - ProcessCanvasBlockView
//
// Renders one CanvasBlock on the infinite canvas.
//
// ── UX features ────────────────────────────────────────────────────────────
//   • Pulsing alarm border  — blocks with active alarms get an animated border
//   • Alarm badge dot       — visible at ALL zoom levels (even below 0.12)
//   • Double-click zoom     — double-tap any block to zoom into it
//   • Hover glow + cursor   — interactive blocks show pointer cursor on hover
//   • Right-click menu      — Zoom / Open Screen / Navigate
//   • Medium-zoom "big number" — key value shown large at 0.12–0.25 zoom
//   • Region block          — labelled coloured area with no live data
//
// ── Level of Detail (LOD) ────────────────────────────────────────────────
//   scale < 0.12  →  alarm badge only (just the coloured box + badge dot)
//   scale < 0.25  →  medium zoom: big value / running state / alarm count
//   scale ≥ 0.25  →  full content view
//
// ── Design vs Operate mode ───────────────────────────────────────────────
//   Operate: content handles taps; outer ZStack catches navButton / hmiScreen / screenGroup.
//   Design:  Color.clear overlay routes all taps → onSelect(), drags → onDragEnd.

struct ProcessCanvasBlockView: View {

    let block:       CanvasBlock
    let scale:       CGFloat
    let pan:         CGPoint
    let isSelected:  Bool
    let isDesigning: Bool

    // MARK: - Operate-mode callbacks
    let onNavigate:        (Double, Double, Double) -> Void
    var onOpenScreen:      (String) -> Void            = { _ in }
    var onOpenScreenGroup: ([ScreenGroupEntry], Int, String) -> Void = { _, _, _ in }
    var onZoomTo:          () -> Void                  = {}   // double-click → zoom

    // MARK: - Design-mode callbacks
    var onSelect:    () -> Void          = {}
    var onDragEnd:   (CGPoint) -> Void   = { _ in }

    // MARK: - Live data (for alarm state + medium-zoom values)
    @EnvironmentObject var tagEngine:    TagEngine
    @EnvironmentObject var alarmManager: AlarmManager

    // MARK: - Drag state
    @State private var dragOffset: CGPoint = .zero
    @State private var isDragging: Bool    = false

    // MARK: - Interaction state
    @State private var isHovered:   Bool = false
    @State private var alarmPulse:  Bool = false

    // MARK: - Computed screen geometry

    private var sx: CGFloat { block.x * scale + pan.x + dragOffset.x }
    private var sy: CGFloat { block.y * scale + pan.y + dragOffset.y }
    private var sw: CGFloat { block.w * scale }
    private var sh: CGFloat { block.h * scale }

    // MARK: - Alarm state

    enum AlarmBlockState { case none, warning, critical }

    private var blockAlarmState: AlarmBlockState {
        switch block.content.kind {
        case "alarmPanel":
            if alarmManager.activeAlarms.contains(where: {
                $0.severity == .critical && $0.state.requiresAction }) { return .critical }
            if !alarmManager.activeAlarms.isEmpty { return .warning }
            return .none
        case "equipment":
            let alarms = alarmManager.getAlarms(forTag: block.content.equipTagID)
            if alarms.contains(where: { $0.severity == .critical }) { return .critical }
            if !alarms.isEmpty { return .warning }
            return .none
        case "tagMonitor", "statusGrid", "trendMini":
            let all = block.content.tagIDs.flatMap { alarmManager.getAlarms(forTag: $0) }
            if all.contains(where: { $0.severity == .critical }) { return .critical }
            if !all.isEmpty { return .warning }
            return .none
        default:
            return .none
        }
    }

    private var hasAlarm: Bool { blockAlarmState != .none }

    private var alarmColor: Color {
        blockAlarmState == .critical ? .red : .orange
    }

    // MARK: - Interactive (cursor + hover glow)
    private var isInteractive: Bool {
        ["navButton", "hmiScreen", "screenGroup"].contains(block.content.kind)
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .topLeading) {
            blockBody
                .frame(width: max(sw, 4), height: max(sh, 4))
                .position(x: sx + sw / 2, y: sy + sh / 2)
        }
    }

    // MARK: - Block appearance

    @ViewBuilder
    private var blockBody: some View {
        ZStack(alignment: .topLeading) {

            // ── Background fill ────────────────────────────────────────────
            RoundedRectangle(cornerRadius: clampedCorner)
                .fill(Color(hex: block.bgHex))

            // ── Hover glow (interactive blocks only) ──────────────────────
            if isHovered && isInteractive && !isDesigning {
                RoundedRectangle(cornerRadius: clampedCorner)
                    .fill(Color.white.opacity(0.06))
            }

            // ── Border: pulsing alarm / selected / default ─────────────────
            RoundedRectangle(cornerRadius: clampedCorner)
                .strokeBorder(
                    isSelected
                        ? Color.accentColor
                        : (hasAlarm
                            ? alarmColor.opacity(alarmPulse ? 1.0 : 0.35)
                            : Color(hex: block.borderHex)),
                    lineWidth: isSelected ? 2 : (hasAlarm ? 2 : 1)
                )

            // ── Content (title + LOD view) ────────────────────────────────
            VStack(alignment: .leading, spacing: 0) {
                if block.showTitle && scale > 0.12 {
                    titleBar
                }
                if scale >= 0.25 {
                    blockContent
                } else if scale >= 0.12 {
                    mediumZoomContent  // big number / running state
                }
                // Below 0.12 → only alarm badge shows
            }
            .clipShape(RoundedRectangle(cornerRadius: clampedCorner))
            .allowsHitTesting(!isDesigning)

            // ── Design-mode overlay ────────────────────────────────────────
            if isDesigning {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect() }
                    .gesture(blockDragGesture)
            }

            // ── Selection handles ──────────────────────────────────────────
            if isDesigning && isSelected {
                selectionHandles.allowsHitTesting(false)
            }

            // ── Alarm badge dot — visible at ALL zoom levels ──────────────
            if hasAlarm {
                let dotSize: CGFloat = max(8, min(14, sw * 0.06))
                Circle()
                    .fill(alarmColor)
                    .frame(width: dotSize, height: dotSize)
                    .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 0.5))
                    .shadow(color: alarmColor.opacity(0.9), radius: alarmPulse ? 5 : 2)
                    .scaleEffect(alarmPulse ? 1.3 : 0.95)
                    .position(x: max(sw - dotSize / 2 - 4, dotSize / 2 + 2), y: dotSize / 2 + 4)
                    .allowsHitTesting(false)
            }
        }
        // ── Operate-mode taps ─────────────────────────────────────────────
        // Double-tap first so SwiftUI's recognizer doesn't treat it as two single taps.
        .onTapGesture(count: 2) {
            guard !isDesigning else { return }
            onZoomTo()
        }
        .onTapGesture(count: 1) {
            guard !isDesigning else { return }
            switch block.content.kind {
            case "navButton":
                onNavigate(block.content.navX, block.content.navY, block.content.navScale)
            case "hmiScreen":
                onOpenScreen(block.content.hmiScreenID)
            case "screenGroup":
                onOpenScreenGroup(block.content.screenGroupEntries,
                                  block.content.screenGroupCols,
                                  block.title)
            default: break
            }
        }
        // ── Right-click context menu ──────────────────────────────────────
        .contextMenu {
            Button { onZoomTo() } label: {
                Label("Zoom to Block", systemImage: "magnifyingglass")
            }
            if block.content.kind == "navButton" {
                Button { onNavigate(block.content.navX, block.content.navY, block.content.navScale) } label: {
                    Label("Navigate Here", systemImage: "arrow.right.circle")
                }
            }
            if block.content.kind == "hmiScreen" {
                Button { onOpenScreen(block.content.hmiScreenID) } label: {
                    Label("Open Screen", systemImage: "rectangle.on.rectangle")
                }
            }
            if block.content.kind == "screenGroup" {
                Button {
                    onOpenScreenGroup(block.content.screenGroupEntries,
                                      block.content.screenGroupCols,
                                      block.title)
                } label: {
                    Label("Open Combined View", systemImage: "square.grid.2x2")
                }
            }
        }
        // ── Hover tracking ─────────────────────────────────────────────────
        .onHover { hovering in
            isHovered = hovering
            guard !isDesigning && isInteractive else { return }
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        // ── Alarm pulse animation ─────────────────────────────────────────
        .onAppear {
            if hasAlarm { startPulse() }
        }
        .onChange(of: hasAlarm) { _, alarming in
            if alarming { startPulse() } else { stopPulse() }
        }
    }

    private func startPulse() {
        withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) {
            alarmPulse = true
        }
    }

    private func stopPulse() {
        withAnimation(.easeInOut(duration: 0.3)) {
            alarmPulse = false
        }
    }

    // MARK: - Corner radius

    private var clampedCorner: CGFloat { min(8, sw * 0.04) }

    // MARK: - Title bar

    private var titleBar: some View {
        HStack(spacing: 4) {
            Image(systemName: contentIcon)
                .font(.system(size: clamp(scale * 9, lo: 7, hi: 12)))
                .foregroundColor(.secondary)
            Text(block.title)
                .font(.system(size: clamp(scale * 10, lo: 8, hi: 13), weight: .semibold))
                .lineLimit(1)
                .foregroundColor(.white.opacity(0.85))
            Spacer()
            // Alarm count badge in title bar (visible at full zoom)
            if hasAlarm {
                let count = alarmCountForBlock
                Text("\(count)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(alarmColor, in: Capsule())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.06))
    }

    private var alarmCountForBlock: Int {
        switch block.content.kind {
        case "alarmPanel":       return alarmManager.activeAlarms.count
        case "equipment":        return alarmManager.getAlarms(forTag: block.content.equipTagID).count
        default:                 return block.content.tagIDs.flatMap { alarmManager.getAlarms(forTag: $0) }.count
        }
    }

    // MARK: - Medium zoom content (0.12 ≤ scale < 0.25)
    // Shows the operationally most important value large enough to read across the room.

    @ViewBuilder
    private var mediumZoomContent: some View {
        VStack(spacing: 3) {
            switch block.content.kind {
            case "tagMonitor", "statusGrid":
                if let id = block.content.tagIDs.first, let tag = tagEngine.tags[id] {
                    Text(tag.formattedValue)
                        .font(.system(size: clamp(scale * 64, lo: 14, hi: 28),
                                      weight: .bold, design: .monospaced))
                        .foregroundColor(tag.quality == .bad ? .red : .white)
                        .lineLimit(1)
                    Text(tag.name)
                        .font(.system(size: clamp(scale * 28, lo: 8, hi: 12)))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else {
                    compactSummary
                }
            case "equipment":
                let tag  = block.content.equipTagID.isEmpty ? nil : tagEngine.tags[block.content.equipTagID]
                let running = tag.map { isTagRunning($0) } ?? false
                Image(systemName: contentIcon)
                    .font(.system(size: clamp(scale * 80, lo: 18, hi: 32)))
                    .foregroundColor(hasAlarm ? .orange : (running ? .green : .secondary))
                Text(running ? "RUN" : "STOP")
                    .font(.system(size: clamp(scale * 28, lo: 9, hi: 13), weight: .bold))
                    .foregroundColor(running ? .green : .secondary)
            case "alarmPanel":
                let count = alarmManager.activeAlarms.count
                Text("\(count)")
                    .font(.system(size: clamp(scale * 80, lo: 18, hi: 36),
                                  weight: .heavy, design: .monospaced))
                    .foregroundColor(count == 0 ? .green : .red)
                Text("ALARMS")
                    .font(.system(size: clamp(scale * 22, lo: 8, hi: 11), weight: .semibold))
                    .foregroundColor(.secondary)
            case "trendMini":
                if let id = block.content.tagIDs.first, let tag = tagEngine.tags[id] {
                    HStack(spacing: 4) {
                        Image(systemName: "chart.xyaxis.line")
                            .font(.system(size: 12)).foregroundColor(.secondary)
                        Text(tag.formattedValue)
                            .font(.system(size: clamp(scale * 52, lo: 13, hi: 22),
                                          weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                } else {
                    compactSummary
                }
            default:
                compactSummary
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(4)
    }

    // MARK: - Compact summary (fallback for medium zoom)

    private var compactSummary: some View {
        HStack {
            Image(systemName: contentIcon)
                .foregroundColor(.secondary)
                .font(.system(size: 11))
            Text(summaryText)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // MARK: - Full content (scale ≥ 0.25)

    @ViewBuilder
    private var blockContent: some View {
        Group {
            switch block.content.kind {
            case "label":
                LabelContent(text: block.content.text, fontSize: block.content.fontSize * scale)
            case "tagMonitor":
                TagMonitorContent(tagIDs: block.content.tagIDs)
            case "statusGrid":
                StatusGridContent(tagIDs: block.content.tagIDs)
            case "alarmPanel":
                AlarmPanelContent(maxAlarms: block.content.maxAlarms)
            case "navButton":
                NavButtonContent(label: block.content.navLabel) {
                    onNavigate(block.content.navX, block.content.navY, block.content.navScale)
                }
            case "equipment":
                EquipmentContent(kind: block.content.equipKind, tagID: block.content.equipTagID)
            case "trendMini":
                TrendMiniContent(tagIDs: block.content.tagIDs, minutes: block.content.minutes)
            case "hmiScreen":
                HMIScreenContent(
                    screenID:   block.content.hmiScreenID,
                    screenName: block.content.hmiScreenName
                ) { onOpenScreen(block.content.hmiScreenID) }
            case "screenGroup":
                ScreenGroupContent(
                    entries: block.content.screenGroupEntries,
                    cols:    block.content.screenGroupCols,
                    title:   block.title
                ) {
                    onOpenScreenGroup(block.content.screenGroupEntries,
                                      block.content.screenGroupCols,
                                      block.title)
                }
            case "region":
                RegionContent(text: block.content.text, colorHex: block.content.regionColorHex)
            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Selection handles

    private var selectionHandles: some View {
        ZStack {
            ForEach([CGPoint(x: 0, y: 0),
                     CGPoint(x: 1, y: 0),
                     CGPoint(x: 0, y: 1),
                     CGPoint(x: 1, y: 1)], id: \.x) { corner in
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .position(x: corner.x * sw, y: corner.y * sh)
            }
        }
    }

    // MARK: - Drag gesture (design mode)

    private var blockDragGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { v in
                isDragging = true
                dragOffset = CGPoint(x: v.translation.width, y: v.translation.height)
            }
            .onEnded { v in
                isDragging = false
                let newCanvasX = block.x + v.translation.width  / scale
                let newCanvasY = block.y + v.translation.height / scale
                dragOffset = .zero
                onDragEnd(CGPoint(x: newCanvasX, y: newCanvasY))
            }
    }

    // MARK: - Helpers

    private func isTagRunning(_ tag: Tag) -> Bool {
        if case .digital(let b) = tag.value { return b }
        if case .analog(let v)  = tag.value { return v > 0 }
        return false
    }

    private var contentIcon: String {
        switch block.content.kind {
        case "label":       return "text.alignleft"
        case "tagMonitor":  return "list.bullet"
        case "statusGrid":  return "square.grid.2x2"
        case "alarmPanel":  return "exclamationmark.triangle"
        case "navButton":   return "arrow.right.circle"
        case "equipment":
            switch block.content.equipKind {
            case "pump":       return "drop.circle.fill"
            case "motor":      return "bolt.circle.fill"
            case "valve":      return "flowchart.fill"
            case "tank":       return "cylinder.fill"
            case "exchanger":  return "arrow.triangle.2.circlepath"
            case "compressor": return "wind"
            default:           return "gearshape.fill"
            }
        case "trendMini":   return "chart.xyaxis.line"
        case "hmiScreen":   return "rectangle.on.rectangle"
        case "screenGroup": return "square.grid.2x2"
        case "region":      return "rectangle.dashed"
        default:            return "square"
        }
    }

    private var summaryText: String {
        switch block.content.kind {
        case "tagMonitor":  return "\(block.content.tagIDs.count) tags"
        case "statusGrid":  return "\(block.content.tagIDs.count) tags"
        case "trendMini":   return "\(block.content.tagIDs.count) trends"
        case "alarmPanel":  return "Alarm panel"
        case "navButton":   return block.content.navLabel
        case "equipment":   return block.content.equipKind.capitalized
        case "hmiScreen":   return block.content.hmiScreenName.isEmpty ? "HMI Screen" : block.content.hmiScreenName
        case "screenGroup": return "\(block.content.screenGroupEntries.count) screens"
        default:            return block.content.text
        }
    }
}

// MARK: - Clamp helper

private func clamp(_ v: CGFloat, lo: CGFloat, hi: CGFloat) -> CGFloat {
    max(lo, min(hi, v))
}
