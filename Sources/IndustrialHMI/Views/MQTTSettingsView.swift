// MARK: - MQTTSettingsView.swift
//
// Settings view for configuring the MQTT protocol driver.
// Lets engineers define the broker connection and topic-to-tag mappings.
//
// ── Layout (ScrollView) ───────────────────────────────────────────────────────
//   connectionSection  — broker host + port, client ID, username + password,
//                        keepalive seconds, enabled toggle
//                        Live connection status badge (isConnected from MQTTDriver)
//   subscriptionSection — table of MQTTSubscription entries:
//                         columns: topic, tag name, jsonPath (optional)
//                         row actions: edit (AddEditMQTTSubscriptionSheet), delete
//                         "+" button → AddEditMQTTSubscriptionSheet (add mode)
//   actionBar          — "Save Configuration" → saves DriverConfig + subscriptions
//                         to ConfigDatabase; "Reconnect" → dataService.reconnectMQTTDriver()
//
// ── Load/Save ─────────────────────────────────────────────────────────────────
//   .task: loads existing DriverConfig (type == .mqtt) from ConfigDatabase.
//   Parses endpoint "host:port" and parameters into @State fields.
//   On save: builds DriverConfig.endpoint = "host:port" and parameters dict.
//   Upserts to ConfigDatabase.saveDriverConfig() + saveMQTTSubscriptions().
//   Calls dataService.reconnectMQTTDriver() to apply live.
//
// ── Subscription Edit ─────────────────────────────────────────────────────────
//   AddEditMQTTSubscriptionSheet: topic field (with wildcard info tooltip),
//   tagName picker from tagEngine.getAllTags(), optional jsonPath field.
//   editingSubscription drives the sheet (nil = add, non-nil = edit).
//
// ── JSON Path ─────────────────────────────────────────────────────────────────
//   jsonPath: dot-separated string (e.g. "sensors.temperature.value").
//   MQTTDriver uses this to extract a numeric value from structured JSON payloads.
//   Nil = treat entire payload as a numeric string.
//
// ── Role Guard ────────────────────────────────────────────────────────────────
//   Save + add/delete controls disabled unless sessionManager.canManageTags (engineer+).

import SwiftUI

// MARK: - MQTTSettingsView

struct MQTTSettingsView: View {
    @EnvironmentObject var dataService:    DataService
    @EnvironmentObject var tagEngine:      TagEngine
    @EnvironmentObject var sessionManager: SessionManager

    /// When set, this view manages a specific driver config instead of the first one.
    let configId: String?

    init(configId: String? = nil) { self.configId = configId }

    // ── Broker config state ──────────────────────────────────────────────────
    @State private var driverConfigId: String = UUID().uuidString  // preserved across saves
    @State private var brokerHost:       String = ""
    @State private var brokerPort:       String = "1883"
    @State private var clientId:         String = ""
    @State private var username:         String = ""
    @State private var password:         String = ""
    @State private var keepaliveSeconds: String = "60"
    @State private var isEnabled:        Bool   = true

    // ── Subscription list state ──────────────────────────────────────────────
    @State private var subscriptions:       [MQTTSubscription] = []
    @State private var editingSubscription: MQTTSubscription?  = nil
    @State private var showAddSubscription: Bool               = false

    // ── Async operation state ────────────────────────────────────────────────
    @State private var isSaving:    Bool    = false
    @State private var saveError:   String? = nil
    @State private var saveSuccess: Bool    = false

