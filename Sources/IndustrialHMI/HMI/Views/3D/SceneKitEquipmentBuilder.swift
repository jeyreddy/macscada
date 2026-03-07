// MARK: - SceneKitEquipmentBuilder.swift
//
// Factory enum that constructs and animates SceneKit node hierarchies for
// the 3D HMI plant-floor view. All geometry uses SCNGeometry primitives
// (SCNCylinder, SCNBox, SCNSphere, SCNCone, SCNTorus) with PBR materials.
//
// ── Equipment Types (15 total) ────────────────────────────────────────────────
//   centrifugalPump  — pump volute (cylinder) + impeller (sphere) + pipe nozzles
//   compressor       — large cylinder body + motor section + discharge flanges
//   motorDrive       — square frame + rotor shaft cylinder + end caps
//   verticalTank     — vertical cylinder + hemispherical caps
//   horizontalTank   — horizontal cylinder + flat end caps
//   processVessel    — large vertical cylinder + dished heads + nozzle connections
//   separator        — horizontal drum + boot (small cylinder at bottom)
//   heatExchanger    — shell cylinder + tube-sheet flanges + channel heads
//   gateValve        — body box + stem cylinder + handwheel torus
//   controlValve     — body box + actuator cylinder + positioner box
//   pipeSection      — thin SCNCylinder (diameter from equip.diameter)
//   pipeElbow        — two half-cylinders joined at 90°
//   pipeTee          — T-junction from three cylinders
//   structuralColumn — I-beam approximation (three SCNBox nodes)
//   platform         — flat SCNBox floor grating
//
// ── Node Naming Convention ────────────────────────────────────────────────────
//   Root node name = equip.id.uuidString (for hit-test → equipment ID lookup).
//   Child nodes named descriptively: "body", "impeller", "fill", "stem", etc.
//   Fill nodes for tanks named "fill" — updateLiveAnimations scales their Y.
//   Rotating nodes for pumps/motors named "rotor" — updateLiveAnimations sets angularVelocity.
//
// ── PBR Materials ─────────────────────────────────────────────────────────────
//   makeMaterial(color:roughness:metalness:) helper creates SCNMaterial with
//   lightingModel = .physicallyBased. Equipment color from equip.color (CodableColor).
//   Default roughness 0.6, metalness 0.4 (matte industrial metal appearance).
//
// ── Live Animation ────────────────────────────────────────────────────────────
//   updateLiveAnimations(node:equip:liveValue:isAlarm:isEditMode:isTransparentMode:):
//     fraction = (liveValue - minTagValue) / (maxTagValue - minTagValue) clamped 0–1
//     Rotating equipment (pump, compressor, motor):
//       rotor child node: SCNAction rotateBy(angle:) perpetually at fraction-scaled speed
//     Tank/vessel fill level:
//       "fill" node: scaleY = max(0.01, fraction) — scales a pre-sized inner cylinder
//       fill material color: blue (20–80%) → orange (>80%) → red (<20%)
//     Alarm state:
//       isAlarm=true: emissiveColor pulsed red via SCNAction (customAction alternating)
//       isAlarm=false: emissiveColor = .black
//     Transparent mode:
//       isTransparentMode=true: outer "body" material opacity = 0.3

import SceneKit
import AppKit

// SceneKit on macOS uses CGFloat for SCNVector3 components.
private let cPI = CGFloat.pi

// MARK: - SceneKitEquipmentBuilder

/// Builds SCNNode trees from HMI3DEquipment definitions using SCN primitive geometry.
/// All materials use PBR (physicallyBased lighting model).
enum SceneKitEquipmentBuilder {

    // MARK: - Make Node

