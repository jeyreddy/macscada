import SwiftUI

// MARK: - OPCUAConnectionView

/// Full OPC-UA server discovery and connection management panel.
/// Shown in the Settings tab.
struct OPCUAConnectionView: View {
    @EnvironmentObject var opcuaService: OPCUAClientService
    @EnvironmentObject var dataService:  DataService

    // Discovery
    @State private var discoveryURL:  String = Configuration.opcuaServerURL.isEmpty
                                               ? "opc.tcp://localhost:4840"
                                               : Configuration.opcuaServerURL
    @State private var isDiscovering: Bool   = false
    @State private var discoveredEndpoints:  [OPCUAEndpointInfo]  = []
    @State private var discoveredServers:    [OPCUAServerInfo]     = []
    @State private var discoveryError:       String?

    // Direct connect
    @State private var directURL:  String = Configuration.opcuaServerURL
    @State private var isConnecting: Bool = false
    @State private var connectError:  String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // ── Status card ─────────────────────────────────────────────
                statusCard

                Divider()

                // ── Discovery section ────────────────────────────────────────
                discoverySection

                // ── Results ──────────────────────────────────────────────────
                if !discoveredEndpoints.isEmpty {
                    endpointResultsSection
                }

                if !discoveredServers.isEmpty && discoveredEndpoints.isEmpty {
                    serverResultsSection
                }

                Divider()

