// MARK: - HMI3DDesignerView.swift
//
// Full 3D plant-floor editor combining the equipment palette, SceneKit canvas,
// and 3D inspector into one coordinated view.
//
// ── Layout ────────────────────────────────────────────────────────────────────
//   VStack:
//     toolbarRow — Edit/Run toggle, display mode picker (when showDisplayModePicker=true),
//                  transparent mode toggle, camera preset picker
//     HSplitView:
//       HMI3DEquipmentPalette  (left — drag-to-add equipment list)
//       ZStack:
//         HMI3DSceneView       (SceneKit 3D canvas, fills remaining space)
//         HMI3DInspectorPanel  (trailing overlay, shown in edit mode with selection)
//
// ── Live Tag Values ───────────────────────────────────────────────────────────
//   liveValues: [String: Double] computed from hmi3DSceneStore.scene.equipment:
//     for each equipment with a tagBinding, reads tagEngine.tags[tag]?.value.numericValue.
//   Passed to HMI3DSceneView and forwarded to SceneKitEquipmentBuilder.updateLiveAnimations().
//   SwiftUI re-computes on every tagEngine.$tags change (ObservableObject).
//
// ── Equipment Interaction ─────────────────────────────────────────────────────
//   selectedEquipmentId: UUID? — set by HMI3DSceneView.Coordinator on click.
//   In edit mode: dragging equipment calls onEquipmentMoved(id, newX, newZ)
//     → updates posX/posZ in hmi3DSceneStore.scene.equipment[idx].
//   HMI3DInspectorPanel reads selectedEquipmentId to show the property editor.
//
// ── Display Mode Picker ───────────────────────────────────────────────────────
//   showDisplayModePicker=false when embedded in the "Both" HSplitView in
//   HMIDesignerView (the 2D side already shows the picker there).
//   @AppStorage("hmi.displayMode") shared with HMIDesignerView via @AppStorage.
//
// ── Transparent Mode ──────────────────────────────────────────────────────────
//   isTransparentMode = true: SceneKitEquipmentBuilder renders vessel/tank walls
//   as translucent (opacity ~0.3) so internal fill levels are visible.

import SwiftUI

// MARK: - HMI3DDesignerView

/// Full 3D plant-floor editor: palette sidebar + SceneKit canvas + inspector overlay.
/// Toolbar implemented as toolbarRow (not .toolbar{}) since this is not in a NavigationStack.
struct HMI3DDesignerView: View {
    @EnvironmentObject var hmi3DSceneStore: HMI3DSceneStore
    @EnvironmentObject var tagEngine: TagEngine
    @EnvironmentObject var hmiScreenStore: HMIScreenStore

    /// Set to false when this view is embedded in the "Both" split layout
    /// (the 2D side already shows the picker there).
    var showDisplayModePicker: Bool = true

    @AppStorage("hmi.displayMode") private var displayMode: HMIDisplayMode = .twoD

    @State private var isEditMode: Bool = true
    @State private var isTransparentMode: Bool = false
    @State private var selectedEquipmentId: UUID? = nil

    // Live tag values for animation
    private var liveValues: [String: Double] {
        var dict: [String: Double] = [:]
        for equip in hmi3DSceneStore.scene.equipment {
            if let tag = equip.tagBinding,
               let val = tagEngine.tags[tag]?.value.numericValue {
                dict[tag] = val
            }
        }
        return dict
    }

    // Tags with active alarms (from @EnvironmentObject AlarmManager is not injected here —
    // we use an empty set; HMI3DSceneView receives it as a parameter)
    private var alarmTagNames: Set<String> { [] }

