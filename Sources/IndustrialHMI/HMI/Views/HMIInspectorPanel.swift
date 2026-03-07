// MARK: - HMIInspectorPanel.swift
//
// Right-side property editor for the HMI 2D canvas. Visible only in edit mode.
// Rendered as a vertical ScrollView panel overlaid on HMICanvasView's right edge.
//
// ── Sections ──────────────────────────────────────────────────────────────────
//   objectSection  — object type label, designer label
//   geometrySection — x, y, width, height (canvas units), rotation (degrees), zIndex
//   styleSection    — fill color, stroke color, stroke width, corner radius, opacity
//   textSection     — font size, font weight, alignment, display format string
//   industrialSection — P&ID-specific: pipe color, flow indicator on/off, animate running
//   tagBindingSection — tag name binding + read-only: dataType, units, last value
//   actionsSection  — write value (button tap), delete object, z-order (bring forward/send back)
//
// ── Binding Pattern ───────────────────────────────────────────────────────────
//   binding(_:_:) helper returns a Binding<T> that reads from the live HMIObject
//   in hmiScreenStore.screen.objects and writes via hmiScreenStore.updateObject().
//   This ensures every field change immediately persists and re-renders the canvas.
//
// ── P&ID Industrial Section ───────────────────────────────────────────────────
//   Only shown for objects where obj.type.category == "P&ID".
//   Contains: pipe color picker (tintColor), flow direction toggle,
//   "Animate Running" toggle (isRunning from liveValue >= writeOnValue).
//
// ── Tag Binding ───────────────────────────────────────────────────────────────
//   tagBindingSection shows a text field for the tag name.
//   Tag metadata (dataType, units) is looked up live from tagEngine.getTag(named:).
//   Provides a searchable tag picker if the operator wants to browse available tags.
//
// ── Z-Order Controls ──────────────────────────────────────────────────────────
//   "Bring Forward": increments zIndex by 1 (swaps with next-higher object if adjacent).
//   "Send Back": decrements zIndex by 1 (swaps with next-lower object if adjacent).
//   Implemented by comparing zIndex values in the sorted objects array.

import SwiftUI

// MARK: - HMIInspectorPanel

/// Right-side property editor, visible only in edit mode.
struct HMIInspectorPanel: View {
    @EnvironmentObject var hmiScreenStore: HMIScreenStore
    @EnvironmentObject var tagEngine: TagEngine

    @Binding var selectedObjectId: UUID?

    private var selectedObject: HMIObject? {
        guard let id = selectedObjectId else { return nil }
        return hmiScreenStore.screen.objects.first { $0.id == id }
    }

