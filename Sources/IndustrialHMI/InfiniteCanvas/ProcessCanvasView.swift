import SwiftUI
import AppKit

// MARK: - ProcessCanvasView
//
// The main "Process Overview" tab view.
// Renders an infinite scrollable/zoomable canvas containing CanvasBlocks.
//
// ── Coordinate system ────────────────────────────────────────────────────────
//   Canvas space: origin at (0,0), units = logical points.
//   Screen space: canvas point (cx, cy) maps to screen point via:
//     screenX = cx * scale + pan.x
//     screenY = cy * scale + pan.y
//   pan tracks where the canvas origin (0,0) appears in screen space.
//
// ── Interaction ──────────────────────────────────────────────────────────────
//   Zoom:  trackpad pinch  |  Ctrl+scroll  |  ⌘+scroll  |  toolbar ±
//   Pan:   two-finger scroll  |  drag on empty background
//   Edge-pan (operate mode only): cursor within 60 pt of edge → slow auto-pan
//
// ── ZStack layer order (bottom → top) ────────────────────────────────────────
//   1. CanvasScrollCapture (NSView for scroll/magnify events — behind everything)
//   2. CanvasGridView or solid background colour
//   3. Color.clear hit-test layer for background taps/drag (MUST be below blocks)
//   4. ForEach(canvas.blocks) → ProcessCanvasBlockView  ← receives taps first
//   5. Zoom hint toast
//   6. Empty state overlay
//   7. ProcessCanvasInspector (design mode right sidebar)
//   8. Bottom toolbar
//   9. .overlay { CompositeHMIView } (full-screen, slides in from trailing edge)

struct ProcessCanvasView: View {

    @EnvironmentObject var canvasStore:    ProcessCanvasStore
    @EnvironmentObject var tagEngine:      TagEngine
    @EnvironmentObject var alarmManager:   AlarmManager
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var hmiScreenStore: HMIScreenStore

    // MARK: - Viewport state (not persisted — resets on launch)

    /// Current zoom level. 1.0 = 100 %. Clamped to [minScale, maxScale].
    @State private var scale:  CGFloat = 1.0
    /// Screen-space offset of the canvas origin (0,0). Updated by pan gestures and navigation.
    @State private var pan:    CGPoint = .zero

    private let minScale: CGFloat = 0.08
    private let maxScale: CGFloat = 5.0

    // MARK: - Interaction state

    /// True when the toolbar is in Design mode (drag/select blocks, show inspector).
    @State private var isDesigning:    Bool    = false
    /// ID of the block currently selected in design mode. nil = nothing selected.
    @State private var selectedID:     UUID?   = nil
    /// Screen-space start of a background drag gesture. nil when not dragging.
    @State private var panStartPos:    CGPoint?
    /// Value of `pan` at the moment the background drag started.
    @State private var panAtStart:     CGPoint = .zero
    /// Tracks cursor position for edge-auto-pan in operate mode.
    @State private var mouseLocation:  CGPoint = .zero
    /// View size updated by GeometryReader — used by fitToWindow and animateTo.
    @State private var viewSize:       CGSize  = .zero

    // MARK: - Keyboard focus

    @FocusState private var canvasFocused: Bool

    // MARK: - Designer sheets

    @State private var showAddBlock:   Bool    = false
    @State private var showSettings:   Bool    = false

    // MARK: - Composite HMI view (screen group block tap)

