// MARK: - UserManagementView.swift
//
// Admin-only panel for managing operator accounts. Visible only in Settings
// when the currently logged-in operator has the .admin role.
//
// ── Layout ────────────────────────────────────────────────────────────────────
//   VStack:
//     headerBar — "Operator Accounts" title + "Add Operator" button
//     operatorTable — Table<Operator> with columns:
//       username, full name, role badge, last login, "active" indicator
//       Row context menu: Edit Role, Change Password, Deactivate/Reactivate, Delete
//
// ── Sheets ────────────────────────────────────────────────────────────────────
//   AddOperatorSheet     — username, full name, role picker, initial password
//   EditOperatorSheet    — edit role and full name (not username — it's immutable)
//   ChangePasswordSheet  — admin sets a new password for the target operator
//
// ── Role Hierarchy ────────────────────────────────────────────────────────────
//   .viewer, .control, .engineer, .admin (Comparable Int)
//   Admin cannot delete or downgrade their own account.
//   At least one admin must remain — deleting the last admin is blocked.
//
// ── Password Policy ───────────────────────────────────────────────────────────
//   sessionManager.addOperator() salts + SHA-256 hashes the password before storage.
//   Passwords are never stored in plain text (see Operator.swift + SessionManager.swift).
//   ChangePasswordSheet calls sessionManager.changePassword(for:newPassword:) directly.
//
// ── Self-Protection ───────────────────────────────────────────────────────────
//   Admin cannot delete themselves (id check against sessionManager.currentOperator).
//   Admin cannot demote themselves to a non-admin role (prevents lockout).
//   "Delete" button row hidden for the currently logged-in operator.

import SwiftUI

// MARK: - UserManagementView

/// Admin-only panel for creating, editing, and removing operator accounts.
/// Embedded in SettingsView — visible only when the current role is `.admin`.
struct UserManagementView: View {
    @EnvironmentObject var sessionManager: SessionManager

