import SwiftUI

// MARK: - ProcessCanvasDesigner
//
// This file contains three design-mode UI components used when the toolbar
// is in Design mode (isDesigning = true) in ProcessCanvasView:
//
//   1. ProcessCanvasInspector  — Right-sidebar panel for editing the selected block.
//      Shows content-specific fields (tags, nav targets, equipment kind, etc.) and
//      a shared Appearance section (background/border hex colour pickers).
//
//   2. AddBlockSheet           — Modal sheet for inserting a new block.
//      Presents a 2-column grid of block type cards; also lists every existing
//      HMI screen so the designer can create hmiScreen blocks in one click.
//
//   3. CanvasSettingsSheet     — Modal sheet for canvas-level settings:
//      name, background colour, grid visibility, and grid cell size.
//
// ── Binding pattern ───────────────────────────────────────────────────────────
//   ProcessCanvasInspector holds a @Binding<CanvasBlock?> to the parent's
//   `selectedBlock` state variable.  Every text field / picker that edits a
//   block property uses one of two helper factories:
//
//     • binding(_ kp: WritableKeyPath<CanvasBlock, V>)
//       Returns a Binding<V> that reads/writes directly into selectedBlock.
//
//     • contentBinding(_ kp: WritableKeyPath<BlockContent, V>)
//       Returns a Binding<V> that reads/writes into selectedBlock.content.
//
//   Both factories write through the @Binding so mutations propagate up to
//   ProcessCanvasView, which then calls canvasStore.updateBlock(_:) to persist.
//
// ── Tag browser ───────────────────────────────────────────────────────────────
//   The `tagBrowser` helper is shared by tagMonitor, statusGrid, trendMini
//   (multi-select) and equipment (single-select).
//   • multi = true  → tap toggles presence in block.content.tagIDs array
//   • multi = false → tap replaces block.content.equipTagID
//   A local @State `tagSearch` field filters the live tag list from TagEngine.

// MARK: - Inspector Panel (right sidebar in design mode)
//
// Renders a scrollable form whose content switches on `block.content.kind`.
// All edits are applied immediately via the binding helpers — there is no
// "Save" button; the upstream ProcessCanvasView auto-persists on every change
// because selectedBlock is a @Binding that triggers canvasStore.updateBlock.

struct ProcessCanvasInspector: View {

    // @Binding — mutations here propagate up to ProcessCanvasView's selectedBlock
    // state, which calls canvasStore.updateBlock(_:) to persist to disk.
    @Binding var selectedBlock: CanvasBlock?

    /// Called when the operator presses the trash icon in the inspector header.
    /// The caller (ProcessCanvasView) removes the block from the active canvas.
    let onDelete: () -> Void

    @EnvironmentObject var hmiScreenStore: HMIScreenStore
    @EnvironmentObject var tagEngine:      TagEngine