    /// Entries captured when a screenGroup block is tapped in operate mode.
    @State private var compositeEntries: [ScreenGroupEntry] = []
    /// Column count for the composite grid layout.
    @State private var compositeCols:    Int    = 2
    /// Title shown in the composite toolbar (taken from the block's title).
    @State private var compositeTitle:   String = ""
    /// Whether the CompositeHMIView overlay is currently visible.
    @State private var showComposite:    Bool   = false

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .topLeading) {

            // Layer 1: Scroll & magnify event capture
            // NSViewRepresentable that intercepts scroll wheel, trackpad magnify, and
            // mouse-moved events before SwiftUI sees them. Reports back via callbacks.
            GeometryReader { geo in
                CanvasScrollCapture(
                    onPan:       { dx, dy in pan.x += dx; pan.y += dy },
                    onZoom:      { factor, pt in applyZoom(factor: factor, at: pt) },
                    onMouseMove: { loc in mouseLocation = loc; viewSize = geo.size },
                    onKeyPan:    { dx, dy in
                        withAnimation(.interactiveSpring()) { pan.x += dx; pan.y += dy }
                    },
                    onKeyZoom:   { factor in applyZoom(factor: factor, at: viewCenter) },
                    onFit:       { fitToWindow(size: geo.size) }
                )
                .onAppear {
                    viewSize = geo.size
                    fitToWindow(size: geo.size)  // fit all blocks on first appear
                }
            }

            // Layer 2: Background — grid or solid fill
            if canvasStore.active?.gridVisible ?? true {
                CanvasGridView(scale: scale, pan: pan,
                               gridSize: canvasStore.active?.gridSize ?? 120)
            } else {
                Color(hex: canvasStore.active?.bgHex ?? "#0D1117")
            }

            // Layer 3: Background tap / drag target
            // IMPORTANT: Must be declared BEFORE the blocks ForEach in this ZStack.
            // In SwiftUI, later children are rendered ON TOP and receive pointer events
            // first. Placing Color.clear here (below the blocks) ensures block views
            // sit on top and capture their own taps — this clear layer only fires when
            // the pointer hits empty canvas space.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    // Deselect block when tapping empty canvas in design mode.
                    if isDesigning { selectedID = nil }
                    canvasFocused = true   // re-acquire keyboard focus
                }
                .gesture(
                    DragGesture()
                        .onChanged { v in
                            // Pan on any background drag (block overlays intercept drags
                            // that start on a block, so this only fires on empty canvas).
                            if panStartPos == nil {
                                panStartPos = CGPoint(x: v.startLocation.x, y: v.startLocation.y)
                                panAtStart  = pan
                                canvasFocused = true   // grab focus when panning
                            }
                            pan = CGPoint(x: panAtStart.x + v.translation.width,
                                          y: panAtStart.y + v.translation.height)
                        }
                        .onEnded { _ in panStartPos = nil }
                )

            // Layer 4: Block views
            // Rendered AFTER the background layers so they sit on top in the ZStack
            // and receive taps before the background tap handler.
            if let canvas = canvasStore.active {
                ForEach(canvas.blocks) { block in
                    ProcessCanvasBlockView(
                        block:        block,
                        scale:        scale,
                        pan:          pan,
                        isSelected:   selectedID == block.id,
                        isDesigning:  isDesigning,

                        // Navigate: animate viewport to the stored navX/navY/navScale target.
                        onNavigate: { tx, ty, ts in animateTo(x: tx, y: ty, scale: ts) },

                        // HMI screen link: switch HMI tab to the linked screen.
                        onOpenScreen: { screenIDStr in
                            if let uid = UUID(uuidString: screenIDStr) {
                                canvasStore.navigateToHMIScreen?(uid)
                            }
                        },

                        // Screen group: capture entries and show the composite overlay.
                        onOpenScreenGroup: { entries, cols, title in
                            compositeEntries = entries
                            compositeCols    = cols
                            compositeTitle   = title
                            showComposite    = true
                        },

                        // Design-mode callbacks
                        onSelect:  { selectedID = block.id },
                        onDragEnd: { newPos in
                            var updated = block
                            updated.x = newPos.x
                            updated.y = newPos.y
                            canvasStore.updateBlock(updated)
                        }
                    )
                }
            }

            // Layer 5: Zoom hint toast
            // Blocks exist but are too small (scale < 0.25) to render their content.
            // Prompt the operator to zoom in. Non-interactive so it doesn't block taps.
            if !(canvasStore.active?.blocks.isEmpty ?? true) && scale < 0.25 {
                VStack {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                        Text("Pinch or Ctrl+scroll to zoom in and see block content")
                    }
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.6), in: Capsule())
                    .padding(.top, 12)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .animation(.easeInOut(duration: 0.25), value: scale < 0.25)
                .allowsHitTesting(false)
            }

            // Layer 6: Empty state overlay
            // Shown when the canvas has no blocks — guides the user to design mode.
            if canvasStore.active?.blocks.isEmpty ?? true {
                emptyStateOverlay
            }

            // Layer 7: Design-mode inspector (right sidebar, 260 pt wide)
            if isDesigning {
                HStack(spacing: 0) {
                    Spacer()
                    ProcessCanvasInspector(
                        selectedBlock: selectedBinding,
                        onDelete: {
                            if let id = selectedID {
                                canvasStore.deleteBlock(id)
                                selectedID = nil
                            }
                        }
                    )
                    .frame(width: 260)
                    .background(.regularMaterial)
                }
            }

            // Layer 8: Bottom toolbar (mode toggle, zoom controls, canvas switcher)
            VStack {
                Spacer()
                canvasToolbar
            }

            // Layer 9: Mini-map — bottom-left corner, shows all blocks + viewport rectangle.
            // Tap or drag to navigate the canvas instantly.
            if let blocks = canvasStore.active?.blocks, !blocks.isEmpty {
                VStack {
                    Spacer()
                    HStack(alignment: .bottom) {
                        ProcessCanvasMiniMap(
                            blocks:   blocks,
                            scale:    scale,
                            pan:      pan,
                            viewSize: viewSize
                        ) { cx, cy in
                            // Navigate viewport centre to tapped canvas point, keep current zoom.
                            animateTo(x: cx, y: cy, scale: Double(scale))
                        }
                        .padding(.leading, 14)
                        // Sit above the 52-pt toolbar (padding + border)
                        .padding(.bottom, 56)
                        Spacer()
                    }
                }
                .allowsHitTesting(true)
                .ignoresSafeArea()
            }
        }
        .clipped()
        .background(Color(hex: canvasStore.active?.bgHex ?? "#0D1117"))

        // Add block and canvas-settings sheets
        .sheet(isPresented: $showAddBlock) {
            AddBlockSheet { block in
                // Convert viewport centre from screen space to canvas space,
                // then centre the new block on that point.
                let cx = (viewSize.width  / 2 - pan.x) / scale
                let cy = (viewSize.height / 2 - pan.y) / scale
                var b  = block
                b.x    = cx - b.w / 2
                b.y    = cy - b.h / 2
                canvasStore.addBlock(b)
                selectedID = b.id
            }
        }
        .sheet(isPresented: $showSettings) {
            CanvasSettingsSheet()
        }

        // Layer 9: Full-screen composite HMI overlay (screen group)
        // Slides in from the trailing edge when a screenGroup block is tapped.
        .overlay {
            if showComposite {
                CompositeHMIView(
                    entries:   compositeEntries,
                    cols:      compositeCols,
                    title:     compositeTitle,
                    onDismiss: { showComposite = false }
                )
                .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showComposite)

        // MARK: - Keyboard focus + navigation shortcuts
        //
        //   Arrow keys (plain)     — pan 50 pt
        //   Arrow keys (⇧ Shift)   — pan 200 pt (fast scroll)
        //   = / +                  — zoom in  ×1.25
        //   -                      — zoom out ×0.8
        //   0 or f                 — fit all blocks to window
        //
        .focusable()
        .focused($canvasFocused)
        .onKeyPress(.leftArrow, phases: .down) { press in
            let step: CGFloat = press.modifiers.contains(.shift) ? 200 : 50
            withAnimation(.interactiveSpring()) { pan.x += step }
            return .handled
        }
        .onKeyPress(.rightArrow, phases: .down) { press in
            let step: CGFloat = press.modifiers.contains(.shift) ? 200 : 50
            withAnimation(.interactiveSpring()) { pan.x -= step }
            return .handled
        }
        .onKeyPress(.upArrow, phases: .down) { press in
            let step: CGFloat = press.modifiers.contains(.shift) ? 200 : 50
            withAnimation(.interactiveSpring()) { pan.y += step }
            return .handled
        }
        .onKeyPress(.downArrow, phases: .down) { press in
            let step: CGFloat = press.modifiers.contains(.shift) ? 200 : 50
            withAnimation(.interactiveSpring()) { pan.y -= step }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "=+"), phases: .down) { _ in
            applyZoom(factor: 1.25, at: viewCenter); return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "-"), phases: .down) { _ in
            applyZoom(factor: 0.8, at: viewCenter); return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "0f"), phases: .down) { _ in
            fitToWindow(size: viewSize); return .handled
        }

        .onAppear {
            canvasFocused = true
            startEdgePanTimer()
        }

        // Auto-zoom to selected block when selection changes in design mode.
        .onChange(of: selectedID) { _, newID in
            guard isDesigning,
                  let id = newID,
                  let block = canvasStore.active?.blocks.first(where: { $0.id == id })
            else { return }
            centerOnBlock(block)
        }
    }

    // MARK: - Selected block binding for inspector

    /// Creates a two-way binding between the inspector and the canvas store.
    /// get: finds the selected block by ID in the active canvas.
    /// set: persists the updated block via canvasStore.updateBlock.
    private var selectedBinding: Binding<CanvasBlock?> {
        Binding(
            get: {
                guard let id = selectedID else { return nil }
                return canvasStore.active?.blocks.first { $0.id == id }
            },
            set: { newValue in
                if let b = newValue { canvasStore.updateBlock(b) }
            }
        )
    }

    // MARK: - Bottom Toolbar

    private var canvasToolbar: some View {
        HStack(spacing: 10) {

            // Design / Operate mode toggle
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isDesigning.toggle() }
                if !isDesigning { selectedID = nil }  // clear selection on exit
            } label: {
                Label(isDesigning ? "Designing" : "Operating",
                      systemImage: isDesigning ? "pencil.circle.fill" : "play.circle.fill")
                    .font(.caption.bold())
            }
            .buttonStyle(.bordered)
            .tint(isDesigning ? .orange : .green)
            .help(isDesigning ? "Switch to Operate mode" : "Switch to Design mode")

            Divider().frame(height: 20)

            // Design-only buttons
            if isDesigning {
                Button { showAddBlock = true } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .buttonStyle(.bordered)
                .help("Add a new block to the canvas")

                Button { showSettings = true } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .help("Canvas name, background, and grid settings")

                Divider().frame(height: 20)
            }

            // Canvas switcher (only shown when more than one canvas exists)
            if canvasStore.canvases.count > 1 {
                Menu {
                    ForEach(canvasStore.canvases) { c in
                        Button(c.name) {
                            canvasStore.activeID = c.id
                            fitToWindow(size: viewSize)
                        }
                    }
                    Divider()
                    Button("New Canvas…") { canvasStore.newCanvas() }
                } label: {
                    Label(canvasStore.active?.name ?? "Canvas", systemImage: "square.stack")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                Divider().frame(height: 20)
            }

            Spacer()

            // Zoom percentage indicator
            Text("\(Int(scale * 100))%")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 42, alignment: .trailing)

            // Zoom controls
            Button { applyZoom(factor: 0.8,  at: viewCenter) } label: { Image(systemName: "minus.magnifyingglass") }
                .buttonStyle(.bordered)
            Button { applyZoom(factor: 1.25, at: viewCenter) } label: { Image(systemName: "plus.magnifyingglass")  }
                .buttonStyle(.bordered)
            Button { fitToWindow(size: viewSize) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .buttonStyle(.bordered)
                .help("Fit all blocks in the window")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    /// Screen-space point at the centre of the visible area.
    private var viewCenter: CGPoint { CGPoint(x: viewSize.width / 2, y: viewSize.height / 2) }

    // MARK: - Empty state overlay

    private var emptyStateOverlay: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.grid.3x3.fill")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))
            Text("Process Canvas is Empty")
                .font(.title2.bold())
                .foregroundColor(.white)
            Text("Switch to **Design** mode to add blocks — tag monitors,\nalarm panels, equipment icons, HMI screen links, and more.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isDesigning = true }
                showAddBlock = true
            } label: {
                Label("Enter Design Mode & Add Block", systemImage: "pencil.circle.fill")
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding(40)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // MARK: - Zoom

    /// Apply a multiplicative zoom factor centred on `screenPt`.
    ///
    /// The zoom is anchored so that the canvas point under `screenPt` stays fixed:
    ///   canvasPt = (screenPt - pan) / oldScale
    ///   newPan   = screenPt - canvasPt * newScale
    func applyZoom(factor: CGFloat, at screenPt: CGPoint) {
        let oldScale = scale
        let newScale = (oldScale * factor).clamped(to: minScale...maxScale)
        let canvasPt = CGPoint(x: (screenPt.x - pan.x) / oldScale,
                               y: (screenPt.y - pan.y) / oldScale)
        withAnimation(.interactiveSpring()) {
            scale = newScale
            pan.x = screenPt.x - canvasPt.x * newScale
            pan.y = screenPt.y - canvasPt.y * newScale
        }
    }

    // MARK: - Animated navigation

    /// Animate the viewport so that `block` is centred and fully visible.
    ///
    /// The target scale is the larger of:
    ///   (a) the current scale (never zooms out automatically), and
    ///   (b) a scale that makes the block fill 70 % of the available area.
    /// The result is clamped to [0.50, maxScale] so content is always readable.
    private func centerOnBlock(_ block: CanvasBlock) {
        let cx = block.x + block.w / 2
        let cy = block.y + block.h / 2
        // Available area excludes the inspector panel (280 pt) and toolbar padding (80 pt).
        let availW = (isDesigning ? viewSize.width - 280 : viewSize.width) - 80
        let availH = viewSize.height - 100
        let fitScale  = min(availW / CGFloat(block.w), availH / CGFloat(block.h)) * 0.70
        let targetScale = max(scale, fitScale).clamped(to: 0.50...maxScale)
        animateTo(x: cx, y: cy, scale: Double(targetScale))
    }

    /// Animate the viewport so that canvas point (x, y) is at the screen centre, at `scale`.
    func animateTo(x: Double, y: Double, scale targetScale: Double) {
        let ts = CGFloat(targetScale).clamped(to: minScale...maxScale)
        // Convert canvas centre to screen space, then solve for pan:
        //   screenCentre = canvasPt * ts + pan  →  pan = screenCentre - canvasPt * ts
        let sc = CGFloat(x) * ts
        let sy = CGFloat(y) * ts
        withAnimation(.easeInOut(duration: 0.55)) {
            scale = ts
            pan   = CGPoint(x: viewSize.width  / 2 - sc,
                            y: viewSize.height / 2 - sy)
        }
    }

    // MARK: - Fit to window

    /// Compute scale and pan so that all blocks are visible with 80-pt padding on each side.
    func fitToWindow(size: CGSize) {
        guard let blocks = canvasStore.active?.blocks, !blocks.isEmpty else {
            // Nothing to fit — reset to 1:1 at origin.
            scale = 1.0; pan = .zero; return
        }
        // Bounding box of all blocks in canvas space.
        let minX = blocks.map { $0.x }.min()!
        let minY = blocks.map { $0.y }.min()!
        let maxX = blocks.map { $0.x + $0.w }.max()!
        let maxY = blocks.map { $0.y + $0.h }.max()!
        let cw = maxX - minX
        let ch = maxY - minY
        let padding = 80.0
        // Uniform scale that fits the bounding box inside the padded viewport.
        let s = min((size.width  - padding) / cw,
                    (size.height - padding) / ch,
                    maxScale)
        withAnimation(.easeInOut(duration: 0.4)) {
            scale = CGFloat(s)
            // Centre the bounding box in the viewport.
            pan   = CGPoint(
                x: (size.width  - CGFloat(cw) * CGFloat(s)) / 2 - CGFloat(minX) * CGFloat(s),
                y: (size.height - CGFloat(ch) * CGFloat(s)) / 2 - CGFloat(minY) * CGFloat(s)
            )
        }
    }

    // MARK: - Edge auto-pan (operate mode only)

    /// Starts a 60 fps timer that slowly pans the canvas when the cursor approaches
    /// within 60 pt of any window edge — lets operators scroll large canvases without
    /// needing to use the trackpad while watching live values.
    private func startEdgePanTimer() {
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
            Task { @MainActor in
                guard !isDesigning, viewSize != .zero else { return }
                let margin: CGFloat = 60    // edge zone width in screen points
                let speed:  CGFloat = 6     // maximum pan pixels per frame at full proximity
                var dx: CGFloat = 0, dy: CGFloat = 0
                let m = mouseLocation
                let s = viewSize
                // Linear falloff from `speed` at the edge to 0 at `margin` distance.
                if m.x > 0 && m.x < margin        { dx =  speed * (1 - m.x / margin) }
                if m.x > s.width - margin          { dx = -speed * (1 - (s.width  - m.x) / margin) }
                if m.y > 0 && m.y < margin         { dy =  speed * (1 - m.y / margin) }
                if m.y > s.height - margin         { dy = -speed * (1 - (s.height - m.y) / margin) }
                if dx != 0 || dy != 0 { pan.x += dx; pan.y += dy }
            }
        }
    }
}

