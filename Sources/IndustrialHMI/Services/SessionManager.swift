import Foundation

// MARK: - SessionManager.swift
//
// Manages operator authentication, role-based access control, and session lifetime.
//
// ── Operator storage ──────────────────────────────────────────────────────────
//   Operators are stored in a JSON file (NOT the Keychain):
//     ~/Library/Application Support/IndustrialHMI/operators.json
//   Each Operator record stores a SHA-256 password hash + salt (never plaintext).
//   On first launch (empty file), a default admin account is seeded:
//     username: "admin", password: "admin1234", role: .admin
//
// ── Session lifecycle ─────────────────────────────────────────────────────────
//   Sessions are in-memory only — every app launch requires a fresh login.
//   currentOperator is set on successful login() and cleared by logout() or timeout.
//   recordActivity() must be called on significant operator events (tab switch, write,
//   button press) to reset the inactivity clock.
//
// ── Inactivity timeout ────────────────────────────────────────────────────────
//   A background Task polls every 60 s and calls logout() if
//     Date().timeIntervalSince(lastActivity) >= sessionTimeout (30 min).
//   The task is cancelled and restarted on each login.
//
// ── Role-based access control ────────────────────────────────────────────────
//   SessionManager exposes convenience Bool properties (canWrite, canAcknowledge,
//   canManageTags, canManageUsers) derived from currentRole.
//   Views gate their actions on these properties:
//     guard sessionManager.canWrite else { ... }

// MARK: - SessionManager

/// Manages operator authentication, role-based access control, and session lifetime.
///
/// Operator accounts are stored in operators.json (not the Keychain).
/// Sessions are in-memory only — every app launch requires a fresh login.
/// A 30-minute inactivity timer automatically logs out the current operator.
@MainActor
class SessionManager: ObservableObject {

    // MARK: - Published

    @Published private(set) var currentOperator: Operator?
    @Published private(set) var operators: [Operator] = []
    @Published var loginError: String?

    // MARK: - Session timeout

    let sessionTimeout: TimeInterval = 30 * 60   // 30 minutes
    private var lastActivity: Date = Date()
    private var timeoutTask: Task<Void, Never>?

    // MARK: - File storage path

    private var operatorsFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
        let dir = support.appendingPathComponent("IndustrialHMI")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("operators.json")
    }

    // MARK: - Computed

    var isLoggedIn: Bool      { currentOperator != nil }
    var currentRole: OperatorRole { currentOperator?.role ?? .viewer }
    var currentUsername: String   { currentOperator?.displayName ?? "System" }

    // Role capability shortcuts (mirrors OperatorRole helpers)
    var canWrite:           Bool { currentRole.canWrite           }
    var canAcknowledge:     Bool { currentRole.canAcknowledge     }
    var canConfigureAlarms: Bool { currentRole.canConfigureAlarms }
    var canManageTags:      Bool { currentRole.canManageTags      }
    var canManageUsers:     Bool { currentRole.canManageUsers     }

    // MARK: - Init

    init() {
        loadOperators()
        if operators.isEmpty { createDefaultAdmin() }
        startTimeoutWatcher()
    }

    // MARK: - Login / Logout

    func login(username: String, password: String) -> Bool {
        loginError = nil
        guard let op = operators.first(where: {
            $0.username.lowercased() == username.lowercased() && $0.isEnabled
        }) else {
            loginError = "Invalid username or password."
            return false
        }
        guard op.verifyPassword(password) else {
            loginError = "Invalid username or password."
            return false
        }

        // Record login timestamp
        if let idx = operators.firstIndex(where: { $0.id == op.id }) {
            operators[idx].lastLoginAt = Date()
            saveOperators()
        }
        currentOperator = op
        lastActivity    = Date()
        Logger.shared.info("Login: \(op.username) (\(op.role.displayName))")
        return true
    }

    func logout() {
        Logger.shared.info("Logout: \(currentOperator?.username ?? "?")")
        currentOperator = nil
        loginError      = nil
    }

    /// Call this whenever the operator interacts with the app to reset the timeout.
    func recordActivity() {
        lastActivity = Date()
    }

    // MARK: - User Management  (requires admin role for callers to enforce)

    func addOperator(
        username:    String,
        displayName: String,
        role:        OperatorRole,
        password:    String
    ) {
        guard !username.trimmingCharacters(in: .whitespaces).isEmpty,
              !operators.contains(where: { $0.username.lowercased() == username.lowercased() })
        else { return }

        let op = Operator(username: username, displayName: displayName,
                          role: role, password: password)
        operators.append(op)
        saveOperators()
        Logger.shared.info("User added: \(username) (\(role.displayName)) by \(currentUsername)")
    }

    func updateOperator(_ op: Operator) {
        guard let idx = operators.firstIndex(where: { $0.id == op.id }) else { return }
        operators[idx] = op
        saveOperators()
        // Keep currentOperator in sync if it's the same account
        if currentOperator?.id == op.id { currentOperator = op }
    }

    func removeOperator(id: UUID) {
        // Prevent removing the last admin
        guard let op = operators.first(where: { $0.id == id }) else { return }
        if op.role == .admin && operators.filter({ $0.role == .admin }).count <= 1 { return }
        operators.removeAll { $0.id == id }
        saveOperators()
        Logger.shared.info("User removed: \(op.username) by \(currentUsername)")
    }

    func changePassword(for operatorId: UUID, newPassword: String) {
        guard !newPassword.isEmpty,
              let idx = operators.firstIndex(where: { $0.id == operatorId }) else { return }
        operators[idx].setPassword(newPassword)
        saveOperators()
        Logger.shared.info("Password changed for \(operators[idx].username) by \(currentUsername)")
    }

    func setEnabled(_ enabled: Bool, for operatorId: UUID) {
        guard let idx = operators.firstIndex(where: { $0.id == operatorId }) else { return }
        // Can't disable the last admin
        if !enabled && operators[idx].role == .admin &&
            operators.filter({ $0.role == .admin && $0.isEnabled }).count <= 1 { return }
        operators[idx].isEnabled = enabled
        saveOperators()
    }

    // MARK: - Inactivity Timeout

    private func startTimeoutWatcher() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, !Task.isCancelled else { return }
                if self.isLoggedIn,
                   Date().timeIntervalSince(self.lastActivity) > self.sessionTimeout {
                    Logger.shared.info("Session timed out: \(self.currentOperator?.username ?? "?")")
                    self.currentOperator = nil
                }
            }
        }
    }

    // MARK: - File Persistence (Application Support — no Keychain prompts across builds)

    private func saveOperators() {
        guard let data = try? JSONEncoder().encode(operators) else { return }
        let url = operatorsFileURL
        do {
            try data.write(to: url)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: url.path)
        } catch {
            Logger.shared.error("SessionManager: save failed — \(error)")
        }
    }

    private func loadOperators() {
        let url = operatorsFileURL
        guard let data    = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Operator].self, from: data)
        else { return }
        operators = decoded
    }

    private func createDefaultAdmin() {
        let admin = Operator(
            username:    "admin",
            displayName: "Administrator",
            role:        .admin,
            password:    "admin"
        )
        operators = [admin]
        saveOperators()
        Logger.shared.info("SessionManager: default admin created (password: admin)")
    }
}