    /// Local search term for the tag browser — not persisted.
    @State private var tagSearch: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Inspector header ──────────────────────────────────────────
            // Shows "Inspector" title and a trash button when a block is selected.
            HStack {
                Text("Inspector")
                    .font(.headline)
                Spacer()
                if selectedBlock != nil {
                    // Destructive delete — confirmed by role: .destructive
                    Button(role: .destructive) { onDelete() } label: {
                        Image(systemName: "trash").foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)

            Divider()

            if let block = selectedBlock {
                // Block is selected — show its editable form
                inspectorForm(block)
            } else {
                // No block selected — placeholder hint
                Text("Select a block to edit its properties.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Inspector form (content-switched)
    //
    // Renders three logical sections:
    //   1. General     — title, showTitle toggle, W/H/X/Y geometry fields
    //   2. Content     — kind-specific fields (switch on block.content.kind)
    //   3. Appearance  — background + border hex colour pickers
    //
    // All fields use binding() or contentBinding() so edits propagate immediately
    // to the parent's @State without an explicit "Apply" step.

    @ViewBuilder
    private func inspectorForm(_ block: CanvasBlock) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // ── 1. General ────────────────────────────────────────────
                // Block title (shown in the title bar of the block on canvas),
                // optional title visibility toggle, and canvas-space geometry.
                inspectorSection("General") {
                    HStack {
                        Text("Title")
                        TextField("Title", text: binding(\.title))
                            .textFieldStyle(.roundedBorder)
                    }
                    Toggle("Show Title", isOn: binding(\.showTitle))
                    HStack {
                        Text("W"); TextField("Width", value: binding(\.w), format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 70)
                        Text("H"); TextField("Height", value: binding(\.h), format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 70)
                    }
                    HStack {
                        Text("X"); TextField("X", value: binding(\.x), format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 70)
                        Text("Y"); TextField("Y", value: binding(\.y), format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 70)
                    }
                }

                Divider()

                // ── 2. Content-specific ───────────────────────────────────
                // Each content kind has a unique set of editable fields.
                // The switch selects the correct sub-form; unknown kinds show nothing.
                switch block.content.kind {

                case "label":
                    // Multiline text input + font size slider
                    inspectorSection("Label") {
                        TextField("Text", text: contentBinding(\.text), axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(3...6)
                        HStack {
                            Text("Size")
                            Slider(value: contentBinding(\.fontSize), in: 12...80)
                            Text("\(Int(block.content.fontSize))").frame(width: 28)
                        }
                    }

                case "tagMonitor", "statusGrid", "trendMini":
                    // Multi-select tag browser shared by the three tag-list block kinds.
                    // • tagMonitor: live value table
                    // • statusGrid: coloured status tiles
                    // • trendMini:  sparklines (+ history window slider)
                    inspectorSection("Tags") {

                        // Current tag list — shows each selected tag with quality dot and remove button
                        if !block.content.tagIDs.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(block.content.tagIDs, id: \.self) { tagID in
                                    HStack(spacing: 6) {
                                        // Quality dot sourced from live TagEngine state
                                        Circle()
                                            .fill(tagEngine.tags[tagID]?.quality.dot ?? Color.secondary)
                                            .frame(width: 6)
                                        Text(tagID)
                                            .font(.system(size: 11, design: .monospaced))
                                            .lineLimit(1)
                                        Spacer()
                                        // Remove button — writes directly through selectedBlock binding
                                        Button {
                                            var b = block
                                            b.content.tagIDs.removeAll { $0 == tagID }
                                            selectedBlock = b
                                        } label: {
                                            Image(systemName: "minus.circle.fill")
                                                .foregroundColor(.red.opacity(0.7))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.white.opacity(0.04))
                                    .cornerRadius(4)
                                }
                            }
                        }

                        // trendMini-only: history window length in minutes
                        if block.content.kind == "trendMini" {
                            HStack {
                                Text("History (min)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                TextField("", value: contentBinding(\.minutes), format: .number)
                                    .textFieldStyle(.roundedBorder).frame(width: 60)
                            }
                        }

                        // Searchable tag browser (multi-select: tap toggles membership in tagIDs)
                        tagBrowser(selectedIDs: block.content.tagIDs, multi: true) { tagID in
                            var b = block
                            if b.content.tagIDs.contains(tagID) {
                                b.content.tagIDs.removeAll { $0 == tagID }
                            } else {
                                b.content.tagIDs.append(tagID)
                            }
                            selectedBlock = b
                        }
                    }

                case "navButton":
                    // Navigation button: label + target canvas coordinates.
                    // In Operate mode, tapping the block calls
                    //   ProcessCanvasView.animateTo(x: navX, y: navY, scale: navScale)
                    // to smoothly pan & zoom the viewport to the configured area.
                    inspectorSection("Navigation") {
                        TextField("Button label", text: contentBinding(\.navLabel))
                            .textFieldStyle(.roundedBorder)
                        Group {
                            HStack { Text("Target X"); TextField("X", value: contentBinding(\.navX), format: .number).textFieldStyle(.roundedBorder) }
                            HStack { Text("Target Y"); TextField("Y", value: contentBinding(\.navY), format: .number).textFieldStyle(.roundedBorder) }
                            HStack { Text("Scale");    TextField("Scale", value: contentBinding(\.navScale), format: .number).textFieldStyle(.roundedBorder) }
                        }
                        Text("Tip: set target to the canvas coords of the area you want to jump to.")
                            .font(.caption2).foregroundColor(.secondary)
                    }

                case "equipment":
                    // Equipment block: icon kind picker + single-select tag for running state.
                    // Supported kinds: pump, motor, valve, tank, exchanger, compressor.
                    // The linked tag drives the icon colour (green = running, red = alarm, grey = stopped).
                    inspectorSection("Equipment") {
                        Picker("Kind", selection: contentBinding(\.equipKind)) {
                            ForEach(["pump","motor","valve","tank","exchanger","compressor"], id: \.self) {
                                Text($0.capitalized).tag($0)
                            }
                        }
                        .pickerStyle(.menu)

                        // Currently linked tag (if any)
                        if !block.content.equipTagID.isEmpty {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(tagEngine.tags[block.content.equipTagID]?.quality.dot ?? Color.secondary)
                                    .frame(width: 6)
                                Text(block.content.equipTagID)
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineLimit(1)
                                Spacer()
                                // Clear the linked tag
                                Button {
                                    selectedBlock?.content.equipTagID = ""
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundColor(.red.opacity(0.7))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.white.opacity(0.04)).cornerRadius(4)
                        }

                        // Single-select tag browser: tap replaces the current equipTagID
                        tagBrowser(selectedIDs: block.content.equipTagID.isEmpty ? [] : [block.content.equipTagID],
                                   multi: false) { tagID in
                            selectedBlock?.content.equipTagID = tagID
                        }
                    }

                case "alarmPanel":
                    // Alarm panel: just a max-rows stepper (1–20).
                    // The alarm list itself is live-populated from AlarmManager at runtime.
                    inspectorSection("Alarm Panel") {
                        HStack {
                            Text("Max rows")
                            Stepper("\(block.content.maxAlarms)", value: contentBinding(\.maxAlarms), in: 1...20)
                        }
                    }

                case "screenGroup":
                    // Screen group: configure the grid column count and the ordered list
                    // of HMI screens.  In Operate mode, tapping the block opens
                    // CompositeHMIView, which renders all screens side-by-side as one
                    // infinite canvas using the same scale/pan system as ProcessCanvasView.
                    inspectorSection("Screen Group") {
                        HStack {
                            Text("Columns")
                                .font(.caption).foregroundColor(.secondary)
                            Stepper("\(block.content.screenGroupCols)",
                                    value: contentBinding(\.screenGroupCols), in: 1...6)
                        }

                        // Current ordered screen list with remove buttons
                        if !block.content.screenGroupEntries.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Screens in group:")
                                    .font(.caption2).foregroundColor(.secondary)
                                ForEach(Array(block.content.screenGroupEntries.enumerated()),
                                        id: \.element.id) { idx, entry in
                                    HStack(spacing: 6) {
                                        // Position index in the grid (1-based for display)
                                        Text("\(idx + 1)")
                                            .font(.caption2.bold())
                                            .foregroundColor(.secondary)
                                            .frame(width: 16)
                                        Image(systemName: "rectangle.on.rectangle")
                                            .font(.caption2)
                                            .foregroundColor(.blue)
                                        Text(entry.hmiScreenName.isEmpty ? "—" : entry.hmiScreenName)
                                            .font(.system(size: 11))
                                            .lineLimit(1)
                                        Spacer()
                                        // Remove screen from group (preserves others)
                                        Button {
                                            var b = block
                                            b.content.screenGroupEntries.remove(at: idx)
                                            selectedBlock = b
                                        } label: {
                                            Image(systemName: "minus.circle.fill")
                                                .foregroundColor(.red.opacity(0.7))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Color.white.opacity(0.04)).cornerRadius(4)
                                }
                            }
                        }

                        // Add available screens — deduplication: already-added screens show
                        // a checkmark and are disabled so they cannot be added twice.
                        Text("Add screens:")
                            .font(.caption2).foregroundColor(.secondary)

                        if hmiScreenStore.allScreenMeta.isEmpty {
                            Text("No HMI screens exist yet.\nCreate them in the HMI Screens tab.")
                                .font(.caption).foregroundColor(.secondary)
                        } else {
                            // Build a Set of already-included IDs for O(1) lookup
                            let alreadyAdded = Set(block.content.screenGroupEntries.map(\.hmiScreenID))
                            ForEach(hmiScreenStore.allScreenMeta) { meta in
                                let added = alreadyAdded.contains(meta.id.uuidString)
                                Button {
                                    guard !added else { return }
                                    var b = block
                                    b.content.screenGroupEntries.append(
                                        ScreenGroupEntry(hmiScreenID: meta.id.uuidString,
                                                         hmiScreenName: meta.name)
                                    )
                                    selectedBlock = b
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: added ? "checkmark.circle.fill" : "plus.circle")
                                            .foregroundColor(added ? .green : .accentColor)
                                        Text(meta.name)
                                            .font(.system(size: 11))
                                            .foregroundColor(added ? .secondary : .primary)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Color.white.opacity(0.03)).cornerRadius(4)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(added)
                            }
                        }

                        Text("Tip: in Operate mode, click this block to open all screens as one seamless canvas.")
                            .font(.caption2).foregroundColor(.secondary)
                    }

                case "hmiScreen":
                    // hmiScreen block: a Picker that selects one HMI screen by ID.
                    // The block stores both the UUID string (hmiScreenID) and the display
                    // name (hmiScreenName) so it can be shown even if the screen is renamed.
                    // Selecting a new screen updates both fields atomically via the Picker binding.
                    inspectorSection("HMI Screen") {
                        if hmiScreenStore.allScreenMeta.isEmpty {
                            Text("No HMI screens exist yet.\nCreate one in the HMI Screens tab.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Picker("Screen", selection: Binding(
                                get: { block.content.hmiScreenID },
                                set: { newID in
                                    // Resolve the display name from the store to keep it in sync
                                    let name = hmiScreenStore.allScreenMeta
                                        .first { $0.id.uuidString == newID }?.name ?? ""
                                    selectedBlock?.content.hmiScreenID   = newID
                                    selectedBlock?.content.hmiScreenName = name
                                }
                            )) {
                                Text("— none —").tag("")
                                ForEach(hmiScreenStore.allScreenMeta) { meta in
                                    Text(meta.name).tag(meta.id.uuidString)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }

                default:
                    EmptyView()
                }

                Divider()

                // ── 3. Appearance ──────────────────────────────────────────
                // Hex colour pickers for background and border.
                // The colour preview swatch next to each text field gives live feedback.
                inspectorSection("Appearance") {
                    HStack {
                        Text("Background")
                        TextField("Hex", text: binding(\.bgHex))
                            .textFieldStyle(.roundedBorder)
                        // Live swatch — re-renders whenever bgHex changes
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(hex: block.bgHex))
                            .frame(width: 20, height: 20)
                    }
                    HStack {
                        Text("Border")
                        TextField("Hex", text: binding(\.borderHex))
                            .textFieldStyle(.roundedBorder)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(hex: block.borderHex))
                            .frame(width: 20, height: 20)
                    }
                }
            }
            .padding(14)
        }
    }

