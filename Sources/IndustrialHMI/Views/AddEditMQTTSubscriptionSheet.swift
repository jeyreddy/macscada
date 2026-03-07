// MARK: - AddEditMQTTSubscriptionSheet.swift
//
// Modal sheet for creating or editing a single MQTT topic-to-tag subscription.
// Presented from MQTTSettingsView's subscription table.
//
// ── Fields ────────────────────────────────────────────────────────────────────
//   topic    — MQTT topic filter (supports + single-level and # multi-level wildcards)
//              e.g. "sensors/+/temperature" or "plant/area1/#"
//   tagName  — Picker from tagNames list (all tags in TagEngine)
//   jsonPath — optional dot-separated path into JSON payload (e.g. "data.sensors.temp")
//              Empty = treat entire payload as a numeric string.
//              Tooltip explains the format.
//
// ── Validation ────────────────────────────────────────────────────────────────
//   formValid = !topic.trimmed.isEmpty && !tagName.isEmpty
//   Save button disabled when formValid = false.
//   validationError: optional inline error label (future: invalid wildcard detection).
//
// ── JSON Path ─────────────────────────────────────────────────────────────────
//   jsonPath "data.value" → MQTTDriver parses payload as JSON dict,
//   traverses ["data"]["value"] to extract a numeric Double.
//   Allows reuse of one MQTT topic for multiple tags via different JSON paths.
//   jsonPath stored as String? (nil when the text field is empty).
//
// ── Save Flow ─────────────────────────────────────────────────────────────────
//   Builds MQTTSubscription with backingId for INSERT OR REPLACE compatibility.
//   jsonPath stored as nil if the text field is empty (not as empty string).
//   Calls onSave(subscription) → MQTTSettingsView upserts to subscriptions @State.
//   Persisted on next "Save Configuration" press via ConfigDatabase.

import SwiftUI

// MARK: - AddEditMQTTSubscriptionSheet

/// Add or edit a single MQTTSubscription.
/// Pass `subscription: nil` for add mode, or an existing subscription for edit mode.
struct AddEditMQTTSubscriptionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let subscription: MQTTSubscription?
    let tagNames:     [String]
    let onSave:       (MQTTSubscription) -> Void

    // Form state
    @State private var topic:    String
    @State private var tagName:  String
    @State private var jsonPath: String

    // Inline validation
    @State private var validationError: String? = nil

    // Preserve id in edit mode so INSERT OR REPLACE updates the same row
    private let backingId: String
    private var isEditing: Bool { subscription != nil }

    init(subscription: MQTTSubscription?,
         tagNames: [String],
         onSave: @escaping (MQTTSubscription) -> Void) {
        self.subscription = subscription
        self.tagNames     = tagNames
        self.onSave       = onSave
        backingId         = subscription?.id ?? UUID().uuidString
        _topic    = State(initialValue: subscription?.topic              ?? "")
        _tagName  = State(initialValue: subscription?.tagName           ?? tagNames.first ?? "")
        _jsonPath = State(initialValue: subscription?.jsonPath          ?? "")
    }

    private var formValid: Bool {
        !topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !tagName.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                title: isEditing ? "Edit Subscription" : "Add Subscription",
                icon:  "antenna.radiowaves.left.and.right"
            )
            Divider()

            Form {
                Section("Topic") {
                    TextField("e.g.  sensors/+/temperature  or  plant/#", text: $topic)
                        .font(.system(.body, design: .monospaced))
                    Text("Use + for single-level wildcards and # for multi-level wildcards (# must be the last segment).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Tag Mapping") {
                    if tagNames.isEmpty {
                        Label("No tags configured — add tags in the Monitor view first.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundColor(.orange)
                    } else {
                        Picker("Tag Name", selection: $tagName) {
                            ForEach(tagNames, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                    }
                }

                Section("JSON Path (Optional)") {
                    TextField("e.g.  data.value  or  readings.0.temp", text: $jsonPath)
                        .font(.system(.body, design: .monospaced))
                    Text("Dot-separated path into a JSON payload. Leave empty to use the entire payload as a number.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let err = validationError {
                    Section {
                        Text(err)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            SheetFooter(
                onCancel:     { dismiss() },
                onSave:       save,
                saveDisabled: !formValid
            )
        }
        .frame(width: 460)
    }

    // MARK: - Save

    private func save() {
        validationError = nil
        let trimmedTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTopic.isEmpty else {
            validationError = "Topic cannot be empty."
            return
        }
        let trimmedPath = jsonPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = MQTTSubscription(
            id:       backingId,
            topic:    trimmedTopic,
            tagName:  tagName,
            jsonPath: trimmedPath.isEmpty ? nil : trimmedPath
        )
        onSave(result)
        dismiss()
    }
}
