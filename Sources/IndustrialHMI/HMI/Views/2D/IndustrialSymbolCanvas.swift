// MARK: - IndustrialSymbolCanvas.swift
//
// P&ID industrial symbol renderer for the HMI 2D canvas.
// Implements all 12 HMI P&ID object types as SwiftUI Canvas-based drawings.
//
// ── Symbol Types ──────────────────────────────────────────────────────────────
//   centrifugalPump  — circle with impeller lines; rotates when isRunning
//   motorDrive       — square with "M" + rotor circle; rotates when isRunning
//   gateValve        — two triangles (ISA gate valve symbol); filled when open
//   globeValve       — circle with horizontal bar; color by liveValue (0=closed)
//   ballValve        — circle with rectangular plug; rotated 90° when open
//   checkValve       — triangle + line (one-way flow indicator)
//   controlValve     — triangle + actuator circle above; position from liveValue
//   closedVessel     — ellipse cap + cylindrical body; fill level from liveValue
//   openTank         — rectangular body open at top; fill level from liveValue
//                      agitation animation when isRunning
//   pipeStraight     — horizontal pipe with flow arrows when isRunning
//   instrumentBubble — circle with instrument tag number (from HMIObject.designerLabel)
//   heatExchangerSym — shell-and-tube schematic (two concentric arcs with arrows)
//
// ── Rendering Pattern ─────────────────────────────────────────────────────────
//   Each symbol is a private SwiftUI View struct receiving: object, scale, liveValue,
//   isRunning, isEditMode.
//   Static symbols use Canvas { context, size in Self.draw(...) }.
//   Animated symbols (pump, motor, open tank) use:
//     TimelineView(.animation(minimumInterval: 1/30, paused: !isRunning || isEditMode))
//       Canvas { context, size in Self.draw(context, size, t, ...) }
//   `paused: !isRunning || isEditMode` ensures zero idle rendering cost.
//
// ── Scale & Sizing ────────────────────────────────────────────────────────────
//   Each symbol draws into a Canvas whose frame is (object.width * scale, object.height * scale).
//   All path coordinates use the Canvas's `size` to remain proportional at any scale.
//   Stroke lineWidth is also scaled: typically `max(1, 2 * scale)`.
//
// ── Level Fill ────────────────────────────────────────────────────────────────
//   ClosedVessel and OpenTank use liveValue (0.0–100.0 %) to compute fill height:
//     fillY = size.height - (liveValue / 100.0) * bodyHeight
//   Color transitions: 0–20%=red, 20–80%=blue, 80–100%=orange.
//
// ── Valve Position ────────────────────────────────────────────────────────────
//   Ball/gate/globe/control valves use liveValue (0.0–100.0) as open percentage.
//   0 = fully closed (red tint), 100 = fully open (green tint).
//   ControlValve actuator stem position moves proportionally to liveValue.
//
// ── IndustrialSymbolCanvas (Factory) ──────────────────────────────────────────
//   Static factory enum with view(for:scale:liveValue:isRunning:isEditMode:)
//   dispatches to the correct private symbol struct via switch on object.type.
//   HMIObjectView calls this for all P&ID category objects.

import SwiftUI

// MARK: - IndustrialSymbolCanvas

/// Provides SwiftUI views for all 12 P&ID industrial symbols.
/// Animated symbols use TimelineView with `paused:` so idle rendering costs nothing.
enum IndustrialSymbolCanvas {