// MARK: - Comparable clamp helper

extension Comparable {
    /// Clamp self to [range.lowerBound, range.upperBound].
    func clamped(to range: ClosedRange<Self>) -> Self {
        max(range.lowerBound, min(range.upperBound, self))
    }
}

// MARK: - Canvas Grid Background

/// Infinite dot-grid background drawn with a SwiftUI Canvas.
/// Uses the pan offset modulo the grid spacing so only the visible portion is drawn —
/// no matter how far the user pans, exactly one screen worth of lines is rendered.
struct CanvasGridView: View {
    let scale:    CGFloat
    let pan:      CGPoint
    let gridSize: Double

    var body: some View {
        Canvas { ctx, size in
            // Scale the grid spacing — hide the grid when it would be too dense (< 6 pt).
            let gs  = CGFloat(gridSize) * scale
            guard gs > 6 else { return }

            // Offset within one grid cell — makes the grid scroll with the pan.
            let ox  = pan.x.truncatingRemainder(dividingBy: gs)
            let oy  = pan.y.truncatingRemainder(dividingBy: gs)
            let col = Color.white.opacity(0.055)

            // Vertical lines
            var x = ox
            while x < size.width {
                ctx.stroke(
                    Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)) },
                    with: .color(col)
                )
                x += gs
            }
            // Horizontal lines
            var y = oy
            while y < size.height {
                ctx.stroke(
                    Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)) },
                    with: .color(col)
                )
                y += gs
            }
        }
        .background(Color(hex: "#0D1117"))
    }
}

