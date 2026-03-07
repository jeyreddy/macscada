// MARK: - HMICanvasView.swift
//
// The HMI 2D drawing canvas — renders all HMIObjects for the active screen,
// scaled uniformly to fit the available view geometry.
//
// ── Coordinate System ─────────────────────────────────────────────────────────
//   HMIObject positions are in canvas space (1280 × 800 virtual units).
//   canvasScale(geo) = min(geo.width / 1280, geo.height / 800)
//   Display position: (obj.x * scale, obj.y * scale)
//   Drag deltas from DragGesture are in display coords → divided by scale to
//   convert back to canvas units before updating HMIObject.x / .y.
//
// ── Edit vs Run Mode ──────────────────────────────────────────────────────────
//   Edit mode (isEditMode = true):
//     HMIObjectView receives isSelected=true for selectedObjectId.
//     Drag gesture moves objects; resize handles appear on selected object.
//     DragGesture from background creates new objects (drag-to-place):
//       createStart + createCurrent track the rubber-band rect.
//       On gesture end: create HMIObject of activeTool type at canvas coords.
//   Run mode (isEditMode = false):
//     liveTag provided to HMIObjectView from TagEngine for live value display.
//     Tap on object with tagBinding → set faceplateObjectId → popover opens.
//     Push buttons (HMIObjectType.button) write via pendingWrite confirmation sheet.
//
// ── Alarm Flash ───────────────────────────────────────────────────────────────
//   alarmActive is true when alarmManager.activeAlarms contains an UnackActive or
//   UnackRTN alarm for the object's bound tag. HMIObjectView drives a repeating
//   opacity animation (0.3 ↔ 1.0, 0.6 s easeInOut) when hasActiveAlarm is true.
//
// ── Sparklines ────────────────────────────────────────────────────────────────
//   sparklineData[objectId] caches the last 30 historian samples for objects
//   with objectType == .trendSparkline. sparkTimer fires every 30 s to refresh.
//   Initial load happens in .onAppear via loadSparklines().
//
// ── Z-ordering ────────────────────────────────────────────────────────────────
//   Objects rendered in ascending zIndex order (lower = drawn first = behind).
//   HMIInspectorPanel provides z-order controls (Bring Forward, Send Back).

import SwiftUI
import Combine

// MARK: - HMICanvasView

/// The main drawing canvas. Renders all HMI objects scaled to fit the view.
struct HMICanvasView: View {
    @EnvironmentObject var hmiScreenStore: HMIScreenStore
    @EnvironmentObject var tagEngine: TagEngine
    @EnvironmentObject var alarmManager: AlarmManager
    @EnvironmentObject var dataService: DataService

    let isEditMode: Bool
    @Binding var activeTool: HMIObjectType?
    @Binding var selectedObjectId: UUID?
    @Binding var faceplateObjectId: UUID?

    // Drag-to-create tracking
    @State private var createStart:   CGPoint? = nil
    @State private var createCurrent: CGPoint? = nil

    // Run-mode write confirmation
    @State private var pendingWrite: PendingHMIWrite? = nil

    // Sparkline historian data, keyed by object ID
    @State private var sparklineData: [UUID: [Double]] = [:]

    // 30-second sparkline refresh timer
    private let sparkTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            let scale = canvasScale(geo)

