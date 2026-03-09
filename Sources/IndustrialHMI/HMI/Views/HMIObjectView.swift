// MARK: - HMIObjectView.swift
//
// Renders a single HMIObject on the canvas in either edit mode or run mode.
// Acts as a thin dispatcher — routes to the appropriate shape/symbol renderer
// based on HMIObject.objectType, then applies common decoration (alarm flash,
// selection handles, rotation).
//
// ── Object Shape Rendering ────────────────────────────────────────────────────
//   objectShape computes the visual based on objectType:
//     .rectangle / .ellipse / .label / .button / .indicator / .bargraph /
//     .trendSparkline / .image → basic SwiftUI shapes + text + sparkline overlay
//     .motorSymbol / .pumpSymbol / .valveSymbol / .tankSymbol / .heatExchangerSymbol /
//     .filterSymbol / .fanSymbol / .pipeStraight / .pipeElbow / .pipeTee /
//     .sensorSymbol → IndustrialSymbolCanvas (P&ID SVG-style renderer)
//
// ── Edit Mode ─────────────────────────────────────────────────────────────────
//   selectionHandles: 8 resize handles (corners + midpoints) as small blue squares.
//   DragGesture on handles calls onResizeHandle(handle, delta) → HMICanvasView
//   calls applyResize() which adjusts x, y, width, height while keeping the
//   opposite corner/edge anchored.
//   DragGesture on the object body calls onDrag(translation) → updates x/y.
//
// ── Run Mode ──────────────────────────────────────────────────────────────────
//   liveTag provides the current TagValue. DisplayValue computed:
//     .analog: formatted with displayFormat (printf-style) + unit string
//     .digital: displayOnText / displayOffText mapped to Bool
//     .string: raw string value
//   onWrite callback: push button (objectType == .button) calls onWrite when tapped.
//
// ── Alarm Flash ───────────────────────────────────────────────────────────────
//   alarmIndicator: red/orange flashing border rendered via .overlay + .opacity animation.
//   alarmOpacity 1.0 → 0.3 repeating easeInOut 0.6 s when hasActiveAlarm = true.
//   Animation stopped when hasActiveAlarm = false (alarmOpacity reset to 1.0).
//
// ── P&ID Running Animation ───────────────────────────────────────────────────
//   isRunning: true when liveTag.numericValue >= object.writeOnValue AND
//   object.animateRunning is true. Passed to IndustrialSymbolCanvas to drive
//   rotation animation for pump/motor symbols.
//
// ── HandlePosition ────────────────────────────────────────────────────────────
//   8 positions: topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight.
//   Each handle's anchor point determines which object edges are resized.

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
    var sparklinePoints: [Double] = []          // pre-fetched history for trendSparkline

    var onSelect: () -> Void
    var onDrag: (CGSize) -> Void                              // display-coord delta
    var onResizeHandle: (HandlePosition, CGSize) -> Void
    var onWrite: ((String, Double) -> Void)? = nil            // run-mode write callback

    // Flashing alarm animation state
    @State private var alarmOpacity: Double = 1.0
    // Push-button press visual state
    @State private var isPressed: Bool = false
    // P&ID running state (true when tag value >= writeOnValue)
    @State private var isRunning: Bool = false

    var body: some View {
        ZStack {
            objectShape
            if hasActiveAlarm && !isEditMode { alarmIndicator }
            if isEditMode && isSelected { selectionHandles }
        }
        .frame(width: object.width  * scale,
               height: object.height * scale)
        .contentShape(Rectangle())          // ensure full bounding box is tappable (Canvas / P&ID symbols)
        .rotationEffect(.degrees(object.rotation))
        .gesture(
            DragGesture(minimumDistance: 2)
                .onEnded { value in onDrag(value.translation) }
        )
        .onTapGesture { onSelect() }
        .onAppear {
            updateFlash(hasActiveAlarm)
            updateRunning(liveTagDoubleValue)
        }
        .onChange(of: hasActiveAlarm) { _, v in updateFlash(v) }
        .onChange(of: liveTagDoubleValue) { _, v in updateRunning(v) }
    }

    // MARK: - Running state (P&ID animation driver)

    private func updateRunning(_ value: Double?) {
        guard object.animateRunning else { isRunning = false; return }
        isRunning = (value ?? 0) >= object.writeOnValue
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

        case .circularGauge:
            circularGaugeView

        case .pushButton:
            pushButtonView

        case .toggleSwitch:
            toggleSwitchView

        case .trendSparkline:
            trendSparklineView

        // P&ID Industrial symbols (Phase 16) — delegate to IndustrialSymbolCanvas
        case .centrifugalPump, .motorDrive, .gateValve, .globeValve,
             .ballValve, .checkValve, .controlValve, .closedVessel,
             .openTank, .pipeStraight, .instrumentBubble, .heatExchangerSym:
            IndustrialSymbolCanvas.view(
                for:        object,
                scale:      scale,
                liveValue:  liveTagDoubleValue,
                isRunning:  isRunning,
                isEditMode: isEditMode
            )
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

    // MARK: - Circular Gauge

    @ViewBuilder
    private var circularGaugeView: some View {
        let fill   = resolvedFillColor
        let stroke = object.strokeColor.color
        let sweep  = object.gaugeSweepDegrees
        // fraction of the gauge range filled by the current value
        let fraction: Double = {
            guard let d = liveTagDoubleValue else { return isEditMode ? 0.55 : 0 }
            let range = object.gaugeMax - object.gaugeMin
            guard range > 0 else { return 0 }
            return min(max((d - object.gaugeMin) / range, 0), 1)
        }()

        ZStack {
            Canvas { ctx, size in
                let cx = size.width  / 2
                let cy = size.height / 2
                let r  = min(cx, cy) * 0.78
                // Arc convention: 0° = 3-o'clock; we want bottom-left to bottom-right.
                // Start angle: 90° + (180° - sweep/2)  = 90 + 90 - sweep/2 = 180 - sweep/2 + 90
                // Simplified: start = -(90 + sweep/2) in standard SwiftUI .degrees
                let startAngle = Angle.degrees(90 + (180 - sweep) / 2)
                let endAngle   = Angle.degrees(90 + (180 - sweep) / 2 + sweep)

                // Track arc (dimmed)
                var trackPath = Path()
                trackPath.addArc(center: CGPoint(x: cx, y: cy),
                                 radius: r,
                                 startAngle: startAngle,
                                 endAngle: endAngle,
                                 clockwise: false)
                ctx.stroke(trackPath,
                           with: .color(fill.opacity(0.25)),
                           style: StrokeStyle(lineWidth: 10 * min(size.width, size.height) / 160,
                                             lineCap: .round))

                // Value arc (filled)
                let fillEnd = Angle.degrees(startAngle.degrees + sweep * fraction)
                var fillPath = Path()
                fillPath.addArc(center: CGPoint(x: cx, y: cy),
                                radius: r,
                                startAngle: startAngle,
                                endAngle: fillEnd,
                                clockwise: false)
                ctx.stroke(fillPath,
                           with: .color(fill),
                           style: StrokeStyle(lineWidth: 10 * min(size.width, size.height) / 160,
                                             lineCap: .round))

                // Needle
                let needleAngle = startAngle.radians + (endAngle.radians - startAngle.radians) * fraction
                let nx = cx + r * 0.72 * cos(needleAngle)
                let ny = cy + r * 0.72 * sin(needleAngle)
                var needle = Path()
                needle.move(to: CGPoint(x: cx, y: cy))
                needle.addLine(to: CGPoint(x: nx, y: ny))
                ctx.stroke(needle, with: .color(stroke),
                           style: StrokeStyle(lineWidth: 2.5 * min(size.width, size.height) / 160,
                                             lineCap: .round))

                // Centre pivot dot
                let dot = Path(ellipseIn: CGRect(x: cx - 4, y: cy - 4, width: 8, height: 8))
                ctx.fill(dot, with: .color(stroke))
            }

            // Centre value label
            VStack(spacing: 1) {
                Text(isEditMode ? String(format: "%.1f", (object.gaugeMin + object.gaugeMax) / 2)
                               : (liveTagDoubleValue.map { String(format: object.numberFormat, $0) } ?? "—"))
                    .font(.system(size: object.fontSize * scale * 0.85,
                                  weight: .semibold, design: .monospaced))
                    .foregroundColor(object.textColor.color)
                if !effectiveUnit.isEmpty {
                    Text(effectiveUnit)
                        .font(.system(size: object.fontSize * scale * 0.55))
                        .foregroundColor(object.textColor.color.opacity(0.7))
                }
            }
            .offset(y: object.height * scale * 0.12)
        }
    }

    // MARK: - Push Button

    @ViewBuilder
    private var pushButtonView: some View {
        let fill   = isPressed ? resolvedFillColor.opacity(0.6) : resolvedFillColor
        let stroke = object.strokeColor.color
        let sw     = (isPressed ? object.strokeWidth * 2 : object.strokeWidth) * scale

        ZStack {
            RoundedRectangle(cornerRadius: 8 * scale)
                .fill(fill)
                .overlay(
                    RoundedRectangle(cornerRadius: 8 * scale)
                        .strokeBorder(stroke, lineWidth: sw)
                )
            Text(isEditMode ? object.staticText : (object.staticText.isEmpty ? "Press" : object.staticText))
                .font(.system(size: object.fontSize * scale,
                              weight: object.fontBold ? .bold : .semibold))
                .foregroundColor(object.textColor.color)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(4 * scale)
        }
        .onTapGesture {
            guard !isEditMode, let tagName = object.tagBinding?.tagName else {
                if isEditMode { onSelect() }
                return
            }
            isPressed = true
            Task {
                try? await Task.sleep(for: .milliseconds(120))
                isPressed = false
            }
            onWrite?(tagName, object.writeOnValue)
        }
    }

    // MARK: - Toggle Switch

    @ViewBuilder
    private var toggleSwitchView: some View {
        let isOn      = (liveTagDoubleValue ?? 0) >= (object.writeOnValue - 0.01)
        let capsuleColor: Color = isEditMode ? object.fillColor.color
                                             : (isOn ? .green : Color(nsColor: .systemGray))

        ZStack {
            Capsule()
                .fill(capsuleColor.opacity(0.85))
                .overlay(Capsule().strokeBorder(object.strokeColor.color,
                                                lineWidth: object.strokeWidth * scale))

            GeometryReader { geo in
                let w   = geo.size.width
                let h   = geo.size.height
                let pad = h * 0.12
                let dia = h - pad * 2
                let travel = w - dia - pad * 2
                let xPos: CGFloat = isEditMode ? w / 2 - dia / 2
                                               : (isOn ? pad + travel : pad)

                Circle()
                    .fill(Color.white)
                    .shadow(radius: 2 * scale)
                    .frame(width: dia, height: dia)
                    .offset(x: xPos, y: pad)
                    .animation(.easeInOut(duration: 0.15), value: isOn)
            }

            // ON / OFF label
            HStack {
                if !isEditMode && isOn  { Spacer() }
                Text(isEditMode ? "OFF" : (isOn ? "ON" : "OFF"))
                    .font(.system(size: object.fontSize * scale * 0.7, weight: .bold))
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 6 * scale)
                if !isEditMode && !isOn { Spacer() }
            }
        }
        .onTapGesture {
            guard !isEditMode, let tagName = object.tagBinding?.tagName else {
                if isEditMode { onSelect() }
                return
            }
            let nextValue = isOn ? object.writeOffValue : object.writeOnValue
            onWrite?(tagName, nextValue)
        }
    }

    // MARK: - Trend Sparkline

    @ViewBuilder
    private var trendSparklineView: some View {
        let fill   = object.fillColor.color
        let stroke = object.strokeColor.color

        ZStack {
            // Background
            RoundedRectangle(cornerRadius: 4 * scale)
                .fill(fill.opacity(0.15))
                .overlay(
                    RoundedRectangle(cornerRadius: 4 * scale)
                        .strokeBorder(stroke.opacity(0.4), lineWidth: object.strokeWidth * scale)
                )

            if sparklinePoints.count >= 2 {
                Canvas { ctx, size in
                    let pts   = sparklinePoints
                    let minV  = pts.min() ?? 0
                    let maxV  = pts.max() ?? 1
                    let range = maxV - minV
                    let safeRange = range > 0 ? range : 1

                    let inset: CGFloat = 6 * scale
                    let drawW = size.width  - inset * 2
                    let drawH = size.height - inset * 2

                    func point(_ i: Int) -> CGPoint {
                        let x = inset + drawW * CGFloat(i) / CGFloat(pts.count - 1)
                        let y = inset + drawH * (1 - CGFloat((pts[i] - minV) / safeRange))
                        return CGPoint(x: x, y: y)
                    }

                    // Line path
                    var linePath = Path()
                    linePath.move(to: point(0))
                    for i in 1..<pts.count { linePath.addLine(to: point(i)) }

                    // Fill area (if enabled)
                    if object.sparklineShowFill {
                        var fillPath = linePath
                        fillPath.addLine(to: CGPoint(x: point(pts.count - 1).x, y: size.height - inset))
                        fillPath.addLine(to: CGPoint(x: inset, y: size.height - inset))
                        fillPath.closeSubpath()
                        ctx.fill(fillPath, with: .color(stroke.opacity(0.25)))
                    }

                    ctx.stroke(linePath,
                               with: .color(stroke),
                               style: StrokeStyle(lineWidth: 1.5 * scale, lineCap: .round,
                                                 lineJoin: .round))
                }
            } else {
                // No data yet
                Text(isEditMode ? "Sparkline" : "No data")
                    .font(.system(size: object.fontSize * scale * 0.8))
                    .foregroundColor(object.textColor.color.opacity(0.5))
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