// MARK: - Scroll + Magnify capture via NSView
//
// SwiftUI does not expose raw scroll-wheel events or trackpad magnification on macOS.
// We wrap an NSView that overrides scrollWheel(with:) and magnify(with:) and forwards
// the deltas to SwiftUI via callback closures.
//
// The view is placed at the bottom of the ZStack (declared first) so it covers the
// whole canvas but sits behind all SwiftUI views — it only intercepts events that
// SwiftUI itself doesn't consume.

/// SwiftUI wrapper for `_CanvasNSView` — forwards scroll, pinch, and mouse events.
struct CanvasScrollCapture: NSViewRepresentable {
    var onPan:       (CGFloat, CGFloat) -> Void
    var onZoom:      (CGFloat, CGPoint) -> Void
    var onMouseMove: (CGPoint) -> Void
    var onKeyPan:    (CGFloat, CGFloat) -> Void
    var onKeyZoom:   (CGFloat) -> Void
    var onFit:       () -> Void

    func makeNSView(context: Context) -> _CanvasNSView {
        let v = _CanvasNSView()
        v.onPan       = onPan
        v.onZoom      = onZoom
        v.onMouseMove = onMouseMove
        v.onKeyPan    = onKeyPan
        v.onKeyZoom   = onKeyZoom
        v.onFit       = onFit
        return v
    }