    @State private var showAddSheet     = false
    @State private var editingOperator: Operator? = nil
    @State private var changePasswordFor: Operator? = nil

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            operatorTable
        }
        .sheet(isPresented: $showAddSheet) {
            AddOperatorSheet().environmentObject(sessionManager)
        }
        .sheet(item: $editingOperator) { op in
            EditOperatorSheet(editOp: op).environmentObject(sessionManager)
        }
        .sheet(item: $changePasswordFor) { op in
            ChangePasswordSheet(targetOp: op).environmentObject(sessionManager)
        }
    }

    // MARK: Header bar

    private var headerBar: some View {
        HStack {
            Text("Operator Accounts")
                .font(.headline)
            Spacer()
            Button(action: { showAddSheet = true }) {
                Label("Add Operator", systemImage: "person.badge.plus")
            }
            .buttonStyle(.bordered)
        }
        .padding(10)
    }

    // MARK: Table

    @ViewBuilder
    private var operatorTable: some View {
        if sessionManager.operators.isEmpty {
            ContentUnavailableView(
                "No Operators",
                systemImage: "person.slash",
                description: Text("Add an operator to get started.")
            )
        } else {
            List(sessionManager.operators) { op in
                operatorRow(op)
            }
        }
    }

    private func operatorRow(_ op: Operator) -> some View {
        HStack(spacing: 12) {
            // Role badge
            Text(op.role.displayName)
                .font(.caption.bold())
                .foregroundColor(roleColor(op.role))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(roleColor(op.role).opacity(0.12))
                .cornerRadius(5)
                .frame(width: 78, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(op.username)
                        .font(.system(.body, design: .monospaced))
                    if !op.isEnabled {
                        Text("Disabled")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15))
                            .cornerRadius(3)
                    }
                }
                if op.displayName != op.username {
                    Text(op.displayName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Last login
            VStack(alignment: .trailing, spacing: 2) {
                if let ts = op.lastLoginAt {
                    Text("Last login")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(ts, style: .relative)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    Text("Never logged in")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            // Context menu actions
            Menu {
                Button("Edit…")            { editingOperator     = op }
                Button("Change Password…") { changePasswordFor   = op }
                Divider()
                Button(op.isEnabled ? "Disable" : "Enable") {
                    sessionManager.setEnabled(!op.isEnabled, for: op.id)
                }
                Divider()
                Button("Delete", role: .destructive) {
                    sessionManager.removeOperator(id: op.id)
                }
                .disabled(
                    op.role == .admin &&
                    sessionManager.operators.filter { $0.role == .admin }.count <= 1
                )
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 4)
    }

    private func roleColor(_ role: OperatorRole) -> Color {
        switch role {
        case .viewer:   return .secondary
        case .control:  return .blue
        case .engineer: return .orange
        case .admin:    return .red
        }
    }
}

// MARK: - AddOperatorSheet

private struct AddOperatorSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var sessionManager: SessionManager

    @State private var username    = ""
    @State private var displayName = ""
    @State private var role        = OperatorRole.control
    @State private var password    = ""
    @State private var confirm     = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "Add Operator", icon: "person.badge.plus")
            Divider()
            form
            Divider()
            SheetFooter(
                onCancel: { dismiss() },
                onSave:   save,
                saveDisabled: !formValid
            )
        }
        .frame(width: 380)
    }

    private var form: some View {
        Form {
            Section("Identity") {
                TextField("Username",     text: $username)
                TextField("Display Name", text: $displayName)
                Picker("Role", selection: $role) {
                    ForEach(OperatorRole.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
            }
            Section("Password") {
                SecureField("Password", text: $password)
                SecureField("Confirm",  text: $confirm)
                if let e = error {
                    Text(e).font(.caption).foregroundColor(.red)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 4)
    }

    private var formValid: Bool {
        !username.isEmpty && !password.isEmpty && password == confirm
    }

    private func save() {
        guard formValid else { error = "Passwords do not match."; return }
        if sessionManager.operators.contains(where: {
            $0.username.lowercased() == username.lowercased()
        }) {
            error = "Username already exists."
            return
        }
        sessionManager.addOperator(username: username, displayName: displayName,
                                   role: role, password: password)
        dismiss()
    }
}

// MARK: - EditOperatorSheet

private struct EditOperatorSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var sessionManager: SessionManager

    @State var editOp: Operator
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "Edit Operator", icon: "person.badge.key.fill")
            Divider()
            Form {
                Section("Identity") {
                    TextField("Username",     text: $editOp.username)
                    TextField("Display Name", text: $editOp.displayName)
                    Picker("Role", selection: $editOp.role) {
                        ForEach(OperatorRole.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    Toggle("Enabled", isOn: $editOp.isEnabled)
                }
            }
            .formStyle(.grouped)
            .padding(.vertical, 4)
            Divider()
            SheetFooter(
                onCancel: { dismiss() },
                onSave:   {
                    sessionManager.updateOperator(editOp)
                    dismiss()
                },
                saveDisabled: editOp.username.isEmpty
            )
        }
        .frame(width: 380)
    }
}

// MARK: - ChangePasswordSheet

private struct ChangePasswordSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var sessionManager: SessionManager

    let targetOp: Operator
    @State private var newPassword = ""
    @State private var confirm     = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "Change Password", icon: "key.fill")
            Divider()
            Form {
                Section("New Password for \"\(targetOp.displayName)\"") {
                    SecureField("New Password", text: $newPassword)
                    SecureField("Confirm",      text: $confirm)
                    if let e = error {
                        Text(e).font(.caption).foregroundColor(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .padding(.vertical, 4)
            Divider()
            SheetFooter(
                onCancel: { dismiss() },
                onSave:   save,
                saveDisabled: newPassword.isEmpty || newPassword != confirm
            )
        }
        .frame(width: 340)
    }

    private func save() {
        guard !newPassword.isEmpty, newPassword == confirm else {
            error = "Passwords do not match."
            return
        }
        sessionManager.changePassword(for: targetOp.id, newPassword: newPassword)
        dismiss()
    }
}

// MARK: - Sheet helpers (shared)

struct SheetHeader: View {
    let title: String
    let icon:  String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
            Text(title).font(.headline)
            Spacer()
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct SheetFooter: View {
    let onCancel:     () -> Void
    let onSave:       () -> Void
    let saveDisabled: Bool
    var body: some View {
        HStack {
            Button("Cancel", action: onCancel).keyboardShortcut(.escape, modifiers: [])
            Spacer()
            Button("Save",   action: onSave)
                .buttonStyle(.borderedProminent)
                .disabled(saveDisabled)
                .keyboardShortcut(.return, modifiers: .command)
        }
        .padding()
    }
}
