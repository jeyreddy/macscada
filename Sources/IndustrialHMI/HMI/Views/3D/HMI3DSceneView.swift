// MARK: - HMI3DSceneView.swift
//
// NSViewRepresentable that hosts a SceneKit SCNView for the 3D plant-floor HMI.
// Bridges SwiftUI state (scene data, live values, selection) to the SceneKit world.
//
// ── Scene Build ───────────────────────────────────────────────────────────────
//   makeNSView() constructs the initial SCNScene from HMI3DScene data:
//     - Floor grid (SCNFloor + grid material)
//     - Grid lines (SCNNode array)
//     - Equipment nodes via SceneKitEquipmentBuilder.makeNode(for:)
//     - Camera node (preset position + lookAt constraint)
//     - Lighting: ambient + key directional light (intensity from Scene3DEnvironment)
//   Camera presets: isometric, topDown, frontView, perspective (positions in HMI3DModels).
//
// ── Update Cycle ──────────────────────────────────────────────────────────────
//   updateNSView() called by SwiftUI when @Binding/let values change:
//     1. Sync environment (backgroundColor, lighting intensity)
//     2. Add nodes for new equipment (by comparing node names to equipment IDs)
//     3. Remove nodes for deleted equipment
//     4. Call SceneKitEquipmentBuilder.updateLiveAnimations() for each equipment
//        to push liveValues (fill level, rotation speed, alarm glow)
//
// ── Selection ─────────────────────────────────────────────────────────────────
//   NSClickGestureRecognizer → Coordinator.handleClick(_:)
//     hitTest at click location → find SCNNode → walk up to root equipment node
//     (named equip.nodeName = equip.id.uuidString) → set selectedEquipmentId binding.
//     Selected node gets a highlight by adjusting its material emissive intensity.
//
// ── Drag to Move (Edit Mode) ──────────────────────────────────────────────────
//   NSPanGestureRecognizer → Coordinator.handlePan(_:)
//     Started: hitTest to find dragged equipment node.
//     Changed: project drag delta onto XZ floor plane using camera view.
//     Ended: call onEquipmentMoved(id, newX, newZ) → HMIDesignerView updates store.
//   GestureRecognizer delegate allows simultaneous recognition with camera orbit.
//
// ── Live Animations ───────────────────────────────────────────────────────────
//   Equipment tagged with liveValues gets animated by SceneKitEquipmentBuilder:
//     Pumps/motors: rotation speed ∝ liveValue
//     Tanks/vessels: fill node scaleY ∝ liveValue / 100
//     Alarm state: emissiveColor pulsed red via SCNAction repeatForever(sequence)

import SwiftUI
import SceneKit
import AppKit

// MARK: - HMI3DSceneView

/// NSViewRepresentable wrapping SCNView.
/// The scene is rebuilt from HMI3DScene data; live tag values are pushed
/// each frame via updateNSView → SceneKitEquipmentBuilder.updateLiveAnimations.
struct HMI3DSceneView: NSViewRepresentable {

    let scene3D: HMI3DScene
    let liveValues: [String: Double]        // tagName → current value
    let alarmTagNames: Set<String>          // tags with active alarms
    @Binding var selectedEquipmentId: UUID?
    var isEditMode: Bool = true
    var isTransparentMode: Bool = false
    /// Called on the main thread when the user drags an object. Provides new X and Z (floor-plane) position.
    var onEquipmentMoved: ((UUID, Float, Float) -> Void)? = nil

    // MARK: - NSViewRepresentable

    func makeNSView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.scene = buildScene(from: scene3D)
        scnView.autoenablesDefaultLighting = false
        scnView.antialiasingMode = .multisampling4X
        scnView.showsStatistics = false
        scnView.backgroundColor = scene3D.environmentStyle.backgroundColor

        // Camera
        let cameraNode = makeCameraNode(preset: scene3D.cameraPreset)
        scnView.scene?.rootNode.addChildNode(cameraNode)
        scnView.pointOfView = cameraNode

        // Allow orbit (drag to rotate, scroll to zoom)
        scnView.allowsCameraControl = true
        scnView.defaultCameraController.interactionMode = .orbitTurntable