    func updateNSView(_ v: _CanvasNSView, context: Context) {
        v.onPan       = onPan
        v.onZoom      = onZoom
        v.onMouseMove = onMouseMove
        v.onKeyPan    = onKeyPan
        v.onKeyZoom   = onKeyZoom
        v.onFit       = onFit
    }
}

// MARK: - ProcessCanvasMiniMap
//
// A 180×112-pt thumbnail of the entire canvas shown in the bottom-left corner.
// It renders all blocks as filled rectangles and the current viewport as a blue
// bordered rectangle.  Tap or drag on the minimap to pan the main canvas.
//
// Coordinate mapping:
//   contentBounds  — bounding box of all blocks with 200-pt margin, in canvas space
//   mapScale       — uniform scale that fits contentBounds inside the minimap
//   toMap(cx, cy)  — canvas → minimap pixel
//   toCanvas(mx,my)— minimap pixel → canvas centre

struct ProcessCanvasMiniMap: View {
    let blocks:    [CanvasBlock]
    let scale:     CGFloat
    let pan:       CGPoint
    let viewSize:  CGSize
    var onNavigate: (Double, Double) -> Void

    private let mapW:     CGFloat = 180
    private let mapH:     CGFloat = 112
    private let mapPad:   CGFloat = 6

    // Bounding box of all content with a comfortable margin.
    private var contentBounds: CGRect {
        guard !blocks.isEmpty else { return CGRect(x: 0, y: 0, width: 1280, height: 800) }
        let minX = blocks.map { $0.x }.min()! - 200
        let minY = blocks.map { $0.y }.min()! - 200
        let maxX = blocks.map { $0.x + $0.w }.max()! + 200
        let maxY = blocks.map { $0.y + $0.h }.max()! + 200
        return CGRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
    }

