// MARK: - HMIDesignerView.swift
//
// Top-level container for the "HMI Screens" tab. Always alive in MainView's ZStack
// (opacity-hidden rather than removed) so edit state survives tab switches.
//
// ── Display Modes ─────────────────────────────────────────────────────────────
//   @AppStorage("hmi.displayMode") HMIDisplayMode controls which content renders:
//   .twoD   — traditional 2D P&ID canvas (HMICanvasView)
//   .threeD — SceneKit 3D view (HMI3DDesignerView)
//   .both   — HSplitView with 2D on left and 3D on right
//   HMIDisplaySettingsView lets users switch modes.
//
// ── 2D Layout ─────────────────────────────────────────────────────────────────
//   HSplitView:
//     Left  — HMIScreenListPane (screen browser sidebar)
//     Right — VStack:
//               toolbarRow (Edit/Run toggle + object palette + screen settings)
//               HMICanvasView (canvas + drag-create)
//               HMIInspectorPanel (overlaid on right edge in edit mode)
//
// ── Edit / Run Mode ───────────────────────────────────────────────────────────
//   isEditMode @State drives HMICanvasView and HMIInspectorPanel.
//   Toggled by the toolbar Edit/Run button.
//   On transition to run mode: selectedObjectId + activeTool cleared.
//   faceplateObjectId drives the run-mode HMIFaceplateView popover.
//
// ── Object Type Palette ───────────────────────────────────────────────────────
//   toolbarRow shows object type buttons when isEditMode = true.
//   Tapping a button sets activeTool → HMICanvasView creates objects of that type
//   when the user drags on the canvas background.
//   activeTool = nil = pointer/select mode.
//
// ── HMIScreenListPane ─────────────────────────────────────────────────────────
//   Left sidebar showing all screens with add/rename/delete/duplicate controls.
//   Selecting a screen calls hmiScreenStore.setCurrentScreen(id:).
//   CompositeHMIView (full-screen overview) is accessed via a toolbar button.

import SwiftUI

// MARK: - HMIDesignerView

/// Top-level view for the "HMI Screens" tab.
/// Always alive in the ZStack (like TrendView) so state is preserved across tab switches.
/// Phase 16: supports 2D / 3D / Both display modes via @AppStorage.
struct HMIDesignerView: View {
    @EnvironmentObject var tagEngine: TagEngine
    @EnvironmentObject var alarmManager: AlarmManager
    @EnvironmentObject var hmiScreenStore: HMIScreenStore
    @EnvironmentObject var hmi3DSceneStore: HMI3DSceneStore

    // Display mode — shared across views
    @AppStorage("hmi.displayMode") private var displayMode: HMIDisplayMode = .twoD

    @State private var isEditMode: Bool = true
    @State private var activeTool: HMIObjectType? = nil   // nil = pointer / select
    @State private var selectedObjectId: UUID? = nil
    @State private var faceplateObjectId: UUID? = nil     // run-mode tap

    @FocusState private var canvasFocused: Bool

    var body: some View {
        Group {
            switch displayMode {
            case .twoD:
                twoDLayout
            case .threeD:
                HMI3DDesignerView()
                    .environmentObject(hmi3DSceneStore)
                    .environmentObject(tagEngine)
            case .both:
                HSplitView {
                    twoDLayout
                        .frame(minWidth: 600)
                    HMI3DDesignerView(showDisplayModePicker: false)
                        .environmentObject(hmi3DSceneStore)
                        .environmentObject(tagEngine)
                        .frame(minWidth: 500)
                }
            }
        }
        // Faceplate popover in run mode
        .popover(item: faceplateBinding) { objId in
            if let obj = hmiScreenStore.screen.objects.first(where: { $0.id == objId.id }) {
                HMIFaceplateView(object: obj)
            }
        }
        // Clear selection when entering run mode
        .onChange(of: isEditMode) { _, editMode in
            if !editMode { selectedObjectId = nil; activeTool = nil }
        }
    }

    // MARK: - 2D Layout (extracted so it can be used in both .twoD and .both modes)