                // ── Quick connect ────────────────────────────────────────────
                quickConnectSection
            }
            .padding(20)
        }
        .navigationTitle("OPC-UA Connection")
        .onAppear {
            // Sync text fields with current saved URL
            if !Configuration.opcuaServerURL.isEmpty {
                directURL    = Configuration.opcuaServerURL
                discoveryURL = Configuration.opcuaServerURL
            }
        }
    }

    // MARK: - Status Card

    private var statusCard: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(statusColor)
                .frame(width: 12, height: 12)
                .shadow(color: statusColor.opacity(0.5), radius: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(opcuaService.connectionState.rawValue)
                    .font(.headline)
                if !opcuaService.serverURL.isEmpty {
                    Text(opcuaService.serverURL)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }

            Spacer()

            if opcuaService.connectionState == .connected {
                Button("Disconnect") {
                    Task { await dataService.stopDataCollection() }
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
        }
        .padding(14)
        .background(statusColor.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(statusColor.opacity(0.3), lineWidth: 1))
        .cornerRadius(10)
    }

    private var statusColor: Color {
        switch opcuaService.connectionState {
        case .connected:    return .green
        case .connecting:   return .orange
        case .error:        return .red
        case .disconnected: return .secondary
        }
    }

    // MARK: - Discovery Section

    private var discoverySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Server Discovery", systemImage: "network.badge.shield.half.filled")
                .font(.headline)

            Text("Enter a server or discovery-server URL to browse available endpoints and server types.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                TextField("opc.tcp://host:4840", text: $discoveryURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runDiscovery() }

                Button {
                    runDiscovery()
                } label: {
                    if isDiscovering {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Discover", systemImage: "magnifyingglass")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(discoveryURL.trimmingCharacters(in: .whitespaces).isEmpty || isDiscovering)
                .frame(minWidth: 90)
            }

            if let err = discoveryError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Endpoint Results

    private var endpointResultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Found \(discoveredEndpoints.count) endpoint\(discoveredEndpoints.count == 1 ? "" : "s")")
                    .font(.subheadline.bold())
                Spacer()
                Button("Clear") {
                    discoveredEndpoints = []
                    discoveredServers   = []
                    discoveryError      = nil
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .font(.caption)
            }

            ForEach(discoveredEndpoints) { ep in
                endpointRow(ep)
            }
        }
    }

    private func endpointRow(_ ep: OPCUAEndpointInfo) -> some View {
        HStack(spacing: 12) {
            // Server type icon
            Image(systemName: ep.applicationType.systemIcon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                // Server name + type badge
                HStack(spacing: 6) {
                    Text(ep.serverName)
                        .font(.body.bold())
                        .lineLimit(1)
                    typeBadge(ep.applicationType)
                }
                // Endpoint URL
                Text(ep.endpointUrl)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                // Security badge
                HStack(spacing: 4) {
                    Image(systemName: securityIcon(ep.securityMode))
                        .font(.caption2)
                        .foregroundColor(securityColor(ep.securityMode))
                    Text(ep.securityMode.rawValue)
                        .font(.caption2)
                        .foregroundColor(securityColor(ep.securityMode))
                    if ep.securityPolicyName != "None" && !ep.securityPolicyName.isEmpty {
                        Text("· \(ep.securityPolicyName)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Connect to this endpoint
            Button("Connect") {
                connectTo(url: ep.endpointUrl)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isConnecting || opcuaService.connectionState == .connecting)
            .controlSize(.small)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }

    // MARK: - Server (ApplicationDescription) Results

    private var serverResultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Registered Servers (\(discoveredServers.count))")
                .font(.subheadline.bold())

            ForEach(discoveredServers) { srv in
                HStack(spacing: 12) {
                    Image(systemName: srv.applicationType.systemIcon)
                        .font(.title3)
                        .foregroundColor(.accentColor)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(srv.applicationName).font(.body.bold()).lineLimit(1)
                            typeBadge(srv.applicationType)
                        }
                        ForEach(srv.discoveryUrls, id: \.self) { url in
                            Text(url).font(.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    if let url = srv.discoveryUrls.first {
                        Button("Probe") {
                            discoveryURL = url
                            runDiscovery()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
            }
        }
    }

    // MARK: - Quick Connect

    private var quickConnectSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Direct Connection", systemImage: "link")
                .font(.headline)

            Text("Type a server URL directly and connect without scanning.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                TextField("opc.tcp://host:4840", text: $directURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { connectTo(url: directURL) }

                Button {
                    connectTo(url: directURL)
                } label: {
                    if isConnecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Connect", systemImage: "bolt.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(directURL.trimmingCharacters(in: .whitespaces).isEmpty
                          || isConnecting
                          || opcuaService.connectionState == .connecting)
                .frame(minWidth: 90)
            }

            if let err = connectError {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        }
    }

    // MARK: - Badge helpers

    private func typeBadge(_ type: OPCUAApplicationType) -> some View {
        Text(type.rawValue)
            .font(.caption2.bold())
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(badgeColor(type).opacity(0.15))
            .foregroundColor(badgeColor(type))
            .cornerRadius(4)
    }

    private func badgeColor(_ type: OPCUAApplicationType) -> Color {
        switch type {
        case .server:          return .blue
        case .discoveryServer: return .purple
        case .clientAndServer: return .cyan
        default:               return .secondary
        }
    }

    private func securityColor(_ mode: OPCUASecurityMode) -> Color {
        switch mode {
        case .none:          return .orange
        case .sign:          return .blue
        case .signAndEncrypt: return .green
        case .invalid:       return .red
        }
    }

    private func securityIcon(_ mode: OPCUASecurityMode) -> String {
        switch mode {
        case .none:          return "lock.open"
        case .sign:          return "signature"
        case .signAndEncrypt: return "lock.shield.fill"
        case .invalid:       return "exclamationmark.shield"
        }
    }

    // MARK: - Actions

    private func runDiscovery() {
        let url = discoveryURL.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        isDiscovering = true
        discoveryError = nil
        discoveredEndpoints = []
        discoveredServers   = []

        Task {
            let (eps, srvs) = await opcuaService.discoverAt(url: url)
            isDiscovering = false
            discoveredEndpoints = eps
            discoveredServers   = srvs
            if eps.isEmpty && srvs.isEmpty {
                discoveryError = "No endpoints or servers found at \(url). Check the URL and ensure the server is running."
            }
        }
    }

    private func connectTo(url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isConnecting = true
        connectError = nil

        Task {
            do {
                try await opcuaService.connect(to: trimmed)
                // After successful connect, kick off polling and reconnect loop
                if opcuaService.connectionState == .connected {
                    opcuaService.startAutoReconnect()
                    try? await opcuaService.subscribe(to: [], callback: { _, _, _, _ in })
                }
            } catch {
                connectError = error.localizedDescription
            }
            isConnecting = false
        }
    }
}
