import SwiftUI

// MARK: - HMIDesignerView

/// Top-level view for the "HMI Screens" tab.
/// Always alive in the ZStack (like TrendView) so state is preserved across tab switches.
struct HMIDesignerView: View {
    @EnvironmentObject var tagEngine: TagEngine
    @EnvironmentObject var alarmManager: AlarmManager
    @EnvironmentObject var hmiScreenStore: HMIScreenStore

    @State private var isEditMode: Bool = true
    @State private var activeTool: HMIObjectType? = nil   // nil = pointer / select
    @State private var selectedObjectId: UUID? = nil
    @State private var faceplateObjectId: UUID? = nil     // run-mode tap

    var body: some View {
        VStack(spacing: 0) {
            // ── Toolbar ─────────────────────────────────────────────────────
            toolbarRow
            Divider()

            // ── Canvas + Inspector ───────────────────────────────────────────
            // Inspector overlays the canvas on the right only when an object
            // is selected, so the canvas fills the full width by default.
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

            // ── Alarm Ribbon ─────────────────────────────────────────────────
            alarmRibbon
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

    // MARK: - Toolbar

    private var toolbarRow: some View {
        HStack(spacing: 12) {
            // Edit / Run toggle
            Picker("Mode", selection: $isEditMode) {
                Label("Edit", systemImage: "pencil").tag(true)
                Label("Run",  systemImage: "play.fill").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 160)

            Divider().frame(height: 22)

            if isEditMode {
                // Pointer tool
                toolButton(icon: "cursorarrow", label: "Select", active: activeTool == nil) {
                    activeTool = nil
                }

                // Object type tools
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

            Spacer()

            Text("\(hmiScreenStore.screen.objects.count) object\(hmiScreenStore.screen.objects.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
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
