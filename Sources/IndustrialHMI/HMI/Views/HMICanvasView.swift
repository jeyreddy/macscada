import SwiftUI

// MARK: - HMICanvasView

/// The main drawing canvas. Renders all HMI objects scaled to fit the view.
struct HMICanvasView: View {
    @EnvironmentObject var hmiScreenStore: HMIScreenStore
    @EnvironmentObject var tagEngine: TagEngine
    @EnvironmentObject var alarmManager: AlarmManager

    let isEditMode: Bool
    @Binding var activeTool: HMIObjectType?
    @Binding var selectedObjectId: UUID?
    @Binding var faceplateObjectId: UUID?

    // Drag-to-create tracking
    @State private var createStart:   CGPoint? = nil
    @State private var createCurrent: CGPoint? = nil

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
}
