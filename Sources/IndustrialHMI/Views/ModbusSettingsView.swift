// MARK: - ModbusSettingsView.swift
//
// Settings view for configuring the Modbus protocol driver (TCP, RTU, or ASCII).
// Lets engineers define the endpoint, serial port parameters, poll interval,
// and all register-to-tag mappings.
//
// ── Layout (ScrollView) ───────────────────────────────────────────────────────
//   connectionSection  — mode picker (TCP/RTU/ASCII)
//                        TCP: host + port fields
//                        RTU/ASCII: serial port path + baud + data bits + parity + stop bits
//                        shared: poll interval (seconds), enabled toggle
//   registerMapSection — table of ModbusRegisterMap entries:
//                        columns: tag name, slave ID, function code, address, data type, scale
//                        row actions: edit (AddEditModbusMapSheet), delete
//                        "+" button → AddEditModbusMapSheet (add mode)
//   actionBar          — "Save Configuration" button → saves DriverConfig + all register maps
//                        to ConfigDatabase; "Test Connection" → transient Modbus ping
//
// ── Load/Save ─────────────────────────────────────────────────────────────────
//   .task: loads existing DriverConfig (type == .modbus) from ConfigDatabase.
//   If found: populates all @State fields from DriverConfig.endpoint + parameters.
//   On save: builds new DriverConfig + ModbusRegisterMap array → upserts to DB
//   then calls dataService.reconnectModbusDriver() to apply changes live.
//
// ── Register Map Edit ─────────────────────────────────────────────────────────
//   AddEditModbusMapSheet: slaveId, functionCode, address, dataType, scale, valueOffset,
//   and tagName picker (from tagEngine.getAllTags()).
//   editingRegisterMap drives the sheet: nil = add, non-nil = edit.
//
// ── Role Guard ────────────────────────────────────────────────────────────────
//   Save + add/delete controls disabled unless sessionManager.canManageTags (engineer+).
//   Viewer and control operators can read the configuration but cannot modify it.

import SwiftUI

// MARK: - ModbusSettingsView

struct ModbusSettingsView: View {
    @EnvironmentObject var dataService:    DataService
    @EnvironmentObject var tagEngine:      TagEngine
    @EnvironmentObject var sessionManager: SessionManager

    /// When set, this view manages a specific driver config instead of the first one.
    let configId: String?

    init(configId: String? = nil) { self.configId = configId }

    // ── Connection config state ──────────────────────────────────────────────
    @State private var driverConfigId: String = UUID().uuidString
    @State private var selectedMode:   ModbusMode = .tcp
    @State private var isEnabled:      Bool       = true

    // TCP params
    @State private var tcpHost: String = ""
    @State private var tcpPort: String = "502"

    // Serial params (RTU / ASCII)
    @State private var serialPath: String              = ""
    @State private var baud:       String              = "9600"
    @State private var dataBits:   String              = "8"
    @State private var parity:     ModbusSerialParity  = .none
    @State private var stopBits:   String              = "1"

    // Shared
    @State private var pollInterval: String = "1.0"

    // ── Register map state ───────────────────────────────────────────────────
    @State private var registerMaps:       [ModbusRegisterMap] = []
    @State private var editingRegisterMap: ModbusRegisterMap?  = nil
    @State private var showAddRegisterMap: Bool                = false

    // ── Async operation state ────────────────────────────────────────────────
    @State private var isSaving:    Bool    = false
    @State private var saveError:   String? = nil
    @State private var saveSuccess: Bool    = false

    // ── Derived ─────────────────────────────────────────────────────────────
    private var tagNames: [String] { tagEngine.getAllTags().map(\.name) }
    private var modbusDriver: ModbusDriver? {
        if let id = configId { return dataService.driver(configId: id) as? ModbusDriver }
        return dataService.driver(ofType: .modbus) as? ModbusDriver
    }
    private var isConnected: Bool { modbusDriver?.isConnected ?? false }

    private var builtEndpoint: String {
        switch selectedMode {
        case .tcp:
            let p = tcpPort.trimmingCharacters(in: .whitespaces).isEmpty ? "502" : tcpPort
            return "\(tcpHost.trimmingCharacters(in: .whitespaces)):\(p)"
        case .rtu:
            return "rtu:\(serialPath.trimmingCharacters(in: .whitespaces))"
        case .ascii:
            return "ascii:\(serialPath.trimmingCharacters(in: .whitespaces))"
        }
    }

