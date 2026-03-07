// MARK: - AddEditJobSheet.swift
//
// Modal sheet for creating or editing a ScheduledJob in the Scheduler.
// Pass editingJob = nil for add mode, existing ScheduledJob for edit mode.
//
// ── Form Sections ─────────────────────────────────────────────────────────────
//   Name + enabled toggle
//   Trigger Type picker (daily / interval / once):
//     .daily:    hour stepper (0–23) + minute stepper (0–59)
//     .interval: intervalMinutes stepper (minimum 1)
//     .once:     DatePicker with GraphicalDatePickerStyle
//   Action Type picker (activateRecipe / writeTag):
//     .activateRecipe: recipe picker from recipeStore.recipes (by name)
//     .writeTag:       tag name text field + nodeId text field + value text field
//
// ── Validation ────────────────────────────────────────────────────────────────
//   Name must not be empty.
//   .activateRecipe: selectedRecipeID must be non-nil.
//   .writeTag: tagName must not be empty; writeValue must parse as Double.
//   On validation failure: showError = true → errorMessage shown as red label.
//
// ── Save Flow ─────────────────────────────────────────────────────────────────
//   On save: build ScheduledJob from form state.
//   isEditing = false → schedulerService.addJob(job)
//   isEditing = true  → schedulerService.updateJob(job) (preserves id + lastRunAt)
//   dismiss() on success.
//
// ── Init Pre-population ───────────────────────────────────────────────────────
//   editingJob non-nil: all @State fields initialized from editingJob in .onAppear.
//   editingJob nil: defaults used (name="New Job", daily@08:00, activateRecipe).

import SwiftUI

// MARK: - AddEditJobSheet

struct AddEditJobSheet: View {
    @EnvironmentObject var schedulerService: SchedulerService
    @EnvironmentObject var recipeStore:      RecipeStore
    @Environment(\.dismiss) private var dismiss

    // nil = creating new job
    let editingJob: ScheduledJob?

    // MARK: - Form state

    @State private var name:            String = "New Job"
    @State private var isEnabled:       Bool   = true

    // Trigger
    @State private var triggerType:     TriggerType = .daily
    @State private var dailyHour:       Int    = 8
    @State private var dailyMinute:     Int    = 0
    @State private var intervalMinutes: Int    = 60
    @State private var onceDate:        Date   = Date().addingTimeInterval(3600)

    // Action
    @State private var actionType:      ScheduledActionType = .activateRecipe
    @State private var selectedRecipeID: UUID?
    @State private var tagName:         String = ""
    @State private var nodeId:          String = ""
    @State private var writeValue:      String = "0.0"

    // Validation
    @State private var showError = false
    @State private var errorMessage = ""

