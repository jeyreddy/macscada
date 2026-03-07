// MARK: - HMIDisplaySettingsView.swift
//
// Settings form for controlling HMI canvas display preferences.
// Changes take effect immediately via @AppStorage and @EnvironmentObject bindings.
//
// ── Sections ──────────────────────────────────────────────────────────────────
//   Display Mode (radio group):
//     .twoD   — traditional 2D P&ID canvas only
//     .threeD — SceneKit 3D view only
//     .both   — side-by-side HSplitView (2D left, 3D right)
//   3D Scene (visible only when displayMode != .twoD):
//     Environment picker — darkIndustrial / brightWarehouse / outdoorRefinery
//       → hmi3DSceneStore.setEnvironment(_:) → HMI3DSceneView updates lighting
//     Camera Preset picker — isometric / topDown / frontView / perspective
//       → hmi3DSceneStore.setCameraPreset(_:)
//     Show Grid toggle (@AppStorage "hmi3d.showGrid")
//     Show Labels toggle (@AppStorage "hmi3d.showLabels")
//     Reset Scene button → showResetConfirm .confirmationDialog
//       → hmi3DSceneStore.resetScene() (clears all equipment for current screen)
//
// ── @AppStorage Keys ──────────────────────────────────────────────────────────
//   "hmi.displayMode"   — HMIDisplayMode raw value (persisted)
//   "hmi3d.showGrid"    — Bool, default true (grid lines in 3D scene)
//   "hmi3d.showLabels"  — Bool, default true (equipment floating labels in 3D)
//   These keys are shared with HMI3DSceneView which reads them on updateNSView.
//
// ── Mode Description ──────────────────────────────────────────────────────────
//   modeDescription: computed String shown below the radio group explaining
//   what each mode does (used for user guidance, not stored).

import SwiftUI

// MARK: - HMIDisplaySettingsView

/// Settings tab for controlling HMI display mode (2D / 3D / Both),
/// 3D scene environment style, grid and labels, and scene reset.
struct HMIDisplaySettingsView: View {
    @EnvironmentObject var hmi3DSceneStore: HMI3DSceneStore

    @AppStorage("hmi.displayMode") private var displayMode: HMIDisplayMode = .twoD

    @State private var showResetConfirm = false

    var body: some View {
        Form {
            // ── Display Mode ─────────────────────────────────────────────────
            Section("Display Mode") {
                Picker("Mode", selection: $displayMode) {
                    ForEach(HMIDisplayMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(modeDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // ── 3D Scene Settings ────────────────────────────────────────────
            if displayMode != .twoD {
                Section("3D Scene") {
                    Picker("Environment", selection: Binding(
                        get: { hmi3DSceneStore.scene.environmentStyle },
                        set: { hmi3DSceneStore.setEnvironment($0) }
                    )) {
                        ForEach(Scene3DEnvironment.allCases, id: \.self) { env in
                            Text(env.rawValue).tag(env)
                        }
                    }

                    Toggle("Show Grid", isOn: Binding(
                        get: { hmi3DSceneStore.scene.showGrid },
                        set: { hmi3DSceneStore.setShowGrid($0) }
                    ))

                    Toggle("Show Labels", isOn: Binding(
                        get: { hmi3DSceneStore.scene.showLabels },
                        set: { hmi3DSceneStore.setShowLabels($0) }
                    ))
                }

                Section("Scene Management") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Objects in scene: \(hmi3DSceneStore.scene.equipment.count)")
                                .font(.caption)
                            Text("Scene is saved automatically per HMI screen.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Reset Scene…") {
                            showResetConfirm = true
                        }
                        .tint(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset 3D Scene?",
                            isPresented: $showResetConfirm,
                            titleVisibility: .visible) {
            Button("Reset", role: .destructive) {
                hmi3DSceneStore.resetScene()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All 3D equipment in this scene will be permanently deleted.")
        }
    }

    private var modeDescription: String {
        switch displayMode {
        case .twoD:   return "Classic 2D P&ID canvas — full screen."
        case .threeD: return "Immersive 3D plant-floor builder — full screen."
        case .both:   return "2D canvas on the left, 3D scene on the right (HSplitView)."
        }
    }
}