    // MARK: - Inspector section builder
    //
    // Wraps content in a small-capped section label + VStack.
    // Used purely for visual grouping — no functional role.

    @ViewBuilder
    private func inspectorSection<Content: View>(_ title: String,
                                                 @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.bold()).foregroundColor(.secondary)
            content()
        }
    }

    // MARK: - Tag Browser
    //
    // A searchable list of all tags known to TagEngine.
    //
    // Parameters:
    //   selectedIDs — tag IDs that are currently checked (shown with accent + checkmark)
    //   multi       — true = toggling; false = replace-on-tap (single-select)
    //   onTap       — callback with the tapped tag name; caller mutates selectedBlock

    @ViewBuilder
    private func tagBrowser(selectedIDs: [String], multi: Bool, onTap: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(multi ? "Available Tags — tap to add/remove" : "Pick a tag")
                .font(.caption2)
                .foregroundColor(.secondary)

            // Live search filter — filters tagEngine.tags by name substring
            TextField("Search tags…", text: $tagSearch)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))

            // Sort alphabetically, then apply search filter
            let allTags = tagEngine.tags.values
                .sorted { $0.name < $1.name }
                .filter { tagSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(tagSearch) }

            if allTags.isEmpty {
                Text(tagSearch.isEmpty ? "No tags available" : "No match")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                // LazyVStack for performance when tag count is large (1000+)
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(allTags, id: \.name) { tag in
                            let isSelected = selectedIDs.contains(tag.name)
                            Button {
                                onTap(tag.name)
                            } label: {
                                HStack(spacing: 6) {
                                    // Quality dot: green = good, orange = uncertain, red = bad
                                    Circle()
                                        .fill(tag.quality.dot)
                                        .frame(width: 6)
                                    Text(tag.name)
                                        .font(.system(size: 11, design: .monospaced))
                                        .lineLimit(1)
                                        .foregroundColor(isSelected ? .accentColor : .primary)
                                    Spacer()
                                    if isSelected {
                                        Image(systemName: "checkmark")
                                            .font(.caption2.bold())
                                            .foregroundColor(.accentColor)
                                    }
                                    // Live current value (formatted by Tag.formattedValue)
                                    Text(tag.formattedValue)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .frame(width: 50, alignment: .trailing)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
                                .cornerRadius(4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.2)))
            }
        }
    }

    // MARK: - Binding helpers
    //
    // These factory methods return SwiftUI Bindings that read/write through
    // the @Binding<CanvasBlock?> `selectedBlock`.
    //
    // Why use these instead of direct $selectedBlock.someProperty?
    //   selectedBlock is Optional — force-unwrapping inline is unsafe.
    //   These helpers safely guard nil while still providing a mutable Binding.
    //
    // binding<V>(_ kp) — targets top-level CanvasBlock properties (title, x, y, w, h, ...)
    // contentBinding<V>(_ kp) — targets BlockContent properties (text, fontSize, navX, ...)

    private func binding<V>(_ kp: WritableKeyPath<CanvasBlock, V>) -> Binding<V> {
        Binding(
            get: { selectedBlock?[keyPath: kp] ?? selectedBlock![keyPath: kp] },
            set: { val in selectedBlock?[keyPath: kp] = val }
        )
    }

    private func contentBinding<V>(_ kp: WritableKeyPath<BlockContent, V>) -> Binding<V> {
        Binding(
            get: { selectedBlock?.content[keyPath: kp] ?? selectedBlock!.content[keyPath: kp] },
            set: { val in selectedBlock?.content[keyPath: kp] = val }
        )
    }
}