    /// Returns the appropriate View for the given HMIObjectType and live state.
    @ViewBuilder
    static func view(
        for object: HMIObject,
        scale: CGFloat,
        liveValue: Double?,
        isRunning: Bool,
        isEditMode: Bool
    ) -> some View {
        switch object.type {
        case .centrifugalPump:
            CentrifugalPumpSymbol(object: object, scale: scale, liveValue: liveValue,
                                  isRunning: isRunning, isEditMode: isEditMode)
        case .motorDrive:
            MotorDriveSymbol(object: object, scale: scale, liveValue: liveValue,
                             isRunning: isRunning, isEditMode: isEditMode)
        case .gateValve:
            GateValveSymbol(object: object, scale: scale, liveValue: liveValue, isEditMode: isEditMode)
        case .globeValve:
            GlobeValveSymbol(object: object, scale: scale, liveValue: liveValue, isEditMode: isEditMode)
        case .ballValve:
            BallValveSymbol(object: object, scale: scale, liveValue: liveValue, isEditMode: isEditMode)
        case .checkValve:
            CheckValveSymbol(object: object, scale: scale, isEditMode: isEditMode)
        case .controlValve:
            ControlValveSymbol(object: object, scale: scale, liveValue: liveValue, isEditMode: isEditMode)
        case .closedVessel:
            ClosedVesselSymbol(object: object, scale: scale, liveValue: liveValue, isEditMode: isEditMode)
        case .openTank:
            OpenTankSymbol(object: object, scale: scale, liveValue: liveValue,
                           isRunning: isRunning, isEditMode: isEditMode)
        case .pipeStraight:
            PipeStraightSymbol(object: object, scale: scale, isRunning: isRunning, isEditMode: isEditMode)
        case .instrumentBubble:
            InstrumentBubbleSymbol(object: object, scale: scale, isEditMode: isEditMode)
        case .heatExchangerSym:
            HeatExchangerSymbol(object: object, scale: scale, isEditMode: isEditMode)
        default:
            // Fallback — should never hit (caller only routes P&ID types here)
            Color.gray.opacity(0.3)
        }
    }
}

// MARK: - Centrifugal Pump

private struct CentrifugalPumpSymbol: View {
    let object: HMIObject
    let scale: CGFloat
    let liveValue: Double?
    let isRunning: Bool
    let isEditMode: Bool

    var body: some View {
        let paused = !isRunning || isEditMode
        TimelineView(.animation(minimumInterval: 1.0/30.0, paused: paused)) { ctx in
            Canvas { context, size in
                var ctx2 = context
                let t = paused ? 0.0 : ctx.date.timeIntervalSinceReferenceDate
                Self.draw(context: &ctx2, size: size, t: t, object: object, scale: scale)
            }
        }
    }

    private static func draw(context: inout GraphicsContext, size: CGSize,
                              t: Double, object: HMIObject, scale: CGFloat) {
        let cx = size.width / 2
        let cy = size.height / 2
        let r = min(cx, cy) * 0.85
        let stroke = object.strokeColor.color
        let fill   = object.fillColor.color
        let lw = 2.0 * scale
        let circleRect = CGRect(x: cx - r, y: cy - r, width: r*2, height: r*2)
        context.stroke(Path(ellipseIn: circleRect), with: .color(stroke), lineWidth: lw)
        let angle = CGFloat(t) * 3.0
        let cosA = cos(angle)
        let sinA = sin(angle)
        let bx: CGFloat = -r * 0.35
        let by0: CGFloat = -r * 0.4
        let by1: CGFloat = r * 0.4
        let p0 = CGPoint(x: cx + r * 0.6 * cosA, y: cy + r * 0.6 * sinA)
        let p1x = cx + bx * cosA - by0 * sinA
        let p1y = cy + bx * sinA + by0 * cosA
        let p2x = cx + bx * cosA - by1 * sinA
        let p2y = cy + bx * sinA + by1 * cosA
        let p1 = CGPoint(x: p1x, y: p1y)
        let p2 = CGPoint(x: p2x, y: p2y)
        var tri = Path()
        tri.move(to: p0); tri.addLine(to: p1); tri.addLine(to: p2); tri.closeSubpath()
        context.fill(tri, with: .color(fill))
        context.stroke(tri, with: .color(stroke), lineWidth: lw * 0.6)
        if object.showISATag {
            context.draw(Text("P").font(.system(size: 10 * scale, weight: .bold)),
                         at: CGPoint(x: cx - r * 0.55, y: cy))
        }
        if !object.designerLabel.isEmpty {
            context.draw(Text(object.designerLabel).font(.system(size: 9 * scale))
                .foregroundStyle(stroke), at: CGPoint(x: cx, y: size.height - 6 * scale))
        }
    }
}

// MARK: - Motor Drive

private struct MotorDriveSymbol: View {
    let object: HMIObject
    let scale: CGFloat
    let liveValue: Double?
    let isRunning: Bool
    let isEditMode: Bool

