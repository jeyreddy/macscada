// MARK: - WriteValueSheet.swift
//
// Write-confirmation sheet for manually setting a single tag value.
// Invoked from MonitorView (and HMICanvasView run-mode push button).
// Role-gated: caller hides the button for non-canWrite operators.
//
// ── Two-Phase Write Flow ──────────────────────────────────────────────────────
//   WriteValueSheet creates a WriteRequest (pending) via:
//     dataService.requestWrite(tagName:value:requestedBy:)
//   This adds the request to TagEngine.pendingWrites.
//   Operator sees current value + proposed value in the sheet, confirms.
//   On confirm: dataService.confirmWrite(request) →
//     OPCUAClientService.writeValue(nodeId:value:) (if tag has nodeId)
//     tagEngine.resolveWrite(request) (simulation mode or no nodeId)
//     historian.logWrite(request, status:, actualValue:)
//   Cancel: dataService.cancelWrite(request) → removes from pendingWrites.
//
// ── Input Fields ──────────────────────────────────────────────────────────────
//   Analog tags:  TextField pre-filled with current numericValue (String("%g"))
//   Digital tags: Toggle/Picker pre-filled with current Bool state
//   String tags:  TextField pre-filled with current string value
//   Input type determined by tag.value case at init time.
//
// ── Validation ────────────────────────────────────────────────────────────────
//   Analog: Double(analogInput) must succeed; empty input = invalid.
//   Validated before enabling the "Write" button.
//   On OPC-UA write failure: writeError shown as red label; sheet stays open.
//
// ── Current Value Display ─────────────────────────────────────────────────────
//   Shows tag.name, tag.unit, and tag.value.displayString (pre-write, read-only).
//   Allows operators to compare proposed vs current before committing.

import SwiftUI

// MARK: - WriteValueSheet

/// Confirmation sheet for writing a single tag value via OPC-UA.
/// Presented from MonitorView when operator clicks "Write Value…".
/// Requires canWrite permission (enforced by the caller — button hidden for Viewers).
struct WriteValueSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var dataService: DataService
    @EnvironmentObject var tagEngine:   TagEngine

    let tag:          Tag
    let operatorName: String

    @State private var analogInput:   String  // pre-filled with current value
    @State private var boolSelection: Bool    // pre-filled with current digital state
    @State private var isWriting:     Bool    = false
    @State private var writeError:    String? = nil

    init(tag: Tag, operatorName: String) {
        self.tag          = tag
        self.operatorName = operatorName

        // Pre-populate inputs from current tag value
        switch tag.value {
        case .analog(let v):
            _analogInput   = State(initialValue: String(format: "%g", v))
            _boolSelection = State(initialValue: false)
        case .digital(let b):
            _analogInput   = State(initialValue: "")
            _boolSelection = State(initialValue: b)
        case .string(let s):
            _analogInput   = State(initialValue: s)
            _boolSelection = State(initialValue: false)
        case .none:
            _analogInput   = State(initialValue: "")
            _boolSelection = State(initialValue: false)
        }
    }

    // MARK: - Validation

    private var isValidInput: Bool {
        switch tag.dataType {
        case .analog:
            return Double(analogInput.trimmingCharacters(in: .whitespaces)) != nil
        case .digital:
            return true
        case .string:
            return !analogInput.trimmingCharacters(in: .whitespaces).isEmpty
        case .calculated, .totalizer, .composite:
            return false
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "Write Tag Value", icon: "pencil.line")
            Divider()

            Form {
                Section("Tag") {
                    LabeledContent("Name") {
                        Text(tag.name)
                            .font(.system(.body, design: .monospaced))
                    }
                    LabeledContent("Current Value") {
                        Text(tag.formattedValue)
                            .foregroundColor(.secondary)
                    }
                    if let desc = tag.description, !desc.isEmpty {
                        LabeledContent("Description") {
                            Text(desc).foregroundColor(.secondary).font(.caption)
                        }
                    }
                }

                Section("New Value") {
                    switch tag.dataType {
                    case .analog:
                        HStack {
                            TextField("Enter numeric value", text: $analogInput)
                                .font(.system(.body, design: .monospaced))
                            if let unit = tag.unit, !unit.isEmpty {
                                Text(unit).foregroundColor(.secondary)
                            }
                        }
                    case .digital:
                        Toggle(boolSelection ? "ON" : "OFF", isOn: $boolSelection)
                    case .string:
                        TextField("Enter text value", text: $analogInput)
                    case .calculated:
                        Label("Calculated tags cannot be written.", systemImage: "exclamationmark.triangle")
                            .foregroundColor(.orange).font(.caption)
                    case .totalizer:
                        Label("Totalizer tags cannot be written.", systemImage: "exclamationmark.triangle")
                            .foregroundColor(.orange).font(.caption)
                    case .composite:
                        Label("Composite tags cannot be written.", systemImage: "exclamationmark.triangle")
                            .foregroundColor(.orange).font(.caption)
                    }
                }

                if let err = writeError {
                    Section {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "xmark.octagon.fill")
                                .foregroundColor(.red).font(.caption)
                            Text(err)
                                .font(.caption).foregroundColor(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            // Footer
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                if isWriting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Writing…")
                    }
                } else {
                    Button("Write") { Task { await performWrite() } }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .disabled(!isValidInput)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding()
        }
        .frame(width: 420)
    }

    // MARK: - Write

    private func performWrite() async {
        guard isValidInput else { return }
        isWriting  = true
        writeError = nil

        // Build the TagValue to write
        let newValue: TagValue
        switch tag.dataType {
        case .analog:
            guard let d = Double(analogInput.trimmingCharacters(in: .whitespaces)) else {
                writeError = "Invalid numeric value."
                isWriting  = false
                return
            }
            newValue = .analog(d)
        case .digital:
            newValue = .digital(boolSelection)
        case .string:
            newValue = .string(analogInput.trimmingCharacters(in: .whitespaces))
        case .calculated:
            writeError = "Calculated tags cannot be written."
            isWriting  = false
            return
        case .totalizer:
            writeError = "Totalizer tags cannot be written."
            isWriting  = false
            return
        case .composite:
            writeError = "Composite tags cannot be written."
            isWriting  = false
            return
        }

        // Stage the write request in TagEngine
        guard let req = tagEngine.requestWrite(
            tagName:     tag.name,
            newValue:    newValue,
            requestedBy: operatorName
        ) else {
            writeError = "Tag '\(tag.name)' not found in engine."
            isWriting  = false
            return
        }

        // Execute via DataService (OPC-UA write + historian log)
        do {
            try await dataService.confirmWrite(req)
            dismiss()
        } catch {
            tagEngine.cancelWrite(req)
            writeError = error.localizedDescription
        }

        isWriting = false
    }
}