    var body: some View {
        VStack(spacing: 0) {
            toolbarRow
            Divider()
            HSplitView {
                // ── Equipment Palette ─────────────────────────────────────────
                HMI3DEquipmentPalette(isEditMode: $isEditMode)
                    .environmentObject(hmi3DSceneStore)

                // ── 3D Canvas + Inspector overlay ─────────────────────────────
                ZStack(alignment: .trailing) {
                    HMI3DSceneView(
                        scene3D:             hmi3DSceneStore.scene,
                        liveValues:          liveValues,
                        alarmTagNames:       alarmTagNames,
                        selectedEquipmentId: $selectedEquipmentId,
                        isEditMode:          isEditMode,
                        isTransparentMode:   isTransparentMode,
                        onEquipmentMoved:    { id, x, z in
                            guard let idx = hmi3DSceneStore.scene.equipment
                                    .firstIndex(where: { $0.id == id }) else { return }
                            var equip = hmi3DSceneStore.scene.equipment[idx]
                            equip.posX = x
                            equip.posZ = z
                            hmi3DSceneStore.updateEquipment(equip)
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if isEditMode && selectedEquipmentId != nil {
                        HMI3DInspectorPanel(selectedEquipmentId: $selectedEquipmentId)
                            .environmentObject(hmi3DSceneStore)
                            .environmentObject(tagEngine)
                            .frame(width: 240)
                            .background(Color(nsColor: .windowBackgroundColor).opacity(0.97))
                            .overlay(
                                Rectangle().frame(width: 1).foregroundColor(Color(nsColor: .separatorColor)),
                                alignment: .leading
                            )
                            .transition(.move(edge: .trailing))
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: isEditMode && selectedEquipmentId != nil)
            }
        }
        .onAppear {
            // Ensure scene is linked to the current HMI screen
            if hmi3DSceneStore.currentScreenId == nil,
               let id = hmiScreenStore.currentScreenId {
                hmi3DSceneStore.loadScene(for: id)
            }
        }
    }

    // MARK: - Toolbar (no NavigationStack — plain HStack)

    private var toolbarRow: some View {
        HStack(spacing: 12) {
            Text("3D Scene")
                .font(.caption.bold())
                .foregroundColor(.secondary)

            Divider().frame(height: 22)

            // Display mode — only shown when this is the standalone 3D view
            if showDisplayModePicker {
                Picker("View", selection: $displayMode) {
                    ForEach(HMIDisplayMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 130)
                .help("Switch between 2D canvas, 3D scene, or both side-by-side")

                Divider().frame(height: 22)
            }

            // Edit / Run toggle
            Picker("Mode", selection: $isEditMode) {
                Label("Edit", systemImage: "pencil").tag(true)
                Label("Run",  systemImage: "play.fill").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 160)
            .onChange(of: isEditMode) { _, editMode in
                if !editMode { selectedEquipmentId = nil }
            }

            Divider().frame(height: 22)

            // Camera preset picker
            Picker("Camera", selection: Binding(
                get: { hmi3DSceneStore.scene.cameraPreset },
                set: { hmi3DSceneStore.setCameraPreset($0) }
            )) {
                ForEach(Camera3DPreset.allCases, id: \.self) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            .frame(maxWidth: 140)
            .help("Camera viewpoint")

            Divider().frame(height: 22)

            // Show grid toggle
            Toggle("Grid", isOn: Binding(
                get: { hmi3DSceneStore.scene.showGrid },
                set: { hmi3DSceneStore.setShowGrid($0) }
            ))
            .toggleStyle(.checkbox)
            .font(.caption)

            // Show labels toggle
            Toggle("Labels", isOn: Binding(
                get: { hmi3DSceneStore.scene.showLabels },
                set: { hmi3DSceneStore.setShowLabels($0) }
            ))
            .toggleStyle(.checkbox)
            .font(.caption)

            // Transparent glass mode toggle
            Toggle("Glass", isOn: $isTransparentMode)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("See-through glass mode — reveals live process content inside equipment")

            Divider().frame(height: 22)

            // Clear scene
            if isEditMode {
                Button {
                    selectedEquipmentId = nil
                    hmi3DSceneStore.clearScene()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .help("Remove all equipment from scene")
            }

            Spacer()

            Text("\(hmi3DSceneStore.scene.equipment.count) object\(hmi3DSceneStore.scene.equipment.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