    var body: some View {
        Group {
            if let obj = selectedObject {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        objectSection(obj)
                        Divider()
                        geometrySection(obj)
                        Divider()
                        styleSection(obj)
                        Divider()
                        textSection(obj)
                        if obj.type.category == "P&ID" {
                            Divider()
                            industrialSection(obj)
                        }
                        Divider()
                        tagBindingSection(obj)
                        Divider()
                        actionsSection(obj)
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Selection",
                    systemImage: "cursorarrow",
                    description: Text("Click an object to edit its properties")
                )
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func objectSection(_ obj: HMIObject) -> some View {
        InspectorSection(title: "Object") {
            HStack {
                Label(obj.type.displayName, systemImage: obj.type.icon)
                    .font(.subheadline.bold())
                Spacer()
            }
            InspectorRow(label: "Label") {
                TextField("Designer label", text: binding(obj, \.designerLabel))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    @ViewBuilder
    private func geometrySection(_ obj: HMIObject) -> some View {
        InspectorSection(title: "Geometry") {
            InspectorRow(label: "X") {
                NumberField(value: binding(obj, \.x), format: "%.1f")
            }
            InspectorRow(label: "Y") {
                NumberField(value: binding(obj, \.y), format: "%.1f")
            }
            InspectorRow(label: "Width") {
                NumberField(value: binding(obj, \.width), format: "%.1f")
            }
            InspectorRow(label: "Height") {
                NumberField(value: binding(obj, \.height), format: "%.1f")
            }
            InspectorRow(label: "Rotation") {
                HStack {
                    Slider(value: binding(obj, \.rotation), in: -180...180)
                    Text(String(format: "%.0f°", obj.rotation))
                        .font(.caption)
                        .frame(width: 38, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder
    private func styleSection(_ obj: HMIObject) -> some View {
        InspectorSection(title: "Style") {
            InspectorRow(label: "Fill") {
                ColorPicker("", selection: colorBinding(obj, \.fillColor))
                    .labelsHidden()
            }
            InspectorRow(label: "Stroke") {
                ColorPicker("", selection: colorBinding(obj, \.strokeColor))
                    .labelsHidden()
            }
            InspectorRow(label: "Stroke Width") {
                NumberField(value: binding(obj, \.strokeWidth), format: "%.1f")
            }
            if obj.type == .rectangle {
                InspectorRow(label: "Corner Radius") {
                    NumberField(value: binding(obj, \.cornerRadius), format: "%.1f")
                }
            }
        }
    }

    @ViewBuilder
    private func textSection(_ obj: HMIObject) -> some View {
        // Rectangle and ellipse also support a built-in text overlay
        let showStaticText = (obj.type == .textLabel
                              || obj.type == .rectangle
                              || obj.type == .ellipse
                              || obj.type == .pushButton)
        let showFormat     = (obj.type == .numericDisplay || obj.type == .circularGauge)
        let showBar        = (obj.type == .levelBar)
        let showGauge      = (obj.type == .circularGauge)
        let showButton     = (obj.type == .pushButton || obj.type == .toggleSwitch)
        let showSpark      = (obj.type == .trendSparkline)

        if showStaticText || showFormat || showBar || showGauge || showButton || showSpark {
            InspectorSection(title: "Content") {
                if showStaticText {
                    InspectorRow(label: "Text") {
                        TextField("Label text", text: binding(obj, \.staticText))
                            .textFieldStyle(.roundedBorder)
                    }
                }
                if showFormat {
                    InspectorRow(label: "Format") {
                        TextField("%.1f", text: binding(obj, \.numberFormat))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                    InspectorRow(label: "Unit") {
                        TextField("e.g. °C", text: binding(obj, \.unit))
                            .textFieldStyle(.roundedBorder)
                    }
                }
                if showBar {
                    InspectorRow(label: "Vertical") {
                        Toggle("", isOn: binding(obj, \.barIsVertical)).labelsHidden()
                    }
                    InspectorRow(label: "Min") {
                        NumberField(value: binding(obj, \.barMin), format: "%.1f")
                    }
                    InspectorRow(label: "Max") {
                        NumberField(value: binding(obj, \.barMax), format: "%.1f")
                    }
                }

                // ── Circular Gauge ─────────────────────────────────────────
                if showGauge {
                    InspectorRow(label: "Gauge Min") {
                        NumberField(value: binding(obj, \.gaugeMin), format: "%.1f")
                    }
                    InspectorRow(label: "Gauge Max") {
                        NumberField(value: binding(obj, \.gaugeMax), format: "%.1f")
                    }
                    InspectorRow(label: "Sweep°") {
                        HStack {
                            Slider(value: binding(obj, \.gaugeSweepDegrees), in: 90...330)
                            Text(String(format: "%.0f°", obj.gaugeSweepDegrees))
                                .font(.caption)
                                .frame(width: 38, alignment: .trailing)
                        }
                    }
                }

                // ── Button / Toggle write values ───────────────────────────
                if showButton {
                    if obj.type == .toggleSwitch {
                        InspectorRow(label: "ON val") {
                            NumberField(value: binding(obj, \.writeOnValue), format: "%.2f")
                        }
                        InspectorRow(label: "OFF val") {
                            NumberField(value: binding(obj, \.writeOffValue), format: "%.2f")
                        }
                    } else {
                        InspectorRow(label: "Write val") {
                            NumberField(value: binding(obj, \.writeOnValue), format: "%.2f")
                        }
                    }
                }

                // ── Sparkline ──────────────────────────────────────────────
                if showSpark {
                    InspectorRow(label: "History") {
                        HStack {
                            Slider(value: Binding(
                                get: { Double(obj.sparklineMinutes) },
                                set: { var u = obj; u.sparklineMinutes = max(1, Int($0))
                                       hmiScreenStore.updateObject(u) }
                            ), in: 5...120, step: 5)
                            Text("\(obj.sparklineMinutes) min")
                                .font(.caption)
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                    InspectorRow(label: "Fill") {
                        Toggle("", isOn: binding(obj, \.sparklineShowFill)).labelsHidden()
                    }
                }

                // Common text style (not shown for toggle or sparkline)
                if !showSpark {
                    InspectorRow(label: "Font Size") {
                        NumberField(value: binding(obj, \.fontSize), format: "%.0f")
                    }
                    InspectorRow(label: "Bold") {
                        Toggle("", isOn: binding(obj, \.fontBold)).labelsHidden()
                    }
                    InspectorRow(label: "Text Color") {
                        ColorPicker("", selection: colorBinding(obj, \.textColor)).labelsHidden()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tagBindingSection(_ obj: HMIObject) -> some View {
        InspectorSection(title: "Tag Binding") {
            let allTags = ["(None)"] + tagEngine.getAllTags().map { $0.name }
            let currentTag = obj.tagBinding?.tagName ?? "(None)"

            Picker("Tag", selection: tagNameBinding(obj)) {
                ForEach(allTags, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .labelsHidden()

            if obj.tagBinding != nil {
                // Number format for numeric / bar objects
                if obj.type == .numericDisplay || obj.type == .levelBar {
                    InspectorRow(label: "Format") {
                        TextField("%.1f", text: tagFormatBinding(obj))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                    InspectorRow(label: "Unit") {
                        TextField("e.g. bar", text: tagUnitBinding(obj))
                            .textFieldStyle(.roundedBorder)
                    }
                }

                // Color thresholds
                Text("Color Thresholds")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                    .padding(.top, 4)

                ForEach(obj.tagBinding?.colorThresholds ?? [], id: \.id) { threshold in
                    thresholdRow(obj: obj, threshold: threshold)
                }

                Button {
                    var updated = obj
                    let newT = ColorThreshold(value: 80,
                                             color: CodableColor(.orange))
                    updated.tagBinding?.colorThresholds.append(newT)
                    hmiScreenStore.updateObject(updated)
                } label: {
                    Label("Add Threshold", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }

            // Suppress the "Unused variable" warning for currentTag
            let _ = currentTag
        }
    }

    @ViewBuilder
    private func thresholdRow(obj: HMIObject, threshold: ColorThreshold) -> some View {
        HStack(spacing: 6) {
            Text("≥")
                .font(.caption)
                .foregroundColor(.secondary)
            TextField("value", value: thresholdValueBinding(obj, id: threshold.id),
                      formatter: NumberFormatter())
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
                .font(.system(.caption, design: .monospaced))

            ColorPicker("", selection: thresholdColorBinding(obj, id: threshold.id))
                .labelsHidden()
                .frame(width: 32)

            Spacer()

            Button {
                var updated = obj
                updated.tagBinding?.colorThresholds.removeAll { $0.id == threshold.id }
                hmiScreenStore.updateObject(updated)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundColor(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Industrial / P&ID section (Phase 16)

    @ViewBuilder
    private func industrialSection(_ obj: HMIObject) -> some View {
        InspectorSection(title: "P&ID Properties") {
            // Flow direction — shown for pumps and pipes
            if obj.type == .centrifugalPump || obj.type == .motorDrive
                || obj.type == .pipeStraight {
                InspectorRow(label: "Flow Dir") {
                    Picker("", selection: binding(obj, \.flowDirection)) {
                        ForEach(HMIFlowDirection.allCases, id: \.self) { dir in
                            Text(dir.rawValue.capitalized).tag(dir)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
            }

            // Equipment variant (free-text tag subtype)
            InspectorRow(label: "Variant") {
                TextField("e.g. NPS4", text: binding(obj, \.equipmentVariant))
                    .textFieldStyle(.roundedBorder)
            }

            // Show ISA tag label inside symbol
            InspectorRow(label: "ISA Tag") {
                Toggle("", isOn: binding(obj, \.showISATag)).labelsHidden()
            }

            // Animate when running
            if obj.type == .centrifugalPump || obj.type == .motorDrive
                || obj.type == .openTank    || obj.type == .pipeStraight {
                InspectorRow(label: "Animate") {
                    Toggle("", isOn: binding(obj, \.animateRunning)).labelsHidden()
                }
            }

            // Pipe chevron count
            if obj.type == .pipeStraight {
                InspectorRow(label: "Segments") {
                    Stepper("\(obj.pipeSegmentCount)",
                            value: binding(obj, \.pipeSegmentCount),
                            in: 1...10)
                }
            }
        }
    }

    @ViewBuilder
    private func actionsSection(_ obj: HMIObject) -> some View {
        InspectorSection(title: "Actions") {
            HStack(spacing: 8) {
                Button("Bring to Front") { hmiScreenStore.bringToFront(id: obj.id) }
                    .buttonStyle(.bordered)
                Button("Send to Back")  { hmiScreenStore.sendToBack(id: obj.id)   }
                    .buttonStyle(.bordered)
            }
            Button(role: .destructive) {
                hmiScreenStore.deleteObject(id: obj.id)
                selectedObjectId = nil
            } label: {
                Label("Delete Object", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
    }

    // MARK: - Binding Helpers

    private func binding<V>(_ obj: HMIObject, _ kp: WritableKeyPath<HMIObject, V>) -> Binding<V> {
        Binding(
            get: { obj[keyPath: kp] },
            set: { newVal in
                var updated = obj
                updated[keyPath: kp] = newVal
                hmiScreenStore.updateObject(updated)
            }
        )
    }

    private func colorBinding(_ obj: HMIObject, _ kp: WritableKeyPath<HMIObject, CodableColor>) -> Binding<Color> {
        Binding(
            get: { obj[keyPath: kp].color },
            set: { newColor in
                var updated = obj
                updated[keyPath: kp] = CodableColor(newColor)
                hmiScreenStore.updateObject(updated)
            }
        )
    }

    // Tag name Picker binding ("(None)" ↔ nil tagBinding)
    private func tagNameBinding(_ obj: HMIObject) -> Binding<String> {
        Binding(
            get: { obj.tagBinding?.tagName ?? "(None)" },
            set: { newName in
                var updated = obj
                if newName == "(None)" {
                    updated.tagBinding = nil
                } else if updated.tagBinding == nil {
                    updated.tagBinding = TagBinding(tagName: newName)
                } else {
                    updated.tagBinding?.tagName = newName
                }
                hmiScreenStore.updateObject(updated)
            }
        )
    }

    private func tagFormatBinding(_ obj: HMIObject) -> Binding<String> {
        Binding(
            get: { obj.tagBinding?.numberFormat ?? "%.1f" },
            set: { val in
                var updated = obj; updated.tagBinding?.numberFormat = val
                hmiScreenStore.updateObject(updated)
            }
        )
    }

    private func tagUnitBinding(_ obj: HMIObject) -> Binding<String> {
        Binding(
            get: { obj.tagBinding?.unit ?? "" },
            set: { val in
                var updated = obj; updated.tagBinding?.unit = val
                hmiScreenStore.updateObject(updated)
            }
        )
    }

    private func thresholdValueBinding(_ obj: HMIObject, id: UUID) -> Binding<Double> {
        Binding(
            get: {
                obj.tagBinding?.colorThresholds.first { $0.id == id }?.value ?? 0
            },
            set: { newVal in
                var updated = obj
                if let idx = updated.tagBinding?.colorThresholds.firstIndex(where: { $0.id == id }) {
                    updated.tagBinding?.colorThresholds[idx].value = newVal
                }
                hmiScreenStore.updateObject(updated)
            }
        )
    }

    private func thresholdColorBinding(_ obj: HMIObject, id: UUID) -> Binding<Color> {
        Binding(
            get: {
                obj.tagBinding?.colorThresholds.first { $0.id == id }?.color.color ?? .orange
            },
            set: { newColor in
                var updated = obj
                if let idx = updated.tagBinding?.colorThresholds.firstIndex(where: { $0.id == id }) {
                    updated.tagBinding?.colorThresholds[idx].color = CodableColor(newColor)
                }
                hmiScreenStore.updateObject(updated)
            }
        )
    }
}

// MARK: - Inspector Sub-Views

private struct InspectorSection<Content: View>: View {
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

private struct InspectorRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .frame(width: 80, alignment: .leading)
            content
        }
    }
}

private struct NumberField: View {
    @Binding var value: Double
    let format: String
    @State private var text: String = ""
    @State private var editing = false

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .font(.system(.caption, design: .monospaced))
            .onAppear { text = String(format: format, value) }
            .onChange(of: value) { _, v in
                if !editing { text = String(format: format, v) }
            }
            .onSubmit {
                if let d = Double(text) { value = d }
                else { text = String(format: format, value) }
                editing = false
            }
            .onReceive(NotificationCenter.default.publisher(
                for: NSTextField.textDidBeginEditingNotification)) { _ in
                editing = true
            }
    }
}
