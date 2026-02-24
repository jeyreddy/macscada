import SwiftUI

// MARK: - Handle Position

enum HandlePosition: CaseIterable {
    case topLeft, top, topRight
    case left,            right
    case bottomLeft, bottom, bottomRight
}

// MARK: - HMIObjectView

/// Renders a single HMI object in either edit or run mode.
struct HMIObjectView: View {
    let object: HMIObject
    let scale: CGFloat
    let isSelected: Bool
    let isEditMode: Bool
    let liveTag: Tag?            // nil in edit mode; supplies live value in run mode
    let hasActiveAlarm: Bool     // true → draw flashing alarm outline in run mode

    var onSelect: () -> Void
    var onDrag: (CGSize) -> Void                              // display-coord delta
    var onResizeHandle: (HandlePosition, CGSize) -> Void

    // Flashing alarm animation state
    @State private var alarmOpacity: Double = 1.0

    var body: some View {
        ZStack {
            objectShape
            if hasActiveAlarm && !isEditMode { alarmIndicator }
            if isEditMode && isSelected { selectionHandles }
        }
        .frame(width: object.width  * scale,
               height: object.height * scale)
        .rotationEffect(.degrees(object.rotation))
        .gesture(
            DragGesture(minimumDistance: 2)
                .onEnded { value in onDrag(value.translation) }
        )
        .onTapGesture { onSelect() }
        .onAppear   { updateFlash(hasActiveAlarm) }
        .onChange(of: hasActiveAlarm) { _, v in updateFlash(v) }
    }

    // MARK: - Flash

