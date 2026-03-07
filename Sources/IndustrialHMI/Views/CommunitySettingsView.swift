// MARK: - CommunitySettingsView.swift
//
// Settings view for the Community Federation feature — configures this instance's
// identity, listen port, shared secret, and outbound peer connections.
//
// ── Layout (ScrollView) ───────────────────────────────────────────────────────
//   "This Instance" GroupBox:
//     siteName        — unique name used as tag prefix by remote peers
//     listenPort      — TCP port for inbound peer connections (default 9001)
//     sharedSecret    — HMAC key for authenticating incoming connections
//     enabled toggle  — master switch; stops/starts server + peers on change
//   "Peers" GroupBox:
//     List of CommunityPeer rows with PeerConnectionStatus indicators
//       (disconnected, connecting, connected, rejected) shown as colored dots
//     Context menu per peer: Edit, Remove, Reconnect
//     "+" button → AddEditPeerSheet
//   Save button — calls communityService.applyNewConfig(draftConfig)
//
// ── draftConfig vs live config ────────────────────────────────────────────────
//   draftConfig: CommunityConfig @State — local edit copy
//   isDirty: Bool — true when draftConfig differs from communityService.config
//   "Save" button only enabled when isDirty = true
//   On save: communityService.applyNewConfig() stops all connections, applies config,
//   restarts if enabled. Persists to UserDefaults["communityConfig"].
//
// ── Peer Status Display ───────────────────────────────────────────────────────
//   communityService.peerStatuses: [UUID: PeerConnectionStatus]
//   Row for each peer shows: name, host:port, status dot, lastError text if rejected.
//   Status dot colors: gray=disconnected, yellow=connecting, green=connected, red=rejected.
//
// ── AddEditPeerSheet ──────────────────────────────────────────────────────────
//   Fields: peer name (displayed as SiteName prefix), host, port, enabled toggle.
//   Adds or updates the peer in draftConfig.peers; marks isDirty.

import SwiftUI

// MARK: - CommunitySettingsView

/// Settings view for the Community Federation feature.
/// Shows this-instance configuration and the peer list with live status.
struct CommunitySettingsView: View {
    @EnvironmentObject var communityService: CommunityService

    @State private var draftConfig:  CommunityConfig = CommunityConfig()
    @State private var showAddPeer:  Bool = false
    @State private var editingPeer:  CommunityPeer? = nil
    @State private var removingPeer: CommunityPeer? = nil
    @State private var isDirty:      Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // ── This Instance ─────────────────────────────────────────
                GroupBox("This Instance") {
                    VStack(alignment: .leading, spacing: 10) {
                        // Site Name
                        LabeledContent("Site Name") {
                            TextField("e.g. Plant-A", text: $draftConfig.siteName)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: .infinity)
                                .onChange(of: draftConfig.siteName) { _, _ in isDirty = true }
                        }
                        .help("Unique name for this HMI instance (used as tag prefix by peers)")

                        Divider()

                        // Listen Port
                        LabeledContent("Listen Port") {
                            TextField("Port", value: $draftConfig.listenPort, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 100)
                                .onChange(of: draftConfig.listenPort) { _, _ in isDirty = true }
                        }

                        Divider()

                        // Shared Secret
                        LabeledContent("Community Secret") {
                            SecureField("Shared secret", text: $draftConfig.secret)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: .infinity)
                                .onChange(of: draftConfig.secret) { _, _ in isDirty = true }
                        }
                        .help("All instances in the community must use the same secret")

                        Divider()

                        // Enable toggle
                        Toggle("Enable Community Federation", isOn: $draftConfig.enabled)
                            .onChange(of: draftConfig.enabled) { _, _ in isDirty = true }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                }

                // ── Save Button ────────────────────────────────────────────
                if isDirty {
                    HStack {
                        Spacer()
                        Button("Save Changes") {
                            communityService.updateConfig(draftConfig)
                            isDirty = false
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                // ── Peers ─────────────────────────────────────────────────
                GroupBox {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("Peers")
                                .font(.headline)
                            Spacer()
                            Button {
                                editingPeer = nil
                                showAddPeer = true
                            } label: {
                                Image(systemName: "plus")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Add peer")
                        }
                        .padding(.bottom, 8)

                        if draftConfig.peers.isEmpty {
                            Text("No peers configured. Add a peer to connect to another HMI instance.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(draftConfig.peers) { peer in
                                peerRow(peer)
                                if peer.id != draftConfig.peers.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                    .padding(4)
                }

                Spacer()
            }
            .padding()
        }
        .navigationTitle("Community")
        .onAppear { draftConfig = communityService.config }
        .sheet(isPresented: $showAddPeer) {
            AddEditPeerSheet(existingPeer: editingPeer)
                .environmentObject(communityService)
                .onDisappear { draftConfig = communityService.config }
        }
        .confirmationDialog(
            "Remove Peer?",
            isPresented: Binding(
                get:  { removingPeer != nil },
                set:  { if !$0 { removingPeer = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let peer = removingPeer {
                    communityService.removePeer(id: peer.id)
                    draftConfig = communityService.config
                }
                removingPeer = nil
            }
            Button("Cancel", role: .cancel) { removingPeer = nil }
        } message: {
            Text("\"\(removingPeer?.name ?? "this peer")\" will be removed.")
        }
    }

    // MARK: - Peer Row

    private func peerRow(_ peer: CommunityPeer) -> some View {
        HStack(spacing: 10) {
            // Status badge
            statusBadge(for: peer)

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.name)
                    .font(.caption.bold())
                    .lineLimit(1)
                Text("\(peer.host):\(peer.port)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if let err = communityService.peerStatuses[peer.id]?.lastError {
                    Text(err)
                        .font(.caption2)
                        .foregroundColor(.red)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Actions
            Button {
                editingPeer = peer
                showAddPeer = true
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .help("Edit peer")

            Button {
                removingPeer = peer
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundColor(.red)
            .help("Remove peer")
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func statusBadge(for peer: CommunityPeer) -> some View {
        let status = communityService.peerStatuses[peer.id]?.status ?? .disconnected
        Circle()
            .fill(statusColor(status))
            .frame(width: 10, height: 10)
            .help(status.rawValue)
    }

    private func statusColor(_ status: PeerStatus) -> Color {
        switch status {
        case .disconnected: return .gray
        case .connecting:   return .yellow
        case .connected:    return .green
        case .rejected:     return .red
        }
    }
}
