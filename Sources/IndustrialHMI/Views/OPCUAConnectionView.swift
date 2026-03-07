// MARK: - OPCUAConnectionView.swift
//
// OPC-UA server discovery and connection management panel, shown in the Settings tab.
// Combines live status, diagnostics, automatic Bonjour discovery, endpoint enumeration,
// and direct URL connection in a single scrollable form.
//
// ── Sections ──────────────────────────────────────────────────────────────────
//   1. statusCard        — connection state chip (Disconnected/Connecting/Connected/Error)
//                          + server URL badge + Disconnect button
//   2. diagnosticsSection — OPCUADiagnostics panel: round-trip latency, poll cycle timing,
//                           missed polls counter; refreshed every 10 s while connected
//   3. bonjourSection    — OPCUABonjourScanner: lists all opc.tcp services found via
//                          mDNS on the local network; "Connect" button per result
//   4. discoverySection  — UA endpoint discovery: enter a URL → discover endpoints
//                          (security modes, auth policies); "Connect" button per endpoint
//   5. directConnectSection — text field for opc.tcp://host:4840 → "Connect" button
//   6. serverInfoSection — UA server info (product name, build version) shown when connected
//
// ── OPCUABonjourScanner ───────────────────────────────────────────────────────
//   @StateObject scans for _opcua-tcp._tcp.local. services via NetServiceBrowser.
//   Each found service: hostname, port, name. "Connect" builds opc.tcp://host:port URL.
//
// ── OPCUADiagnostics ──────────────────────────────────────────────────────────
//   @StateObject wraps OPCUAClientService polling metrics.
//   Displays: average latency (ms), max latency, poll rate (Hz), missed polls.
//   Refreshed every 10 s via an internal Timer when showDiagnostics = true.
//
// ── Connection Flow ───────────────────────────────────────────────────────────
//   All connect actions call opcuaService.connect(to: url) (async/await).
//   isConnecting and connectError drive UI feedback (progress + error label).
//   On success, dataService.startDataCollection() is NOT called automatically —
//   operator must use MonitorView's "Start" button.

import SwiftUI

// MARK: - OPCUAConnectionView

/// Full OPC-UA server discovery and connection management panel (Settings tab).
struct OPCUAConnectionView: View {
    @EnvironmentObject var opcuaService: OPCUAClientService
    @EnvironmentObject var dataService:  DataService

    // Bonjour scanner (mDNS — finds servers without knowing their hostname)
    @StateObject private var bonjour    = OPCUABonjourScanner()
    @StateObject private var diagnostics = OPCUADiagnostics()

    // Endpoint discovery (UA_Client_getEndpoints at a known URL)
    @State private var discoveryURL       = ""
    @State private var isDiscovering      = false
    @State private var discoveredEndpoints: [OPCUAEndpointInfo] = []
    @State private var discoveredServers:   [OPCUAServerInfo]   = []
    @State private var discoveryError:    String?

    // Direct connect
    @State private var directURL      = ""
    @State private var isConnecting   = false
    @State private var connectError:  String?

    // Diagnostics panel
    @State private var showDiagnostics = false
    @State private var diagURL         = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // ── 1. Live status card ──────────────────────────────────────
                statusCard

                Divider()

                // ── 2. Diagnostics ───────────────────────────────────────────
                diagnosticsSection

                Divider()

                // ── 3. mDNS / Bonjour scan ───────────────────────────────────
                bonjourSection

                Divider()

                // ── 4. Endpoint discovery (by URL) ───────────────────────────
                discoverySection

                if !discoveredEndpoints.isEmpty { endpointResultsSection }
                if discoveredEndpoints.isEmpty && !discoveredServers.isEmpty { serverResultsSection }

                Divider()