    var body: some View {
        let paused = !isRunning || isEditMode
        TimelineView(.animation(minimumInterval: 1.0/30.0, paused: paused)) { ctx in
            Canvas { context, size in
                var ctx2 = context
                let t = paused ? 0.0 : ctx.date.timeIntervalSinceReferenceDate
                Self.draw(context: &ctx2, size: size, t: t, object: object, scale: scale)
            }
        }
    }

    private static func draw(context: inout GraphicsContext, size: CGSize,
                              t: Double, object: HMIObject, scale: CGFloat) {
        let cx = size.width / 2, cy = size.height / 2
        let r = min(cx, cy) * 0.85
        let stroke = object.strokeColor.color
        let fill   = object.fillColor.color
        let lw = 2.0 * scale
        let circleRect = CGRect(x: cx - r, y: cy - r, width: r*2, height: r*2)
        context.stroke(Path(ellipseIn: circleRect), with: .color(stroke), lineWidth: lw)
        let baseAngle = CGFloat(t) * 2.0
        for i in 0..<8 {
            let a = baseAngle + CGFloat(i) * (2 * CGFloat.pi / 8)
            var p = Path()
            p.move(to: CGPoint(x: cx + r * 0.78 * cos(a), y: cy + r * 0.78 * sin(a)))
            p.addLine(to: CGPoint(x: cx + r * 0.98 * cos(a), y: cy + r * 0.98 * sin(a)))
            context.stroke(p, with: .color(fill), lineWidth: lw * 0.8)
        }
        if object.showISATag {
            context.draw(Text("M").font(.system(size: 14 * scale, weight: .bold))
                .foregroundStyle(stroke), at: CGPoint(x: cx, y: cy))
        }
    }
}

// MARK: - Gate Valve

private struct GateValveSymbol: View {
    let object: HMIObject
    let scale: CGFloat
    let liveValue: Double?
    let isEditMode: Bool

    var body: some View {
        Canvas { context, size in
            let cx = size.width / 2, cy = size.height / 2
            let hw = size.width * 0.45, hh = size.height * 0.42
            let stroke = object.strokeColor.color
            let lw = 2.0 * scale

            // Gate valve = two triangles tip-to-tip (bowtie)
            let isOpen = !isEditMode && (liveValue ?? 0) > 0.5
            let fillColor = isEditMode ? object.fillColor.color
                           : (isOpen ? Color.green.opacity(0.7) : Color.red.opacity(0.7))

            // Left triangle
            var left = Path()
            left.move(to: CGPoint(x: cx, y: cy))
            left.addLine(to: CGPoint(x: cx - hw, y: cy - hh))
            left.addLine(to: CGPoint(x: cx - hw, y: cy + hh))
            left.closeSubpath()

            // Right triangle
            var right = Path()
            right.move(to: CGPoint(x: cx, y: cy))
            right.addLine(to: CGPoint(x: cx + hw, y: cy - hh))
            right.addLine(to: CGPoint(x: cx + hw, y: cy + hh))
            right.closeSubpath()

            context.fill(left,  with: .color(fillColor))
            context.fill(right, with: .color(fillColor))
            context.stroke(left,  with: .color(stroke), lineWidth: lw)
            context.stroke(right, with: .color(stroke), lineWidth: lw)

            // Stem (top centre line)
            var stem = Path()
            stem.move(to: CGPoint(x: cx, y: cy - hh))
            stem.addLine(to: CGPoint(x: cx, y: 4 * scale))
            context.stroke(stem, with: .color(stroke), lineWidth: lw)
        }
    }
}

// MARK: - Globe Valve

private struct GlobeValveSymbol: View {
    let object: HMIObject
    let scale: CGFloat
    let liveValue: Double?
    let isEditMode: Bool

