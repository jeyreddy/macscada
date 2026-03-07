import SwiftUI

// MARK: - ProcessCanvasBlockView
//
// Renders one CanvasBlock on the infinite canvas.
//
// ── Coordinate math ──────────────────────────────────────────────────────────
//   Canvas space  →  screen space conversion (same as ProcessCanvasView):
//     sx = block.x * scale + pan.x        (screen X of top-left corner)
//     sy = block.y * scale + pan.y        (screen Y of top-left corner)
//     sw = block.w * scale                (screen width)
//     sh = block.h * scale                (screen height)
//   SwiftUI .position() takes the *centre*, so we pass (sx + sw/2, sy + sh/2).
//
// ── Level of Detail (LOD) ─────────────────────────────────────────────────────
//   scale < 0.12  →  nothing inside the block is shown (just the coloured box)
//   scale < 0.25  →  compact summary: icon + single-line summary text
//   scale ≥ 0.25  →  full content view (TagMonitorContent, EquipmentContent, …)
//
//   These thresholds were chosen so that at the default fit-to-window scale
//   (~0.3–0.6 for a typical 4-block canvas), full content is always visible.
//
// ── Design vs Operate mode ────────────────────────────────────────────────────
//   Operate mode:
//     • Content (buttons, scroll views) handles its own taps.
//     • .onTapGesture on the outer ZStack handles block-level tap actions
//       (navButton, hmiScreen, screenGroup).
//
//   Design mode:
//     • Content VStack has .allowsHitTesting(false) so buttons/ScrollViews inside
//       blocks don't consume taps intended for block selection.
//     • A Color.clear overlay with .contentShape(Rectangle()) sits on top and
//       routes all taps to onSelect() and all drags to blockDragGesture.
//     • Selection handles (filled circles at the four corners) are drawn topmost
//       with .allowsHitTesting(false) so they don't interfere with drag.

struct ProcessCanvasBlockView: View {

    let block:       CanvasBlock
    /// Current canvas zoom level — used for LOD switching and screen geometry.
    let scale:       CGFloat
    /// Pan offset (screen position of the canvas origin).
    let pan:         CGPoint
    /// Whether this block is currently selected in design mode.
    let isSelected:  Bool
    /// True when the toolbar is in Design mode.
    let isDesigning: Bool

    // MARK: - Operate-mode callbacks

    /// navButton: animate viewport to (navX, navY) at navScale.
    let onNavigate:        (Double, Double, Double) -> Void
    /// hmiScreen: switch HMI tab to this screen ID string.
    var onOpenScreen:      (String) -> Void = { _ in }
    /// screenGroup: open CompositeHMIView with the given entries, columns, and title.
    var onOpenScreenGroup: ([ScreenGroupEntry], Int, String) -> Void = { _, _, _ in }

    // MARK: - Design-mode callbacks

    /// Called when the block is tapped to select it.
    var onSelect:    () -> Void   = {}
    /// Called when a drag ends. Parameter is the new canvas-space top-left corner.
    var onDragEnd:   (CGPoint) -> Void = { _ in }

    // MARK: - Drag state

    /// Screen-space drag translation while the block is being dragged.
    /// Reset to .zero when the drag ends so the block snaps to its persisted position.
    @State private var dragOffset:    CGPoint = .zero
    @State private var isDragging:    Bool    = false

    // MARK: - Computed screen geometry

