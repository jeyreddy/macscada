// MARK: - EtherNetIPSettingsView.swift
//
// Settings view for configuring the EtherNet/IP (CIP) protocol driver.
// Allows engineers to set the PLC endpoint and define CIP symbolic tag mappings.
//
// ── Layout ────────────────────────────────────────────────────────────────────
//   connectionSection — host IP/hostname, optional port override, poll interval, enabled toggle
//   tagMapSection     — table of EIPTagMap entries:
//                         columns: app tag name, CIP tag, data type, scale/offset
//                         row actions: delete
//                         "+" button → AddEIPTagMapSheet
//   actionBar         — Save Configuration + Test Connection buttons
//
// ── Load/Save ─────────────────────────────────────────────────────────────────
//   .task: loads DriverConfig and EIPTagMap rows from ConfigDatabase.
//   On save: upserts DriverConfig, saves all tag maps, calls reloadDriver.
//
// ── Role Guard ────────────────────────────────────────────────────────────────
//   Save + add/delete controls disabled unless sessionManager.canManageTags (engineer+).

import SwiftUI
import Network

// MARK: - EtherNetIPSettingsView

struct EtherNetIPSettingsView: View {
    @EnvironmentObject var dataService:    DataService
    @EnvironmentObject var tagEngine:      TagEngine
    @EnvironmentObject var sessionManager: SessionManager

    let configId: String?

    init(configId: String? = nil) { self.configId = configId }

    // Connection config
    @State private var driverConfigId: String = UUID().uuidString
    @State private var host:           String = ""
    @State private var port:           String = "44818"
    @State private var pollInterval:   String = "1.0"
    @State private var isEnabled:      Bool   = true

    // Tag maps
    @State private var tagMaps:        [EIPTagMap] = []
    @State private var showAddSheet:   Bool        = false

    // Async state
    @State private var isSaving:    Bool    = false
    @State private var saveError:   String? = nil
    @State private var saveSuccess: Bool    = false

