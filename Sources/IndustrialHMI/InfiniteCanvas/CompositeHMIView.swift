import SwiftUI
import AppKit

// MARK: - CompositeHMIView
//
// A full-screen infinite canvas that renders multiple HMI screens side-by-side
// in a configurable grid, giving the operator the impression of one very large display.
//
// ── Grid layout ──────────────────────────────────────────────────────────────
//   col = index % cols
//   row = index / cols
//   Cell top-left in canvas space: (col * cellW, row * cellH)
//   Cell screen position: col * cellW * scale + pan.x, row * cellH * scale + pan.y
//
// ── Viewport coordinate system ───────────────────────────────────────────────
//   Identical to ProcessCanvasView:
//     screenX = canvasX * scale + pan.x
//     screenY = canvasY * scale + pan.y
//   pan.x = pan.y = 0 means the canvas origin is at the screen origin (top-left).
//
// ── Cell size ────────────────────────────────────────────────────────────────
//   cellW × cellH = 1280 × 800 canvas units (matches HMIScreen default canvas size).
//   This ensures that HMI objects drawn at 1:1 in the HMI designer render at full
//   fidelity when the composite view is zoomed to scale = 1.0.
//
// ── View stack (ZStack bottom → top) ─────────────────────────────────────────
//   1. Solid background (#0A0E17 — matches the HMI canvas dark theme)
//   2. CanvasScrollCapture — intercepts scroll/magnify events (same as ProcessCanvasView)
//   3. Background drag gesture for panning
//   4. HMIScreenCell views (read-only, allowsHitTesting = false)
//   5. Canvas overlay with thin grid separator lines
//   6. Top toolbar (Back, title, zoom controls)

struct CompositeHMIView: View {

    /// Ordered list of screen references from the ScreenGroup block.
    let entries: [ScreenGroupEntry]
    /// Number of grid columns (rows = ceil(count / cols)).
    let cols:    Int
    /// Displayed in the toolbar — taken from the ScreenGroup block's title.
    let title:   String
    /// Called when the operator presses Back — hides this overlay in ProcessCanvasView.
    var onDismiss: () -> Void

    @EnvironmentObject var hmiScreenStore: HMIScreenStore
    @EnvironmentObject var tagEngine:      TagEngine
    @EnvironmentObject var alarmManager:   AlarmManager

    // MARK: - Viewport state

    @State private var scale:    CGFloat = 1.0
    @State private var pan:      CGPoint = .zero
    @State private var viewSize: CGSize  = .zero

    // MARK: - Pan gesture state

    @State private var panStart:   CGPoint?
    @State private var panAtStart: CGPoint = .zero

    private let minScale: CGFloat = 0.03
    private let maxScale: CGFloat = 4.0

    // MARK: - Loaded screen data

    /// Screen data keyed by hmiScreenID (UUID string).
    /// Populated by loadAllScreens() in .onAppear.
    @State private var screens: [String: HMIScreen] = [:]

    // MARK: - Cell size constants