    /// Screen X of the block's top-left corner (including drag offset).
    private var sx: CGFloat { block.x * scale + pan.x + dragOffset.x }
    private var sy: CGFloat { block.y * scale + pan.y + dragOffset.y }
    /// Screen width and height of the block.
    private var sw: CGFloat { block.w * scale }
    private var sh: CGFloat { block.h * scale }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .topLeading) {
            blockBody
                .frame(width: max(sw, 4), height: max(sh, 4))
                // SwiftUI .position() anchors at the view centre.
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

            // ── Border stroke (thicker + accent-coloured when selected) ───
            RoundedRectangle(cornerRadius: clampedCorner)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color(hex: block.borderHex),
                    lineWidth: isSelected ? 2 : 1
                )

            // ── Content (title bar + main content view) ───────────────────
            // .allowsHitTesting(!isDesigning) prevents the buttons and ScrollViews
            // inside blocks from absorbing taps in design mode — taps are handled
            // by the Color.clear overlay below instead.
            VStack(alignment: .leading, spacing: 0) {
                // Title bar — hidden at very small zoom (scale < 0.12)
                if block.showTitle && scale > 0.12 {
                    titleBar
                }
                // LOD-based content selection
                if scale >= 0.25 {
                    blockContent    // full content (tag tables, gauges, etc.)
                } else if scale >= 0.12 {
                    compactSummary  // icon + one-line description
                }
                // Below 0.12: nothing shown inside (block is tiny)
            }
            .clipShape(RoundedRectangle(cornerRadius: clampedCorner))
            .allowsHitTesting(!isDesigning)

            // ── Design-mode tap + drag overlay ────────────────────────────
            // Sits above the content layer but below selection handles.
            // Color.clear with contentShape makes the full block area hittable.
            if isDesigning {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect() }
                    .gesture(blockDragGesture)
            }

            // ── Selection handles (four corner dots) ──────────────────────
            // Topmost so they render above everything else.
            // Non-interactive (.allowsHitTesting(false)) — they are visual only.
            if isDesigning && isSelected {
                selectionHandles.allowsHitTesting(false)
            }
        }
        // Operate-mode tap actions — fires only when isDesigning is false because
        // the design-mode overlay's .onTapGesture would fire first otherwise.
        .onTapGesture {
            guard !isDesigning else { return }
            switch block.content.kind {
            case "navButton":
                // Animate the Process Canvas viewport to the stored target.
                onNavigate(block.content.navX, block.content.navY, block.content.navScale)
            case "hmiScreen":
                // Switch to HMI tab and load the linked screen.
                onOpenScreen(block.content.hmiScreenID)
            case "screenGroup":
                // Open the full-screen composite view with all linked screens.
                onOpenScreenGroup(block.content.screenGroupEntries,
                                  block.content.screenGroupCols,
                                  block.title)
            default:
                break
            }
        }
    }

    /// Corner radius clamped to 4 % of the block's screen width so very small blocks
    /// don't have a radius larger than their dimensions.
    private var clampedCorner: CGFloat { min(8, sw * 0.04) }

    // MARK: - Title bar

    /// Compact single-line header shown at the top of the block.
    /// Font size scales with `scale` but is clamped so it stays legible.
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
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.06))
    }

    // MARK: - Content (full zoom: scale ≥ 0.25)

    @ViewBuilder
    private var blockContent: some View {
        Group {
            switch block.content.kind {
            case "label":
                // Static text label — no live data, just displays block.content.text.
                LabelContent(text: block.content.text, fontSize: block.content.fontSize * scale)

            case "tagMonitor":
                // Scrollable table: tag name | formatted value | quality dot.
                TagMonitorContent(tagIDs: block.content.tagIDs)

            case "statusGrid":
                // Coloured tile grid: green=running, orange=alarm, red=bad quality.
                StatusGridContent(tagIDs: block.content.tagIDs)

            case "alarmPanel":
                // ISA-18.2 active alarm list, capped at maxAlarms rows.
                AlarmPanelContent(maxAlarms: block.content.maxAlarms)

            case "navButton":
                // Tappable button that animates the viewport (operate mode tap handled above).
                NavButtonContent(label: block.content.navLabel) {
                    onNavigate(block.content.navX, block.content.navY, block.content.navScale)
                }

            case "equipment":
                // Industrial equipment icon with running/alarm/stopped colour from a tag.
                EquipmentContent(kind: block.content.equipKind, tagID: block.content.equipTagID)

            case "trendMini":
                // Mini sparklines for up to 3 tags.
                TrendMiniContent(tagIDs: block.content.tagIDs, minutes: block.content.minutes)

            case "hmiScreen":
                // Button-style card showing the linked HMI screen name.
                HMIScreenContent(
                    screenID:   block.content.hmiScreenID,
                    screenName: block.content.hmiScreenName
                ) {
                    onOpenScreen(block.content.hmiScreenID)
                }

            case "screenGroup":
                // Mini grid preview; tap opens CompositeHMIView.
                ScreenGroupContent(
                    entries: block.content.screenGroupEntries,
                    cols:    block.content.screenGroupCols,
                    title:   block.title
                ) {
                    onOpenScreenGroup(block.content.screenGroupEntries,
                                      block.content.screenGroupCols,
                                      block.title)
                }

            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Compact summary (medium zoom: 0.12 ≤ scale < 0.25)

    /// Shown when the block is too small for full content but large enough for a single line.
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

    // MARK: - Selection handles

    /// Four small filled circles at the block corners — visual feedback for selection.
    private var selectionHandles: some View {
        ZStack {
            ForEach([CGPoint(x: 0, y: 0),
                     CGPoint(x: 1, y: 0),
                     CGPoint(x: 0, y: 1),
                     CGPoint(x: 1, y: 1)], id: \.x) { corner in
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    // corner.x/y are normalised (0 or 1) — multiply by screen dimensions.
                    .position(x: corner.x * sw, y: corner.y * sh)
            }
        }
    }

    // MARK: - Drag gesture (design mode)

    /// Moves the block by accumulating the drag translation as a screen-space offset.
    /// On gesture end, converts the offset to canvas-space coordinates and calls onDragEnd.
    private var blockDragGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { v in
                isDragging = true
                // Store raw screen-space translation for live visual feedback.
                dragOffset = CGPoint(x: v.translation.width, y: v.translation.height)
            }
            .onEnded { v in
                isDragging = false
                // Convert screen-space delta to canvas-space delta by dividing by scale.
                let newCanvasX = block.x + v.translation.width  / scale
                let newCanvasY = block.y + v.translation.height / scale
                dragOffset = .zero  // reset so the block snaps to its new persisted position
                onDragEnd(CGPoint(x: newCanvasX, y: newCanvasY))
            }
    }

    // MARK: - Content metadata helpers

    /// SF Symbol icon for the block's content kind (used in title bar and compact summary).
    private var contentIcon: String {
        switch block.content.kind {
        case "label":       return "text.alignleft"
        case "tagMonitor":  return "list.bullet"
        case "statusGrid":  return "square.grid.2x2"
        case "alarmPanel":  return "exclamationmark.triangle"
        case "navButton":   return "arrow.right.circle"
        case "equipment":   return "gearshape"
        case "trendMini":   return "chart.xyaxis.line"
        case "hmiScreen":   return "rectangle.on.rectangle"
        case "screenGroup": return "square.grid.2x2"
        default:            return "square"
        }
    }

    /// Single-line description shown in the compact summary view.
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

/// Constrain `v` to the range [lo, hi].
private func clamp(_ v: CGFloat, lo: CGFloat, hi: CGFloat) -> CGFloat {
    max(lo, min(hi, v))
}