    var body: some View {
        Canvas { context, size in
            let cx = size.width / 2, cy = size.height * 0.65
            let hw = size.width * 0.42, hh = size.height * 0.30
            let stroke = object.strokeColor.color
            let fill   = object.fillColor.color
            let lw = 2.0 * scale

            // Downward-pointing triangle body
            var body = Path()
            body.move(to: CGPoint(x: cx - hw, y: cy - hh))
            body.addLine(to: CGPoint(x: cx + hw, y: cy - hh))
            body.addLine(to: CGPoint(x: cx, y: cy + hh))
            body.closeSubpath()
            context.fill(body, with: .color(fill.opacity(0.7)))
            context.stroke(body, with: .color(stroke), lineWidth: lw)

            // Horizontal bonnet bar
            var bar = Path()
            bar.move(to: CGPoint(x: cx - hw, y: cy - hh))
            bar.addLine(to: CGPoint(x: cx + hw, y: cy - hh))
            context.stroke(bar, with: .color(stroke), lineWidth: lw * 1.4)

            // Stem to top
            var stem = Path()
            stem.move(to: CGPoint(x: cx, y: cy - hh))
            stem.addLine(to: CGPoint(x: cx, y: 4 * scale))
            context.stroke(stem, with: .color(stroke), lineWidth: lw)
        }
    }
}

// MARK: - Ball Valve

private struct BallValveSymbol: View {
    let object: HMIObject
    let scale: CGFloat
    let liveValue: Double?
    let isEditMode: Bool

    var body: some View {
        Canvas { context, size in
            let cx = size.width / 2, cy = size.height / 2
            let r = min(size.width, size.height) * 0.38
            let stroke = object.strokeColor.color
            let lw = 2.0 * scale

            let isOpen = !isEditMode && (liveValue ?? 0) > 0.5
            let fillColor = isEditMode ? object.fillColor.color
                           : (isOpen ? Color.green.opacity(0.7) : Color.red.opacity(0.7))

            // Circle
            let rect = CGRect(x: cx - r, y: cy - r, width: r*2, height: r*2)
            let circle = Path(ellipseIn: rect)
            context.fill(circle, with: .color(fillColor))
            context.stroke(circle, with: .color(stroke), lineWidth: lw)

            // 45° diagonal crossbar
            let d = r * 0.7
            var diag = Path()
            diag.move(to: CGPoint(x: cx - d, y: cy + d))
            diag.addLine(to: CGPoint(x: cx + d, y: cy - d))
            context.stroke(diag, with: .color(stroke), lineWidth: lw * 1.2)

            // Stem top
            var stem = Path()
            stem.move(to: CGPoint(x: cx, y: cy - r))
            stem.addLine(to: CGPoint(x: cx, y: 4 * scale))
            context.stroke(stem, with: .color(stroke), lineWidth: lw)
        }
    }
}

// MARK: - Check Valve

private struct CheckValveSymbol: View {
    let object: HMIObject
    let scale: CGFloat
    let isEditMode: Bool

    var body: some View {
        Canvas { context, size in
            let cx = size.width / 2, cy = size.height / 2
            let hw = size.width * 0.36, hh = size.height * 0.40
            let stroke = object.strokeColor.color
            let fill   = object.fillColor.color
            let lw = 2.0 * scale

            // Filled right-pointing triangle
            var tri = Path()
            tri.move(to: CGPoint(x: cx - hw * 0.3, y: cy - hh))
            tri.addLine(to: CGPoint(x: cx + hw, y: cy))
            tri.addLine(to: CGPoint(x: cx - hw * 0.3, y: cy + hh))
            tri.closeSubpath()
            context.fill(tri, with: .color(fill))
            context.stroke(tri, with: .color(stroke), lineWidth: lw)

            // Stop line on right edge
            var stop = Path()
            stop.move(to: CGPoint(x: cx + hw, y: cy - hh))
            stop.addLine(to: CGPoint(x: cx + hw, y: cy + hh))
            context.stroke(stop, with: .color(stroke), lineWidth: lw * 1.5)
        }
    }
}

// MARK: - Control Valve

private struct ControlValveSymbol: View {
    let object: HMIObject
    let scale: CGFloat
    let liveValue: Double?
    let isEditMode: Bool

