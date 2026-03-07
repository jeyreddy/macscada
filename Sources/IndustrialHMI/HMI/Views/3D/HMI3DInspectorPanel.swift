// MARK: - HMI3DInspectorPanel.swift
//
// Right-side property editor for the 3D plant-floor designer.
// Shown as a trailing overlay inside HMI3DDesignerView when an equipment piece
// is selected and isEditMode is true.
//
// ── Sections ──────────────────────────────────────────────────────────────────
//   labelSection    — type display name (read-only) + editable label text field
//   positionSection — X, Y, Z position fields (Float, in metres)
//                     + Y-rotation field (degrees)
//   scaleSection    — scaleX, scaleY, scaleZ fields (Float)
//                     + "Lock Aspect Ratio" toggle (uniform scale)
//                     + diameter field (for pipe equipment types)
//   tagSection      — tag name text field; looks up tag in tagEngine to show
//                     dataType, units, last value (read-only display)
//                     + minTagValue/maxTagValue for animation normalization
//   colorSection    — ColorPicker for equip.color (equipment material colour)
//   deleteSection   — "Remove" button → hmi3DSceneStore.removeEquipment(id:)
//                     + confirmation alert
//
// ── Binding Pattern ───────────────────────────────────────────────────────────
//   binding(_:_:) helper returns Binding<T> that reads from selectedEquipment
//   (computed from selectedEquipmentId + hmi3DSceneStore.scene.equipment)
//   and writes via hmi3DSceneStore.updateEquipment().
//   Every field change immediately re-renders the 3D scene via @Published scene.
//
// ── No Selection State ────────────────────────────────────────────────────────
//   When selectedEquipmentId is nil (or the equipment was deleted), shows
//   ContentUnavailableView("No Selection", systemImage: "cube").

import SwiftUI

// MARK: - HMI3DInspectorPanel

/// Right-side inspector for the 3D designer.
/// Shows Label, Position/Rotation, Scale, Tag Binding, Color, and Delete.
struct HMI3DInspectorPanel: View {
    @EnvironmentObject var hmi3DSceneStore: HMI3DSceneStore
    @EnvironmentObject var tagEngine: TagEngine
    @Binding var selectedEquipmentId: UUID?

    private var selectedEquipment: HMI3DEquipment? {
        guard let id = selectedEquipmentId else { return nil }
        return hmi3DSceneStore.scene.equipment.first { $0.id == id }
    }