    private var tagNames: [String] { tagEngine.getAllTags().map(\.name) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                connectionSection
                tagMapSection
                actionBar
            }
            .padding()
        }
        .task { await loadConfig() }
        .sheet(isPresented: $showAddSheet) {
            AddEIPTagMapSheet(tagNames: tagNames) { map in
                tagMaps.append(map)
            }
        }
    }

    // MARK: - Connection Section

    private var connectionSection: some View {
        GroupBox("EtherNet/IP Connection (CIP Explicit Messaging)") {
            Form {
                LabeledContent("Host / IP") {
                    TextField("192.168.1.10", text: $host)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .help("Allen-Bradley PLC IP address or hostname. Port 44818 is standard.")
                }
                LabeledContent("Port") {
                    TextField("44818", text: $port)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .help("Default EtherNet/IP TCP port is 44818.")
                }
                LabeledContent("Poll Interval (s)") {
                    TextField("1.0", text: $pollInterval)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .help("Seconds between full tag poll cycles.")
                }
                Toggle("Enabled", isOn: $isEnabled)
                    .help("Disable to prevent this driver from connecting on startup.")
            }
            .formStyle(.grouped)
            .disabled(!sessionManager.canManageTags)
        }
    }

    // MARK: - Tag Map Section

    private var tagMapSection: some View {
        GroupBox("CIP Tag Mappings") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Map Allen-Bradley PLC tags to app tag names.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    if sessionManager.canManageTags {
                        Button {
                            showAddSheet = true
                        } label: {
                            Label("Add Tag", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if tagMaps.isEmpty {
                    Text("No tag mappings — add CIP symbolic tags above.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 8)
                } else {
                    // Header row
                    HStack(spacing: 0) {
                        Text("App Tag").font(.caption2).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("CIP Tag").font(.caption2).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Type").font(.caption2).foregroundColor(.secondary)
                            .frame(width: 60, alignment: .leading)
                        Text("Scale").font(.caption2).foregroundColor(.secondary)
                            .frame(width: 50, alignment: .trailing)
                    }
                    .padding(.horizontal, 4)

                    Divider()

                    ForEach(tagMaps) { map in
                        HStack(spacing: 0) {
                            Text(map.tagName)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(1)
                            Text(map.cipTag)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(1)
                                .foregroundColor(.blue)
                            Text(map.dataType.rawValue)
                                .font(.caption2)
                                .frame(width: 60, alignment: .leading)
                                .foregroundColor(.secondary)
                            Text(map.scale == 1.0 && map.offset == 0.0
                                 ? "1:1"
                                 : "×\(String(format: "%.2f", map.scale))")
                                .font(.caption2)
                                .frame(width: 50, alignment: .trailing)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 3)
                        .contextMenu {
                            if sessionManager.canManageTags {
                                Button(role: .destructive) {
                                    tagMaps.removeAll { $0.id == map.id }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        Divider()
                    }
                }
            }
            .padding(6)
        }
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack {
            if let err = saveError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
            }
            if saveSuccess {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
            }
            Spacer()
            Button {
                Task { await testConnection() }
            } label: {
                Label("Test", systemImage: "network.badge.shield.half.filled")
            }
            .buttonStyle(.bordered)
            .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || !sessionManager.canManageTags)

            Button {
                Task { await saveConfig() }
            } label: {
                if isSaving {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Saving…") }
                } else {
                    Label("Save Configuration", systemImage: "square.and.arrow.down")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!sessionManager.canManageTags || isSaving)
            .keyboardShortcut("s", modifiers: .command)
        }
    }

    // MARK: - Load / Save

    private func loadConfig() async {
        let allConfigs = (try? await dataService.configDatabase.fetchAll()) ?? []
        let cfg = allConfigs.first(where: { c in
            configId != nil ? c.id == configId : c.type == .ethernetip
        })
        guard let cfg else { return }

        driverConfigId = cfg.id
        let parts      = cfg.endpoint.split(separator: ":", maxSplits: 1)
        host           = String(parts.first ?? "")
        port           = parts.count > 1 ? String(parts[1]) : "44818"
        pollInterval   = cfg.parameters["pollInterval"] ?? "1.0"
        isEnabled      = cfg.enabled
        tagMaps        = (try? await dataService.configDatabase.fetchEIPTagMaps(
                            forDriverId: driverConfigId)) ?? []
    }

    private func saveConfig() async {
        isSaving    = true
        saveError   = nil
        saveSuccess = false

        let hostTrimmed = host.trimmingCharacters(in: .whitespaces)
        let portStr     = port.trimmingCharacters(in: .whitespaces)
        let endpoint    = portStr.isEmpty || portStr == "44818" ? hostTrimmed : "\(hostTrimmed):\(portStr)"

        let cfg = DriverConfig(
            id:         driverConfigId,
            type:       .ethernetip,
            name:       "EtherNet/IP",
            endpoint:   endpoint,
            enabled:    isEnabled,
            parameters: ["pollInterval": pollInterval.trimmingCharacters(in: .whitespaces)]
        )

        do {
            try await dataService.configDatabase.save(cfg)
            // Delete and re-save all tag maps (simplest upsert strategy)
            try await dataService.configDatabase.deleteEIPTagMaps(forDriverId: driverConfigId)
            for map in tagMaps {
                try await dataService.configDatabase.saveEIPTagMap(map, forDriverId: driverConfigId)
            }
            await dataService.reloadDriver(ofType: .ethernetip)
            saveSuccess = true
        } catch {
            saveError = error.localizedDescription
        }
        isSaving = false
    }

    private func testConnection() async {
        // Quick TCP port 44818 reachability check using NWConnection
        let hostTrimmed = host.trimmingCharacters(in: .whitespaces)
        guard !hostTrimmed.isEmpty else { return }
        saveError   = nil
        saveSuccess = false

        let portVal = UInt16(port.trimmingCharacters(in: .whitespaces)) ?? 44818
        let conn    = NWConnection(
            host: NWEndpoint.Host(hostTrimmed),
            port: NWEndpoint.Port(integerLiteral: portVal),
            using: .tcp
        )
        let queue = DispatchQueue(label: "enip.test")
        let result: String = await withCheckedContinuation { cont in
            var resumed = false
            conn.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    conn.cancel()
                    cont.resume(returning: "Connected to \(hostTrimmed):\(portVal)")
                case .failed(let err):
                    resumed = true
                    cont.resume(returning: "Failed: \(err.localizedDescription)")
                case .cancelled:
                    if !resumed { resumed = true; cont.resume(returning: "Cancelled") }
                default: break
                }
            }
            conn.start(queue: queue)
            // Timeout after 3 seconds
            queue.asyncAfter(deadline: .now() + 3) {
                guard !resumed else { return }
                resumed = true
                conn.cancel()
                cont.resume(returning: "Timeout — no response from \(hostTrimmed):\(portVal)")
            }
        }

        if result.hasPrefix("Connected") {
            saveSuccess = true
        } else {
            saveError = result
        }
    }
}

// MARK: - AddEIPTagMapSheet

struct AddEIPTagMapSheet: View {
    let tagNames: [String]
    let onAdd:    (EIPTagMap) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var cipTag:   String      = ""
    @State private var tagName:  String      = ""
    @State private var dataType: EIPDataType = .real
    @State private var scale:    String      = "1.0"
    @State private var offset:   String      = "0.0"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "cpu.fill").foregroundColor(.green)
                Text("Add CIP Tag Mapping").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundColor(.secondary)
            }
            .padding()

            Divider()

            Form {
                Section("PLC Tag") {
                    LabeledContent("CIP Tag Name") {
                        TextField("Motor_Speed  or  Program:Main.Flow_PV", text: $cipTag)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                    Picker("Data Type", selection: $dataType) {
                        ForEach(EIPDataType.allCases, id: \.self) { dt in
                            Text(dt.rawValue).tag(dt)
                        }
                    }
                }
                Section("App Mapping") {
                    LabeledContent("App Tag Name") {
                        if tagNames.isEmpty {
                            TextField("Tag name (will create new)", text: $tagName)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            Picker("", selection: $tagName) {
                                Text("— enter manually —").tag("")
                                ForEach(tagNames, id: \.self) { n in Text(n).tag(n) }
                            }
                            if tagName.isEmpty {
                                TextField("Enter tag name", text: $tagName)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                    LabeledContent("Scale") {
                        TextField("1.0", text: $scale).textFieldStyle(.roundedBorder).frame(width: 80)
                    }
                    LabeledContent("Offset") {
                        TextField("0.0", text: $offset).textFieldStyle(.roundedBorder).frame(width: 80)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button {
                    let map = EIPTagMap(
                        tagName:  tagName.trimmingCharacters(in: .whitespaces),
                        cipTag:   cipTag.trimmingCharacters(in: .whitespaces),
                        dataType: dataType,
                        scale:    Double(scale) ?? 1.0,
                        offset:   Double(offset) ?? 0.0
                    )
                    onAdd(map)
                    dismiss()
                } label: {
                    Label("Add Tag Map", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(cipTag.trimmingCharacters(in: .whitespaces).isEmpty
                          || tagName.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
        .frame(width: 480, height: 440)
    }
}