        // Selection tap gesture
        let tap = NSClickGestureRecognizer(target: context.coordinator,
                                            action: #selector(Coordinator.handleClick(_:)))
        scnView.addGestureRecognizer(tap)

        // Drag-to-move pan gesture (simultaneous with camera pan)
        let pan = NSPanGestureRecognizer(target: context.coordinator,
                                          action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = context.coordinator
        scnView.addGestureRecognizer(pan)

        context.coordinator.scnView = scnView
        return scnView
    }

    func updateNSView(_ scnView: SCNView, context: Context) {
        context.coordinator.parent = self          // keep coordinator's closure references current
        guard let rootNode = scnView.scene?.rootNode else { return }

        // Sync environment
        scnView.backgroundColor = scene3D.environmentStyle.backgroundColor
        applyLighting(to: rootNode, env: scene3D.environmentStyle)

        // Only reset the camera when the preset selection actually changes.
        // Comparing against coordinator.lastAppliedPreset (not the node name) prevents
        // every tag-poll update from wiping out the user's zoom / orbit position.
        if context.coordinator.lastAppliedPreset != scene3D.cameraPreset {
            context.coordinator.lastAppliedPreset = scene3D.cameraPreset
            scnView.pointOfView?.removeFromParentNode()
            let newCam = makeCameraNode(preset: scene3D.cameraPreset)
            rootNode.addChildNode(newCam)
            scnView.pointOfView = newCam
        }

        // Build set of node names that should exist
        let expectedNames = Set(scene3D.equipment.map { $0.nodeName })

        // Remove nodes that no longer exist
        for child in rootNode.childNodes where child.name?.hasPrefix("eq_") == true {
            if !expectedNames.contains(child.name ?? "") {
                child.removeFromParentNode()
            }
        }

        // Add or update equipment nodes
        for equip in scene3D.equipment {
            let liveValue = equip.tagBinding.flatMap { liveValues[$0] }
            let isAlarm   = equip.tagBinding.map { alarmTagNames.contains($0) } ?? false

            let targetNode: SCNNode
            if let existing = rootNode.childNode(withName: equip.nodeName, recursively: false) {
                // Check if transparent mode toggled — rebuild geometry once on change
                let prevTransparent = existing.value(forKey: "transpMode") as? Bool ?? false
                if prevTransparent != isTransparentMode {
                    existing.removeFromParentNode()
                    let fresh = SceneKitEquipmentBuilder.makeNode(for: equip)
                    if isTransparentMode { SceneKitEquipmentBuilder.applyTransparentShell(to: fresh) }
                    fresh.setValue(isTransparentMode, forKey: "transpMode")
                    rootNode.addChildNode(fresh)
                    targetNode = fresh
                } else {
                    // Same mode — update position/scale only (no geometry rebuild)
                    SCNTransaction.begin()
                    SCNTransaction.animationDuration = 0
                    existing.position    = SCNVector3(equip.posX, equip.posY, equip.posZ)
                    existing.eulerAngles = SCNVector3(0, CGFloat(equip.rotationY) * CGFloat.pi / 180, 0)
                    existing.scale       = SCNVector3(equip.scaleX, equip.scaleY, equip.scaleZ)
                    SCNTransaction.commit()
                    targetNode = existing
                }
            } else {
                // Brand-new node
                let node = SceneKitEquipmentBuilder.makeNode(for: equip)
                if isTransparentMode { SceneKitEquipmentBuilder.applyTransparentShell(to: node) }
                node.setValue(isTransparentMode, forKey: "transpMode")
                rootNode.addChildNode(node)
                targetNode = node
            }

            SceneKitEquipmentBuilder.updateLiveAnimations(
                node:              targetNode,
                equip:             equip,
                liveValue:         liveValue,
                isAlarm:           isAlarm,
                isEditMode:        isEditMode,
                isTransparentMode: isTransparentMode
            )
            setSelection(on: targetNode, selected: equip.id == selectedEquipmentId)
        }

        // Grid floor visibility
        if let floor = rootNode.childNode(withName: "floor_grid", recursively: false) {
            floor.isHidden = !scene3D.showGrid
        }

        // Label nodes
        updateLabels(in: rootNode)
    }

    // MARK: - Coordinator (selection)

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator: NSObject, NSGestureRecognizerDelegate {
        var parent: HMI3DSceneView
        weak var scnView: SCNView?
        var dragEquipmentId: UUID?          // non-nil while dragging an equipment node

        /// Tracks which preset was last applied so updateNSView only resets the camera
        /// when the user explicitly picks a different preset — not on every tag-value update.
        var lastAppliedPreset: Camera3DPreset? = nil

        init(parent: HMI3DSceneView) {
            self.parent = parent
        }

        // Allow our pan gesture to fire alongside SceneKit's built-in camera pan.
        func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: NSGestureRecognizer) -> Bool { true }

        @objc func handleClick(_ recognizer: NSClickGestureRecognizer) {
            guard let scnView else { return }
            let pt = recognizer.location(in: scnView)
            let hits = scnView.hitTest(pt, options: [.searchMode: SCNHitTestSearchMode.all.rawValue])

            // Walk up the node tree to find a root equipment node (name starts with "eq_")
            for hit in hits {
                var node: SCNNode? = hit.node
                while let n = node {
                    if let name = n.name, name.hasPrefix("eq_"),
                       let uuidStr = name.split(separator: "_", maxSplits: 1).last,
                       let uuid = UUID(uuidString: String(uuidStr)) {
                        DispatchQueue.main.async {
                            if self.parent.selectedEquipmentId == uuid {
                                self.parent.selectedEquipmentId = nil   // deselect
                            } else {
                                self.parent.selectedEquipmentId = uuid
                            }
                        }
                        return
                    }
                    node = n.parent
                }
            }
            // Click on empty space — deselect
            DispatchQueue.main.async { self.parent.selectedEquipmentId = nil }
        }

        // MARK: - Drag-to-move (edit mode only)

        @objc func handlePan(_ recognizer: NSPanGestureRecognizer) {
            guard let scnView, parent.isEditMode else { return }
            let pt = recognizer.location(in: scnView)

            switch recognizer.state {
            case .began:
                // Hit-test to find the equipment node under the cursor
                let hits = scnView.hitTest(pt, options: nil)
                dragEquipmentId = nil
                for hit in hits {
                    var node: SCNNode? = hit.node
                    while let n = node {
                        if let name = n.name, name.hasPrefix("eq_"),
                           let uuidStr = name.split(separator: "_", maxSplits: 1).last,
                           let uuid = UUID(uuidString: String(uuidStr)) {
                            dragEquipmentId = uuid
                            scnView.allowsCameraControl = false   // pause camera while dragging object
                            DispatchQueue.main.async { self.parent.selectedEquipmentId = uuid }
                            return
                        }
                        node = n.parent
                    }
                }
                // Nothing hit — camera pan continues via simultaneous recognition.

            case .changed:
                guard let equipId = dragEquipmentId else { return }
                if let pos = floorPosition(at: pt, in: scnView) {
                    let nx = Float(pos.x), nz = Float(pos.z)
                    DispatchQueue.main.async { self.parent.onEquipmentMoved?(equipId, nx, nz) }
                }

            case .ended, .cancelled, .failed:
                if dragEquipmentId != nil {
                    scnView.allowsCameraControl = true
                    dragEquipmentId = nil
                }

            default: break
            }
        }

        /// Intersects a screen-space ray with the Y = 0 (floor) plane and returns the world-space point.
        private func floorPosition(at pt: CGPoint, in scnView: SCNView) -> SCNVector3? {
            let near = scnView.unprojectPoint(SCNVector3(CGFloat(pt.x), CGFloat(pt.y), 0))
            let far  = scnView.unprojectPoint(SCNVector3(CGFloat(pt.x), CGFloat(pt.y), 1))
            let dy = far.y - near.y
            guard abs(dy) > 1e-6 else { return nil }
            let t = -near.y / dy
            guard t >= 0 else { return nil }
            return SCNVector3(near.x + t * (far.x - near.x), 0, near.z + t * (far.z - near.z))
        }
    }

