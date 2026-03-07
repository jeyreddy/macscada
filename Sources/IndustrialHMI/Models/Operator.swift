import Foundation
import CryptoKit
import Security

// MARK: - Operator.swift
//
// Data models for operator authentication and role-based access control.
//
// ── Role hierarchy ────────────────────────────────────────────────────────────
//   Roles are ordered integers (Comparable) so capabilities can be checked with >=:
//     .viewer   (0) — read-only: view tags, trends, alarms
//     .control  (1) — + write tags, acknowledge alarms
//     .engineer (2) — + configure alarms, calculated tags, OPC-UA settings
//     .admin    (3) — + manage users
//
// ── Password storage ──────────────────────────────────────────────────────────
//   Passwords are NEVER stored in plaintext. The scheme:
//     salt = 16 random bytes (re-generated each time password changes)
//     hash = SHA-256(salt_hex + password_utf8)
//   Both stored as lowercase hex strings in the operator JSON file.
//   SessionManager stores operators in a JSON file under Application Support —
//   NOT in the Keychain, by design choice for simplicity at this stage.
//
// ── Operator file ─────────────────────────────────────────────────────────────
//   ~/Library/Application Support/IndustrialHMI/operators.json
//   On first launch, SessionManager seeds a default admin account:
//     username: "admin", password: "admin1234", role: .admin

// MARK: - OperatorRole

/// Role-based access control levels (ordered: higher rawValue = more privilege).
enum OperatorRole: Int, Codable, CaseIterable, Comparable {
    case viewer   = 0   // read-only: can view tags, trends, alarms
    case control  = 1   // operator: ack alarms, write tags
    case engineer = 2   // configure alarms, calculated tags, OPC-UA
    case admin    = 3   // full access + user management

    static func < (lhs: OperatorRole, rhs: OperatorRole) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var displayName: String {
        switch self {
        case .viewer:   return "Viewer"
        case .control:  return "Operator"
        case .engineer: return "Engineer"
        case .admin:    return "Admin"
        }
    }

    // MARK: Role capability helpers
    var canWrite:            Bool { self >= .control  }
    var canAcknowledge:      Bool { self >= .control  }
    var canConfigureAlarms:  Bool { self >= .engineer }
    var canManageTags:       Bool { self >= .engineer }
    var canManageUsers:      Bool { self == .admin    }
}

// MARK: - Operator

/// An industrial control system operator account.
///
/// Passwords are stored as SHA-256(salt + password) — never in plain text.
/// Salt is 16 random bytes re-generated each time the password changes.
struct Operator: Identifiable, Codable {
    let id:           UUID
    var username:     String
    var displayName:  String
    var role:         OperatorRole
    var isEnabled:    Bool
    var createdAt:    Date
    var lastLoginAt:  Date?

    // Stored credential — salt is hex-encoded, hash is hex SHA-256
    fileprivate var passwordHash: String
    fileprivate var salt:         String

    // MARK: Init (sets password directly)

    init(
        id:          UUID = UUID(),
        username:    String,
        displayName: String = "",
        role:        OperatorRole,
        password:    String,
        isEnabled:   Bool = true
    ) {
        self.id          = id
        self.username    = username
        self.displayName = displayName.isEmpty ? username : displayName
        self.role        = role
        self.isEnabled   = isEnabled
        self.createdAt   = Date()
        self.lastLoginAt = nil

        let (s, h)        = Operator.makeHash(password: password)
        self.salt         = s
        self.passwordHash = h
    }

    // MARK: Password operations

    func verifyPassword(_ password: String) -> Bool {
        Operator.makeHash(password: password, existingSalt: salt).hash == passwordHash
    }

    mutating func setPassword(_ password: String) {
        let (s, h)    = Operator.makeHash(password: password)
        self.salt     = s
        self.passwordHash = h
    }

    // MARK: Private hashing

    /// Returns (salt, hash). If `existingSalt` is nil a new salt is generated.
    private static func makeHash(password: String, existingSalt: String? = nil)
        -> (salt: String, hash: String)
    {
        let salt: String
        if let s = existingSalt {
            salt = s
        } else {
            var bytes = [UInt8](repeating: 0, count: 16)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            salt = bytes.map { String(format: "%02x", $0) }.joined()
        }
        let input  = Data((salt + password).utf8)
        let digest = SHA256.hash(data: input)
        let hash   = digest.map { String(format: "%02x", $0) }.joined()
        return (salt, hash)
    }
}