    private var twoDLayout: some View {
        HSplitView {
            // ── Screen Sidebar ───────────────────────────────────────────────
            HMIScreenListPane()
                .environmentObject(hmiScreenStore)

            // ── Main Content ─────────────────────────────────────────────────
            VStack(spacing: 0) {
                // ── Toolbar ──────────────────────────────────────────────────
                toolbarRow
                Divider()

                // ── Canvas + Inspector ───────────────────────────────────────
                ZStack(alignment: .trailing) {
                    HMICanvasView(
                        isEditMode:        isEditMode,
                        activeTool:        $activeTool,
                        selectedObjectId:  $selectedObjectId,
                        faceplateObjectId: $faceplateObjectId
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if isEditMode && selectedObjectId != nil {
                        HMIInspectorPanel(selectedObjectId: $selectedObjectId)
                            .frame(width: 280)
                            .background(Color(nsColor: .windowBackgroundColor).opacity(0.97))
                            .overlay(
                                Rectangle()
                                    .frame(width: 1)
                                    .foregroundColor(Color(nsColor: .separatorColor)),
                                alignment: .leading
                            )
                            .transition(.move(edge: .trailing))
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: isEditMode && selectedObjectId != nil)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .focusable()
                .focused($canvasFocused)
                .onAppear { canvasFocused = true }
                .onTapGesture { canvasFocused = true }
                // ── Keyboard shortcuts (canvas focused, edit mode) ───────────
                // Delete is handled via the HMI Editor menu command (notification)
                // so it fires even when the inspector panel has focus.
                .onKeyPress(.escape) {
                    guard isEditMode else { return .ignored }
                    if activeTool != nil { activeTool = nil; return .handled }
                    if selectedObjectId != nil { selectedObjectId = nil; return .handled }
                    return .ignored
                }
                .onKeyPress(.leftArrow)  { nudgeSelected(dx: -1, dy:  0) }
                .onKeyPress(.rightArrow) { nudgeSelected(dx:  1, dy:  0) }
                .onKeyPress(.upArrow)    { nudgeSelected(dx:  0, dy: -1) }
                .onKeyPress(.downArrow)  { nudgeSelected(dx:  0, dy:  1) }
                // ── Delete via menu command (bypasses focus) ─────────────────
                .onReceive(NotificationCenter.default.publisher(for: .hmiDeleteSelected)) { _ in
                    deleteSelected()
                }

                // ── Alarm Ribbon ──────────────────────────────────────────────
                alarmRibbon
            }
        }
    }

    // MARK: - Toolbar

    private var toolbarRow: some View {
        HStack(spacing: 12) {
            // Current screen name label
            Text(hmiScreenStore.screen.name)
                .font(.caption.bold())
                .foregroundColor(.secondary)
                .lineLimit(1)

            Divider().frame(height: 22)

            // Display mode (2D / 3D / Both) — quick toggle without going to Settings
            Picker("View", selection: $displayMode) {
                ForEach(HMIDisplayMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 130)
            .help("Switch between 2D canvas, 3D scene, or both side-by-side")

            Divider().frame(height: 22)

            // Edit / Run toggle
            Picker("Mode", selection: $isEditMode) {
                Label("Edit", systemImage: "pencil").tag(true)
                Label("Run",  systemImage: "play.fill").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 160)

            Divider().frame(height: 22)

            if isEditMode {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        // Pointer tool
                        toolButton(icon: "cursorarrow", label: "Select", active: activeTool == nil) {
                            activeTool = nil
                        }

                        Divider().frame(height: 22)

                        // Object type tools — 21 items (9 basic + 12 P&ID), scrollable
                        ForEach(HMIObjectType.allCases, id: \.self) { type in
                            toolButton(icon: type.icon, label: type.displayName, active: activeTool == type) {
                                activeTool = (activeTool == type) ? nil : type
                            }
                        }

                        Divider().frame(height: 22)

                        // Delete selected object
                        Button {
                            if let id = selectedObjectId {
                                hmiScreenStore.deleteObject(id: id)
                                selectedObjectId = nil
                            }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .disabled(selectedObjectId == nil)
                        .help("Delete selected object")
                    }
                }
            }

            Spacer()

            Text("\(hmiScreenStore.screen.objects.count) object\(hmiScreenStore.screen.objects.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Keyboard Actions

    @discardableResult
    private func deleteSelected() -> KeyPress.Result {
        guard isEditMode, let id = selectedObjectId else { return .ignored }
        hmiScreenStore.deleteObject(id: id)
        selectedObjectId = nil
        return .handled
    }

    @discardableResult
    private func nudgeSelected(dx: Double, dy: Double) -> KeyPress.Result {
        guard isEditMode, let id = selectedObjectId,
              let obj = hmiScreenStore.screen.objects.first(where: { $0.id == id })
        else { return .ignored }
        var updated = obj
        updated.x += dx
        updated.y += dy
        hmiScreenStore.updateObject(updated)
        return .handled
    }

    private func toolButton(icon: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title3)
        }
        .buttonStyle(.bordered)
        .tint(active ? .accentColor : nil)
        .background(active ? Color.accentColor.opacity(0.15) : Color.clear)
        .cornerRadius(6)
        .help(label)
    }

    // MARK: - Alarm Ribbon

    @ViewBuilder
    private var alarmRibbon: some View {
        let alarms = alarmManager.activeAlarms

        VStack(spacing: 0) {
            Divider()
            if alarms.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                    Text("No Active Alarms")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color(nsColor: .controlBackgroundColor))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(alarms) { alarm in
                            alarmPill(alarm)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                }
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .frame(height: alarms.isEmpty ? 28 : 36)
    }

    private func alarmPill(_ alarm: Alarm) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(severityColor(alarm.severity))
                .frame(width: 7, height: 7)
            Text(alarm.tagName)
                .font(.caption2.bold())
                .foregroundColor(.primary)
            Text("·")
                .foregroundColor(.secondary)
                .font(.caption2)
            Text(alarm.message)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
            Text("·")
                .foregroundColor(.secondary)
                .font(.caption2)
            Text(alarm.triggerTime, style: .relative)
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(minWidth: 30)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(severityColor(alarm.severity).opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(severityColor(alarm.severity).opacity(0.35), lineWidth: 0.5)
        )
        .cornerRadius(4)
    }

    private func severityColor(_ severity: AlarmSeverity) -> Color {
        switch severity {
        case .critical: return .red
        case .warning:  return .orange
        case .info:     return .blue
        }
    }

    // MARK: - Faceplate Binding

    private var faceplateBinding: Binding<IdentifiedUUID?> {
        Binding(
            get: {
                guard let id = faceplateObjectId,
                      let obj = hmiScreenStore.screen.objects.first(where: { $0.id == id }),
                      obj.tagBinding != nil else { return nil }
                return IdentifiedUUID(id: id)
            },
            set: { newVal in faceplateObjectId = newVal?.id }
        )
    }
}

// MARK: - IdentifiedUUID helper

/// Thin Identifiable wrapper so UUID? can be used with `.popover(item:)`.
private struct IdentifiedUUID: Identifiable {
    let id: UUID
}