    /// Returns a complete SCNNode hierarchy for the given equipment piece.
    static func makeNode(for equip: HMI3DEquipment) -> SCNNode {
        let root = SCNNode()
        root.name = equip.nodeName

        switch equip.type {
        case .centrifugalPump:  buildPump(into: root, equip: equip)
        case .compressor:       buildCompressor(into: root, equip: equip)
        case .motorDrive:       buildMotor(into: root, equip: equip)
        case .verticalTank:     buildVerticalTank(into: root, equip: equip)
        case .horizontalTank:   buildHorizontalTank(into: root, equip: equip)
        case .processVessel:    buildProcessVessel(into: root, equip: equip)
        case .separator:        buildSeparator(into: root, equip: equip)
        case .heatExchanger:    buildHeatExchanger(into: root, equip: equip)
        case .gateValve:        buildGateValve(into: root, equip: equip)
        case .controlValve:     buildControlValve(into: root, equip: equip)
        case .pipeSection:      buildPipe(into: root, equip: equip)
        case .pipeElbow:        buildPipeElbow(into: root, equip: equip)
        case .pipeTee:          buildPipeTee(into: root, equip: equip)
        case .structuralColumn: buildColumn(into: root, equip: equip)
        case .platform:         buildPlatform(into: root, equip: equip)
        }

        root.position    = SCNVector3(equip.posX, equip.posY, equip.posZ)
        root.eulerAngles = SCNVector3(0, CGFloat(equip.rotationY) * cPI / 180, 0)
        root.scale       = SCNVector3(equip.scaleX, equip.scaleY, equip.scaleZ)
        return root
    }

    // MARK: - Live Animations

    static func updateLiveAnimations(node: SCNNode,
                                     equip: HMI3DEquipment,
                                     liveValue: Double?,
                                     isAlarm: Bool,
                                     isEditMode: Bool = false,
                                     isTransparentMode: Bool = false) {
        // Edit-mode preview: when tag is bound but no live data, use 0.5 so animation is visible.
        let effectiveLive: Double? = (isEditMode && equip.tagBinding != nil && liveValue == nil)
            ? 0.5
            : liveValue

        let fraction: Double = {
            guard let v = effectiveLive else { return 0 }
            let range = equip.maxTagValue - equip.minTagValue
            guard range > 0 else { return 0 }
            return min(max((v - equip.minTagValue) / range, 0), 1)
        }()

        let isRunning = (effectiveLive ?? 0) > 0.01

        // Alarm emission overrides everything; otherwise clear all first.
        if equip.useAlarmColors && isAlarm {
            setEmission(on: node, color: NSColor.red.withAlphaComponent(0.5))
        } else {
            setEmission(on: node, color: .clear)
        }

        switch equip.type {

        case .centrifugalPump, .compressor:
            if let imp = node.childNode(withName: "anim_impeller", recursively: true) {
                if isRunning {
                    if imp.action(forKey: "spin") == nil {
                        let rpm    = 300 + fraction * 900
                        let period = 60 / rpm
                        let spin   = SCNAction.rotateBy(x: 0, y: CGFloat.pi * 2, z: 0, duration: period)
                        imp.runAction(SCNAction.repeatForever(spin), forKey: "spin")
                    }
                } else {
                    imp.removeAction(forKey: "spin")
                }
                if !isAlarm {
                    imp.geometry?.firstMaterial?.emission.contents = (isTransparentMode && isRunning)
                        ? NSColor(red: 0.2, green: 0.8, blue: 1.0,
                                  alpha: CGFloat(0.35 + fraction * 0.40))
                        : NSColor.clear
                }
            }

        case .motorDrive:
            if let shaft = node.childNode(withName: "anim_impeller", recursively: true) {
                if isRunning {
                    if shaft.action(forKey: "spin") == nil {
                        let spin = SCNAction.rotateBy(x: 0, y: CGFloat.pi * 2, z: 0, duration: 0.3)
                        shaft.runAction(SCNAction.repeatForever(spin), forKey: "spin")
                    }
                } else {
                    shaft.removeAction(forKey: "spin")
                }
                if !isAlarm {
                    shaft.geometry?.firstMaterial?.emission.contents = (isTransparentMode && isRunning)
                        ? NSColor.white.withAlphaComponent(0.40)
                        : NSColor.clear
                }
            }

        case .verticalTank, .processVessel:
            if let fill = node.childNode(withName: "anim_fill", recursively: true) {
                let maxH: CGFloat = 1.0
                let newH  = CGFloat(max(0.02, fraction)) * maxH
                let baseY: CGFloat = -0.5
                fill.scale.y    = newH
                fill.position.y = baseY + newH / 2
                let color = fillLevelColor(fraction: fraction)
                setMaterialColor(on: fill, color: color)
                if !isAlarm {
                    fill.geometry?.firstMaterial?.emission.contents = isTransparentMode
                        ? color.withAlphaComponent(0.45)
                        : NSColor.clear
                }
            }

        case .controlValve, .gateValve:
            if let disc = node.childNode(withName: "anim_disc", recursively: true) {
                disc.position.y = CGFloat(0.4 + fraction * 0.4)
                if !isAlarm {
                    disc.geometry?.firstMaterial?.emission.contents = isTransparentMode
                        ? NSColor.white.withAlphaComponent(CGFloat(fraction * 0.5))
                        : NSColor.clear
                }
            }

        default:
            break
        }
    }