    var isEditing: Bool { editingJob != nil }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Sheet header
            HStack {
                Text(isEditing ? "Edit Job" : "New Job")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button(isEditing ? "Save" : "Add") { save() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            // Form
            Form {
                // ── General ──────────────────────────────────────────────
                Section("General") {
                    TextField("Job Name", text: $name)
                    Toggle("Enabled", isOn: $isEnabled)
                }

                // ── Trigger ───────────────────────────────────────────────
                Section("Trigger") {
                    Picker("Type", selection: $triggerType) {
                        ForEach(TriggerType.allCases, id: \.self) { t in
                            Text(t.displayName).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch triggerType {
                    case .daily:
                        HStack {
                            Text("Hour")
                            Spacer()
                            Picker("Hour", selection: $dailyHour) {
                                ForEach(0..<24, id: \.self) { h in
                                    Text(String(format: "%02d", h)).tag(h)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 70)

                            Text("Minute")
                            Picker("Minute", selection: $dailyMinute) {
                                ForEach([0,5,10,15,20,25,30,35,40,45,50,55], id: \.self) { m in
                                    Text(String(format: "%02d", m)).tag(m)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 70)
                        }

                    case .interval:
                        Stepper("Every \(intervalMinutes) minute\(intervalMinutes == 1 ? "" : "s")",
                                value: $intervalMinutes, in: 1...1440, step: 1)

                    case .once:
                        DatePicker("Date & Time", selection: $onceDate,
                                   displayedComponents: [.date, .hourAndMinute])
                            .datePickerStyle(.graphical)
                    }
                }

                // ── Action ────────────────────────────────────────────────
                Section("Action") {
                    Picker("Type", selection: $actionType) {
                        ForEach(ScheduledActionType.allCases, id: \.self) { a in
                            Text(a.displayName).tag(a)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch actionType {
                    case .activateRecipe:
                        if recipeStore.recipes.isEmpty {
                            Text("No recipes available — create one in Recipes tab.")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        } else {
                            Picker("Recipe", selection: $selectedRecipeID) {
                                Text("— select —").tag(Optional<UUID>.none)
                                ForEach(recipeStore.recipes) { r in
                                    Text(r.name).tag(Optional(r.id))
                                }
                            }
                        }

                    case .writeTag:
                        TextField("Tag Name", text: $tagName)
                        TextField("OPC-UA Node ID (optional)", text: $nodeId)
                        TextField("Value", text: $writeValue)
                            .overlay(alignment: .trailing) {
                                if Double(writeValue) == nil {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .foregroundColor(.red)
                                        .padding(.trailing, 8)
                                }
                            }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 460, minHeight: 520)
        .alert("Validation Error", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
        }
        .onAppear { loadFromJob() }
    }

    // MARK: - Load / Save

    private func loadFromJob() {
        guard let job = editingJob else { return }
        name            = job.name
        isEnabled       = job.isEnabled
        triggerType     = job.triggerType
        dailyHour       = job.dailyHour
        dailyMinute     = job.dailyMinute
        intervalMinutes = job.intervalMinutes
        onceDate        = job.onceDate
        actionType      = job.actionType
        selectedRecipeID = job.recipeId
        tagName         = job.tagName
        nodeId          = job.nodeId
        writeValue      = String(job.writeValue)
    }

    private func save() {
        // Validate
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if trimmedName.isEmpty {
            errorMessage = "Job name cannot be empty."
            showError = true
            return
        }
        if actionType == .activateRecipe && selectedRecipeID == nil && !recipeStore.recipes.isEmpty {
            errorMessage = "Please select a recipe."
            showError = true
            return
        }
        if actionType == .writeTag {
            if tagName.trimmingCharacters(in: .whitespaces).isEmpty {
                errorMessage = "Tag name cannot be empty."
                showError = true
                return
            }
            if Double(writeValue) == nil {
                errorMessage = "Write value must be a valid number."
                showError = true
                return
            }
        }

        var job = editingJob ?? ScheduledJob()
        job.name            = trimmedName
        job.isEnabled       = isEnabled
        job.triggerType     = triggerType
        job.dailyHour       = dailyHour
        job.dailyMinute     = dailyMinute
        job.intervalMinutes = intervalMinutes
        job.onceDate        = onceDate
        job.actionType      = actionType
        job.recipeId        = selectedRecipeID
        job.tagName         = tagName.trimmingCharacters(in: .whitespaces)
        job.nodeId          = nodeId.trimmingCharacters(in: .whitespaces)
        job.writeValue      = Double(writeValue) ?? 0.0

        if isEditing {
            schedulerService.updateJob(job)
        } else {
            schedulerService.addJob(job)
        }
        dismiss()
    }
}

// MARK: - Display name helpers

extension TriggerType {
    var displayName: String {
        switch self {
        case .daily:    return "Daily"
        case .interval: return "Interval"
        case .once:     return "Once"
        }
    }
}

extension ScheduledActionType {
    var displayName: String {
        switch self {
        case .activateRecipe: return "Activate Recipe"
        case .writeTag:       return "Write Tag"
        }
    }
}