    var body: some View {
        Canvas { context, size in
            let cx = size.width / 2
            let hw = size.width * 0.40
            let stroke = object.strokeColor.color
            let fill   = object.fillColor.color
            let lw = 2.0 * scale

            // Valve position: 0.5 in edit mode, liveValue fraction otherwise
            let openFraction: Double = {
                if isEditMode { return 0.5 }
                guard let v = liveValue else { return 0 }
                let range = object.barMax - object.barMin
                guard range > 0 else { return 0 }
                return min(max((v - object.barMin) / range, 0), 1)
            }()

            // Stem base Y (valve body top)
            let bodyTopY = size.height * 0.55
            let bodyBotY = size.height * 0.88

            // Downward-pointing triangle valve body
            var body = Path()
            body.move(to: CGPoint(x: cx - hw, y: bodyTopY))
            body.addLine(to: CGPoint(x: cx + hw, y: bodyTopY))
            body.addLine(to: CGPoint(x: cx, y: bodyBotY))
            body.closeSubpath()
            context.fill(body, with: .color(fill.opacity(0.7)))
            context.stroke(body, with: .color(stroke), lineWidth: lw)

            // Actuator circle (moves up/down with openFraction)
            let stemLen = bodyTopY - 16 * scale
            let stemY = bodyTopY - stemLen * CGFloat(openFraction)
            let actuatorR = min(size.width, 24 * scale) * 0.4
            let actuatorRect = CGRect(x: cx - actuatorR, y: stemY - actuatorR * 2,
                                      width: actuatorR * 2, height: actuatorR * 2)
            context.fill(Path(ellipseIn: actuatorRect), with: .color(fill))
            context.stroke(Path(ellipseIn: actuatorRect), with: .color(stroke), lineWidth: lw)

            // Stem line
            var stem = Path()
            stem.move(to: CGPoint(x: cx, y: bodyTopY))
            stem.addLine(to: CGPoint(x: cx, y: stemY))
            context.stroke(stem, with: .color(stroke), lineWidth: lw)
        }
    }
}

// MARK: - Closed Vessel

private struct ClosedVesselSymbol: View {
    let object: HMIObject
    let scale: CGFloat
    let liveValue: Double?
    let isEditMode: Bool

    var body: some View {
        Canvas { context, size in
            let stroke = object.strokeColor.color
            let fill   = object.fillColor.color
            let lw = 2.0 * scale
            let rx = size.width * 0.35
            let headH = size.height * 0.12

            let bodyRect = CGRect(x: size.width/2 - rx,
                                  y: headH,
                                  width: rx * 2,
                                  height: size.height - headH * 2)

            // Fill level
            let pct: Double = {
                if isEditMode { return 0.6 }
                guard let v = liveValue else { return 0 }
                let range = object.barMax - object.barMin
                guard range > 0 else { return 0 }
                return min(max((v - object.barMin) / range, 0), 1)
            }()
            let fillH = bodyRect.height * CGFloat(pct)
            let fillRect = CGRect(x: bodyRect.minX, y: bodyRect.maxY - fillH,
                                  width: bodyRect.width, height: fillH)
            context.fill(
                Path(CGPath(roundedRect: fillRect, cornerWidth: 2, cornerHeight: 2, transform: nil)),
                with: .color(fill.opacity(0.65))
            )

            // Body outline
            let bodyPath = Path(roundedRect: bodyRect, cornerRadius: 4)
            context.stroke(bodyPath, with: .color(stroke), lineWidth: lw)

            // Top ellipse head
            let topEllipse = CGRect(x: size.width/2 - rx, y: 2, width: rx * 2, height: headH * 2)
            context.stroke(Path(ellipseIn: topEllipse), with: .color(stroke), lineWidth: lw)

            // Bottom ellipse head
            let botEllipse = CGRect(x: size.width/2 - rx,
                                    y: size.height - headH * 2 - 2,
                                    width: rx * 2, height: headH * 2)
            context.stroke(Path(ellipseIn: botEllipse), with: .color(stroke), lineWidth: lw)
        }
    }
}

// MARK: - Open Tank

private struct OpenTankSymbol: View {
    let object: HMIObject
    let scale: CGFloat
    let liveValue: Double?
    let isRunning: Bool
    let isEditMode: Bool

    var body: some View {
        let paused = !isRunning || isEditMode
        TimelineView(.animation(minimumInterval: 1.0/30.0, paused: paused)) { ctx in
            Canvas { context, size in
                var ctx2 = context
                let t = paused ? 0.0 : ctx.date.timeIntervalSinceReferenceDate
                Self.draw(context: &ctx2, size: size, t: t,
                          object: object, scale: scale, liveValue: liveValue, isEditMode: isEditMode)
            }
        }
    }