    // MARK: - Equipment Builders

    private static func buildPump(into root: SCNNode, equip: HMI3DEquipment) {
        let color = equip.primaryNSColor

        let casing = SCNNode(geometry: SCNCylinder(radius: 0.5, height: 0.5))
        casing.geometry?.firstMaterial = steelMaterial(color: color)
        casing.position = SCNVector3(0, 0.25, 0)
        root.addChildNode(casing)

        let inlet = SCNNode(geometry: SCNCylinder(radius: 0.12, height: 0.4))
        inlet.geometry?.firstMaterial = steelMaterial(color: color.blended(withFraction: 0.3, of: .darkGray) ?? color)
        inlet.eulerAngles = SCNVector3(cPI / 2, 0, 0)
        inlet.position = SCNVector3(0, 0.2, 0.45)
        root.addChildNode(inlet)

        let outlet = SCNNode(geometry: SCNCylinder(radius: 0.10, height: 0.35))
        outlet.geometry?.firstMaterial = inlet.geometry?.firstMaterial
        outlet.position = SCNVector3(0, 0.65, 0)
        root.addChildNode(outlet)

        let impeller = SCNNode(geometry: SCNCylinder(radius: 0.32, height: 0.06))
        impeller.name = "anim_impeller"
        impeller.geometry?.firstMaterial = steelMaterial(color: .lightGray)
        impeller.position = SCNVector3(0, 0.25, 0)
        root.addChildNode(impeller)

        let motor = SCNNode(geometry: SCNCylinder(radius: 0.22, height: 0.45))
        motor.geometry?.firstMaterial = paintedMaterial(color: .darkGray)
        motor.position = SCNVector3(0, -0.1, 0)
        root.addChildNode(motor)

        let base = SCNNode(geometry: SCNBox(width: 1.2, height: 0.08, length: 0.8, chamferRadius: 0.01))
        base.geometry?.firstMaterial = steelMaterial(color: .darkGray)
        base.position = SCNVector3(0, -0.36, 0)
        root.addChildNode(base)
    }

    private static func buildCompressor(into root: SCNNode, equip: HMI3DEquipment) {
        let color = equip.primaryNSColor

        let barrel = SCNNode(geometry: SCNCylinder(radius: 0.55, height: 1.0))
        barrel.geometry?.firstMaterial = steelMaterial(color: color)
        barrel.position = SCNVector3(0, 0.5, 0)
        root.addChildNode(barrel)

        let imp = SCNNode(geometry: SCNCylinder(radius: 0.4, height: 0.05))
        imp.name = "anim_impeller"
        imp.geometry?.firstMaterial = steelMaterial(color: .lightGray)
        imp.position = SCNVector3(0, 0.5, 0)
        root.addChildNode(imp)

        for xOff: CGFloat in [-0.65, 0.65] {
            let pipe = SCNNode(geometry: SCNCylinder(radius: 0.1, height: 0.5))
            pipe.geometry?.firstMaterial = steelMaterial(color: .darkGray)
            pipe.eulerAngles = SCNVector3(0, 0, cPI / 2)
            pipe.position = SCNVector3(xOff, 0.5, 0)
            root.addChildNode(pipe)
        }

        let base = SCNNode(geometry: SCNBox(width: 1.4, height: 0.08, length: 1.0, chamferRadius: 0))
        base.geometry?.firstMaterial = steelMaterial(color: .darkGray)
        base.position = SCNVector3(0, -0.04, 0)
        root.addChildNode(base)
    }

