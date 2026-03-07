// MARK: - RecipesView.swift
//
// Recipe management screen — browse, create, edit, delete, and activate production recipes.
//
// ── Layout (NavigationSplitView) ──────────────────────────────────────────────
//   Sidebar:  sidebarList — list of all recipes, sorted by name.
//             Each row shows: name, version, setpoint count, last activated timestamp.
//             Context menu: Edit, Duplicate, Delete.
//   Detail:   RecipeDetailView(recipe:) — shown when a recipe is selected.
//             ContentUnavailableView when nothing selected.
//
// ── RecipeDetailView (inline) ─────────────────────────────────────────────────
//   Shows recipe metadata: name, description, version, createdAt, lastActivatedAt.
//   Setpoints Table: tag name | target value | current live value | delta column.
//     Current live value: tagEngine.getTag(named:)?.value.numericValue ?? "--"
//     Delta: target − current (color-coded: green ≈ 0, yellow mild, red large)
//   "Activate" button: recipeStore.activateRecipe(recipe, by: username)
//     Role guard: only visible if sessionManager.currentOperator.canWrite.
//     Shows activation result (RecipeActivationResult) in an alert after firing.
//   "+ Add Setpoint" button: inline form for tag name + target value.
//
// ── Add/Edit Recipe Sheet ─────────────────────────────────────────────────────
//   AddRecipeSheet: name, description, initial setpoints list.
//   EditRecipeSheet: same fields pre-populated; saves via recipeStore.updateRecipe().
//   Both sheets use a form with TextField + stepper for each setpoint value.
//
// ── Activation Result ────────────────────────────────────────────────────────
//   RecipeActivationResult: successes: [String], failures: [(String, String)]
//   recipeStore.lastActivationResult is published and observed in RecipeDetailView.
//   Alert shows summary: "X of Y setpoints applied" with failure details if any.
//
// ── Role-Based Access ─────────────────────────────────────────────────────────
//   sessionManager.canManageTags (engineer+): create/edit/delete recipes.
//   sessionManager.currentOperator.canWrite (control+): activate recipes.
//   Viewer role: read-only; activate button and edit controls hidden.

import SwiftUI

// MARK: - RecipesView

/// Main recipe management screen.
///
/// Left panel: list of saved recipes with quick-info (setpoint count, last activation).
/// Right panel: recipe detail / editor — shows each setpoint's target vs. live current
/// value, lets engineers add / remove setpoints, and lets operators activate the recipe.
struct RecipesView: View {
    @EnvironmentObject var recipeStore:    RecipeStore
    @EnvironmentObject var tagEngine:      TagEngine
    @EnvironmentObject var sessionManager: SessionManager

    @State private var selectedRecipeId: UUID?
    @State private var showAddRecipe     = false
    @State private var editingRecipe:    Recipe? = nil  // non-nil = editor sheet open

    private var selectedRecipe: Recipe? {
        recipeStore.recipes.first { $0.id == selectedRecipeId }
    }

