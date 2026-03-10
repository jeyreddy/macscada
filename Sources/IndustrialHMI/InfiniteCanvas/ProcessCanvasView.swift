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

    @State private var compositeEntries: [ScreenGroupEntry] = []
    @State private var compositeCols:    Int    = 2
    @State private var compositeTitle:   String = ""
    @State private var showComposite:    Bool   = false

    // MARK: - Space+drag panning

    /// True while the Space bar is held down — enables pan from any surface (even over blocks).
    @State private var spaceHeld:    Bool    = false
    @State private var keyMonitors:  [Any]   = []

    // MARK: - Alarm bubble

    /// Alarm shown in the bubble. nil = bubble not visible.
    @State private var toastAlarm:       Alarm?  = nil
    @State private var toastPopping:     Bool    = false
    @State private var lastAlarmIDs:     Set<UUID> = []
    /// Cancellable auto-dismiss task — replaced each time a new alarm arrives.
    @State private var toastDismissTask: Task<Void, Never>? = nil

    // MARK: - Search overlay

    @State private var showSearch:   Bool    = false
    @State private var searchText:   String  = ""

    // MARK: - Keyboard shortcuts overlay

    @State private var showShortcuts: Bool   = false

    // MARK: - Plant overview navigator (M key)

    @State private var showOverview:  Bool = false
    @State private var tabNavIndex:   Int  = -1

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
                            if panStartPos == nil {
                                panStartPos = CGPoint(x: v.startLocation.x, y: v.startLocation.y)
                                panAtStart  = pan
                                canvasFocused = true
                            }
                            pan = CGPoint(x: panAtStart.x + v.translation.width,
                                          y: panAtStart.y + v.translation.height)
                        }
                        .onEnded { v in
                            panStartPos = nil
                            // Momentum: carry 55 % of the predicted extra travel
                            let momentum = CGPoint(
                                x: (v.predictedEndTranslation.width  - v.translation.width)  * 0.55,
                                y: (v.predictedEndTranslation.height - v.translation.height) * 0.55
                            )
                            withAnimation(.easeOut(duration: 0.45)) {
                                pan.x += momentum.x
                                pan.y += momentum.y
                            }
                        }
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

                        // Double-click → zoom to this block
                        onZoomTo:  { centerOnBlock(block) },

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
                            blocks:     blocks,
                            scale:      scale,
                            pan:        pan,
                            viewSize:   viewSize,
                            alarmState: Dictionary(
                                uniqueKeysWithValues: blocks.map { b in
                                    let tagAlarms = (b.content.tagIDs + [b.content.equipTagID])
                                        .flatMap { alarmManager.getAlarms(forTag: $0) }
                                    let panelAlarms = b.content.kind == "alarmPanel"
                                        ? alarmManager.activeAlarms : []
                                    let all = tagAlarms + panelAlarms
                                    let severity: MiniMapAlarmSeverity
                                    if all.contains(where: { $0.severity == .critical }) {
                                        severity = .critical
                                    } else if !all.isEmpty {
                                        severity = .warning
                                    } else {
                                        severity = .none
                                    }
                                    return (b.id, severity)
                                })
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

            // Layer 10: Space+drag overlay
            // When Space is held this sits on top of all blocks and captures
            // the drag gesture — so operators can pan regardless of cursor position.
            if spaceHeld {
                Color.clear
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering { NSCursor.openHand.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture()
                            .onChanged { v in
                                if panStartPos == nil { panStartPos = .zero; panAtStart = pan }
                                pan = CGPoint(x: panAtStart.x + v.translation.width,
                                              y: panAtStart.y + v.translation.height)
                            }
                            .onEnded { v in
                                panStartPos = nil
                                let m = CGPoint(
                                    x: (v.predictedEndTranslation.width  - v.translation.width)  * 0.55,
                                    y: (v.predictedEndTranslation.height - v.translation.height) * 0.55
                                )
                                withAnimation(.easeOut(duration: 0.55)) { pan.x += m.x; pan.y += m.y }
                            }
                    )
            }

            // Layer 11: Alarm bubble — 44pt circle, bottom-centre above toolbar.
            // Shown in Operate mode only; suppressed while the engineer is designing.
            // Tapping or auto-dismiss triggers a balloon-pop burst animation.
            if let alarm = toastAlarm, !isDesigning {
                AlarmBubble(alarm: alarm, popping: $toastPopping) {
                    toastAlarm   = nil
                    toastPopping = false
                }
                .position(x: viewSize.width / 2, y: viewSize.height - 88)
                .allowsHitTesting(true)
                .transition(.scale(scale: 0.1, anchor: .center).combined(with: .opacity))
            }

            // Layer 12: Search overlay (/)
            if showSearch {
                canvasSearchOverlay
            }

            // Layer 13: Keyboard shortcuts overlay (?)
            if showShortcuts {
                shortcutsOverlay
            }

            // Layer 14: Plant Overview navigator (M key)
            // Full-screen interactive plant map. Tap any tile to jump there.
            if showOverview {
                ProcessCanvasOverview(
                    blocks:     canvasStore.active?.blocks ?? [],
                    onNavigate: { block in
                        withAnimation(.easeInOut(duration: 0.2)) { showOverview = false }
                        centerOnBlock(block)
                    },
                    onDismiss: {
                        withAnimation(.easeInOut(duration: 0.2)) { showOverview = false }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .center)))
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

        // Search shortcut
        .onKeyPress(characters: CharacterSet(charactersIn: "/"), phases: .down) { _ in
            showSearch.toggle(); searchText = ""; return .handled
        }
        // Shortcuts reference
        .onKeyPress(characters: CharacterSet(charactersIn: "?"), phases: .down) { _ in
            showShortcuts.toggle(); return .handled
        }
        // Plant overview (m key)
        .onKeyPress(characters: CharacterSet(charactersIn: "m"), phases: .down) { _ in
            withAnimation(.easeInOut(duration: 0.2)) { showOverview.toggle() }
            return .handled
        }
        // Tab: jump to next block in spatial reading order
        .onKeyPress(.tab, phases: .down) { _ in
            navigateToNextBlock(); return .handled
        }
        // Close overlays on Escape
        .onKeyPress(.escape, phases: .down) { _ in
            if showOverview  { withAnimation(.easeInOut(duration: 0.2)) { showOverview  = false }; return .handled }
            if showSearch    { showSearch    = false; return .handled }
            if showShortcuts { showShortcuts = false; return .handled }
            return .ignored
        }

        .onAppear {
            canvasFocused = true
            startSpaceMonitor()
            // Seed known alarms so first-run doesn't immediately toast all existing ones
            lastAlarmIDs = Set(alarmManager.activeAlarms.map(\.id))
        }
        // Reset tab-cycle index when the active canvas changes
        .onChange(of: canvasStore.activeID) { _, _ in tabNavIndex = -1 }
        .onDisappear {
            keyMonitors.forEach { NSEvent.removeMonitor($0) }
            keyMonitors = []
        }
        // Watch for new alarms → show toast.
        // New alarm → show bubble. Cancels any pending auto-dismiss so rapid alarms
        // each get their own full 4-second window.
        .onReceive(alarmManager.$activeAlarms) { alarms in
            let newAlarms = alarms.filter { !lastAlarmIDs.contains($0.id) }
            lastAlarmIDs  = Set(alarms.map(\.id))
            if let newest = newAlarms.first {
                toastDismissTask?.cancel()
                toastPopping = false
                withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) {
                    toastAlarm = newest
                }
                toastDismissTask = Task {
                    try? await Task.sleep(for: .seconds(4))
                    guard !Task.isCancelled else { return }
                    await MainActor.run { toastPopping = true }
                }
            }
        }

        // Delete key (via HMI Editor menu) — removes the selected block in design mode.
        .onReceive(NotificationCenter.default.publisher(for: .hmiDeleteSelected)) { _ in
            guard isDesigning, let id = selectedID else { return }
            canvasStore.deleteBlock(id)
            selectedID = nil
        }

        // Clear alarm toast immediately on entering Design mode — no distractions while building.
        .onChange(of: isDesigning) { _, designing in
            if designing {
                toastDismissTask?.cancel()
                toastAlarm   = nil
                toastPopping = false
            }
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

            // Quick zoom presets
            ForEach([25, 50, 100], id: \.self) { pct in
                Button { animateTo(x: (viewSize.width / 2 - pan.x) / scale,
                                   y: (viewSize.height / 2 - pan.y) / scale,
                                   scale: Double(pct) / 100) } label: {
                    Text("\(pct)%").font(.system(size: 10, design: .monospaced))
                }
                .buttonStyle(.bordered)
                .help("Zoom to \(pct)%")
            }

            Divider().frame(height: 20)

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
                .help("Fit all blocks  (f)")

            // Plant overview button
            Button { withAnimation(.easeInOut(duration: 0.2)) { showOverview.toggle() } } label: {
                Image(systemName: "map")
            }
            .buttonStyle(.bordered)
            .help("Plant Overview — full map navigator  (m)")

            // Search button
            Button { showSearch.toggle(); searchText = "" } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.bordered)
                .help("Search blocks  (/)")
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

    // MARK: - Space+drag keyboard monitor

    private func startSpaceMonitor() {
        let down = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 49 && !event.isARepeat { // Space
                Task { @MainActor in spaceHeld = true }
            }
            return event
        }
        let up = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { event in
            if event.keyCode == 49 { // Space
                Task { @MainActor in spaceHeld = false }
            }
            return event
        }
        if let d = down { keyMonitors.append(d) }
        if let u = up   { keyMonitors.append(u) }
    }

    // MARK: - Search overlay

    private var canvasSearchOverlay: some View {
        VStack {
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                        TextField("Search blocks…", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.body)
                            .foregroundColor(.white)
                            .onSubmit { navigateToFirstMatch() }
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                            }.buttonStyle(.plain)
                        }
                        Button { showSearch = false; searchText = "" } label: {
                            Image(systemName: "xmark").foregroundColor(.secondary)
                        }.buttonStyle(.plain)
                    }
                    .padding(10)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.1), lineWidth: 0.5))

                    // Search results
                    let results = searchResults
                    if !results.isEmpty && !searchText.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(results.prefix(6)) { block in
                                Button {
                                    centerOnBlock(block)
                                    showSearch = false; searchText = ""
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: blockIcon(for: block))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .frame(width: 16)
                                        Text(block.title)
                                            .font(.caption)
                                            .foregroundColor(.white)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(block.content.kind)
                                            .font(.system(size: 9))
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .background(Color.white.opacity(0.03))
                                if block.id != results.prefix(6).last?.id { Divider() }
                            }
                        }
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.1), lineWidth: 0.5))
                        .padding(.top, 4)
                    }
                }
                .frame(width: 320)
                .padding(.top, 14)
                .padding(.trailing, 14)
            }
            Spacer()
        }
    }

    private var searchResults: [CanvasBlock] {
        guard !searchText.isEmpty, let blocks = canvasStore.active?.blocks else { return [] }
        let q = searchText.lowercased()
        return blocks.filter {
            $0.title.lowercased().contains(q) ||
            $0.content.tagIDs.contains { $0.lowercased().contains(q) } ||
            $0.content.equipTagID.lowercased().contains(q) ||
            $0.content.hmiScreenName.lowercased().contains(q)
        }
    }

    private func navigateToFirstMatch() {
        if let first = searchResults.first { centerOnBlock(first) }
        showSearch = false; searchText = ""
    }

    // MARK: - Tab-key spatial navigation

    /// Cycle to the next block in spatial reading order (top-to-bottom, left-to-right within each row).
    /// Wraps around when the last block is reached. Zooms the viewport to the target block.
    private func navigateToNextBlock() {
        guard let blocks = canvasStore.active?.blocks, !blocks.isEmpty else { return }
        // Sort into rows: group blocks whose Y centres are within 80 pt of each other,
        // then sort rows top-to-bottom and within each row left-to-right.
        let sorted = blocks.sorted { a, b in
            let rowA = (a.y / 80).rounded(.towardZero)
            let rowB = (b.y / 80).rounded(.towardZero)
            if rowA != rowB { return rowA < rowB }
            return a.x < b.x
        }
        tabNavIndex = (tabNavIndex + 1) % sorted.count
        let target  = sorted[tabNavIndex]
        selectedID  = target.id
        centerOnBlock(target)
    }

    private func blockIcon(for block: CanvasBlock) -> String {
        switch block.content.kind {
        case "tagMonitor":  return "list.bullet"
        case "statusGrid":  return "square.grid.2x2"
        case "alarmPanel":  return "exclamationmark.triangle"
        case "equipment":   return "gearshape"
        case "trendMini":   return "chart.xyaxis.line"
        case "navButton":   return "arrow.right.circle"
        case "hmiScreen":   return "rectangle.on.rectangle"
        case "screenGroup": return "square.grid.2x2"
        case "region":      return "rectangle.dashed"
        default:            return "square"
        }
    }

    // MARK: - Keyboard shortcuts overlay

    private var shortcutsOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .onTapGesture { showShortcuts = false }

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Keyboard Shortcuts")
                        .font(.headline.bold())
                        .foregroundColor(.white)
                    Spacer()
                    Button { showShortcuts = false } label: {
                        Image(systemName: "xmark").foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)

                Divider()

                let shortcuts: [(String, String)] = [
                    ("Arrow keys",        "Pan canvas (50 pt)"),
                    ("⇧ + Arrow keys",    "Pan fast (200 pt)"),
                    ("=  /  +",           "Zoom in ×1.25"),
                    ("-",                 "Zoom out ×0.8"),
                    ("f  or  0",          "Fit all blocks to window"),
                    ("Space + drag",      "Pan from anywhere (even over blocks)"),
                    ("Double-click block","Zoom into that block"),
                    ("Tab",               "Jump to next block (spatial order)"),
                    ("m",                 "Plant Overview — full map navigator"),
                    ("/",                 "Search blocks and tags"),
                    ("?",                 "Show this shortcuts reference"),
                    ("Esc",               "Close overview / search / shortcuts"),
                    ("Right-click block", "Context menu (Zoom, Open Screen…)"),
                ]

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(shortcuts, id: \.0) { key, desc in
                            HStack(alignment: .center, spacing: 16) {
                                Text(key)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.white)
                                    .frame(width: 160, alignment: .leading)
                                Text(desc)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 7)
                            if key != shortcuts.last?.0 {
                                Divider().padding(.leading, 20)
                            }
                        }
                    }
                }

                Divider()
                Text("Press any key or click outside to dismiss")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.1), lineWidth: 0.5))
            .frame(width: 440)
            .shadow(color: .black.opacity(0.5), radius: 30)
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