    private static func buildMotor(into root: SCNNode, equip: HMI3DEquipment) {
        let color = equip.primaryNSColor

        let body = SCNNode(geometry: SCNCylinder(radius: 0.4, height: 0.8))
        body.geometry?.firstMaterial = paintedMaterial(color: color)
        body.position = SCNVector3(0, 0.4, 0)
        root.addChildNode(body)

        for i in 0..<5 {
            let fin = SCNNode(geometry: SCNTorus(ringRadius: 0.42, pipeRadius: 0.025))
            fin.geometry?.firstMaterial = steelMaterial(color: .darkGray)
            fin.eulerAngles = SCNVector3(cPI / 2, 0, 0)
            fin.position = SCNVector3(0, CGFloat(i) * 0.14 + 0.12, 0)
            root.addChildNode(fin)
        }

        let shaft = SCNNode(geometry: SCNCylinder(radius: 0.06, height: 0.35))
        shaft.name = "anim_impeller"
        shaft.geometry?.firstMaterial = steelMaterial(color: .lightGray)
        shaft.position = SCNVector3(0, 0.98, 0)
        root.addChildNode(shaft)

        let box = SCNNode(geometry: SCNBox(width: 0.25, height: 0.18, length: 0.12, chamferRadius: 0.01))
        box.geometry?.firstMaterial = paintedMaterial(color: .darkGray)
        box.position = SCNVector3(0.45, 0.55, 0)
        root.addChildNode(box)
    }

    private static func buildVerticalTank(into root: SCNNode, equip: HMI3DEquipment) {
        let color = equip.primaryNSColor

        let shell = SCNNode(geometry: SCNCylinder(radius: 0.45, height: 2.0))
        shell.geometry?.firstMaterial = steelMaterial(color: color)
        shell.position = SCNVector3(0, 1.0, 0)
        root.addChildNode(shell)

        let fillNode = SCNNode(geometry: SCNCylinder(radius: 0.42, height: 1.0))
        fillNode.name = "anim_fill"
        fillNode.geometry?.firstMaterial = {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = NSColor.blue.withAlphaComponent(0.55)
            m.isDoubleSided = true
            return m
        }()
        fillNode.position = SCNVector3(0, 0.5, 0)
        root.addChildNode(fillNode)

        let dome = SCNNode(geometry: SCNSphere(radius: 0.45))
        dome.geometry?.firstMaterial = steelMaterial(color: color)
        dome.position = SCNVector3(0, 2.0, 0)
        dome.scale = SCNVector3(1, 0.5, 1)
        root.addChildNode(dome)

        let inlet = SCNNode(geometry: SCNCylinder(radius: 0.08, height: 0.3))
        inlet.geometry?.firstMaterial = steelMaterial(color: .darkGray)
        inlet.eulerAngles = SCNVector3(cPI / 2, 0, 0)
        inlet.position = SCNVector3(0, 1.8, 0.48)
        root.addChildNode(inlet)

        let outlet = SCNNode(geometry: SCNCylinder(radius: 0.08, height: 0.3))
        outlet.geometry?.firstMaterial = inlet.geometry?.firstMaterial
        outlet.eulerAngles = SCNVector3(cPI / 2, 0, 0)
        outlet.position = SCNVector3(0, 0.2, 0.48)
        root.addChildNode(outlet)

        for (x, z): (CGFloat, CGFloat) in [(-0.35, -0.35), (0.35, -0.35), (-0.35, 0.35), (0.35, 0.35)] {
            let leg = SCNNode(geometry: SCNCylinder(radius: 0.04, height: 0.5))
            leg.geometry?.firstMaterial = steelMaterial(color: .darkGray)
            leg.position = SCNVector3(x, -0.25, z)
            root.addChildNode(leg)
        }
    }