    // Uniform scale: canvas → minimap pixels.
    private var mapScale: CGFloat {
        min((mapW - mapPad * 2) / contentBounds.width,
            (mapH - mapPad * 2) / contentBounds.height)
    }

    private func toMap(_ cx: Double, _ cy: Double) -> CGPoint {
        CGPoint(
            x: (cx - contentBounds.minX) * mapScale + mapPad,
            y: (cy - contentBounds.minY) * mapScale + mapPad
        )
    }

    private func toCanvas(_ mx: CGFloat, _ my: CGFloat) -> (Double, Double) {
        let cx = (mx - mapPad) / mapScale + contentBounds.minX
        let cy = (my - mapPad) / mapScale + contentBounds.minY
        return (Double(cx), Double(cy))
    }

    // The visible viewport expressed as a rectangle in minimap space.
    private var viewportRect: CGRect {
        guard viewSize != .zero, scale > 0 else { return .zero }
        let vpMinX = -pan.x / scale
        let vpMinY = -pan.y / scale
        let vpMaxX = (viewSize.width  - pan.x) / scale
        let vpMaxY = (viewSize.height - pan.y) / scale
        let tl = toMap(Double(vpMinX), Double(vpMinY))
        let br = toMap(Double(vpMaxX), Double(vpMaxY))
        return CGRect(x: tl.x, y: tl.y, width: br.x - tl.x, height: br.y - tl.y)
    }