    // ── Derived ─────────────────────────────────────────────────────────────
    private var tagNames: [String] { tagEngine.getAllTags().map(\.name) }
    private var mqttDriver: MQTTDriver? {
        if let id = configId { return dataService.driver(configId: id) as? MQTTDriver }
        return dataService.driver(ofType: .mqtt) as? MQTTDriver
    }
    private var isConnected: Bool { mqttDriver?.isConnected ?? false }
    private var canSave: Bool {
        !isSaving && !brokerHost.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusCard
                Divider()
                brokerConfigSection
                Divider()
                subscriptionsSection
                Divider()
                saveReconnectSection
            }
            .padding(20)
        }
        .navigationTitle("MQTT")
        .task { await loadConfig() }
        .sheet(isPresented: $showAddSubscription) {
            AddEditMQTTSubscriptionSheet(
                subscription: nil,
                tagNames:     tagNames
            ) { newSub in
                subscriptions.append(newSub)
            }
        }
        .sheet(item: $editingSubscription) { sub in
            AddEditMQTTSubscriptionSheet(
                subscription: sub,
                tagNames:     tagNames
            ) { updated in
                if let idx = subscriptions.firstIndex(where: { $0.id == updated.id }) {
                    subscriptions[idx] = updated
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
                if !brokerHost.isEmpty {
                    Text("\(brokerHost):\(brokerPort.isEmpty ? "1883" : brokerPort)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("No broker configured")
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

    private var brokerConfigSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Broker Connection", systemImage: "server.rack")
                .font(.headline)

            Form {
                Section("Endpoint") {
                    HStack(spacing: 8) {
                        TextField("Host or IP address", text: $brokerHost)
                            .textFieldStyle(.roundedBorder)
                        Text(":")
                            .foregroundColor(.secondary)
                        TextField("1883", text: $brokerPort)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section("Authentication") {
                    TextField("Client ID (blank to auto-generate)", text: $clientId)
                    TextField("Username", text: $username)
                    SecureField("Password", text: $password)
                }

                Section("Options") {
                    HStack {
                        Text("Keepalive (seconds)")
                        Spacer()
                        TextField("60", text: $keepaliveSeconds)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                    }
                    Toggle("Enable this driver", isOn: $isEnabled)
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 280)
        }
    }

    private var subscriptionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Topic Subscriptions", systemImage: "list.bullet.rectangle")
                    .font(.headline)
                Spacer()
                Button {
                    showAddSubscription = true
                } label: {
                    Label("Add", systemImage: "plus.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text("Each subscription maps an MQTT topic to a process tag. Use + for single-level and # for multi-level wildcards.")
                .font(.caption)
                .foregroundColor(.secondary)

            if subscriptions.isEmpty {
                ContentUnavailableView(
                    "No Subscriptions",
                    systemImage: "rectangle.on.rectangle.slash",
                    description: Text("Add a topic subscription to receive MQTT data.")
                )
                .frame(minHeight: 100)
            } else {
                List {
                    ForEach(subscriptions) { sub in
                        subscriptionRow(sub)
                    }
                    .onDelete { offsets in
                        subscriptions.remove(atOffsets: offsets)
                    }
                }
                .listStyle(.bordered)
                .frame(minHeight: 120, maxHeight: 320)
            }
        }
    }

    private func subscriptionRow(_ sub: MQTTSubscription) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(sub.topic)
                    .font(.body.bold())
                HStack(spacing: 4) {
                    Text("Tag:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(sub.tagName)
                        .font(.caption)
                        .foregroundColor(.accentColor)
                    if let path = sub.jsonPath, !path.isEmpty {
                        Text("· JSON: \(path)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
            Button("Edit") { editingSubscription = sub }
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
                    Text("Configuration saved and MQTT driver reconnected.")
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
                configs = try await dataService.configDatabase.fetch(type: .mqtt)
            }
            if let cfg = configs.first {
                driverConfigId = cfg.id
                isEnabled      = cfg.enabled
                // Parse "host:port"
                let ep = cfg.endpoint
                if let colonIdx = ep.lastIndex(of: ":") {
                    brokerHost = String(ep[ep.startIndex..<colonIdx])
                    brokerPort = String(ep[ep.index(after: colonIdx)...])
                } else {
                    brokerHost = ep
                    brokerPort = "1883"
                }
                clientId         = cfg.parameters["clientId"]         ?? ""
                username         = cfg.parameters["username"]         ?? ""
                password         = cfg.parameters["password"]         ?? ""
                keepaliveSeconds = cfg.parameters["keepaliveSeconds"] ?? "60"
            }
            if let id = configId {
                subscriptions = try await dataService.configDatabase.fetchMQTTSubscriptions(forDriverId: id)
            } else {
                subscriptions = try await dataService.configDatabase.fetchMQTTSubscriptions()
            }
            diagLog("DIAG [MQTTSettingsView] loaded \(subscriptions.count) subscription(s)")
        } catch {
            saveError = "Failed to load config: \(error.localizedDescription)"
            Logger.shared.error("MQTTSettingsView loadConfig: \(error.localizedDescription)")
        }
    }

    // MARK: - Save & Reconnect

    private func saveAndReconnect() async {
        guard canSave else { return }
        isSaving    = true
        saveError   = nil
        saveSuccess = false

        do {
            // Build endpoint and parameters
            let port     = brokerPort.trimmingCharacters(in: .whitespaces).isEmpty ? "1883" : brokerPort
            let endpoint = brokerHost.trimmingCharacters(in: .whitespaces) + ":" + port
            var params: [String: String] = [:]
            let ka = keepaliveSeconds.trimmingCharacters(in: .whitespaces)
            if !clientId.trimmingCharacters(in: .whitespaces).isEmpty { params["clientId"] = clientId.trimmingCharacters(in: .whitespaces) }
            if !username.trimmingCharacters(in: .whitespaces).isEmpty  { params["username"] = username.trimmingCharacters(in: .whitespaces) }
            if !password.isEmpty                                        { params["password"] = password }
            if !ka.isEmpty                                              { params["keepaliveSeconds"] = ka }

            // Save driver config
            let updated = DriverConfig(
                id:         driverConfigId,
                type:       .mqtt,
                name:       "MQTT Broker",
                endpoint:   endpoint,
                enabled:    isEnabled,
                parameters: params,
                createdAt:  Date(),
                updatedAt:  Date()
            )
            try await dataService.configDatabase.save(updated)

            // Replace subscriptions (delete-then-insert)
            if let id = configId {
                try await dataService.configDatabase.deleteMQTTSubscriptions(forDriverId: id)
                for sub in subscriptions {
                    try await dataService.configDatabase.saveMQTTSubscription(sub, forDriverId: id)
                }
            } else {
                let existing = try await dataService.configDatabase.fetchMQTTSubscriptions()
                for sub in existing { try await dataService.configDatabase.deleteMQTTSubscription(id: sub.id) }
                for sub in subscriptions { try await dataService.configDatabase.saveMQTTSubscription(sub) }
            }

            diagLog("DIAG [MQTTSettingsView] saved \(subscriptions.count) sub(s), reconnecting…")
            if let id = configId {
                await dataService.reloadDriver(configId: id)
            } else {
                await dataService.reloadDriver(ofType: .mqtt)
            }

            saveSuccess = true
            Logger.shared.info("MQTTSettingsView: config saved and driver reloaded")
        } catch {
            saveError = error.localizedDescription
            Logger.shared.error("MQTTSettingsView saveAndReconnect: \(error.localizedDescription)")
        }

        isSaving = false
    }
}