    private static func buildHorizontalTank(into root: SCNNode, equip: HMI3DEquipment) {
        let color = equip.primaryNSColor

        let shell = SCNNode(geometry: SCNCylinder(radius: 0.4, height: 2.5))
        shell.geometry?.firstMaterial = steelMaterial(color: color)
        shell.eulerAngles = SCNVector3(0, 0, cPI / 2)
        shell.position = SCNVector3(0, 0.4, 0)
        root.addChildNode(shell)

        let fillNode = SCNNode(geometry: SCNCylinder(radius: 0.36, height: 2.5))
        fillNode.name = "anim_fill"
        fillNode.geometry?.firstMaterial = {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = NSColor.blue.withAlphaComponent(0.55)
            m.isDoubleSided = true
            return m
        }()
        fillNode.eulerAngles = SCNVector3(0, 0, cPI / 2)
        fillNode.position = SCNVector3(0, 0.4, 0)
        root.addChildNode(fillNode)

        for x: CGFloat in [-0.8, 0.8] {
            let saddle = SCNNode(geometry: SCNBox(width: 0.25, height: 0.3, length: 0.9, chamferRadius: 0.02))
            saddle.geometry?.firstMaterial = steelMaterial(color: .darkGray)
            saddle.position = SCNVector3(x, 0.1, 0)
            root.addChildNode(saddle)
        }
    }

    private static func buildProcessVessel(into root: SCNNode, equip: HMI3DEquipment) {
        let color = equip.primaryNSColor

        let shell = SCNNode(geometry: SCNCylinder(radius: 0.5, height: 2.5))
        shell.geometry?.firstMaterial = steelMaterial(color: color)
        shell.position = SCNVector3(0, 1.25, 0)
        root.addChildNode(shell)

        let fill = SCNNode(geometry: SCNCylinder(radius: 0.46, height: 1.0))
        fill.name = "anim_fill"
        fill.geometry?.firstMaterial = {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = NSColor.cyan.withAlphaComponent(0.5)
            m.isDoubleSided = true
            return m
        }()
        fill.position = SCNVector3(0, 0.5, 0)
        root.addChildNode(fill)

        let manway = SCNNode(geometry: SCNCylinder(radius: 0.22, height: 0.15))
        manway.geometry?.firstMaterial = steelMaterial(color: color)
        manway.position = SCNVector3(0, 2.55, 0)
        root.addChildNode(manway)

        let skirt = SCNNode(geometry: SCNCylinder(radius: 0.52, height: 0.4))
        skirt.geometry?.firstMaterial = steelMaterial(color: .darkGray)
        skirt.position = SCNVector3(0, -0.2, 0)
        root.addChildNode(skirt)
    }

    private static func buildSeparator(into root: SCNNode, equip: HMI3DEquipment) {
        buildHorizontalTank(into: root, equip: equip)
        let nozzle = SCNNode(geometry: SCNCylinder(radius: 0.12, height: 0.4))
        nozzle.geometry?.firstMaterial = steelMaterial(color: equip.primaryNSColor)
        nozzle.position = SCNVector3(-1.1, 0.6, 0)
        nozzle.eulerAngles = SCNVector3(0, 0, cPI / 2)
        root.addChildNode(nozzle)
    }

    private static func buildHeatExchanger(into root: SCNNode, equip: HMI3DEquipment) {
        let color = equip.primaryNSColor

        let shell = SCNNode(geometry: SCNCylinder(radius: 0.38, height: 1.8))
        shell.geometry?.firstMaterial = steelMaterial(color: color)
        shell.eulerAngles = SCNVector3(0, 0, cPI / 2)
        shell.position = SCNVector3(0, 0.38, 0)
        root.addChildNode(shell)

        for xOff: CGFloat in [-0.95, 0.95] {
            let head = SCNNode(geometry: SCNCylinder(radius: 0.40, height: 0.22))
            head.geometry?.firstMaterial = steelMaterial(color: .darkGray)
            head.eulerAngles = SCNVector3(0, 0, cPI / 2)
            head.position = SCNVector3(xOff, 0.38, 0)
            root.addChildNode(head)
        }

        for (x, y): (CGFloat, CGFloat) in [(-1.07, 0.55), (-1.07, 0.22), (1.07, 0.55), (1.07, 0.22)] {
            let noz = SCNNode(geometry: SCNCylinder(radius: 0.07, height: 0.25))
            noz.geometry?.firstMaterial = steelMaterial(color: .darkGray)
            noz.position = SCNVector3(x, y, 0)
            root.addChildNode(noz)
        }

        for (x, z): (CGFloat, CGFloat) in [(-0.6, 0), (0.6, 0)] {
            let leg = SCNNode(geometry: SCNBox(width: 0.12, height: 0.3, length: 0.5, chamferRadius: 0))
            leg.geometry?.firstMaterial = steelMaterial(color: .darkGray)
            leg.position = SCNVector3(x, 0.09, z)
            root.addChildNode(leg)
        }
    }