            ZStack(alignment: .topLeading) {
                // Objects (sorted by zIndex)
                ForEach(hmiScreenStore.screen.objects.sorted { $0.zIndex < $1.zIndex }) { obj in
                    let liveTag      = isEditMode ? nil : tagEngine.getTag(named: obj.tagBinding?.tagName ?? "")
                    // Flash when alarm is unacknowledged (active or RTN)
                    let alarmActive  = !isEditMode && alarmManager.activeAlarms.contains {
                        $0.tagName == (obj.tagBinding?.tagName ?? "") && $0.state.requiresAction
                    }

                    HMIObjectView(
                        object:          obj,
                        scale:           scale,
                        isSelected:      isEditMode && selectedObjectId == obj.id,
                        isEditMode:      isEditMode,
                        liveTag:         liveTag,
                        hasActiveAlarm:  alarmActive,
                        sparklinePoints: sparklineData[obj.id] ?? [],
                        onSelect: {
                            if isEditMode {
                                selectedObjectId = obj.id
                                activeTool = nil
                            } else {
                                if obj.tagBinding != nil { faceplateObjectId = obj.id }
                            }
                        },
                        onDrag: { delta in
                            guard isEditMode else { return }
                            var updated = obj
                            updated.x += Double(delta.width  / scale)
                            updated.y += Double(delta.height / scale)
                            hmiScreenStore.updateObject(updated)
                        },
                        onResizeHandle: { handle, delta in
                            guard isEditMode else { return }
                            applyResize(obj: obj, handle: handle, delta: delta, scale: scale)
                        },
                        onWrite: isEditMode ? nil : { tagName, value in
                            pendingWrite = PendingHMIWrite(tagName: tagName, value: value)
                        }
                    )
                    .position(
                        x: obj.x * scale + obj.width  * scale / 2,
                        y: obj.y * scale + obj.height * scale / 2
                    )
                }

                // Drag-to-create rubber-band preview
                if isEditMode, activeTool != nil,
                   let start = createStart, let cur = createCurrent {
                    let rect = normalizedRect(from: start, to: cur)
                    Rectangle()
                        .strokeBorder(Color.accentColor,
                                      style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
            // Fill the full GeometryReader with the canvas background
            .frame(width: geo.size.width, height: geo.size.height)
            .background(hmiScreenStore.screen.backgroundColor.color)
            .clipped()
            .contentShape(Rectangle())
            .gesture(createGesture(scale: scale))
            .onTapGesture {
                if isEditMode { selectedObjectId = nil }
            }
        }
        // Ensure the GeometryReader fills all available space from the start
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Sparkline refresh
        .onAppear { refreshSparklines() }
        .onReceive(sparkTimer) { _ in refreshSparklines() }
        // Write confirmation alert
        .alert("Write Tag?",
               isPresented: Binding(get: { pendingWrite != nil },
                                    set: { if !$0 { pendingWrite = nil } })) {
            Button("Write") {
                if let pw = pendingWrite {
                    Task { try? await performHMIWrite(tagName: pw.tagName, value: pw.value) }
                }
                pendingWrite = nil
            }
            Button("Cancel", role: .cancel) { pendingWrite = nil }
        } message: {
            if let pw = pendingWrite {
                Text("Write \(String(format: "%.4g", pw.value)) to \"\(pw.tagName)\"?")
            }
        }
    }

    // MARK: - Scale

    private func canvasScale(_ geo: GeometryProxy) -> CGFloat {
        let cw = hmiScreenStore.screen.canvasWidth
        guard cw > 0, geo.size.width > 0 else { return 1 }
        return geo.size.width / CGFloat(cw)
    }

    // MARK: - Drag-to-Create Gesture

    private func createGesture(scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                guard isEditMode, activeTool != nil else { return }
                if createStart == nil { createStart = value.startLocation }
                createCurrent = value.location
            }
            .onEnded { value in
                guard isEditMode, let tool = activeTool,
                      let start = createStart else {
                    createStart = nil; createCurrent = nil; return
                }
                let rect = normalizedRect(from: start, to: value.location)
                if rect.width > 10 && rect.height > 10 {
                    var obj = HMIObject(
                        type: tool,
                        x:    Double(rect.minX / scale),
                        y:    Double(rect.minY / scale)
                    )
                    obj.width  = Double(rect.width  / scale)
                    obj.height = Double(rect.height / scale)
                    hmiScreenStore.addObject(obj)
                    selectedObjectId = obj.id
                    activeTool = nil
                }
                createStart = nil; createCurrent = nil
            }
    }

    // MARK: - Resize

    private func applyResize(obj: HMIObject, handle: HandlePosition, delta: CGSize, scale: CGFloat) {
        var updated = obj
        let dx = Double(delta.width  / scale)
        let dy = Double(delta.height / scale)

        switch handle {
        case .topLeft:     updated.x += dx; updated.y += dy; updated.width -= dx; updated.height -= dy
        case .top:         updated.y += dy; updated.height -= dy
        case .topRight:    updated.width += dx; updated.y += dy; updated.height -= dy
        case .left:        updated.x += dx; updated.width -= dx
        case .right:       updated.width  += dx
        case .bottomLeft:  updated.x += dx; updated.width -= dx; updated.height += dy
        case .bottom:      updated.height += dy
        case .bottomRight: updated.width  += dx; updated.height += dy
        }

        if updated.width  < 20 { updated.width  = 20 }
        if updated.height < 20 { updated.height = 20 }
        hmiScreenStore.updateObject(updated)
    }

    // MARK: - Helpers

    private func normalizedRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    // MARK: - Sparkline Refresh

    private func refreshSparklines() {
        let sparkObjs = hmiScreenStore.screen.objects.filter {
            $0.type == .trendSparkline && $0.tagBinding != nil
        }
        guard !sparkObjs.isEmpty, let historian = dataService.historian else { return }
        Task {
            for obj in sparkObjs {
                guard let tagName = obj.tagBinding?.tagName else { continue }
                let from = Date().addingTimeInterval(-Double(obj.sparklineMinutes) * 60)
                if let pts = try? await historian.getHistory(for: tagName, from: from, to: Date(), maxPoints: 200) {
                    sparklineData[obj.id] = pts.map { $0.value }
                }
            }
        }
    }

    // MARK: - HMI Write

    private func performHMIWrite(tagName: String, value: Double) async throws {
        guard let req = tagEngine.requestWrite(
            tagName: tagName,
            newValue: .analog(value),
            requestedBy: "HMI"
        ) else {
            Logger.shared.warning("HMI write: tag '\(tagName)' not found or not writable")
            return
        }
        try await dataService.confirmWrite(req)
    }
}

// MARK: - PendingHMIWrite

private struct PendingHMIWrite {
    let tagName: String
    let value: Double
}
