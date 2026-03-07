// MARK: - ConnectionsSettingsView.swift
//
// Master-detail view for managing multiple driver connections (OPC-UA, MQTT, Modbus).
// Each connection maps to a DriverConfig row in ConfigDatabase.
//
// Left pane:  Grouped list of all connections by protocol type.
//             Status dot shows live connection state.
//             "+" menu to add a new connection; "−" to remove selected.
//
// Right pane: Protocol-specific configuration panel.
//             OPC-UA  → OPCUAConnectionView  (full discovery + connect)
//             MQTT    → MQTTSettingsView(configId:)
//             Modbus  → ModbusSettingsView(configId:)

import SwiftUI

// MARK: - ConnectionsSettingsView

struct ConnectionsSettingsView: View {
    @EnvironmentObject var dataService:    DataService
    @EnvironmentObject var tagEngine:      TagEngine
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var opcuaService:   OPCUAClientService

    @State private var configs:         [DriverConfig] = []
    @State private var selectedId:      String?
    @State private var showAddSheet     = false
    @State private var addType:         DriverType = .opcua
    @State private var deleteTarget:    DriverConfig?
    @State private var showDeleteAlert  = false

    var body: some View {
        HSplitView {
            // ── Left: connection list ────────────────────────────────────────
            VStack(spacing: 0) {
                List(selection: $selectedId) {
                    ForEach(DriverType.allCases, id: \.self) { type in
                        let group = configs.filter { $0.type == type }
                        if !group.isEmpty {
                            Section(type.rawValue) {
                                ForEach(group) { cfg in
                                    connectionRow(cfg)
                                        .tag(cfg.id)
                                        .contextMenu {
                                            if sessionManager.canManageTags {
                                                Button(role: .destructive) {
                                                    deleteTarget   = cfg
                                                    showDeleteAlert = true
                                                } label: {
                                                    Label("Remove \"\(cfg.name)\"", systemImage: "trash")
                                                }
                                            }
                                        }
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)

                Divider()

                // Bottom toolbar
                HStack(spacing: 4) {
                    Menu {
                        ForEach(DriverType.allCases, id: \.self) { type in
                            Button {
                                addType     = type
                                showAddSheet = true
                            } label: {
                                Label(type.rawValue, systemImage: typeIcon(type))
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 22, height: 22)
                    }
                    .menuStyle(.borderlessButton)
                    .help("Add connection")
                    .disabled(!sessionManager.canManageTags)

                    Spacer()

                    Button {
                        if let cfg = configs.first(where: { $0.id == selectedId }) {
                            deleteTarget   = cfg
                            showDeleteAlert = true
                        }
                    } label: {
                        Image(systemName: "minus")
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("Remove selected connection")
                    .disabled(selectedId == nil || !sessionManager.canManageTags)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .frame(minWidth: 200, idealWidth: 230, maxWidth: 280)

            // ── Right: detail panel ──────────────────────────────────────────
            if let id = selectedId, let cfg = configs.first(where: { $0.id == id }) {
                connectionDetail(cfg)
                    .id(id)                 // force view re-init when selection changes
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyDetail
            }
        }
        .task { await loadConfigs() }
        .sheet(isPresented: $showAddSheet, onDismiss: { Task { await loadConfigs() } }) {
            AddConnectionSheet(type: addType) { newConfig in
                await dataService.addConnection(newConfig)
                await loadConfigs()
                selectedId = newConfig.id
            }
        }
        .alert("Remove Connection", isPresented: $showDeleteAlert, presenting: deleteTarget) { cfg in
            Button("Remove \"\(cfg.name)\"", role: .destructive) {
                Task { await removeConnection(cfg) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { cfg in
            Text("All configuration for \"\(cfg.name)\" will be permanently deleted.")
        }
    }

    // MARK: - List Row

    private func connectionRow(_ cfg: DriverConfig) -> some View {
        HStack(spacing: 8) {
            Image(systemName: typeIcon(cfg.type))
                .foregroundColor(typeColor(cfg.type))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(cfg.name)
                    .font(.body)
                    .lineLimit(1)
                Text(cfg.endpoint.isEmpty ? "Not configured" : cfg.endpoint)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            // Live status dot
            Circle()
                .fill(statusColor(for: cfg.id))
                .frame(width: 8, height: 8)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Detail Panel

    @ViewBuilder
    private func connectionDetail(_ cfg: DriverConfig) -> some View {
        switch cfg.type {
        case .opcua:
            OPCUAConnectionView()
        case .mqtt:
            MQTTSettingsView(configId: cfg.id)
        case .modbus:
            ModbusSettingsView(configId: cfg.id)
        case .ethernetip:
            EtherNetIPSettingsView(configId: cfg.id)
        }
    }

    private var emptyDetail: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.left.to.line")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("Select a connection to configure it")
                .foregroundColor(.secondary)
            if sessionManager.canManageTags {
                Text("Use + to add OPC-UA, MQTT, Modbus, or EtherNet/IP connections")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func loadConfigs() async {
        configs = (try? await dataService.configDatabase.fetchAll()) ?? []
        // If nothing in DB yet, pre-populate with the default instance list
        if configs.isEmpty {
            configs = dataService.driverInstances.map(\.config)
        }
    }

    private func removeConnection(_ cfg: DriverConfig) async {
        await dataService.removeConnection(id: cfg.id)
        if selectedId == cfg.id { selectedId = nil }
        await loadConfigs()
    }

    // MARK: - Helpers

    private func typeIcon(_ type: DriverType) -> String {
        switch type {
        case .opcua:      return "network"
        case .mqtt:       return "antenna.radiowaves.left.and.right"
        case .modbus:     return "cable.connector.horizontal"
        case .ethernetip: return "cpu.fill"
        }
    }

    private func typeColor(_ type: DriverType) -> Color {
        switch type {
        case .opcua:      return .blue
        case .mqtt:       return .orange
        case .modbus:     return .purple
        case .ethernetip: return .green
        }
    }

    private func statusColor(for id: String) -> Color {
        guard let driver = dataService.driver(configId: id) else {
            // Default instances use driverType lookup
            return dataService.driver(ofType: configs.first(where: { $0.id == id })?.type ?? .opcua)?.isConnected == true
                ? .green : Color.secondary
        }
        return driver.isConnected ? .green : Color.secondary
    }
}

// MARK: - AddConnectionSheet

struct AddConnectionSheet: View {
    let type:   DriverType
    let onSave: (DriverConfig) async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name:     String = ""
    @State private var endpoint: String = ""
    @State private var isSaving  = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: typeIcon)
                    .font(.title2)
                    .foregroundColor(typeColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("New \(type.rawValue) Connection")
                        .font(.headline)
                    Text("Add connection details — configure registers or topics after saving.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
            }
            .padding()

            Divider()

            Form {
                Section("General") {
                    LabeledContent("Name") {
                        TextField("e.g. Plant Floor PLC", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Endpoint") {
                        TextField(endpointPlaceholder, text: $endpoint)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Adding…") }
                    } else {
                        Label("Add Connection", systemImage: "plus")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
        .frame(width: 400, height: 280)
    }

    private var typeIcon: String {
        switch type {
        case .opcua:      return "network"
        case .mqtt:       return "antenna.radiowaves.left.and.right"
        case .modbus:     return "cable.connector.horizontal"
        case .ethernetip: return "cpu.fill"
        }
    }

    private var typeColor: Color {
        switch type {
        case .opcua:      return .blue
        case .mqtt:       return .orange
        case .modbus:     return .purple
        case .ethernetip: return .green
        }
    }

    private var endpointPlaceholder: String {
        switch type {
        case .opcua:      return "opc.tcp://host:4840"
        case .mqtt:       return "broker.host:1883"
        case .modbus:     return "192.168.1.100:502"
        case .ethernetip: return "192.168.1.10  (port 44818)"
        }
    }

    private func save() async {
        isSaving = true
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let config = DriverConfig(
            type:     type,
            name:     trimmedName.isEmpty ? type.rawValue : trimmedName,
            endpoint: endpoint.trimmingCharacters(in: .whitespaces),
            enabled:  true
        )
        await onSave(config)
        isSaving = false
        dismiss()
    }
}