    private static func buildGateValve(into root: SCNNode, equip: HMI3DEquipment) {
        let color = equip.primaryNSColor

        let body = SCNNode(geometry: SCNBox(width: 0.5, height: 0.5, length: 0.3, chamferRadius: 0.03))
        body.geometry?.firstMaterial = steelMaterial(color: color)
        body.position = SCNVector3(0, 0.25, 0)
        root.addChildNode(body)

        let bonnet = SCNNode(geometry: SCNCylinder(radius: 0.12, height: 0.5))
        bonnet.geometry?.firstMaterial = steelMaterial(color: color)
        bonnet.position = SCNVector3(0, 0.75, 0)
        root.addChildNode(bonnet)

        let disc = SCNNode(geometry: SCNBox(width: 0.35, height: 0.08, length: 0.22, chamferRadius: 0.01))
        disc.name = "anim_disc"
        disc.geometry?.firstMaterial = steelMaterial(color: .lightGray)
        disc.position = SCNVector3(0, 0.4, 0)
        root.addChildNode(disc)

        let wheel = SCNNode(geometry: SCNTorus(ringRadius: 0.18, pipeRadius: 0.025))
        wheel.geometry?.firstMaterial = steelMaterial(color: .darkGray)
        wheel.position = SCNVector3(0, 1.1, 0)
        root.addChildNode(wheel)

        for xOff: CGFloat in [-0.45, 0.45] {
            let pipe = SCNNode(geometry: SCNCylinder(radius: 0.12, height: 0.3))
            pipe.geometry?.firstMaterial = steelMaterial(color: color)
            pipe.eulerAngles = SCNVector3(0, 0, cPI / 2)
            pipe.position = SCNVector3(xOff, 0.25, 0)
            root.addChildNode(pipe)
        }
    }

    private static func buildControlValve(into root: SCNNode, equip: HMI3DEquipment) {
        let color = equip.primaryNSColor

        let body = SCNNode(geometry: SCNBox(width: 0.4, height: 0.4, length: 0.28, chamferRadius: 0.04))
        body.geometry?.firstMaterial = steelMaterial(color: color)
        body.position = SCNVector3(0, 0.2, 0)
        root.addChildNode(body)

        let actuator = SCNNode(geometry: SCNCylinder(radius: 0.22, height: 0.25))
        actuator.geometry?.firstMaterial = paintedMaterial(color: .systemYellow)
        actuator.position = SCNVector3(0, 0.85, 0)
        root.addChildNode(actuator)

        let stem = SCNNode(geometry: SCNCylinder(radius: 0.04, height: 0.45))
        stem.geometry?.firstMaterial = steelMaterial(color: .lightGray)
        stem.position = SCNVector3(0, 0.55, 0)
        root.addChildNode(stem)

        let disc = SCNNode(geometry: SCNSphere(radius: 0.1))
        disc.name = "anim_disc"
        disc.geometry?.firstMaterial = steelMaterial(color: .lightGray)
        disc.position = SCNVector3(0, 0.4, 0)
        root.addChildNode(disc)

        for xOff: CGFloat in [-0.42, 0.42] {
            let pipe = SCNNode(geometry: SCNCylinder(radius: 0.1, height: 0.25))
            pipe.geometry?.firstMaterial = steelMaterial(color: color)
            pipe.eulerAngles = SCNVector3(0, 0, cPI / 2)
            pipe.position = SCNVector3(xOff, 0.2, 0)
            root.addChildNode(pipe)
        }
    }