    /// Default HMI canvas width in canvas units (must match HMIScreen.canvasWidth).
    private let cellW: CGFloat = 1280
    /// Default HMI canvas height in canvas units (must match HMIScreen.canvasHeight).
    private let cellH: CGFloat = 800

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .topLeading) {

            // Layer 1: Solid background
            Color(hex: "#0A0E17").ignoresSafeArea()

            // Layer 2: Scroll / magnify event capture
            // Same NSViewRepresentable pattern as ProcessCanvasView.
            GeometryReader { geo in
                CanvasScrollCapture(
                    onPan:       { dx, dy in pan.x += dx; pan.y += dy },
                    onZoom:      { factor, pt in applyZoom(factor: factor, at: pt) },
                    onMouseMove: { _ in }   // edge auto-pan not needed in read-only composite
                )
                .onAppear {
                    viewSize = geo.size
                    fitAll(size: geo.size)   // auto-fit all screens on open
                    loadAllScreens()         // load screen JSON from disk
                }
            }

            // Layer 3: Background drag-to-pan
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { v in
                            if panStart == nil {
                                panStart   = CGPoint(x: v.startLocation.x, y: v.startLocation.y)
                                panAtStart = pan
                            }
                            pan = CGPoint(x: panAtStart.x + v.translation.width,
                                          y: panAtStart.y + v.translation.height)
                        }
                        .onEnded { _ in panStart = nil }
                )

            // Layer 4: HMI screen cells
            // Each cell renders one HMIScreen's objects at the composite canvas scale.
            // allowsHitTesting = false — this is a read-only display; operators cannot
            // interact with individual HMI objects from the composite view.
            ForEach(0..<entries.count, id: \.self) { i in
                let entry  = entries[i]
                let col    = CGFloat(i % max(1, cols))
                let row    = CGFloat(i / max(1, cols))
                let cellSW = cellW * scale   // screen width of one cell
                let cellSH = cellH * scale   // screen height of one cell
                // Screen-space position of this cell's top-left corner
                let cx     = col * cellSW + pan.x
                let cy     = row * cellSH + pan.y

                HMIScreenCell(
                    screen:       screens[entry.hmiScreenID],
                    previewScale: scale,
                    cellW:        Double(cellW),
                    cellH:        Double(cellH),
                    name:         entry.hmiScreenName
                )
                .frame(width: max(cellSW, 1), height: max(cellSH, 1))
                // SwiftUI .position() anchors at the view centre — offset by half dimensions.
                .position(x: cx + cellSW / 2, y: cy + cellSH / 2)
                .allowsHitTesting(false)
            }

            // Layer 5: Thin grid separator lines between cells
            // Drawn with a SwiftUI Canvas (no hit-testing — visual only).
            Canvas { ctx, size in
                let strokeColor = Color.white.opacity(0.18)
                let rows       = entries.isEmpty ? 0 : (entries.count - 1) / max(1, cols) + 1
                let actualCols = min(cols, entries.count)
                // Vertical separator lines (between columns)
                for c in 1..<actualCols {
                    let x = CGFloat(c) * cellW * scale + pan.x
                    ctx.stroke(
                        Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)) },
                        with: .color(strokeColor)
                    )
                }
                // Horizontal separator lines (between rows)
                for r in 1..<rows {
                    let y = CGFloat(r) * cellH * scale + pan.y
                    ctx.stroke(
                        Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)) },
                        with: .color(strokeColor)
                    )
                }
            }
            .allowsHitTesting(false)

            // Layer 6: Top toolbar
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    // Back button — dismisses the composite overlay and returns to canvas
                    Button { onDismiss() } label: {
                        Label("Back", systemImage: "arrow.backward")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: "#1D4ED8"))

                    Text(title)
                        .font(.subheadline.bold())
                        .foregroundColor(.white)

                    Spacer()

                    // Zoom percentage readout
                    Text("\(Int(scale * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 42, alignment: .trailing)

                    // Zoom controls
                    Button { applyZoom(factor: 0.8,  at: viewCenter) } label: { Image(systemName: "minus.magnifyingglass") }
                        .buttonStyle(.bordered)
                    Button { applyZoom(factor: 1.25, at: viewCenter) } label: { Image(systemName: "plus.magnifyingglass")  }
                        .buttonStyle(.bordered)
                    Button { fitAll(size: viewSize)                  } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .buttonStyle(.bordered)
                        .help("Fit all screens")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)

                Divider()
                Spacer()
            }
        }
        .clipped()
    }

    // MARK: - Helpers

    private var viewCenter: CGPoint { CGPoint(x: viewSize.width / 2, y: viewSize.height / 2) }

    /// Apply a multiplicative zoom centred on `pt` (same algorithm as ProcessCanvasView).
    private func applyZoom(factor: CGFloat, at pt: CGPoint) {
        let old = scale
        let new = (old * factor).clamped(to: minScale...maxScale)
        // Canvas point that stays fixed under the cursor
        let cp  = CGPoint(x: (pt.x - pan.x) / old, y: (pt.y - pan.y) / old)
        withAnimation(.interactiveSpring()) {
            scale = new
            pan.x = pt.x - cp.x * new
            pan.y = pt.y - cp.y * new
        }
    }

    /// Compute scale and pan so the entire grid of screens fits in the visible area.
    /// Called automatically on appear and when the "fit all" button is pressed.
    private func fitAll(size: CGSize) {
        guard !entries.isEmpty else { return }
        let usedCols = min(cols, entries.count)
        let usedRows = (entries.count + cols - 1) / cols
        let totalW   = CGFloat(usedCols) * cellW
        let totalH   = CGFloat(usedRows) * cellH
        let padding: CGFloat = 40
        // Uniform scale that fits the full grid inside the window minus the toolbar (60 pt).
        let s = min((size.width  - padding) / totalW,
                    (size.height - 60 - padding) / totalH,
                    maxScale)
        withAnimation(.easeInOut(duration: 0.4)) {
            scale = s
            // Centre the grid horizontally and vertically below the toolbar.
            pan   = CGPoint(x: (size.width  - totalW * s) / 2,
                            y: 60 + (size.height - 60 - totalH * s) / 2)
        }
    }

    /// Load all referenced screens from disk without changing HMIScreenStore's global state.
    /// Uses HMIScreenStore.loadScreen(id:) which reads the per-screen JSON file directly.
    private func loadAllScreens() {
        for entry in entries {
            guard !entry.hmiScreenID.isEmpty,
                  let id = UUID(uuidString: entry.hmiScreenID)
            else { continue }
            if let loaded = hmiScreenStore.loadScreen(id: id) {
                screens[entry.hmiScreenID] = loaded
            }
        }
    }
}