                // ── 5. Quick connect ─────────────────────────────────────────
                quickConnectSection
            }
            .padding(20)
        }
        .navigationTitle("OPC-UA Connection")
        .onAppear {
            let saved = Configuration.opcuaServerURL
            let defaultURL = saved.isEmpty ? "opc.tcp://localhost:4840" : saved
            directURL    = defaultURL
            discoveryURL = defaultURL
            diagURL      = defaultURL
        }
    }

    // MARK: - Diagnostics Section

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Connection Diagnostics", systemImage: "stethoscope")
                .font(.headline)

            Text("Step-by-step check: URL parsing → hostname resolution → TCP port test → OPC-UA endpoint probe.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                TextField("opc.tcp://host:4840", text: $diagURL)
                    .textFieldStyle(.roundedBorder)

                Button {
                    showDiagnostics = true
                    Task { await diagnostics.run(url: diagURL) }
                } label: {
                    if diagnostics.isRunning {
                        Label("Running…", systemImage: "waveform.path.ecg")
                    } else {
                        Label("Diagnose", systemImage: "stethoscope")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .disabled(diagURL.trimmingCharacters(in: .whitespaces).isEmpty || diagnostics.isRunning)
            }

            // Quick presets
            HStack(spacing: 6) {
                Text("Quick:").font(.caption2).foregroundColor(.secondary)
                ForEach(["localhost", "127.0.0.1", ProcessInfo.processInfo.hostName], id: \.self) { h in
                    Button(h) {
                        let url = "opc.tcp://\(h):4840"
                        diagURL      = url
                        directURL    = url
                        discoveryURL = url
                        showDiagnostics = true
                        Task { await diagnostics.run(url: url) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }

            if showDiagnostics && !diagnostics.steps.isEmpty {
                diagnosticsResults
            }
        }
    }

    private var diagnosticsResults: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(diagnostics.steps) { step in
                HStack(alignment: .top, spacing: 8) {
                    stepIcon(step.status)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title).font(.caption.bold())
                        Text(step.detail)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let sug = step.suggestion {
                            Text(sug)
                                .font(.caption)
                                .foregroundColor(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    if let ms = step.durationMs {
                        Text("\(ms) ms").font(.caption2).foregroundColor(.secondary)
                    }
                }
                .padding(8)
                .background(stepBackground(step.status))
                .cornerRadius(6)
            }

            if !diagnostics.suggestedURLs.isEmpty {
                Divider()
                Text("Suggested URLs to try:")
                    .font(.caption.bold())
                    .foregroundColor(.green)
                ForEach(diagnostics.suggestedURLs, id: \.self) { url in
                    HStack(spacing: 8) {
                        Text(url)
                            .font(.caption)
                            .textSelection(.enabled)
                        Spacer()
                        Button("Connect") { connectTo(url: url) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                            .tint(.green)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.06))
                    .cornerRadius(6)
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }

    @ViewBuilder
    private func stepIcon(_ status: DiagnosticStep.Status) -> some View {
        switch status {
        case .pass:    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .fail:    Image(systemName: "xmark.circle.fill").foregroundColor(.red)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
        case .running: ProgressView().controlSize(.mini)
        }
    }

    private func stepBackground(_ status: DiagnosticStep.Status) -> Color {
        switch status {
        case .pass:    return Color.green.opacity(0.05)
        case .fail:    return Color.red.opacity(0.05)
        case .warning: return Color.orange.opacity(0.05)
        case .running: return Color(nsColor: .controlBackgroundColor)
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
        case .disconnected: return Color.secondary
        }
    }

    // MARK: - Bonjour Section

    private var bonjourSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Scan Local Network (mDNS)", systemImage: "wifi.router")
                .font(.headline)

            Text("Automatically find OPC-UA servers on your local network — no hostname needed. Most industrial servers (Kepware, Prosys, open62541, UA Demo Server …) advertise via Bonjour.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                Button {
                    if bonjour.isScanning { bonjour.stopScan() }
                    else                  { bonjour.scan() }
                } label: {
                    if bonjour.isScanning {
                        Label("Scanning…", systemImage: "stop.circle")
                    } else {
                        Label("Scan Network", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(.borderedProminent)

                if bonjour.isScanning {
                    ProgressView().controlSize(.small)
                    Text("Listening for 6 s…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if bonjour.servers.isEmpty && !bonjour.isScanning
                && !directURL.isEmpty {
                // Subtle hint after a scan found nothing
            } else if !bonjour.servers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Found \(bonjour.servers.count) server\(bonjour.servers.count == 1 ? "" : "s") via mDNS")
                        .font(.subheadline.bold())
                    ForEach(bonjour.servers) { srv in
                        bonjourRow(srv)
                    }
                }
            } else if !bonjour.isScanning && bonjour.servers.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Text("No OPC-UA servers found via mDNS. Try entering the server IP/hostname manually below.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func bonjourRow(_ srv: OPCUABonjourServer) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(srv.name.isEmpty ? srv.host : srv.name)
                    .font(.body.bold())
                    .lineLimit(1)
                Text(srv.url)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }

            Spacer()

            Button("Probe") {
                discoveryURL = srv.url
                runDiscovery()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Query endpoints at this server")

            Button("Connect") {
                connectTo(url: srv.url)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isConnecting || opcuaService.connectionState == .connecting)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }

    // MARK: - Endpoint Discovery Section

    private var discoverySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Probe Server Endpoints", systemImage: "list.bullet.rectangle")
                .font(.headline)

            Text("Enter a URL to query the server's available endpoints and security modes.")
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
                        Label("Probe", systemImage: "magnifyingglass")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(discoveryURL.trimmingCharacters(in: .whitespaces).isEmpty || isDiscovering)
                .frame(minWidth: 80)
            }

            if let err = discoveryError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Endpoint Results

    private var endpointResultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Endpoints (\(discoveredEndpoints.count))")
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
            Image(systemName: ep.applicationType.systemIcon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(ep.serverName)
                        .font(.body.bold())
                        .lineLimit(1)
                    typeBadge(ep.applicationType)
                }
                Text(ep.endpointUrl)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
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

            Button("Connect") {
                connectTo(url: ep.endpointUrl)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isConnecting || opcuaService.connectionState == .connecting)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }

    // MARK: - Server Results (from findServers — no endpoints returned yet)

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
                            Text(url).font(.caption).foregroundColor(.secondary)
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

            Text("Type a URL and connect directly. The address is saved for auto-reconnect across restarts.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                TextField("opc.tcp://192.168.1.100:4840", text: $directURL)
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
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(8)
                .background(Color.red.opacity(0.06))
                .cornerRadius(6)
            }
        }
    }

    // MARK: - Badge / Icon helpers

    private func typeBadge(_ type: OPCUAApplicationType) -> some View {
        Text(type.rawValue)
            .font(.caption2.bold())
            .padding(.horizontal, 5).padding(.vertical, 2)
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
        isDiscovering   = true
        discoveryError  = nil
        discoveredEndpoints = []
        discoveredServers   = []
        Task {
            let (eps, srvs) = await opcuaService.discoverAt(url: url)
            isDiscovering = false
            discoveredEndpoints = eps
            discoveredServers   = srvs
            if eps.isEmpty && srvs.isEmpty {
                discoveryError = "No endpoints found at \(url). The server may be down or this URL may not support discovery. Try 'Scan Network' to find the server automatically."
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
                if opcuaService.connectionState == .connected {
                    opcuaService.startAutoReconnect()
                }
            } catch {
                connectError = error.localizedDescription
            }
            isConnecting = false
        }
    }
}