    // MARK: - Scene Construction

    private func buildScene(from data: HMI3DScene) -> SCNScene {
        let scene = SCNScene()
        let root  = scene.rootNode

        // Floor + Grid
        let floor = buildFloor(showGrid: data.showGrid)
        root.addChildNode(floor)

        // Lighting
        applyLighting(to: root, env: data.environmentStyle)

        return scene
    }

    private func buildFloor(showGrid: Bool) -> SCNNode {
        let floorGeom = SCNFloor()
        floorGeom.reflectivity = 0.15

        // Procedural grid texture
        let gridSize = 512
        let tileSize = 32
        let image = NSImage(size: NSSize(width: gridSize, height: gridSize))
        image.lockFocus()
        NSColor(white: 0.10, alpha: 1).setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: gridSize, height: gridSize))
        NSColor(white: 0.28, alpha: 1).setStroke()
        let path = NSBezierPath()
        stride(from: 0, through: gridSize, by: tileSize).forEach { v in
            path.move(to: NSPoint(x: v, y: 0))
            path.line(to: NSPoint(x: v, y: gridSize))
            path.move(to: NSPoint(x: 0, y: v))
            path.line(to: NSPoint(x: gridSize, y: v))
        }
        path.lineWidth = 0.8
        path.stroke()
        image.unlockFocus()

        floorGeom.firstMaterial?.diffuse.contents = image
        floorGeom.firstMaterial?.diffuse.wrapS = .repeat
        floorGeom.firstMaterial?.diffuse.wrapT = .repeat
        floorGeom.firstMaterial?.roughness.contents = NSNumber(value: 0.85)

        let node = SCNNode(geometry: floorGeom)
        node.name = "floor_grid"
        node.isHidden = false
        return node
    }

    private func applyLighting(to root: SCNNode, env: Scene3DEnvironment) {
        // Remove old lights
        root.childNodes.filter { $0.name?.hasPrefix("light_") == true }.forEach { $0.removeFromParentNode() }

        // Ambient
        let ambient = SCNNode()
        ambient.name = "light_ambient"
        let ambLight = SCNLight()
        ambLight.type = .ambient
        ambLight.color = env.ambientColor
        ambLight.intensity = env.ambientIntensity
        ambient.light = ambLight
        root.addChildNode(ambient)

        // Key directional light
        let keyNode = SCNNode()
        keyNode.name = "light_key"
        keyNode.position = SCNVector3(10, 20, 10)
        keyNode.eulerAngles = SCNVector3(-CGFloat.pi/4, CGFloat.pi/6, 0)
        let keyLight = SCNLight()
        keyLight.type = .directional
        keyLight.color = NSColor.white
        keyLight.intensity = env.keyLightIntensity
        keyLight.castsShadow = true
        keyLight.shadowSampleCount = 4
        keyLight.shadowRadius = 3
        keyNode.light = keyLight
        root.addChildNode(keyNode)

        // Overhead spot
        let spotNode = SCNNode()
        spotNode.name = "light_spot"
        spotNode.position = SCNVector3(0, 18, 0)
        spotNode.eulerAngles = SCNVector3(-CGFloat.pi/2, 0, 0)
        let spot = SCNLight()
        spot.type = .spot
        spot.color = NSColor.white
        spot.intensity = 2000
        spot.spotInnerAngle = 30
        spot.spotOuterAngle = 70
        spot.castsShadow = false
        spotNode.light = spot
        root.addChildNode(spotNode)
    }

    private func makeCameraNode(preset: Camera3DPreset) -> SCNNode {
        let cam = SCNCamera()
        cam.zFar = 200
        cam.zNear = 0.1
        let node = SCNNode()
        node.name = preset.rawValue
        node.camera = cam
        node.position = preset.position
        node.look(at: SCNVector3(0, 0, 0))
        return node
    }

    // MARK: - Label + Value Badge Management
    //
    // Label nodes are cached by equipment ID.  The node is only removed and
    // recreated when its text content or showLabels flag actually changes.
    // Position updates (from drag-to-move) are applied in-place via SCNTransaction
    // so no SCNText geometry is reallocated on every tag-poll update cycle.

    private func updateLabels(in root: SCNNode) {
        for equip in scene3D.equipment {
            guard let equipNode = root.childNode(withName: equip.nodeName, recursively: false) else {
                // Equipment node not yet added — remove any stale label from a previous cycle
                root.childNode(withName: "label_\(equip.id.uuidString)", recursively: false)?.removeFromParentNode()
                root.childNode(withName: "val_\(equip.id.uuidString)",   recursively: false)?.removeFromParentNode()
                continue
            }

            let (_, maxBB) = equipNode.boundingBox
            let topY = Float(maxBB.y) * equip.scaleY

            // ── Equipment name label ─────────────────────────────────────────────
            let labelName = "label_\(equip.id.uuidString)"
            if scene3D.showLabels {
                let labelPos = SCNVector3(equip.posX - 0.3, equip.posY + topY + 0.3, equip.posZ)
                if let existing = root.childNode(withName: labelName, recursively: false) {
                    // Check whether the text changed (stored as user attribute)
                    let cachedText = existing.value(forKey: "labelText") as? String ?? ""
                    if cachedText == equip.label {
                        // Same text — only move the node, no geometry rebuild
                        SCNTransaction.begin()
                        SCNTransaction.animationDuration = 0
                        existing.position = labelPos
                        SCNTransaction.commit()
                    } else {
                        // Label text changed — rebuild geometry once
                        existing.removeFromParentNode()
                        root.addChildNode(makeLabelNode(text: equip.label, name: labelName,
                                                        position: labelPos))
                    }
                } else {
                    root.addChildNode(makeLabelNode(text: equip.label, name: labelName,
                                                    position: labelPos))
                }
            } else {
                // showLabels toggled off — remove label if present
                root.childNode(withName: labelName, recursively: false)?.removeFromParentNode()
            }

            // ── Live value badge ─────────────────────────────────────────────────
            let valName  = "val_\(equip.id.uuidString)"
            if let tagKey = equip.tagBinding {
                let liveVal  = liveValues[tagKey]
                let valStr   = liveVal.map { String(format: "%.1f", $0) } ?? "---"
                let valColor: NSColor = liveVal != nil
                    ? NSColor(red: 0.10, green: 1.00, blue: 0.30, alpha: 1.0)
                    : NSColor(red: 1.00, green: 0.75, blue: 0.00, alpha: 1.0)
                let badgeOffset: Float = scene3D.showLabels ? 0.85 : 0.50
                let valPos = SCNVector3(equip.posX - 0.2, equip.posY + topY + badgeOffset, equip.posZ)

                if let existing = root.childNode(withName: valName, recursively: false) {
                    let cachedStr   = existing.value(forKey: "valText")   as? String    ?? ""
                    let cachedColor = existing.value(forKey: "valColor")  as? NSColor
                    if cachedStr == valStr && cachedColor == valColor {
                        // Value and colour unchanged — just reposition
                        SCNTransaction.begin()
                        SCNTransaction.animationDuration = 0
                        existing.position = valPos
                        SCNTransaction.commit()
                    } else {
                        // Value changed — rebuild text geometry
                        existing.removeFromParentNode()
                        root.addChildNode(makeValueNode(text: valStr, color: valColor,
                                                        name: valName, position: valPos))
                    }
                } else {
                    root.addChildNode(makeValueNode(text: valStr, color: valColor,
                                                    name: valName, position: valPos))
                }
            } else {
                root.childNode(withName: valName, recursively: false)?.removeFromParentNode()
            }
        }

        // Remove orphaned label/val nodes for equipment that has been deleted
        let liveIDs = Set(scene3D.equipment.map { $0.id.uuidString })
        for child in root.childNodes {
            guard let name = child.name else { continue }
            if name.hasPrefix("label_") || name.hasPrefix("val_") {
                let idPart = String(name.split(separator: "_", maxSplits: 1).last ?? "")
                if !liveIDs.contains(idPart) {
                    child.removeFromParentNode()
                }
            }
        }
    }

    private func makeLabelNode(text: String, name: String, position: SCNVector3) -> SCNNode {
        let geom = SCNText(string: text, extrusionDepth: 0.01)
        geom.font = NSFont.boldSystemFont(ofSize: 0.3)
        geom.firstMaterial?.diffuse.contents = NSColor.white
        geom.firstMaterial?.lightingModel    = .constant
        let node = SCNNode(geometry: geom)
        node.name     = name
        node.scale    = SCNVector3(0.4, 0.4, 0.4)
        node.position = position
        node.constraints = [makeBillboard()]
        node.setValue(text, forKey: "labelText")
        return node
    }

    private func makeValueNode(text: String, color: NSColor,
                                name: String, position: SCNVector3) -> SCNNode {
        let geom = SCNText(string: text, extrusionDepth: 0.005)
        geom.font = NSFont.monospacedSystemFont(ofSize: 0.4, weight: .bold)
        geom.firstMaterial?.diffuse.contents  = color
        geom.firstMaterial?.emission.contents = color.withAlphaComponent(0.5)
        geom.firstMaterial?.lightingModel     = .constant
        let node = SCNNode(geometry: geom)
        node.name     = name
        node.scale    = SCNVector3(0.4, 0.4, 0.4)
        node.position = position
        node.constraints = [makeBillboard()]
        node.setValue(text,  forKey: "valText")
        node.setValue(color, forKey: "valColor")
        return node
    }

    /// Billboard constraint — node always faces the camera on all axes (text readability).
    private func makeBillboard() -> SCNBillboardConstraint {
        let c = SCNBillboardConstraint()
        c.freeAxes = .all
        return c
    }

    // MARK: - Selection highlight

    private func setSelection(on node: SCNNode, selected: Bool) {
        let color = selected ? NSColor.white.withAlphaComponent(0.3) : NSColor.black.withAlphaComponent(0)
        node.enumerateHierarchy { child, _ in
            child.geometry?.materials.forEach {
                $0.emission.contents = color
            }
        }
    }
}