// MARK: - HMIScreenCell
//
// Renders one HMIScreen's objects inside a fixed-size cell of the composite grid.
//
// Object positioning formula (identical to HMICanvasView):
//   screenX = obj.x * scale + obj.width  * scale / 2   (.position() uses centre)
//   screenY = obj.y * scale + obj.height * scale / 2
//
// The cell is read-only — HMIObjectView receives isEditMode = false and
// all mutation callbacks are no-ops.
//
// A name badge fades in when scale > 0.12 to help orient the operator.

/// Read-only renderer for one HMI screen inside the composite grid.
struct HMIScreenCell: View {
    /// Screen data loaded from disk (nil = still loading → shows a ProgressView placeholder).
    let screen:       HMIScreen?
    /// Current composite canvas zoom level — passed to HMIObjectView for LOD/scale.
    let previewScale: CGFloat
    /// Logical canvas width of the cell (matches HMIScreen default = 1280).
    let cellW:        Double
    /// Logical canvas height of the cell (matches HMIScreen default = 800).
    let cellH:        Double
    /// Screen name shown in the badge overlay.
    let name:         String

    @EnvironmentObject var tagEngine:    TagEngine
    @EnvironmentObject var alarmManager: AlarmManager

    var body: some View {
        ZStack(alignment: .topLeading) {

            // Background — use the screen's configured background colour if loaded
            (screen?.backgroundColor.color ?? Color(hex: "#111827"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // HMI objects rendered at composite scale
            if let screen = screen {
                ForEach(screen.objects.sorted { $0.zIndex < $1.zIndex }) { obj in
                    // Resolve live tag value from TagEngine by name
                    let tagName = obj.tagBinding?.tagName ?? ""
                    let liveTag = tagName.isEmpty ? nil : tagEngine.getTag(named: tagName)
                    // Check whether any active alarm matches this object's tag
                    let hasAlarm = liveTag.map { tag in
                        alarmManager.activeAlarms.contains { $0.tagName == tag.name && $0.state.requiresAction }
                    } ?? false

                    HMIObjectView(
                        object:          obj,
                        scale:           previewScale,
                        isSelected:      false,   // never selected in composite view
                        isEditMode:      false,   // read-only display
                        liveTag:         liveTag,
                        hasActiveAlarm:  hasAlarm,
                        sparklinePoints: [],      // sparklines not populated in composite view
                        onSelect:        {},      // no-op
                        onDrag:          { _ in },
                        onResizeHandle:  { _, _ in }
                    )
                    // Position using the same formula as HMICanvasView:
                    // .position() takes the view centre, so offset by half width/height.
                    .position(
                        x: obj.x * previewScale + obj.width  * previewScale / 2,
                        y: obj.y * previewScale + obj.height * previewScale / 2
                    )
                }
            } else {
                // Loading placeholder shown while loadAllScreens() is in progress
                VStack(spacing: 8) {
                    ProgressView()
                    Text(name).font(.caption).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Screen name badge — fades at very small scales to avoid clutter
            if previewScale > 0.12 {
                Text(name)
                    .font(.system(size: min(14, max(8, 13 * previewScale)), weight: .semibold))
                    .foregroundColor(.white.opacity(0.65))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.45))
                    .cornerRadius(4)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .clipped()
    }
}