    private static func buildPipe(into root: SCNNode, equip: HMI3DEquipment) {
        let pipe = SCNNode(geometry: SCNCylinder(radius: 0.12, height: 2.5))
        pipe.geometry?.firstMaterial = steelMaterial(color: equip.primaryNSColor)
        pipe.eulerAngles = SCNVector3(0, 0, cPI / 2)
        pipe.position = SCNVector3(0, 0.12, 0)
        root.addChildNode(pipe)

        for xOff: CGFloat in [-1.22, 1.22] {
            let flange = SCNNode(geometry: SCNCylinder(radius: 0.18, height: 0.08))
            flange.geometry?.firstMaterial = steelMaterial(color: .darkGray)
            flange.eulerAngles = SCNVector3(0, 0, cPI / 2)
            flange.position = SCNVector3(xOff, 0.12, 0)
            root.addChildNode(flange)
        }
    }

    private static func buildPipeElbow(into root: SCNNode, equip: HMI3DEquipment) {
        let color = equip.primaryNSColor
        let h = SCNNode(geometry: SCNCylinder(radius: 0.12, height: 0.7))
        h.geometry?.firstMaterial = steelMaterial(color: color)
        h.eulerAngles = SCNVector3(0, 0, cPI / 2)
        h.position = SCNVector3(-0.12, 0.12, 0)
        root.addChildNode(h)

        let v = SCNNode(geometry: SCNCylinder(radius: 0.12, height: 0.7))
        v.geometry?.firstMaterial = steelMaterial(color: color)
        v.position = SCNVector3(0.24, 0.47, 0)
        root.addChildNode(v)

        let corner = SCNNode(geometry: SCNSphere(radius: 0.14))
        corner.geometry?.firstMaterial = steelMaterial(color: color)
        corner.position = SCNVector3(0.24, 0.12, 0)
        root.addChildNode(corner)
    }

    private static func buildPipeTee(into root: SCNNode, equip: HMI3DEquipment) {
        let color = equip.primaryNSColor
        let run = SCNNode(geometry: SCNCylinder(radius: 0.12, height: 1.4))
        run.geometry?.firstMaterial = steelMaterial(color: color)
        run.eulerAngles = SCNVector3(0, 0, cPI / 2)
        run.position = SCNVector3(0, 0.12, 0)
        root.addChildNode(run)

        let branch = SCNNode(geometry: SCNCylinder(radius: 0.12, height: 0.5))
        branch.geometry?.firstMaterial = steelMaterial(color: color)
        branch.position = SCNVector3(0, 0.37, 0)
        root.addChildNode(branch)
    }

    private static func buildColumn(into root: SCNNode, equip: HMI3DEquipment) {
        let col = SCNNode(geometry: SCNBox(width: 0.35, height: 3.5, length: 0.35, chamferRadius: 0.04))
        col.geometry?.firstMaterial = steelMaterial(color: equip.primaryNSColor)
        col.position = SCNVector3(0, 1.75, 0)
        root.addChildNode(col)

        let base = SCNNode(geometry: SCNBox(width: 0.7, height: 0.08, length: 0.7, chamferRadius: 0))
        base.geometry?.firstMaterial = steelMaterial(color: .darkGray)
        base.position = SCNVector3(0, 0.04, 0)
        root.addChildNode(base)
    }