    var body: some View {
        Canvas { ctx, _ in
            // Draw each block as a small filled rect.
            for block in blocks {
                let tl   = toMap(block.x, block.y)
                let br   = toMap(block.x + block.w, block.y + block.h)
                let rect = CGRect(x: tl.x, y: tl.y,
                                  width: max(br.x - tl.x, 1), height: max(br.y - tl.y, 1))
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1),
                         with: .color(.white.opacity(0.55)))
            }
            // Draw the current viewport rectangle.
            let vp = viewportRect
            if vp.width > 1 && vp.height > 1 {
                let clipped = CGRect(
                    x: max(vp.minX, mapPad - 1), y: max(vp.minY, mapPad - 1),
                    width:  min(vp.width,  mapW - mapPad * 2 + 2),
                    height: min(vp.height, mapH - mapPad * 2 + 2)
                )
                ctx.fill(Path(clipped), with: .color(.blue.opacity(0.12)))
                ctx.stroke(Path(clipped), with: .color(.cyan.opacity(0.85)), lineWidth: 1.0)
            }
        }
        .frame(width: mapW, height: mapH)
        .background(Color.black.opacity(0.70))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 5))
        // Tap or drag anywhere on the minimap to navigate.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let (cx, cy) = toCanvas(v.location.x, v.location.y)
                    onNavigate(cx, cy)
                }
        )
        .help("Mini-map — tap or drag to navigate")
    }
}