    var body: some View {
        Group {
            if let equip = selectedEquipment {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        labelSection(equip)
                        Divider()
                        positionSection(equip)
                        Divider()
                        scaleSection(equip)
                        Divider()
                        tagSection(equip)
                        Divider()
                        colorSection(equip)
                        Divider()
                        deleteSection(equip)
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Selection",
                    systemImage: "cube",
                    description: Text("Click a 3D object to edit its properties")
                )
            }
        }
    }

    // MARK: - Label

    @ViewBuilder
    private func labelSection(_ equip: HMI3DEquipment) -> some View {
        Section3D(title: "Object") {
            Row3D(label: "Type") {
                Label(equip.type.displayName, systemImage: equip.type.icon)
                    .font(.subheadline)
            }
            Row3D(label: "Label") {
                TextField("Label", text: strBind(equip, \.label))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    // MARK: - Position

    @ViewBuilder
    private func positionSection(_ equip: HMI3DEquipment) -> some View {
        Section3D(title: "Position / Rotation") {
            Row3D(label: "X") { floatField(equip, \.posX) }
            Row3D(label: "Y") { floatField(equip, \.posY) }
            Row3D(label: "Z") { floatField(equip, \.posZ) }
            Row3D(label: "Rot Y°") { floatField(equip, \.rotationY) }
        }
    }

    // MARK: - Scale

    @ViewBuilder
    private func scaleSection(_ equip: HMI3DEquipment) -> some View {
        Section3D(title: "Scale") {
            Row3D(label: "X") { floatField(equip, \.scaleX) }
            Row3D(label: "Y") { floatField(equip, \.scaleY) }
            Row3D(label: "Z") { floatField(equip, \.scaleZ) }
        }
    }

    // MARK: - Tag Binding

    @ViewBuilder
    private func tagSection(_ equip: HMI3DEquipment) -> some View {
        Section3D(title: "Tag Binding") {
            let allTags = ["(None)"] + tagEngine.getAllTags().map { $0.name }
            let currentTag = equip.tagBinding ?? "(None)"

            Picker("Tag", selection: tagBind(equip)) {
                ForEach(allTags, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()

            if equip.tagBinding != nil {
                Row3D(label: "Min") { floatField(equip, \.minTagValue, isDouble: true) }
                Row3D(label: "Max") { floatField(equip, \.maxTagValue, isDouble: true) }
                Row3D(label: "Alarm Color") {
                    Toggle("", isOn: boolBind(equip, \.useAlarmColors)).labelsHidden()
                }
            }
            let _ = currentTag
        }
    }

    // MARK: - Color

    @ViewBuilder
    private func colorSection(_ equip: HMI3DEquipment) -> some View {
        Section3D(title: "Color") {
            Row3D(label: "Primary") {
                ColorPicker("", selection: hexColorBind(equip)).labelsHidden()
            }
        }
    }

    // MARK: - Delete

    @ViewBuilder
    private func deleteSection(_ equip: HMI3DEquipment) -> some View {
        Section3D(title: "Actions") {
            Button(role: .destructive) {
                hmi3DSceneStore.deleteEquipment(id: equip.id)
                selectedEquipmentId = nil
            } label: {
                Label("Delete Equipment", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
    }

    // MARK: - Binding helpers

    private func update(_ equip: HMI3DEquipment) {
        hmi3DSceneStore.updateEquipment(equip)
    }

    private func strBind(_ equip: HMI3DEquipment, _ kp: WritableKeyPath<HMI3DEquipment, String>) -> Binding<String> {
        Binding(
            get: { equip[keyPath: kp] },
            set: { var u = equip; u[keyPath: kp] = $0; update(u) }
        )
    }

    private func boolBind(_ equip: HMI3DEquipment, _ kp: WritableKeyPath<HMI3DEquipment, Bool>) -> Binding<Bool> {
        Binding(
            get: { equip[keyPath: kp] },
            set: { var u = equip; u[keyPath: kp] = $0; update(u) }
        )
    }

    // Tag binding ("(None)" ↔ nil)
    private func tagBind(_ equip: HMI3DEquipment) -> Binding<String> {
        Binding(
            get: { equip.tagBinding ?? "(None)" },
            set: { val in
                var u = equip
                u.tagBinding = (val == "(None)") ? nil : val
                update(u)
            }
        )
    }

    // Float field (Float property)
    @ViewBuilder
    private func floatField(_ equip: HMI3DEquipment,
                             _ kp: WritableKeyPath<HMI3DEquipment, Float>,
                             isDouble: Bool = false) -> some View {
        let b: Binding<Double> = Binding(
            get: { Double(equip[keyPath: kp]) },
            set: { var u = equip; u[keyPath: kp] = Float($0); update(u) }
        )
        Num3DField(value: b)
    }

    // Double field (for minTagValue / maxTagValue which are Double)
    @ViewBuilder
    private func floatField(_ equip: HMI3DEquipment,
                             _ kp: WritableKeyPath<HMI3DEquipment, Double>,
                             isDouble: Bool = false) -> some View {
        let b: Binding<Double> = Binding(
            get: { equip[keyPath: kp] },
            set: { var u = equip; u[keyPath: kp] = $0; update(u) }
        )
        Num3DField(value: b)
    }

    private func hexColorBind(_ equip: HMI3DEquipment) -> Binding<Color> {
        Binding(
            get: { Color(equip.primaryNSColor) },
            set: { newColor in
                let ns = NSColor(newColor).usingColorSpace(.sRGB) ?? NSColor.blue
                let r = Int(ns.redComponent * 255)
                let g = Int(ns.greenComponent * 255)
                let b = Int(ns.blueComponent * 255)
                var u = equip
                u.primaryColorHex = String(format: "#%02X%02X%02X", r, g, b)
                update(u)
            }
        )
    }
}

// MARK: - Sub-views

private struct Section3D<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.bold())
                .foregroundColor(.secondary)
                .padding(.bottom, 2)
            content
        }
        .padding(12)
    }
}

private struct Row3D<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .frame(width: 60, alignment: .leading)
            content
        }
    }
}

private struct Num3DField: View {
    @Binding var value: Double
    @State private var text = ""
    @State private var editing = false

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(.caption, design: .monospaced))
            .multilineTextAlignment(.trailing)
            .onAppear { text = String(format: "%.2f", value) }
            .onChange(of: value) { _, v in if !editing { text = String(format: "%.2f", v) } }
            .onSubmit {
                if let d = Double(text) { value = d } else { text = String(format: "%.2f", value) }
                editing = false
            }
            .onReceive(NotificationCenter.default.publisher(
                for: NSTextField.textDidBeginEditingNotification)) { _ in editing = true }
    }
}