// MARK: - MiniMapAlarmSeverity

/// Alarm severity level used by ProcessCanvasMiniMap for colour coding.
/// .none = no alarm (white), .warning = unack/active (orange), .critical = critical active (red).
enum MiniMapAlarmSeverity { case none, warning, critical }

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
    let blocks:     [CanvasBlock]
    let scale:      CGFloat
    let pan:        CGPoint
    let viewSize:   CGSize
    /// Per-block alarm severity keyed by block ID — drives mini-map colour coding.
    let alarmState: [UUID: MiniMapAlarmSeverity]
    var onNavigate: (Double, Double) -> Void

    private let mapW:   CGFloat = 180
    private let mapH:   CGFloat = 112
    private let mapPad: CGFloat = 6

    private var contentBounds: CGRect {
        guard !blocks.isEmpty else { return CGRect(x: 0, y: 0, width: 1280, height: 800) }
        let minX = blocks.map { $0.x }.min()! - 200
        let minY = blocks.map { $0.y }.min()! - 200
        let maxX = blocks.map { $0.x + $0.w }.max()! + 200
        let maxY = blocks.map { $0.y + $0.h }.max()! + 200
        return CGRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
    }

    private var mapScale: CGFloat {
        min((mapW - mapPad * 2) / contentBounds.width,
            (mapH - mapPad * 2) / contentBounds.height)
    }

    private func toMap(_ cx: Double, _ cy: Double) -> CGPoint {
        CGPoint(x: (cx - contentBounds.minX) * mapScale + mapPad,
                y: (cy - contentBounds.minY) * mapScale + mapPad)
    }

    private func toCanvas(_ mx: CGFloat, _ my: CGFloat) -> (Double, Double) {
        ((mx - mapPad) / mapScale + contentBounds.minX,
         (my - mapPad) / mapScale + contentBounds.minY)
    }

    private var viewportRect: CGRect {
        guard viewSize != .zero, scale > 0 else { return .zero }
        let tl = toMap(Double(-pan.x / scale),                      Double(-pan.y / scale))
        let br = toMap(Double((viewSize.width - pan.x) / scale),    Double((viewSize.height - pan.y) / scale))
        return CGRect(x: tl.x, y: tl.y, width: br.x - tl.x, height: br.y - tl.y)
    }

    var body: some View {
        Canvas { ctx, _ in
            // Alarm-colour-coded block thumbnails
            for block in blocks {
                let tl   = toMap(block.x, block.y)
                let br   = toMap(block.x + block.w, block.y + block.h)
                let rect = CGRect(x: tl.x, y: tl.y,
                                  width: max(br.x - tl.x, 1), height: max(br.y - tl.y, 1))
                // Color: red = critical alarm, orange = warning alarm, white = normal
                let fillColor: Color
                switch alarmState[block.id] ?? .none {
                case .critical: fillColor = .red
                case .warning:  fillColor = .orange
                case .none:     fillColor = .white
                }
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1),
                         with: .color(fillColor.opacity(0.55)))
            }
            // Viewport rectangle
            let vp = viewportRect
            if vp.width > 1 && vp.height > 1 {
                let clipped = CGRect(
                    x: max(vp.minX, mapPad - 1), y: max(vp.minY, mapPad - 1),
                    width:  min(vp.width,  mapW - mapPad * 2 + 2),
                    height: min(vp.height, mapH - mapPad * 2 + 2))
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

    /// Two-finger double-tap on trackpad → fit all blocks to window.
    override func smartMagnify(with event: NSEvent) {
        onFit?()
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

// MARK: - ProcessCanvasOverview
//
// Full-screen interactive plant map navigator, shown by pressing 'M' or the toolbar
// Map button. All blocks are rendered as labelled tiles preserving their spatial layout.
// Tap any tile to dismiss the overlay and fly the viewport to that block.
// Supports live text filtering so operators can quickly locate a block by name or type.

private struct ProcessCanvasOverview: View {

    let blocks:     [CanvasBlock]
    let onNavigate: (CanvasBlock) -> Void
    let onDismiss:  () -> Void

    @State private var filterText:    String = ""
    @FocusState private var sfFocused: Bool

    // MARK: - Filtered results

    private var filtered: Set<UUID> {
        guard !filterText.isEmpty else { return Set(blocks.map(\.id)) }
        let q = filterText.lowercased()
        return Set(blocks.filter {
            $0.title.lowercased().contains(q) ||
            $0.content.kind.lowercased().contains(q) ||
            $0.content.tagIDs.contains { $0.lowercased().contains(q) } ||
            $0.content.equipTagID.lowercased().contains(q)
        }.map(\.id))
    }

    // MARK: - Coordinate helpers

    private var contentBounds: CGRect {
        guard !blocks.isEmpty else { return CGRect(x: 0, y: 0, width: 1280, height: 800) }
        let minX = blocks.map { $0.x }.min()! - 120
        let minY = blocks.map { $0.y }.min()! - 120
        let maxX = blocks.map { $0.x + $0.w }.max()! + 120
        let maxY = blocks.map { $0.y + $0.h }.max()! + 120
        return CGRect(x: minX, y: minY,
                      width: max(maxX - minX, 1), height: max(maxY - minY, 1))
    }

    /// Canvas rect → screen rect within `mapSize`, preserving aspect ratio and centring.
    private func tileRect(_ block: CanvasBlock, in mapSize: CGSize) -> CGRect {
        let b = contentBounds
        let s = min(mapSize.width / b.width, mapSize.height / b.height)
        let offX = (mapSize.width  - b.width  * s) / 2
        let offY = (mapSize.height - b.height * s) / 2
        return CGRect(
            x: (block.x - b.minX) * s + offX,
            y: (block.y - b.minY) * s + offY,
            width:  max(block.w * s, 4),
            height: max(block.h * s, 4)
        )
    }

    // MARK: - Block colour coding

    private func blockColor(_ block: CanvasBlock) -> Color {
        switch block.content.kind {
        case "tagMonitor":  return .blue
        case "statusGrid":  return .teal
        case "alarmPanel":  return .red
        case "equipment":   return .green
        case "trendMini":   return .purple
        case "navButton":   return .indigo
        case "hmiScreen":   return .cyan
        case "screenGroup": return .mint
        case "region":      return .gray.opacity(0.6)
        default:            return .white
        }
    }

    // MARK: - Legend items

    private static let legend: [(String, Color)] = [
        ("Tag Monitor", .blue),
        ("Equipment",   .green),
        ("Alarms",      .red),
        ("Trend",       .purple),
        ("HMI Screen",  .cyan),
        ("Region",      .gray),
    ]

    // MARK: - Body

    var body: some View {
        ZStack {
            // Dimmed backdrop — tap outside the panel to dismiss
            Color.black.opacity(0.75)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(spacing: 0) {

                // ── Header ──────────────────────────────────────────────────
                HStack(spacing: 12) {
                    Image(systemName: "map.fill")
                        .font(.title3)
                        .foregroundColor(.cyan)
                    Text("Plant Overview")
                        .font(.headline.bold())
                        .foregroundColor(.white)
                    Text("·  \(blocks.count) blocks")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    // Filter field
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                            .font(.caption)
                        TextField("Filter blocks…", text: $filterText)
                            .textFieldStyle(.plain)
                            .font(.caption)
                            .foregroundColor(.white)
                            .focused($sfFocused)
                            .frame(width: 160)
                        if !filterText.isEmpty {
                            Button { filterText = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }.buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.08))
                    .clipShape(Capsule())

                    Button { onDismiss() } label: {
                        Image(systemName: "xmark")
                            .foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(.black.opacity(0.25))

                Divider().opacity(0.25)

                // ── Map area ─────────────────────────────────────────────────
                GeometryReader { geo in
                    let pad: CGFloat = 20
                    let mapSize = CGSize(width: geo.size.width  - pad * 2,
                                        height: geo.size.height - pad * 2)
                    let match = filtered   // capture for use in ForEach

                    ZStack(alignment: .topLeading) {
                        // Subtle dot-grid backdrop
                        Canvas { ctx, size in
                            let gs: CGFloat = 32
                            var x: CGFloat = 0
                            while x <= size.width {
                                ctx.stroke(Path { p in
                                    p.move(to: .init(x: x, y: 0))
                                    p.addLine(to: .init(x: x, y: size.height))
                                }, with: .color(.white.opacity(0.035)))
                                x += gs
                            }
                            var y: CGFloat = 0
                            while y <= size.height {
                                ctx.stroke(Path { p in
                                    p.move(to: .init(x: 0, y: y))
                                    p.addLine(to: .init(x: size.width, y: y))
                                }, with: .color(.white.opacity(0.035)))
                                y += gs
                            }
                        }
                        .frame(width: mapSize.width, height: mapSize.height)
                        .offset(x: pad, y: pad)

                        // Block tiles
                        ForEach(blocks) { block in
                            let r       = tileRect(block, in: mapSize)
                            let active  = match.contains(block.id)
                            let dimmed  = !filterText.isEmpty && !active
                            let color   = blockColor(block)

                            Button { onNavigate(block) } label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(color.opacity(dimmed ? 0.05 : 0.28))
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(color.opacity(dimmed ? 0.12 : (active && !filterText.isEmpty ? 0.95 : 0.70)),
                                                lineWidth: active && !filterText.isEmpty ? 1.5 : 0.75)

                                    if r.width > 32 && r.height > 14 {
                                        VStack(spacing: 1) {
                                            Text(block.title)
                                                .font(.system(size: min(r.height * 0.22, 11), weight: .medium))
                                                .foregroundColor(.white.opacity(dimmed ? 0.20 : 0.92))
                                                .lineLimit(2)
                                                .multilineTextAlignment(.center)
                                            if r.height > 28 {
                                                Text(block.content.kind)
                                                    .font(.system(size: min(r.height * 0.15, 9)))
                                                    .foregroundColor(.secondary.opacity(dimmed ? 0.15 : 0.75))
                                            }
                                        }
                                        .padding(3)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .frame(width: r.width, height: r.height)
                            // .position centres the view — offset from ZStack top-left by pad
                            .position(x: r.midX + pad, y: r.midY + pad)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
                .padding(.vertical, 6)

                Divider().opacity(0.25)

                // ── Footer / legend ───────────────────────────────────────────
                HStack(spacing: 14) {
                    ForEach(ProcessCanvasOverview.legend, id: \.0) { label, color in
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(color.opacity(0.65))
                                .frame(width: 10, height: 10)
                            Text(label)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    Text("Tap a block to navigate  ·  Esc or M to close")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.55))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.black.opacity(0.25))
            }
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(.white.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.55), radius: 40)
            .padding(36)
            // Prevent tap-on-panel from bubbling up to the dismiss backdrop
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .onTapGesture { /* absorb — blocks the backdrop dismiss */ }
        }
        .onAppear { sfFocused = true }
    }
}

// MARK: - AlarmBubble
//
// A ~44pt circular alarm indicator placed bottom-centre of the canvas.
// Dismissal plays a balloon-pop effect:
//   1. The circle inflates to 1.35× and fades (0.22s)
//   2. A shockwave ring expands from 1× to 2.6× and fades (0.38s)
//   3. Six dots scatter 30pt outward and fade (0.38s)
//   4. onDismiss() is called after the animations finish.
//
// The bubble also pulses a soft glow ring to attract attention while live.

private struct AlarmBubble: View {
    let alarm:    Alarm
    @Binding var popping: Bool
    let onDismiss: () -> Void

    private let size: CGFloat = 44

    @State private var glowScale:     CGFloat = 1.0
    @State private var glowOpacity:   Double  = 0.5
    @State private var bubbleScale:   CGFloat = 1.0
    @State private var bubbleOpacity: Double  = 1.0
    @State private var ringScale:     CGFloat = 1.0
    @State private var ringOpacity:   Double  = 0.0
    @State private var burstRadius:   CGFloat = 0.0
    @State private var burstOpacity:  Double  = 0.0

    private var color: Color { alarm.severity == .critical ? .red : .orange }

    var body: some View {
        ZStack {
            // Burst dots — 6 dots at 60° intervals, scatter on pop
            ForEach(0..<6, id: \.self) { i in
                let angle = Double(i) * 60.0 * .pi / 180
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                    .offset(x: burstRadius * CGFloat(cos(angle)),
                            y: burstRadius * CGFloat(sin(angle)))
                    .opacity(burstOpacity)
            }

            // Shockwave ring — expands outward on pop
            Circle()
                .strokeBorder(color.opacity(ringOpacity), lineWidth: 2.5)
                .frame(width: size, height: size)
                .scaleEffect(ringScale)

            // Ambient glow pulse — animates continuously while bubble is alive
            Circle()
                .strokeBorder(color.opacity(glowOpacity), lineWidth: 2)
                .frame(width: size, height: size)
                .scaleEffect(glowScale)

            // Main bubble
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 17, weight: .black))
                        .foregroundColor(.white)
                }
                .shadow(color: color.opacity(0.55), radius: 6)
                .scaleEffect(bubbleScale)
                .opacity(bubbleOpacity)
        }
        // Frame large enough to contain the burst dots at peak travel
        .frame(width: size + 80, height: size + 80)
        .contentShape(Circle().size(CGSize(width: size, height: size)))
        .onTapGesture { triggerPop() }
        .onAppear { startGlow() }
        .onChange(of: popping) { _, shouldPop in
            if shouldPop { triggerPop() }
        }
    }

    // MARK: - Glow pulse (repeating, while bubble is alive)

    private func startGlow() {
        withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: false)) {
            glowScale   = 1.75
            glowOpacity = 0.0
        }
    }

    // MARK: - Balloon pop

    private func triggerPop() {
        guard bubbleOpacity > 0 else { return }   // prevent double-trigger

        // Shockwave ring: flash visible then expand + fade
        ringOpacity = 0.85
        ringScale   = 1.0
        withAnimation(.easeOut(duration: 0.38)) {
            ringScale   = 2.6
            ringOpacity = 0.0
        }

        // Burst dots: appear then scatter outward and fade
        burstOpacity = 0.9
        burstRadius  = 0.0
        withAnimation(.easeOut(duration: 0.38)) {
            burstRadius  = 32
            burstOpacity = 0.0
        }

        // Main bubble: inflate slightly then vanish
        withAnimation(.easeIn(duration: 0.22)) {
            bubbleScale   = 1.35
            bubbleOpacity = 0.0
        }

        // Notify parent after all animations finish
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            onDismiss()
        }
    }
}
