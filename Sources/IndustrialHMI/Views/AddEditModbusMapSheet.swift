// MARK: - AddEditModbusMapSheet.swift
//
// Modal sheet for creating or editing a single Modbus register-to-tag mapping.
// Presented from ModbusSettingsView's register map table.
//
// ── Fields ────────────────────────────────────────────────────────────────────
//   tagName    — Picker from tagNames list (all tags in TagEngine)
//   slaveId    — text field (UInt8, 1–247; 255 for TCP gateways)
//   functionCode — Picker: 1=Coil, 2=Discrete Input, 3=Holding Register, 4=Input Register
//   address    — text field (UInt16, 0-based register/coil address)
//   dataType   — Picker: uint16, int16, uint32, int32, float32, coil
//   scale      — text field (Double, linear scale factor; default 1.0)
//   offset     — text field (Double, additive offset; default 0.0)
//   Formula displayed: tagValue = rawValue × scale + offset
//
// ── Validation ────────────────────────────────────────────────────────────────
//   slaveId: UInt8(text) required; range 1–255.
//   address: UInt16(text) required.
//   scale: Double(text) required.
//   offset: Double(text) required.
//   validationError shown as inline red text; Save button disabled while invalid.
//
// ── Save Flow ─────────────────────────────────────────────────────────────────
//   Builds ModbusRegisterMap with backingId (preserved from editingMap for update).
//   Calls onSave(map) → ModbusSettingsView upserts to registerMaps @State array.
//   ModbusSettingsView persists on the next "Save Configuration" press.
//
// ── backingId ─────────────────────────────────────────────────────────────────
//   backingId = registerMap?.id ?? UUID().uuidString
//   Preserves the same UUID in edit mode so ConfigDatabase.saveModbusRegisterMap()
//   performs an UPDATE rather than INSERT (SQLite INSERT OR REPLACE by id).

import SwiftUI

// MARK: - AddEditModbusMapSheet

/// Add or edit a single ModbusRegisterMap.
/// Pass `registerMap: nil` for add mode, or an existing map for edit mode.
struct AddEditModbusMapSheet: View {
    @Environment(\.dismiss) private var dismiss

    let registerMap: ModbusRegisterMap?
    let tagNames:    [String]
    let onSave:      (ModbusRegisterMap) -> Void

    // Form state (text for numeric fields to allow flexible input)
    @State private var tagName:       String
    @State private var slaveIdText:   String
    @State private var functionCode:  UInt8
    @State private var addressText:   String
    @State private var dataType:      ModbusDataType
    @State private var scaleText:     String
    @State private var offsetText:    String

    @State private var validationError: String? = nil

    private let backingId: String
    private var isEditing: Bool { registerMap != nil }

    init(registerMap: ModbusRegisterMap?,
         tagNames:    [String],
         onSave:      @escaping (ModbusRegisterMap) -> Void) {
        self.registerMap = registerMap
        self.tagNames    = tagNames
        self.onSave      = onSave
        backingId        = registerMap?.id ?? UUID().uuidString

        _tagName      = State(initialValue: registerMap?.tagName        ?? tagNames.first ?? "")
        _slaveIdText  = State(initialValue: String(registerMap?.slaveId ?? 1))
        _functionCode = State(initialValue: registerMap?.functionCode   ?? 3)
        _addressText  = State(initialValue: String(registerMap?.address ?? 0))
        _dataType     = State(initialValue: registerMap?.dataType       ?? .uint16)
        _scaleText    = State(initialValue: {
            let s = registerMap?.scale ?? 1.0
            return s == s.rounded() ? String(format: "%.0f", s) : String(s)
        }())
        _offsetText   = State(initialValue: {
            let o = registerMap?.valueOffset ?? 0.0
            return o == o.rounded() ? String(format: "%.0f", o) : String(o)
        }())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                title: isEditing ? "Edit Register Map" : "Add Register Map",
                icon:  "tablecells"
            )
            Divider()

            Form {
                Section("Tag Assignment") {
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

                Section("Modbus Address") {
                    HStack {
                        Text("Slave ID (1–247)")
                        Spacer()
                        TextField("1", text: $slaveIdText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                    }

                    Picker("Function Code", selection: $functionCode) {
                        Text("FC01 — Read Coils").tag(UInt8(1))
                        Text("FC02 — Read Discrete Inputs").tag(UInt8(2))
                        Text("FC03 — Read Holding Registers").tag(UInt8(3))
                        Text("FC04 — Read Input Registers").tag(UInt8(4))
                    }

                    HStack {
                        Text("Register Address (0-based)")
                        Spacer()
                        TextField("0", text: $addressText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                    }

                    Picker("Data Type", selection: $dataType) {
                        ForEach(ModbusDataType.allCases, id: \.self) { dt in
                            Text(dt.rawValue).tag(dt)
                        }
                    }
                }

                Section("Scaling  (tag value = raw × scale + offset)") {
                    HStack {
                        Text("Scale Factor")
                        Spacer()
                        TextField("1", text: $scaleText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("Value Offset")
                        Spacer()
                        TextField("0", text: $offsetText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                    }
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
                saveDisabled: tagName.isEmpty
            )
        }
        .frame(width: 460)
    }

    // MARK: - Save

    private func save() {
        validationError = nil

        guard let slaveId = UInt8(slaveIdText.trimmingCharacters(in: .whitespaces)),
              slaveId >= 1 else {
            validationError = "Slave ID must be a whole number between 1 and 247."
            return
        }
        guard let address = UInt16(addressText.trimmingCharacters(in: .whitespaces)) else {
            validationError = "Address must be a whole number between 0 and 65535."
            return
        }
        guard let scale = Double(scaleText.trimmingCharacters(in: .whitespaces)) else {
            validationError = "Scale must be a valid number (e.g. 0.1 or 1)."
            return
        }
        guard let offset = Double(offsetText.trimmingCharacters(in: .whitespaces)) else {
            validationError = "Offset must be a valid number (e.g. 0 or -273.15)."
            return
        }

        let result = ModbusRegisterMap(
            id:           backingId,
            tagName:      tagName,
            slaveId:      slaveId,
            functionCode: functionCode,
            address:      address,
            dataType:     dataType,
            scale:        scale,
            valueOffset:  offset
        )
        onSave(result)
        dismiss()
    }
}
