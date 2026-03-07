// MARK: - AddEditPeerSheet.swift
//
// Modal sheet for adding or editing a Community Federation peer.
// Presented from CommunitySettingsView when the operator taps "+" or "Edit" on a peer row.
//
// ── Fields ────────────────────────────────────────────────────────────────────
//   name    — display name used as the site prefix on remote tags (e.g. "Plant-B")
//             Remote tags appear as "Plant-B/TankLevel" in the local tag table.
//   host    — IP address or hostname of the remote HMI instance
//   port    — TCP port for the community server (default 9001)
//   enabled — toggle; disables this peer connection without removing it
//
// ── Validation ────────────────────────────────────────────────────────────────
//   isValid = name non-empty && host non-empty && Int(port) != nil
//   Save button disabled while isValid = false.
//
// ── Save Flow ─────────────────────────────────────────────────────────────────
//   Add mode (existingPeer = nil):
//     Builds new CommunityPeer(id: UUID(), name:, host:, port:, enabled:)
//     Appended to communityService's draft config in CommunitySettingsView.
//   Edit mode (existingPeer != nil):
//     Builds CommunityPeer with same id as existingPeer (preserves identity).
//     Replaces the existing peer in the draft config by id.
//   In both cases: marks CommunitySettingsView.isDirty = true.
//   communityService.applyNewConfig() is called only on Save in CommunitySettingsView.

import SwiftUI

// MARK: - AddEditPeerSheet

/// Sheet for adding or editing a community peer.
struct AddEditPeerSheet: View {
    @EnvironmentObject var communityService: CommunityService
    @Environment(\.dismiss) private var dismiss

    /// nil = adding new peer; non-nil = editing existing
    var existingPeer: CommunityPeer?

    @State private var name:    String = ""
    @State private var host:    String = ""
    @State private var port:    String = "9001"
    @State private var enabled: Bool   = true

    private var isEditing: Bool { existingPeer != nil }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !host.trimmingCharacters(in: .whitespaces).isEmpty &&
        Int(port) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Title ─────────────────────────────────────────────────────
            Text(isEditing ? "Edit Peer" : "Add Peer")
                .font(.headline)
                .padding()

            Divider()

            // ── Form ──────────────────────────────────────────────────────
            Form {
                Section("Peer Identity") {
                    TextField("Display Name (used as site prefix)", text: $name)
                        .help("Remote tags will be displayed as Name/TagName")

                    TextField("Host (IP or hostname)", text: $host)
                        .help("IP address or hostname of the remote HMI instance")

                    HStack {
                        TextField("Port", text: $port)
                            .frame(width: 80)
                        Text("(default: 9001)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section("Options") {
                    Toggle("Enable this peer", isOn: $enabled)
                }
            }
            .formStyle(.grouped)

            Divider()

            // ── Buttons ───────────────────────────────────────────────────
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Button(isEditing ? "Save" : "Add") {
                    savePeer()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
                .keyboardShortcut(.return)
            }
            .padding()
        }
        .frame(width: 400)
        .onAppear {
            if let peer = existingPeer {
                name    = peer.name
                host    = peer.host
                port    = String(peer.port)
                enabled = peer.enabled
            }
        }
    }

    private func savePeer() {
        guard let portNum = Int(port) else { return }
        var peer = existingPeer ?? CommunityPeer(name: "", host: "")
        peer.name    = name.trimmingCharacters(in: .whitespaces)
        peer.host    = host.trimmingCharacters(in: .whitespaces)
        peer.port    = portNum
        peer.enabled = enabled
        communityService.addOrUpdatePeer(peer)
    }
}