    var body: some View {
        NavigationSplitView {
            sidebarList
        } detail: {
            if let recipe = selectedRecipe {
                RecipeDetailView(recipe: recipe)
                    .id(recipe.id)          // force re-render on selection change
            } else {
                ContentUnavailableView(
                    "No Recipe Selected",
                    systemImage: "square.stack.3d.up",
                    description: Text("Select a recipe from the list, or create a new one.")
                )
            }
        }
        .navigationTitle("Recipes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if sessionManager.canManageTags {
                    Button(action: { showAddRecipe = true }) {
                        Label("New Recipe", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showAddRecipe) {
            AddRecipeSheet { newRecipe in
                recipeStore.addRecipe(newRecipe)
                selectedRecipeId = newRecipe.id
            }
        }
    }

    // MARK: Sidebar

    private var sidebarList: some View {
        List(recipeStore.recipes, selection: $selectedRecipeId) { recipe in
            RecipeRow(recipe: recipe)
                .tag(recipe.id)
                .contextMenu {
                    if sessionManager.canManageTags {
                        Button("Delete", role: .destructive) {
                            if selectedRecipeId == recipe.id { selectedRecipeId = nil }
                            recipeStore.deleteRecipe(id: recipe.id)
                        }
                    }
                }
        }
        .listStyle(.sidebar)
        .overlay {
            if recipeStore.recipes.isEmpty {
                ContentUnavailableView(
                    "No Recipes",
                    systemImage: "square.stack.3d.up.slash",
                    description: Text("Create a recipe to save a process configuration.")
                )
            }
        }
    }
}

// MARK: - RecipeRow

private struct RecipeRow: View {
    let recipe: Recipe

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(recipe.name)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 8) {
                Label("\(recipe.setpoints.count)", systemImage: "slider.horizontal.3")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let by = recipe.lastActivatedBy, let at = recipe.lastActivatedAt {
                    Text("·")
                        .foregroundColor(.secondary)
                    Text("Activated \(at, style: .relative) by \(by)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - RecipeDetailView

private struct RecipeDetailView: View {
    @EnvironmentObject var recipeStore:    RecipeStore
    @EnvironmentObject var tagEngine:      TagEngine
    @EnvironmentObject var sessionManager: SessionManager

    let recipe: Recipe

    @State private var editedRecipe:  Recipe
    @State private var isEditing      = false
    @State private var showAddSP      = false
    @State private var showConfirmAct = false
    @State private var activationBanner: RecipeActivationResult? = nil

    init(recipe: Recipe) {
        self.recipe      = recipe
        _editedRecipe    = State(initialValue: recipe)
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Activation result banner ──────────────────────────────────────
            if let result = activationBanner {
                activationResultBanner(result)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // ── Header ────────────────────────────────────────────────────────
            recipeHeader
            Divider()

            // ── Setpoints table ───────────────────────────────────────────────
            setpointsTable

            Divider()

            // ── Footer ────────────────────────────────────────────────────────
            recipeFooter
        }
        .onChange(of: recipeStore.lastActivationResult?.activatedAt) { _, _ in
            if let r = recipeStore.lastActivationResult, r.recipe.id == recipe.id {
                withAnimation { activationBanner = r }
                Task {
                    try? await Task.sleep(for: .seconds(8))
                    withAnimation { activationBanner = nil }
                }
            }
        }
        .sheet(isPresented: $showAddSP) {
            AddSetpointSheet(existingTagNames: Set(editedRecipe.setpoints.map { $0.tagName })) { sp in
                editedRecipe.setpoints.append(sp)
            }
            .environmentObject(tagEngine)
        }
        .confirmationDialog(
            "Activate '\(recipe.name)'?",
            isPresented: $showConfirmAct,
            titleVisibility: .visible
        ) {
            Button("Activate \(recipe.setpoints.count) Setpoint(s)", role: .destructive) {
                Task { await recipeStore.activateRecipe(recipe, by: sessionManager.currentUsername) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will write \(recipe.setpoints.count) value(s) to the live process.")
        }
    }

    // MARK: Header

    private var recipeHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if isEditing {
                    TextField("Recipe Name", text: $editedRecipe.name)
                        .textFieldStyle(.roundedBorder)
                        .font(.title2.bold())
                    TextField("Description", text: $editedRecipe.description)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                } else {
                    Text(recipe.name)
                        .font(.title2.bold())
                    if !recipe.description.isEmpty {
                        Text(recipe.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Version chip
            Text("v\(recipe.version)")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(4)

            // Edit / Save / Cancel
            if sessionManager.canManageTags {
                if isEditing {
                    Button("Cancel") {
                        editedRecipe = recipe
                        isEditing = false
                    }
                    .buttonStyle(.bordered)
                    Button("Save") {
                        recipeStore.updateRecipe(editedRecipe)
                        isEditing = false
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Edit") { isEditing = true }
                        .buttonStyle(.bordered)
                }
            }

            // Activate button
            Button {
                showConfirmAct = true
            } label: {
                Label(
                    recipeStore.isActivating ? "Activating…" : "Activate",
                    systemImage: "play.fill"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(
                !sessionManager.canWrite ||
                recipe.setpoints.isEmpty ||
                recipeStore.isActivating
            )
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: Setpoints Table

    @ViewBuilder
    private var setpointsTable: some View {
        let setpoints = isEditing ? editedRecipe.setpoints : recipe.setpoints
        if setpoints.isEmpty {
            VStack(spacing: 8) {
                ContentUnavailableView(
                    "No Setpoints",
                    systemImage: "slider.horizontal.3",
                    description: Text("Add setpoints to define the process configuration.")
                )
                if isEditing {
                    Button("Add Setpoint") { showAddSP = true }
                        .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(setpoints) {
                // Tag name
                TableColumn("Tag") { sp in
                    Text(sp.tagName)
                        .font(.system(.body, design: .monospaced))
                }
                .width(min: 160)

                // Target value
                TableColumn("Target") { sp in
                    if isEditing {
                        SetpointValueField(
                            value: bindingForSetpoint(sp),
                            unit: sp.displayUnit
                        )
                    } else {
                        HStack(spacing: 4) {
                            Text(String(format: "%.3f", sp.value))
                                .font(.system(.body, design: .monospaced))
                            if let u = sp.displayUnit {
                                Text(u).foregroundColor(.secondary).font(.caption)
                            }
                        }
                    }
                }
                .width(120)

                // Live current value (always read-only)
                TableColumn("Current") { sp in
                    if let tag = tagEngine.getTag(named: sp.tagName) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(qualityColor(tag.quality))
                                .frame(width: 6, height: 6)
                            Text(tag.formattedValue)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(deltaColor(sp: sp, tag: tag))
                        }
                    } else {
                        Text("—").foregroundColor(.secondary)
                    }
                }
                .width(120)

                // Delta
                TableColumn("Δ") { sp in
                    if let tag = tagEngine.getTag(named: sp.tagName),
                       let cur = tag.value.numericValue {
                        let delta = sp.value - cur
                        Text(String(format: "%+.3f", delta))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(abs(delta) < 0.001 ? .secondary : .primary)
                    } else {
                        Text("—").foregroundColor(.secondary)
                    }
                }
                .width(80)

                // Remove button (edit mode only)
                TableColumn("") { sp in
                    if isEditing {
                        Button(role: .destructive) {
                            editedRecipe.setpoints.removeAll { $0.id == sp.id }
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .width(32)
            }
            .overlay(alignment: .bottomTrailing) {
                if isEditing {
                    Button("Add Setpoint") { showAddSP = true }
                        .buttonStyle(.bordered)
                        .padding()
                }
            }
        }
    }

    // MARK: Footer

    private var recipeFooter: some View {
        HStack {
            if let at = recipe.lastActivatedAt, let by = recipe.lastActivatedBy {
                Image(systemName: "checkmark.circle")
                    .foregroundColor(.green)
                    .font(.caption)
                Text("Last activated \(at, style: .relative) by \(by)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Never activated")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text("\(recipe.setpoints.count) setpoint(s)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: Activation Result Banner

    private func activationResultBanner(_ result: RecipeActivationResult) -> some View {
        HStack(spacing: 10) {
            Image(systemName: result.allSucceeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(result.allSucceeded ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.allSucceeded
                     ? "Recipe activated successfully (\(result.successCount) setpoints)"
                     : "Partial activation: \(result.successCount) OK, \(result.failureCount) failed")
                    .font(.caption.bold())
                if !result.failed.isEmpty {
                    Text(result.failed.map { $0.tagName }.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Button { withAnimation { activationBanner = nil } } label: {
                Image(systemName: "xmark").font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(result.allSucceeded ? Color.green.opacity(0.12) : Color.orange.opacity(0.12))
    }

    // MARK: Helpers

    private func bindingForSetpoint(_ sp: RecipeSetpoint) -> Binding<Double> {
        Binding(
            get: { editedRecipe.setpoints.first(where: { $0.id == sp.id })?.value ?? sp.value },
            set: { newVal in
                if let idx = editedRecipe.setpoints.firstIndex(where: { $0.id == sp.id }) {
                    editedRecipe.setpoints[idx].value = newVal
                }
            }
        )
    }

    private func qualityColor(_ q: TagQuality) -> Color {
        switch q { case .good: return .green; case .uncertain: return .yellow; case .bad: return .red }
    }

    private func deltaColor(sp: RecipeSetpoint, tag: Tag) -> Color {
        guard let cur = tag.value.numericValue else { return .primary }
        return abs(sp.value - cur) < 0.001 ? .green : .primary
    }
}

// MARK: - SetpointValueField

/// Inline numeric text field used in the setpoint editor column.
private struct SetpointValueField: View {
    @Binding var value: Double
    let unit: String?

    @State private var text: String = ""

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 80)
                .onAppear  { text = String(format: "%.3f", value) }
                .onChange(of: text) { _, t in
                    if let v = Double(t) { value = v }
                }
            if let u = unit {
                Text(u).foregroundColor(.secondary).font(.caption)
            }
        }
    }
}

// MARK: - AddRecipeSheet

private struct AddRecipeSheet: View {
    @Environment(\.dismiss) var dismiss

    var onSave: (Recipe) -> Void

    @State private var name        = ""
    @State private var description = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.title3).foregroundColor(.accentColor)
                Text("New Recipe").font(.headline)
                Spacer()
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            Form {
                Section("Recipe Identity") {
                    TextField("Name", text: $name)
                    TextField("Description (optional)", text: $description)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Create") {
                    let r = Recipe(name: name, description: description)
                    onSave(r)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
        .frame(width: 360)
    }
}

// MARK: - AddSetpointSheet

private struct AddSetpointSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var tagEngine: TagEngine

    let existingTagNames: Set<String>
    var onAdd: (RecipeSetpoint) -> Void

    @State private var searchText = ""
    @State private var selectedTagName: String? = nil
    @State private var targetValue: Double = 0.0
    @State private var valueText   = "0.000"

    private var filteredTags: [Tag] {
        let all = tagEngine.getAllTags()
            .filter { $0.dataType != .string }       // only writable types
            .filter { !existingTagNames.contains($0.name) }
        if searchText.isEmpty { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.title3).foregroundColor(.accentColor)
                Text("Add Setpoint").font(.headline)
                Spacer()
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            HSplitView {
                // Left: tag picker
                VStack(spacing: 0) {
                    TextField("Search tags…", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .padding(8)
                    List(filteredTags, selection: $selectedTagName) { tag in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tag.name)
                                .font(.system(.caption, design: .monospaced))
                            HStack {
                                Text(tag.formattedValue).font(.caption2).foregroundColor(.secondary)
                                if let u = tag.unit {
                                    Text(u).font(.caption2).foregroundColor(.secondary)
                                }
                            }
                        }
                        .tag(tag.name)
                    }
                }
                .frame(minWidth: 220, maxWidth: 280)

                // Right: target value
                VStack(alignment: .leading, spacing: 12) {
                    if let name = selectedTagName,
                       let tag  = tagEngine.getTag(named: name) {
                        Group {
                            LabeledContent("Tag",     value: tag.name)
                            LabeledContent("Current", value: tag.formattedValue)
                            LabeledContent("Unit",    value: tag.unit ?? "—")
                        }
                        .font(.caption)

                        Divider()

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Target Value")
                                .font(.caption).foregroundColor(.secondary)
                            HStack {
                                TextField("", text: $valueText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 100)
                                    .onChange(of: valueText) { _, t in
                                        if let v = Double(t) { targetValue = v }
                                    }
                                    .onAppear {
                                        if let v = tag.value.numericValue {
                                            targetValue = v
                                            valueText   = String(format: "%.3f", v)
                                        }
                                    }
                                if let u = tag.unit {
                                    Text(u).font(.caption).foregroundColor(.secondary)
                                }
                            }
                        }
                    } else {
                        Text("Select a tag from the list")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    Spacer()
                }
                .padding()
                .frame(minWidth: 200)
            }
            .frame(height: 300)

            Divider()

            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Add") {
                    guard let name = selectedTagName else { return }
                    let unit = tagEngine.getTag(named: name)?.unit
                    let sp   = RecipeSetpoint(tagName: name, value: targetValue, displayUnit: unit)
                    onAdd(sp)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedTagName == nil)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
        .frame(width: 520)
    }
}