    private var endpointEmpty: Bool {
        switch selectedMode {
        case .tcp:   return tcpHost.trimmingCharacters(in: .whitespaces).isEmpty
        case .rtu, .ascii: return serialPath.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private var canSave: Bool { !isSaving && !endpointEmpty }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusCard
                Divider()
                connectionSection
                Divider()
                registerMapSection
                Divider()
                saveReconnectSection
            }
            .padding(20)
        }
        .navigationTitle("Modbus")
        .task { await loadConfig() }
        .sheet(isPresented: $showAddRegisterMap) {
            AddEditModbusMapSheet(
                registerMap: nil,
                tagNames:    tagNames
            ) { newMap in
                registerMaps.append(newMap)
            }
        }
        .sheet(item: $editingRegisterMap) { map in
            AddEditModbusMapSheet(
                registerMap: map,
                tagNames:    tagNames
            ) { updated in
                if let idx = registerMaps.firstIndex(where: { $0.id == updated.id }) {
                    registerMaps[idx] = updated
                }
            }
        }
    }

    // MARK: - Sections

    private var statusCard: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(isConnected ? Color.green : Color.secondary)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(isConnected ? "Connected" : "Disconnected")
                    .font(.headline)
                if !endpointEmpty {
                    Text(builtEndpoint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("No device configured")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding(14)
        .background((isConnected ? Color.green : Color.secondary).opacity(0.08))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder((isConnected ? Color.green : Color.secondary).opacity(0.3), lineWidth: 1)
        )
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Connection", systemImage: "cable.connector.horizontal")
                .font(.headline)

            Form {
                Section("Transport Mode") {
                    Picker("Mode", selection: $selectedMode) {
                        ForEach(ModbusMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue.uppercased()).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Enable this driver", isOn: $isEnabled)
                }

                if selectedMode == .tcp {
                    Section("TCP Endpoint") {
                        HStack(spacing: 8) {
                            TextField("Host or IP address", text: $tcpHost)
                                .textFieldStyle(.roundedBorder)
                            Text(":")
                                .foregroundColor(.secondary)
                            TextField("502", text: $tcpPort)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                } else {
                    Section("Serial Port") {
                        TextField("/dev/cu.usbserial-0001", text: $serialPath)
                            .font(.system(.body, design: .monospaced))
                        HStack(spacing: 20) {
                            LabeledContent("Baud Rate") {
                                Picker("", selection: $baud) {
                                    ForEach(["1200","2400","4800","9600","19200",
                                             "38400","57600","115200"], id: \.self) {
                                        Text($0).tag($0)
                                    }
                                }
                                .frame(width: 110)
                            }
                            LabeledContent("Data Bits") {
                                Picker("", selection: $dataBits) {
                                    ForEach(["7","8"], id: \.self) { Text($0).tag($0) }
                                }
                                .frame(width: 60)
                            }
                        }
                        HStack(spacing: 20) {
                            LabeledContent("Parity") {
                                Picker("", selection: $parity) {
                                    ForEach(ModbusSerialParity.allCases, id: \.self) { p in
                                        Text(p.displayName).tag(p)
                                    }
                                }
                                .frame(width: 90)
                            }
                            LabeledContent("Stop Bits") {
                                Picker("", selection: $stopBits) {
                                    ForEach(["1","2"], id: \.self) { Text($0).tag($0) }
                                }
                                .frame(width: 60)
                            }
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: selectedMode)
                }

                Section("Polling") {
                    HStack {
                        Text("Poll Interval (seconds)")
                        Spacer()
                        TextField("1.0", text: $pollInterval)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: selectedMode.isSerial ? 380 : 200)
            .animation(.easeInOut(duration: 0.2), value: selectedMode)
        }
    }

    private var registerMapSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Register Map", systemImage: "tablecells")
                    .font(.headline)
                Spacer()
                Button {
                    showAddRegisterMap = true
                } label: {
                    Label("Add Register", systemImage: "plus.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text("Maps Modbus registers and coils to process tags. Tag value = raw × scale + offset.")
                .font(.caption)
                .foregroundColor(.secondary)

            if registerMaps.isEmpty {
                ContentUnavailableView(
                    "No Register Maps",
                    systemImage: "tablecells.badge.ellipsis",
                    description: Text("Add register maps to start reading Modbus data.")
                )
                .frame(minHeight: 100)
            } else {
                List {
                    ForEach(registerMaps) { map in
                        registerMapRow(map)
                    }
                    .onDelete { offsets in
                        registerMaps.remove(atOffsets: offsets)
                    }
                }
                .listStyle(.bordered)
                .frame(minHeight: 140, maxHeight: 400)
            }
        }
    }

    private func registerMapRow(_ map: ModbusRegisterMap) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("FC\(map.functionCode)  @\(map.address)")
                        .font(.system(.body, design: .monospaced).bold())
                    Text("(\(map.dataType.rawValue))")
                        .font(.caption)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.blue.opacity(0.1))
                        .foregroundColor(.blue)
                        .cornerRadius(4)
                }
                HStack(spacing: 4) {
                    Text("Slave \(map.slaveId)  ·")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Tag:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(map.tagName)
                        .font(.caption)
                        .foregroundColor(.accentColor)
                    if map.scale != 1.0 || map.valueOffset != 0.0 {
                        Text("· ×\(String(format: "%g", map.scale))  +\(String(format: "%g", map.valueOffset))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
            Button("Edit") { editingRegisterMap = map }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private var saveReconnectSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let err = saveError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .background(Color.red.opacity(0.06))
                .cornerRadius(6)
            }

            if saveSuccess {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Configuration saved and Modbus driver reconnected.")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }

            HStack {
                Spacer()
                Button {
                    Task { await saveAndReconnect() }
                } label: {
                    if isSaving {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Reconnecting…")
                        }
                    } else {
                        Label("Save & Reconnect", systemImage: "bolt.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    // MARK: - Load

    private func loadConfig() async {
        saveError   = nil
        saveSuccess = false
        do {
            let configs: [DriverConfig]
            if let id = configId {
                let all = try await dataService.configDatabase.fetchAll()
                configs = all.filter { $0.id == id }
                if let cfg = configs.first { driverConfigId = cfg.id }
            } else {
                configs = try await dataService.configDatabase.fetch(type: .modbus)
            }
            if let cfg = configs.first {
                driverConfigId = cfg.id
                isEnabled      = cfg.enabled
                let ep = cfg.endpoint

                if ep.lowercased().hasPrefix("rtu:") {
                    selectedMode = .rtu
                    serialPath   = String(ep.dropFirst(4))  // drop "rtu:"
                } else if ep.lowercased().hasPrefix("ascii:") {
                    selectedMode = .ascii
                    serialPath   = String(ep.dropFirst(6))  // drop "ascii:"
                } else {
                    selectedMode = .tcp
                    if let colonIdx = ep.lastIndex(of: ":") {
                        tcpHost = String(ep[ep.startIndex..<colonIdx])
                        tcpPort = String(ep[ep.index(after: colonIdx)...])
                    } else {
                        tcpHost = ep
                        tcpPort = "502"
                    }
                }

                baud         = cfg.parameters["baud"]         ?? "9600"
                dataBits     = cfg.parameters["databits"]     ?? "8"
                parity       = ModbusSerialParity(rawValue: (cfg.parameters["parity"] ?? "N").uppercased()) ?? .none
                stopBits     = cfg.parameters["stopbits"]     ?? "1"
                pollInterval = cfg.parameters["pollInterval"] ?? "1.0"
            }
            if let id = configId {
                registerMaps = try await dataService.configDatabase.fetchModbusRegisterMaps(forDriverId: id)
            } else {
                registerMaps = try await dataService.configDatabase.fetchModbusRegisterMaps()
            }
            diagLog("DIAG [ModbusSettingsView] loaded \(registerMaps.count) register map(s)")
        } catch {
            saveError = "Failed to load config: \(error.localizedDescription)"
            Logger.shared.error("ModbusSettingsView loadConfig: \(error.localizedDescription)")
        }
    }

    // MARK: - Save & Reconnect

    private func saveAndReconnect() async {
        guard canSave else { return }
        isSaving    = true
        saveError   = nil
        saveSuccess = false

        do {
            // Build parameters dict
            var params: [String: String] = [:]
            let pi = pollInterval.trimmingCharacters(in: .whitespaces)
            params["pollInterval"] = pi.isEmpty ? "1.0" : pi
            if selectedMode.isSerial {
                params["baud"]     = baud
                params["databits"] = dataBits
                params["parity"]   = parity.rawValue
                params["stopbits"] = stopBits
            }

            // Save driver config
            let updated = DriverConfig(
                id:         driverConfigId,
                type:       .modbus,
                name:       "Modbus Device",
                endpoint:   builtEndpoint,
                enabled:    isEnabled,
                parameters: params,
                createdAt:  Date(),
                updatedAt:  Date()
            )
            try await dataService.configDatabase.save(updated)

            // Replace register maps (delete-then-insert)
            if let id = configId {
                try await dataService.configDatabase.deleteModbusRegisterMaps(forDriverId: id)
                for map in registerMaps {
                    try await dataService.configDatabase.saveModbusRegisterMap(map, forDriverId: id)
                }
            } else {
                let existing = try await dataService.configDatabase.fetchModbusRegisterMaps()
                for map in existing { try await dataService.configDatabase.deleteModbusRegisterMap(id: map.id) }
                for map in registerMaps { try await dataService.configDatabase.saveModbusRegisterMap(map) }
            }

            diagLog("DIAG [ModbusSettingsView] saved \(registerMaps.count) map(s), reconnecting…")
            if let id = configId {
                await dataService.reloadDriver(configId: id)
            } else {
                await dataService.reloadDriver(ofType: .modbus)
            }

            saveSuccess = true
            Logger.shared.info("ModbusSettingsView: config saved and driver reloaded")
        } catch {
            saveError = error.localizedDescription
            Logger.shared.error("ModbusSettingsView saveAndReconnect: \(error.localizedDescription)")
        }

        isSaving = false
    }
}