// MARK: - Add Block Sheet
//
// Modal sheet (presented by ProcessCanvasView's "+" toolbar button) for inserting
// a new CanvasBlock into the active canvas.
//
// Layout:
//   • Header: "Add Block" title + Cancel button
//   • 2-column grid of block type cards (static types defined below)
//   • Divider + "HMI Screens" section (one card per existing HMI screen)
//
// When the operator taps a card:
//   1. The factory closure creates a pre-configured CanvasBlock with sane defaults.
//   2. `onAdd(block)` is called — ProcessCanvasView calls canvasStore.addBlock(_:).
//   3. The sheet is dismissed automatically.
//
// Static block types are defined inline as an array of named tuples so that
// each entry bundles its icon, label, description, and default-value factory
// in one place — easy to extend without changing any other code.

struct AddBlockSheet: View {
    /// Called with the newly created block when the operator taps a type card.
    let onAdd: (CanvasBlock) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var hmiScreenStore: HMIScreenStore

    // ── Block type registry ───────────────────────────────────────────────
    // Each entry is a named tuple. The `factory` closure captures no external
    // state — it returns a fresh block with sensible default dimensions and content.
    // Adding a new block type here is the only change needed to expose it in the UI.

    private var staticBlockTypes: [(icon: String, label: String, desc: String, factory: () -> CanvasBlock)] {[
        ("text.alignleft",   "Label",         "Title, heading, or annotation",
         { CanvasBlock(title: "Label", w: 260, h: 130, content: .label("Area Title", size: 32)) }),

        ("list.bullet",      "Tag Monitor",   "Live table of tag values",
         { CanvasBlock(title: "Tag Monitor", w: 320, h: 220, content: .tagMonitor([])) }),

        ("square.grid.2x2", "Status Grid",   "Coloured status tiles",
         { CanvasBlock(title: "Status Grid", w: 340, h: 200, content: .statusGrid([])) }),

        ("exclamationmark.triangle","Alarm Panel","Active alarm list",
         { CanvasBlock(title: "Alarms", w: 360, h: 200, content: .alarmPanel(max: 5)) }),

        ("arrow.right.circle","Nav Button",   "Animate viewport to another area",
         { CanvasBlock(title: "Navigate", w: 240, h: 80, bgHex: "#0A1628", borderHex: "#1D4ED8",
                       content: .navButton(label: "Go to Area →", x: 0, y: 0, scale: 1)) }),

        ("gearshape",        "Equipment",     "Motor, pump, valve, tank status",
         { CanvasBlock(title: "Equipment", w: 200, h: 180, content: .equipment("pump")) }),

        ("chart.xyaxis.line","Mini Trend",    "Sparkline for up to 3 tags",
         { CanvasBlock(title: "Trends", w: 320, h: 160, content: .trendMini([], minutes: 30)) }),

        ("square.grid.2x2", "Screen Group",  "Multiple HMI screens as one seamless display",
         { CanvasBlock(title: "Screen Group", w: 340, h: 220, bgHex: "#0A1628", borderHex: "#1D4ED8",
                       content: .screenGroup(cols: 2)) }),

        ("rectangle.dashed", "Region",       "Labelled area background for plant grouping",
         { CanvasBlock(title: "Region", showTitle: false, w: 600, h: 400,
                       bgHex: "#0D1E3A", borderHex: "#1D4ED8",
                       content: .region("Area Name", colorHex: "#1D4ED8")) }),
    ]}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ────────────────────────────────────────────────────
            HStack {
                Text("Add Block").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.bordered)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    // ── Standard block type grid ──────────────────────────
                    // 2-column flexible grid; each cell is a blockTypeButton card.
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(staticBlockTypes, id: \.label) { bt in
                            blockTypeButton(icon: bt.icon, label: bt.label, desc: bt.desc) {
                                onAdd(bt.factory())
                                dismiss()
                            }
                        }
                    }

                    // ── HMI Screens section ───────────────────────────────
                    // Dynamically populated from HMIScreenStore.allScreenMeta.
                    // Each card creates an hmiScreen block pre-linked to that screen.
                    if !hmiScreenStore.allScreenMeta.isEmpty {
                        Divider()
                        Text("HMI Screens")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            ForEach(hmiScreenStore.allScreenMeta) { meta in
                                blockTypeButton(
                                    icon: "rectangle.on.rectangle",
                                    label: meta.name,
                                    desc: "Open HMI screen"
                                ) {
                                    // Create an hmiScreen block pre-linked to this screen UUID
                                    onAdd(CanvasBlock(
                                        title: meta.name, w: 260, h: 180,
                                        bgHex: "#0A1628", borderHex: "#1D4ED8",
                                        content: .hmiScreen(id: meta.id, name: meta.name)
                                    ))
                                    dismiss()
                                }
                            }
                        }
                    } else {
                        // Hint shown when no HMI screens have been created yet
                        Divider()
                        HStack(spacing: 8) {
                            Image(systemName: "rectangle.on.rectangle")
                                .foregroundColor(.secondary)
                            Text("No HMI screens yet — create them in the HMI Screens tab to link them here.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding()
            }
        }
        .frame(width: 520, height: 480)
    }

    // MARK: - Block type card button
    //
    // Displays an icon, bold label, and description in a rounded card.
    // Tapping fires `action` which creates the block and dismisses the sheet.

    @ViewBuilder
    private func blockTypeButton(icon: String, label: String, desc: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(.accentColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(label).font(.subheadline.bold())
                    Text(desc).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Canvas Settings Sheet
//
// Modal sheet (presented by ProcessCanvasView's "⚙" toolbar button) for editing
// canvas-level settings that apply to the entire active ProcessCanvas document:
//
//   name        — display name shown in the canvas picker and window title
//   bgHex       — canvas background colour (hex string, e.g. "#0D1117")
//   gridSize    — grid snap/display cell size in canvas units (40–400, step 20)
//   gridVisible — whether the background grid lines are rendered
//
// All fields are initialised from the active canvas in .onAppear.
// Changes are written back only when the operator taps "Done" to avoid
// partial-update flicker while the operator is still typing.

struct CanvasSettingsSheet: View {
    @EnvironmentObject var canvasStore: ProcessCanvasStore
    @Environment(\.dismiss) private var dismiss

    // Local working copies — initialised from the active canvas in .onAppear.
    // Written back to the store only on "Done" tap.
    @State private var name:        String  = ""
    @State private var bgHex:       String  = "#0D1117"
    @State private var gridSize:    Double  = 120
    @State private var gridVisible: Bool    = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ────────────────────────────────────────────────────
            HStack {
                Text("Canvas Settings").font(.headline)
                Spacer()
                // "Done" atomically commits all local state to the store in one call.
                Button("Done") {
                    if var c = canvasStore.active {
                        c.name        = name
                        c.bgHex       = bgHex
                        c.gridSize    = gridSize
                        c.gridVisible = gridVisible
                        // Persists the updated canvas to disk via processcanvases.json
                        canvasStore.updateCanvasSettings(c)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            // ── Settings form ─────────────────────────────────────────────
            Form {
                TextField("Canvas Name", text: $name)
                TextField("Background Hex", text: $bgHex)
                Toggle("Show Grid", isOn: $gridVisible)
                HStack {
                    Text("Grid Size")
                    // Slider drives grid cell size; canvas grid lines are drawn every gridSize units
                    Slider(value: $gridSize, in: 40...400, step: 20)
                    Text("\(Int(gridSize))").frame(width: 36)
                }
            }
            .padding()
            .frame(width: 360)
        }
        // Load the active canvas values into local state when the sheet appears.
        // Uses a local copy so changes don't live-update the canvas while editing.
        .onAppear {
            if let c = canvasStore.active {
                name = c.name; bgHex = c.bgHex
                gridSize = c.gridSize; gridVisible = c.gridVisible
            }
        }
    }
}
