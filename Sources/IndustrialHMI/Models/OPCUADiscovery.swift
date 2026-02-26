import Foundation

// MARK: - Discovered Server

/// High-level description of an OPC-UA application (from UA_ApplicationDescription).
struct OPCUAServerInfo: Identifiable {
    let id             = UUID()
    let applicationName: String
    let applicationUri:  String
    let applicationType: OPCUAApplicationType
    let discoveryUrls:   [String]

    /// Best URL to try for getEndpoints / connect.
    var primaryUrl: String { discoveryUrls.first ?? "" }
}

// MARK: - Endpoint

/// A single endpoint returned by UA_Client_getEndpoints.
struct OPCUAEndpointInfo: Identifiable {
    let id              = UUID()
    let endpointUrl:    String
    let serverName:     String
    let applicationType: OPCUAApplicationType
    let securityMode:   OPCUASecurityMode
    let securityPolicy: String    // full URI, e.g. http://…#Basic256Sha256

    /// Short policy label (part after #).
    var securityPolicyName: String {
        securityPolicy.components(separatedBy: "#").last ?? securityPolicy
    }
}

// MARK: - Application Type

enum OPCUAApplicationType: String, Codable {
    case server          = "Server"
    case client          = "Client"
    case clientAndServer = "Client & Server"
    case discoveryServer = "Discovery Server"
    case unknown         = "Unknown"

    init(rawValue uaValue: UInt32) {
        switch uaValue {
        case 0:  self = .server
        case 1:  self = .client
        case 2:  self = .clientAndServer
        case 3:  self = .discoveryServer
        default: self = .unknown
        }
    }

    var systemIcon: String {
        switch self {
        case .server:          return "server.rack"
        case .discoveryServer: return "network"
        case .clientAndServer: return "arrow.left.arrow.right"
        case .client:          return "desktopcomputer"
        case .unknown:         return "questionmark.circle"
        }
    }

    var badgeColor: String {
        switch self {
        case .server:          return "blue"
        case .discoveryServer: return "purple"
        case .clientAndServer: return "cyan"
        case .client:          return "gray"
        case .unknown:         return "gray"
        }
    }
}

// MARK: - Security Mode

enum OPCUASecurityMode: String {
    case none          = "None"
    case sign          = "Sign"
    case signAndEncrypt = "Sign & Encrypt"
    case invalid       = "Invalid"

    init(rawMode: UInt32) {
        switch rawMode {
        case 1:  self = .none
        case 2:  self = .sign
        case 3:  self = .signAndEncrypt
        default: self = .invalid
        }
    }

    var systemIcon: String {
        switch self {
        case .none:          return "lock.open"
        case .sign:          return "signature"
        case .signAndEncrypt: return "lock.shield.fill"
        case .invalid:       return "exclamationmark.shield"
        }
    }

    var displayColor: String {
        switch self {
        case .none:          return "orange"
        case .sign:          return "blue"
        case .signAndEncrypt: return "green"
        case .invalid:       return "red"
        }
    }
}

// MARK: - Discovery Error

enum OPCUADiscoveryError: LocalizedError {
    case invalidURL
    case connectionFailed(String)
    case noEndpointsFound

    var errorDescription: String? {
        switch self {
        case .invalidURL:             return "Invalid server URL"
        case .connectionFailed(let m): return "Discovery failed: \(m)"
        case .noEndpointsFound:       return "No endpoints found at that URL"
        }
    }
}