    private static func draw(context: inout GraphicsContext, size: CGSize, t: Double,
                              object: HMIObject, scale: CGFloat,
                              liveValue: Double?, isEditMode: Bool) {
        let stroke = object.strokeColor.color
        let fill   = object.fillColor.color
        let lw = 2.0 * scale
        let si = size.width * 0.08
        let topY = size.height * 0.04
        let botY = size.height * 0.92
        let arcH = size.height * 0.10
        let pct: Double = {
            if isEditMode { return 0.5 }
            guard let v = liveValue else { return 0 }
            let range = object.barMax - object.barMin
            guard range > 0 else { return 0 }
            return min(max((v - object.barMin) / range, 0), 1)
        }()
        let fillTopY = topY + (botY - topY) * CGFloat(1 - pct)
        let freq: CGFloat = CGFloat.pi * 2 / size.width
        if pct > 0.01 {
            var fp = Path()
            fp.move(to: CGPoint(x: si, y: botY))
            fp.addLine(to: CGPoint(x: si, y: fillTopY))
            for xi in stride(from: si, through: size.width - si, by: 2) {
                fp.addLine(to: CGPoint(x: xi,
                                       y: fillTopY + 3 * scale * sin(freq * xi + CGFloat(t) * 3)))
            }
            fp.addLine(to: CGPoint(x: size.width - si, y: botY))
            fp.closeSubpath()
            context.fill(fp, with: .color(fill.opacity(0.5)))
        }
        var walls = Path()
        walls.move(to: CGPoint(x: si, y: topY))
        walls.addLine(to: CGPoint(x: si, y: botY - arcH))
        walls.addArc(center: CGPoint(x: size.width/2, y: botY - arcH),
                     radius: size.width/2 - si,
                     startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
        walls.addLine(to: CGPoint(x: size.width - si, y: topY))
        context.stroke(walls, with: .color(stroke), lineWidth: lw)
    }
}

// MARK: - Pipe Straight

private struct PipeStraightSymbol: View {
    let object: HMIObject
    let scale: CGFloat
    let isRunning: Bool
    let isEditMode: Bool

    var body: some View {
        let paused = !isRunning || isEditMode
        TimelineView(.animation(minimumInterval: 1.0/30.0, paused: paused)) { ctx in
            Canvas { context, size in
                var ctx2 = context
                let t = paused ? 0.0 : ctx.date.timeIntervalSinceReferenceDate
                Self.draw(context: &ctx2, size: size, t: t, object: object, scale: scale)
            }
        }
    }

    private static func draw(context: inout GraphicsContext, size: CGSize,
                              t: Double, object: HMIObject, scale: CGFloat) {
        let stroke = object.strokeColor.color
        let fill   = object.fillColor.color
        let lw = 2.0 * scale
        let wo = size.height * 0.28
        var tp = Path()
        tp.move(to: CGPoint(x: 0, y: wo)); tp.addLine(to: CGPoint(x: size.width, y: wo))
        context.stroke(tp, with: .color(stroke), lineWidth: lw)
        var bp = Path()
        bp.move(to: CGPoint(x: 0, y: size.height - wo))
        bp.addLine(to: CGPoint(x: size.width, y: size.height - wo))
        context.stroke(bp, with: .color(stroke), lineWidth: lw)
        let count = max(1, object.pipeSegmentCount)
        let spacing = size.width / CGFloat(count + 1)
        let chevH = (size.height - wo * 2) * 0.55
        let rightward = object.flowDirection == .right || object.flowDirection == .down
        let speed: CGFloat = rightward ? 1 : -1
        let phase = CGFloat(t) * spacing * 0.8 * speed
        let midY = size.height / 2
        for i in 0..<count {
            let cx = spacing * CGFloat(i + 1) + phase.truncatingRemainder(dividingBy: spacing)
            let tip = rightward ? cx + chevH * 0.5 : cx - chevH * 0.5
            var chev = Path()
            chev.move(to: CGPoint(x: cx, y: midY - chevH / 2))
            chev.addLine(to: CGPoint(x: tip, y: midY))
            chev.addLine(to: CGPoint(x: cx,  y: midY + chevH / 2))
            context.stroke(chev, with: .color(fill.opacity(0.85)), lineWidth: lw * 0.9)
        }
    }
}

// MARK: - Instrument Bubble

private struct InstrumentBubbleSymbol: View {
    let object: HMIObject
    let scale: CGFloat
    let isEditMode: Bool

