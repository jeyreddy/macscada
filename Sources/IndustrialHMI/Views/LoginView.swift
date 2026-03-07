// MARK: - LoginView.swift
//
// Full-screen login overlay blocking all HMI access until an operator authenticates.
// Shown as a ZStack overlay in MainView when !sessionManager.isLoggedIn.
//
// ── Security ──────────────────────────────────────────────────────────────────
//   Blocks all underlying UI via Color.black.opacity(0.5) + ignoresSafeArea().
//   Authentication: sessionManager.login(username:password:) → SHA-256 hash check.
//   On failure: shows "Invalid credentials" error text below the form.
//   On success: MainView's ZStack reveals the full UI.
//
// ── Layout ────────────────────────────────────────────────────────────────────
//   Centered card (320 pt wide) with:
//     Header: lock shield icon + "Industrial HMI" title + "Sign in to continue"
//     Form: Username TextField + SecureField for password
//     Error label (red, shown on authentication failure)
//     Sign In button (primary action)
//   @FocusState auto-advances: username → password on Return; password → login on Return.
//
// ── Default Credentials ───────────────────────────────────────────────────────
//   SessionManager seeds a default admin on first launch:
//     username: "admin" / password: "admin1234"
//   Engineers should change this via UserManagementView immediately after deployment.
//
// ── Inactivity Timeout ────────────────────────────────────────────────────────
//   SessionManager auto-logs out after 30 min of inactivity.
//   When the timer fires, LoginView reappears automatically via @Published isLoggedIn.

import SwiftUI

// MARK: - LoginView

/// Full-screen overlay shown whenever no operator session is active.
/// Blocks all access to the main UI until successful authentication.
struct LoginView: View {
    @EnvironmentObject var sessionManager: SessionManager

    @State private var username = ""
    @State private var password = ""
    @FocusState private var focus: Field?

    enum Field { case username, password }

    var body: some View {
        ZStack {
            // Semi-transparent backdrop that blocks the underlying UI
            Color.black.opacity(0.5)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Header ──────────────────────────────────────────────────
                HStack(spacing: 12) {
                    Image(systemName: "lock.shield.fill")
                        .font(.title2)
                        .foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Industrial HMI")
                            .font(.headline)
                        Text("Sign in to continue")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding()
                .background(Color(nsColor: .windowBackgroundColor))

                Divider()

                // ── Credential form ──────────────────────────────────────────
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Username")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("Username", text: $username)
                            .textFieldStyle(.roundedBorder)
                            .focused($focus, equals: .username)
                            .onSubmit { focus = .password }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Password")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        SecureField("Password", text: $password)
                            .textFieldStyle(.roundedBorder)
                            .focused($focus, equals: .password)
                            .onSubmit(attemptLogin)
                    }

                    if let err = sessionManager.loginError {
                        Label(err, systemImage: "exclamationmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    Button(action: attemptLogin) {
                        Text("Sign In")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(username.isEmpty || password.isEmpty)
                    .keyboardShortcut(.return, modifiers: [])
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
            }
            .frame(width: 320)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.45), radius: 30, x: 0, y: 10)
        }
        .onAppear { focus = .username }
    }

    private func attemptLogin() {
        if sessionManager.login(username: username, password: password) {
            password = ""
        }
    }
}
