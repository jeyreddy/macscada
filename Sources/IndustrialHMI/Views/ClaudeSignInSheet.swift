// MARK: - ClaudeSignInSheet.swift
//
// Modal sheet for providing the Anthropic API key to the HMI AI Agent.
// Shown from AgentView and ChatbotPanel when agentService.hasAPIKey = false.
//
// ── Key Storage Options ───────────────────────────────────────────────────────
//   sessionOnly = false (default): writes the key to disk at:
//     ~/Library/Application Support/IndustrialHMI/.agentkey (mode 0600)
//     Persists across app restarts; read by AgentService.loadAPIKey() at startup.
//   sessionOnly = true: sets agentService.sessionKey (in-memory only)
//     Key discarded when app quits. Useful for shared kiosk machines.
//
// ── Layout ────────────────────────────────────────────────────────────────────
//   VStack (320 pt wide):
//     Header: CPU icon + "Connect to Claude" title + description
//     Form:
//       Secure text field for API key (eye toggle = isRevealed → plain TextField)
//       "Session only" checkbox + explanation text
//       Error label (shown on validation failure)
//     Footer: Cancel + "Connect" buttons
//
// ── Validation ────────────────────────────────────────────────────────────────
//   Key must start with "sk-ant-" (Anthropic API key prefix).
//   Empty key: errorMessage = "Please enter an API key."
//   Wrong prefix: errorMessage = "This doesn't look like an Anthropic API key."
//   On valid key: calls agentService.setAPIKey(key, sessionOnly: sessionOnly)
//   then dismiss().

import SwiftUI

// MARK: - ClaudeSignInSheet

/// Modal sheet for connecting the HMI Assistant to Claude.
/// Supports Keychain persistence (default) or session-only storage.
struct ClaudeSignInSheet: View {

    @EnvironmentObject var agentService: AgentService
    @Environment(\.dismiss) private var dismiss

    @State private var apiKey:       String = ""
    @State private var sessionOnly:  Bool   = false
    @State private var isRevealed:   Bool   = false
    @State private var errorMessage: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ────────────────────────────────────────────────────
            VStack(spacing: 8) {
                Image(systemName: "cpu.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.accentColor)
                    .padding(.bottom, 4)

                Text("Connect to Claude")
                    .font(.title2.bold())

                Text("Enter your Anthropic API key to enable the HMI Assistant.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 32)
            .padding(.horizontal, 32)
            .padding(.bottom, 24)

            Divider()

            // ── Form ──────────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 16) {

                // API Key field
                VStack(alignment: .leading, spacing: 6) {
                    Text("API Key")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)

                    HStack(spacing: 6) {
                        Group {
                            if isRevealed {
                                TextField("sk-ant-api03-…", text: $apiKey)
                            } else {
                                SecureField("sk-ant-api03-…", text: $apiKey)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))

                        Button {
                            isRevealed.toggle()
                        } label: {
                            Image(systemName: isRevealed ? "eye.slash" : "eye")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(isRevealed ? "Hide key" : "Show key")
                    }

                    Text("Your key starts with sk-ant-api03-. It is never sent anywhere except directly to api.anthropic.com.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Storage option
                VStack(alignment: .leading, spacing: 6) {
                    Text("Storage")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)

                    Picker("Storage", selection: $sessionOnly) {
                        Label("Remember on this Mac (Keychain)", systemImage: "lock.fill")
                            .tag(false)
                        Label("This session only (in-memory)", systemImage: "clock")
                            .tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }

                // Error
                if !errorMessage.isEmpty {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                }

                // Get API key link
                HStack {
                    Spacer()
                    Link("Get your API key at console.anthropic.com →",
                         destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                        .font(.caption)
                }
            }
            .padding(28)

            Divider()

            // ── Actions ───────────────────────────────────────────────────
            HStack(spacing: 12) {
                // Sign out / delete key (shown when a key already exists)
                if agentService.hasAPIKey {
                    Button("Disconnect", role: .destructive) {
                        agentService.deleteAPIKey()
                        dismiss()
                    }
                    .help("Remove the stored API key and disconnect from Claude")
                }

                Spacer()

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)

                Button("Connect") {
                    connect()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
        .frame(width: 460)
        .onAppear {
            // Pre-fill with current key if one exists (for updates)
            if let existing = agentService.loadAPIKey() {
                apiKey = existing
            }
        }
    }

    // MARK: - Connect action

    private func connect() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "API key cannot be empty."
            return
        }
        guard trimmed.hasPrefix("sk-ant-") else {
            errorMessage = "That doesn't look like an Anthropic API key (should start with sk-ant-)."
            return
        }
        errorMessage = ""
        agentService.saveAPIKey(trimmed, sessionOnly: sessionOnly)
        dismiss()
    }
}
