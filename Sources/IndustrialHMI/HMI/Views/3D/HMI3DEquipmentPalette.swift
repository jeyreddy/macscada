// MARK: - HMI3DEquipmentPalette.swift
//
// Left sidebar for the 3D plant-floor designer. Lists all available equipment types
// grouped by category. Clicking an item adds it to the current 3D scene.
//
// ── Categories & Types ────────────────────────────────────────────────────────
//   Rotating:   centrifugalPump, compressor, motorDrive
//   Vessels:    verticalTank, horizontalTank, processVessel, separator, heatExchanger
//   Piping:     gateValve, controlValve, pipeSection, pipeElbow, pipeTee
//   Structures: structuralColumn, platform
//   Categories are pre-sorted in the fixed order ["Rotating","Vessels","Piping","Structures"].
//   Equipment3DType.category provides the category string for each case.
//
// ── Add Equipment ─────────────────────────────────────────────────────────────
//   addEquipment(type:) creates a new HMI3DEquipment with:
//     id = UUID()
//     type = selected type
//     posX = random in -3..3, posZ = random in -3..3 (near-origin scatter)
//     posY = 0 (floor level)
//     scaleX/Y/Z = 1.0
//     label = type.displayName
//   Calls hmi3DSceneStore.addEquipment(equip).
//   Disabled when isEditMode = false (operator cannot add equipment in run mode).
//
// ── PaletteRow ────────────────────────────────────────────────────────────────
//   Private child view rendering one equipment type row:
//     SF Symbol icon (type.icon) + display name + "+" button.
//   Button disabled when isEditMode = false.
//   .help tooltip shows type.displayName.

import SwiftUI

// MARK: - HMI3DEquipmentPalette

/// Left sidebar List for the 3D designer.
/// Items are grouped by Equipment3DType.category.
/// Clicking an item adds it to the current scene at a random near-origin position.
struct HMI3DEquipmentPalette: View {
    @EnvironmentObject var hmi3DSceneStore: HMI3DSceneStore
    @Binding var isEditMode: Bool

    private let categories: [(String, [Equipment3DType])] = {
        let grouped = Dictionary(grouping: Equipment3DType.allCases, by: { $0.category })
        let order = ["Rotating", "Vessels", "Piping", "Structures"]
        return order.compactMap { cat in
            guard let items = grouped[cat] else { return nil }
            return (cat, items)
        }
    }()

    var body: some View {
        VStack(spacing: 0) {
            paletteHeader

            List {
                ForEach(categories, id: \.0) { (category, types) in
                    Section(header: Text(category).font(.caption.bold()).foregroundColor(.secondary)) {
                        ForEach(types, id: \.self) { type in
                            PaletteRow(type: type, isEditMode: isEditMode) {
                                addEquipment(type: type)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .frame(minWidth: 160, maxWidth: 200)
    }

    // MARK: - Header

    private var paletteHeader: some View {
        HStack {
            Text("Equipment")
                .font(.caption.bold())
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Add Equipment

    private func addEquipment(type: Equipment3DType) {
        guard isEditMode else { return }
        let jitter = { Float.random(in: -1.5...1.5) }
        let equip = HMI3DEquipment(
            type: type,
            pos: (jitter(), 0, jitter())
        )
        hmi3DSceneStore.addEquipment(equip)
    }
}

// MARK: - PaletteRow

private struct PaletteRow: View {
    let type: Equipment3DType
    let isEditMode: Bool
    let onAdd: () -> Void

    var body: some View {
        Button(action: onAdd) {
            HStack(spacing: 8) {
                Image(systemName: type.icon)
                    .font(.body)
                    .frame(width: 22, alignment: .center)
                    .foregroundColor(isEditMode ? .accentColor : .secondary)
                Text(type.displayName)
                    .font(.caption)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Spacer()
                if isEditMode {
                    Image(systemName: "plus.circle")
                        .font(.caption)
                        .foregroundColor(.accentColor.opacity(0.7))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEditMode)
        .help(isEditMode ? "Add \(type.displayName) to scene" : "Switch to Edit mode to add equipment")
    }
}