    var body: some View {
        Canvas { context, size in
            let cx = size.width / 2, cy = size.height / 2
            let r = min(cx, cy) * 0.85
            let stroke = object.strokeColor.color
            let fill   = object.fillColor.color
            let lw = 2.0 * scale

            // Circle
            let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
            context.fill(Path(ellipseIn: rect), with: .color(fill.opacity(0.15)))
            context.stroke(Path(ellipseIn: rect), with: .color(stroke), lineWidth: lw)

            // ISA letters (e.g. "PT") from staticText, top half
            let isaText = object.showISATag ? (object.staticText.isEmpty ? "FT" : String(object.staticText.prefix(3))) : ""
            if !isaText.isEmpty {
                let t = Text(isaText)
                    .font(.system(size: 11 * scale, weight: .bold))
                    .foregroundStyle(stroke)
                context.draw(t, at: CGPoint(x: cx, y: cy - r * 0.2))
            }

            // Loop number (designerLabel), bottom half
            if !object.designerLabel.isEmpty {
                let lb = Text(object.designerLabel)
                    .font(.system(size: 9 * scale))
                    .foregroundStyle(stroke.opacity(0.7))
                context.draw(lb, at: CGPoint(x: cx, y: cy + r * 0.35))
            }
        }
    }
}

// MARK: - Heat Exchanger

private struct HeatExchangerSymbol: View {
    let object: HMIObject
    let scale: CGFloat
    let isEditMode: Bool

    var body: some View {
        Canvas { context, size in
            let stroke = object.strokeColor.color
            let fill   = object.fillColor.color
            let lw = 2.0 * scale
            let inset = size.height * 0.14

            // Rectangle outline
            let rect = CGRect(x: inset, y: inset,
                              width: size.width - inset * 2,
                              height: size.height - inset * 2)
            context.stroke(Path(roundedRect: rect, cornerRadius: 4),
                           with: .color(stroke), lineWidth: lw)

            // Two counter-flowing curved arrows
            let midY = size.height / 2
            let cp1x = size.width * 0.35
            let cp2x = size.width * 0.65

            // Arrow 1 — left-to-right upper
            var a1 = Path()
            a1.move(to: CGPoint(x: inset + 4, y: midY - inset))
            a1.addCurve(to:       CGPoint(x: size.width - inset - 4, y: midY - inset),
                        control1: CGPoint(x: cp1x, y: inset + 4),
                        control2: CGPoint(x: cp2x, y: midY - inset * 2))
            context.stroke(a1, with: .color(fill), lineWidth: lw * 0.9)
            arrowHead(context: context, at: CGPoint(x: size.width - inset - 4, y: midY - inset),
                      angle: 0, size: 7 * scale, fill: fill)

            // Arrow 2 — right-to-left lower
            var a2 = Path()
            a2.move(to: CGPoint(x: size.width - inset - 4, y: midY + inset))
            a2.addCurve(to:       CGPoint(x: inset + 4, y: midY + inset),
                        control1: CGPoint(x: cp2x, y: size.height - inset - 4),
                        control2: CGPoint(x: cp1x, y: midY + inset * 2))
            context.stroke(a2, with: .color(stroke.opacity(0.65)), lineWidth: lw * 0.9)
            arrowHead(context: context, at: CGPoint(x: inset + 4, y: midY + inset),
                      angle: .pi, size: 7 * scale, fill: stroke.opacity(0.65))
        }
    }

    private func arrowHead(context: GraphicsContext, at tip: CGPoint, angle: CGFloat,
                           size s: CGFloat, fill: Color) {
        var p = Path()
        p.move(to: tip)
        p.addLine(to: CGPoint(x: tip.x + s * cos(angle + 2.4),
                              y: tip.y + s * sin(angle + 2.4)))
        p.addLine(to: CGPoint(x: tip.x + s * cos(angle - 2.4),
                              y: tip.y + s * sin(angle - 2.4)))
        p.closeSubpath()
        context.fill(p, with: .color(fill))
    }
}