    private static func buildPlatform(into root: SCNNode, equip: HMI3DEquipment) {
        let deck = SCNNode(geometry: SCNBox(width: 3.5, height: 0.12, length: 2.5, chamferRadius: 0.02))
        deck.geometry?.firstMaterial = grating()
        deck.position = SCNVector3(0, 0.06, 0)
        root.addChildNode(deck)

        let postGeom = SCNCylinder(radius: 0.025, height: 0.9)
        postGeom.firstMaterial = steelMaterial(color: .yellow)
        for (x, z): (CGFloat, CGFloat) in [(-1.6, -1.1), (1.6, -1.1), (-1.6, 1.1), (1.6, 1.1), (0, -1.1), (0, 1.1)] {
            let post = SCNNode(geometry: postGeom)
            post.position = SCNVector3(x, 0.57, z)
            root.addChildNode(post)
        }

        let rail1 = SCNNode(geometry: SCNCylinder(radius: 0.02, height: 3.2))
        rail1.geometry?.firstMaterial = steelMaterial(color: .yellow)
        rail1.eulerAngles = SCNVector3(0, 0, cPI / 2)
        rail1.position = SCNVector3(0, 1.02, -1.1)
        root.addChildNode(rail1)

        let rail2 = SCNNode(geometry: SCNCylinder(radius: 0.02, height: 3.2))
        rail2.geometry?.firstMaterial = steelMaterial(color: .yellow)
        rail2.eulerAngles = SCNVector3(0, 0, cPI / 2)
        rail2.position = SCNVector3(0, 1.02, 1.1)
        root.addChildNode(rail2)
    }

    // MARK: - Materials

    static func steelMaterial(color: NSColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents   = color
        m.metalness.contents = NSNumber(value: 0.8)
        m.roughness.contents = NSNumber(value: 0.2)
        return m
    }

    static func paintedMaterial(color: NSColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents   = color
        m.metalness.contents = NSNumber(value: 0.3)
        m.roughness.contents = NSNumber(value: 0.5)
        return m
    }

    /// PBR glass material — nearly invisible shell with high reflectivity (transparent mode).
    static func glassMaterial(tint: NSColor = NSColor(red: 0.75, green: 0.92, blue: 1.0, alpha: 1.0)) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel      = .physicallyBased
        m.diffuse.contents   = tint.withAlphaComponent(0.10)
        m.metalness.contents = NSNumber(value: 0.0)
        m.roughness.contents = NSNumber(value: 0.04)   // very smooth = glass-like reflection
        m.transparency       = 0.82
        m.isDoubleSided      = true
        m.writesToDepthBuffer = true
        return m
    }

    /// Post-processes an equipment node tree: every child geometry whose name does NOT
    /// start with "anim_" gets the glass material so the process internals show through.
    static func applyTransparentShell(to node: SCNNode) {
        let glass = glassMaterial()
        node.enumerateChildNodes { child, _ in
            guard child.geometry != nil else { return }
            // Preserve anim_ nodes (fill, impeller, disc) — they represent visible process content.
            guard child.name?.hasPrefix("anim_") != true else { return }
            child.geometry?.firstMaterial = glass
        }
    }

    private static func grating() -> SCNMaterial {
        let size = 64
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor(white: 0.35, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
        NSColor(white: 0.55, alpha: 1).setStroke()
        let path = NSBezierPath()
        stride(from: 0, through: size, by: 8).forEach { v in
            path.move(to: NSPoint(x: v, y: 0)); path.line(to: NSPoint(x: v, y: size))
            path.move(to: NSPoint(x: 0, y: v)); path.line(to: NSPoint(x: size, y: v))
        }
        path.lineWidth = 1; path.stroke()
        image.unlockFocus()

        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents   = image
        m.metalness.contents = NSNumber(value: 0.6)
        m.roughness.contents = NSNumber(value: 0.5)
        return m
    }

    // MARK: - Helpers

    private static func setEmission(on node: SCNNode, color: NSColor) {
        node.enumerateHierarchy { child, _ in
            child.geometry?.materials.forEach { $0.emission.contents = color }
        }
    }

    private static func setMaterialColor(on node: SCNNode, color: NSColor) {
        node.geometry?.firstMaterial?.diffuse.contents = color
    }

    private static func fillLevelColor(fraction: Double) -> NSColor {
        if fraction > 0.85 {
            return NSColor(red: 1.0, green: 0.45, blue: 0.0, alpha: 0.75)
        } else if fraction > 0.65 {
            return NSColor(red: 0.0, green: 0.8, blue: 0.9, alpha: 0.65)
        } else {
            return NSColor(red: 0.1, green: 0.45, blue: 0.95, alpha: 0.55)
        }
    }
}