/// Raw NSView that captures scroll wheel, magnification, mouse-move, and keyboard events.
/// Named with underscore prefix to indicate it is an internal implementation detail.
final class _CanvasNSView: NSView {
    var onPan:       ((CGFloat, CGFloat) -> Void)?
    var onZoom:      ((CGFloat, CGPoint) -> Void)?
    var onMouseMove: ((CGPoint) -> Void)?
    var onKeyPan:    ((CGFloat, CGFloat) -> Void)?   // keyboard arrow pan (dx, dy)
    var onKeyZoom:   ((CGFloat) -> Void)?            // keyboard zoom factor
    var onFit:       (() -> Void)?                   // fit to window (key 0)

    /// Match SwiftUI's coordinate system (Y increases downward).
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let opts: NSTrackingArea.Options = [
            .mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect
        ]
        addTrackingArea(NSTrackingArea(rect: .zero, options: opts, owner: self, userInfo: nil))
    }

    // Become first responder on click so keyboard events are received.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    // MARK: - Keyboard navigation
    //
    //   Arrow keys          — pan 20 pt (Shift = 100 pt)
    //   = / + / Cmd+=       — zoom in  ×1.25
    //   - / Cmd+-           — zoom out ×0.8
    //   0 / Cmd+0           — fit to window
    //   All other keys      — passed to super (system shortcuts, etc.)

    override func keyDown(with event: NSEvent) {
        let shift    = event.modifierFlags.contains(.shift)
        let step: CGFloat = shift ? 100 : 20

        switch event.keyCode {
        case 123: onKeyPan?( step,     0)     // ← left arrow  → pan canvas right
        case 124: onKeyPan?(-step,     0)     // → right arrow → pan canvas left
        case 126: onKeyPan?(0,         step)  // ↑ up arrow    → pan canvas down
        case 125: onKeyPan?(0,        -step)  // ↓ down arrow  → pan canvas up
        case 24, 69:  onKeyZoom?(1.25)        // = / numpad+   → zoom in
        case 27:      onKeyZoom?(0.8)         // -             → zoom out
        case 29:      onFit?()               // 0             → fit to window
        default:  super.keyDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let loc = flippedLoc(event)
        // Trackpad: hasPreciseScrollingDeltas = true, deltas are in screen points.
        // Scroll wheel: hasPreciseScrollingDeltas = false, deltas are in notch counts (~3 pt each).
        // Apply 10× multiplier for scroll wheels to make navigation feel natural.
        let m: CGFloat = event.hasPreciseScrollingDeltas ? 1.0 : 10.0
        // Control or Command held = zoom instead of pan.
        let isZoom = event.modifierFlags.contains(.control) || event.modifierFlags.contains(.command)
        if isZoom {
            // Map scroll delta to a zoom factor. 0.005 gives ~5 % change per scroll notch.
            let delta  = CGFloat(event.scrollingDeltaY) * m
            let factor = 1.0 - delta * 0.005
            onZoom?(factor, loc)
        } else {
            onPan?(CGFloat(event.scrollingDeltaX) * m, CGFloat(event.scrollingDeltaY) * m)
        }
    }

    /// Trackpad pinch-to-zoom.
    override func magnify(with event: NSEvent) {
        // event.magnification is the fractional change (e.g. 0.1 = 10% larger).
        let factor = 1.0 + CGFloat(event.magnification)
        onZoom?(factor, flippedLoc(event))
    }

    override func mouseMoved(with event: NSEvent) {
        onMouseMove?(flippedLoc(event))
    }

    /// Convert NSEvent.locationInWindow to the NSView's flipped coordinate space.
    private func flippedLoc(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x, y: p.y)   // isFlipped=true already inverts Y
    }
}