    private func updateFlash(_ active: Bool) {
        if active {
            alarmOpacity = 1.0
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                alarmOpacity = 0.08
            }
        } else {
            withAnimation(.default) { alarmOpacity = 1.0 }
        }
    }

    // MARK: - Alarm Indicator (flashing border)

    @ViewBuilder
    private var alarmIndicator: some View {
        let inset: CGFloat = -3 * scale
        let lw: CGFloat    = 2.5 * scale
        let color          = Color.red

        switch object.type {
        case .ellipse:
            Ellipse()
                .strokeBorder(color, lineWidth: lw)
                .padding(inset)
                .opacity(alarmOpacity)
        default:
            RoundedRectangle(cornerRadius: max(object.cornerRadius * scale + 4, 6))
                .strokeBorder(color, lineWidth: lw)
                .padding(inset)
                .opacity(alarmOpacity)
        }
    }

    // MARK: - Per-Type Shape

    @ViewBuilder
    private var objectShape: some View {
        let fill   = resolvedFillColor
        let stroke = object.strokeColor.color
        let sw     = object.strokeWidth * scale

        switch object.type {
        case .rectangle:
            ZStack {
                RoundedRectangle(cornerRadius: object.cornerRadius * scale)
                    .fill(fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: object.cornerRadius * scale)
                            .strokeBorder(stroke, lineWidth: sw)
                    )
                // Built-in text overlay
                inlineText
            }

        case .ellipse:
            ZStack {
                Ellipse()
                    .fill(fill)
                    .overlay(Ellipse().strokeBorder(stroke, lineWidth: sw))
                // Built-in text overlay
                inlineText
            }

        case .textLabel:
            ZStack {
                RoundedRectangle(cornerRadius: 2)
                    .fill(fill)
                Text(runText)
                    .font(.system(size: object.fontSize * scale,
                                  weight: object.fontBold ? .bold : .regular))
                    .foregroundColor(object.textColor.color)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(4 * scale)
            }

        case .numericDisplay:
            ZStack {
                RoundedRectangle(cornerRadius: 4 * scale)
                    .fill(fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4 * scale)
                            .strokeBorder(stroke, lineWidth: sw)
                    )
                VStack(spacing: 1 * scale) {
                    Text(numericText)
                        .font(.system(size: object.fontSize * scale,
                                      weight: object.fontBold ? .bold : .regular,
                                      design: .monospaced))
                        .foregroundColor(object.textColor.color)
                    if !effectiveUnit.isEmpty {
                        Text(effectiveUnit)
                            .font(.system(size: (object.fontSize * 0.65) * scale))
                            .foregroundColor(object.textColor.color.opacity(0.7))
                    }
                }
            }

        case .levelBar:
            levelBarView
        }
    }

    // MARK: - Inline Text (Rectangle / Ellipse)

    /// Short text label inside a rectangle or ellipse, showing tag value in run mode.
    @ViewBuilder
    private var inlineText: some View {
        let text = inlineDisplayText
        if !text.isEmpty {
            Text(text)
                .font(.system(size: object.fontSize * scale,
                              weight: object.fontBold ? .bold : .regular))
                .foregroundColor(object.textColor.color)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(6 * scale)
        }
    }

    private var inlineDisplayText: String {
        if isEditMode {
            // Show static text in edit mode (empty means no overlay)
            return object.staticText
        }
        // Run mode: prefer tag value, fall back to static text
        if let d = liveTagDoubleValue {
            let fmt = object.tagBinding?.numberFormat ?? object.numberFormat
            let unit = effectiveUnit
            let valueStr = String(format: fmt, d)
            return unit.isEmpty ? valueStr : "\(valueStr) \(unit)"
        }
        if let tag = liveTag {
            switch tag.value {
            case .string(let s): return s
            case .digital(let b): return b ? "ON" : "OFF"
            default: break
            }
        }
        return object.staticText
    }

    // MARK: - Level Bar

    @ViewBuilder
    private var levelBarView: some View {
        let fill   = resolvedFillColor
        let stroke = object.strokeColor.color
        let sw     = object.strokeWidth * scale
        let pct    = barFillFraction

        ZStack {
            // Background track
            RoundedRectangle(cornerRadius: 3 * scale)
                .fill(object.fillColor.color.opacity(0.25))
                .overlay(
                    RoundedRectangle(cornerRadius: 3 * scale)
                        .strokeBorder(stroke, lineWidth: sw)
                )

            // Fill level
            GeometryReader { geo in
                let barW = geo.size.width
                let barH = geo.size.height
                if object.barIsVertical {
                    let fillH = barH * pct
                    VStack(spacing: 0) {
                        Spacer()
                        RoundedRectangle(cornerRadius: 3 * scale)
                            .fill(fill)
                            .frame(height: fillH)
                    }
                } else {
                    let fillW = barW * pct
                    HStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: 3 * scale)
                            .fill(fill)
                            .frame(width: fillW)
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: - Selection Handles

    private var selectionHandles: some View {
        let w = object.width  * scale
        let h = object.height * scale
        let hs: CGFloat = 8

        return ZStack {
            // Dashed bounding box
            Rectangle()
                .strokeBorder(Color.accentColor,
                              style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

            ForEach(HandlePosition.allCases, id: \.self) { handle in
                handleDot(handle: handle, parentW: w, parentH: h, size: hs)
            }
        }
    }

    private func handleDot(handle: HandlePosition, parentW: CGFloat, parentH: CGFloat, size: CGFloat) -> some View {
        let (offX, offY) = handleOffset(handle: handle, w: parentW, h: parentH)
        return Circle()
            .fill(Color.white)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1))
            .frame(width: size, height: size)
            .offset(x: offX, y: offY)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onEnded { value in onResizeHandle(handle, value.translation) }
            )
    }

    private func handleOffset(handle: HandlePosition, w: CGFloat, h: CGFloat) -> (CGFloat, CGFloat) {
        let hw = w / 2; let hh = h / 2
        switch handle {
        case .topLeft:     return (-hw, -hh)
        case .top:         return (0,   -hh)
        case .topRight:    return (hw,  -hh)
        case .left:        return (-hw,  0)
        case .right:       return (hw,   0)
        case .bottomLeft:  return (-hw,  hh)
        case .bottom:      return (0,    hh)
        case .bottomRight: return (hw,   hh)
        }
    }

    // MARK: - Helpers

    /// Resolved fill color: either from thresholds or the object's base fill.
    private var resolvedFillColor: Color {
        guard let binding = object.tagBinding,
              !binding.colorThresholds.isEmpty,
              let tagValue = liveTagDoubleValue else {
            return object.fillColor.color
        }
        return resolveColor(value: tagValue,
                            thresholds: binding.colorThresholds,
                            base: object.fillColor)
    }

    private var liveTagDoubleValue: Double? {
        liveTag?.value.numericValue
    }

    private var runText: String {
        guard !isEditMode, let tag = liveTag else { return object.staticText }
        switch tag.value {
        case .string(let s): return s
        default:             return tag.formattedValue
        }
    }

    private var numericText: String {
        if isEditMode { return String(format: object.numberFormat, 42.0) }
        guard let d = liveTagDoubleValue else { return "—" }
        let fmt = object.tagBinding?.numberFormat ?? object.numberFormat
        return String(format: fmt, d)
    }

    private var effectiveUnit: String {
        object.tagBinding?.unit ?? object.unit
    }

    private var barFillFraction: CGFloat {
        guard let d = liveTagDoubleValue else { return isEditMode ? 0.6 : 0 }
        let range = object.barMax - object.barMin
        guard range > 0 else { return 0 }
        return CGFloat(min(max((d - object.barMin) / range, 0), 1))
    }

    private func resolveColor(value: Double, thresholds: [ColorThreshold], base: CodableColor) -> Color {
        let sorted = thresholds.sorted { $0.value < $1.value }
        return sorted.last { value >= $0.value }?.color.color ?? base.color
    }
}
