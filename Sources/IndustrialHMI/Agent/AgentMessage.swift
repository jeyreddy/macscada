import Foundation

// MARK: - AgentError

enum AgentError: LocalizedError {
    case serviceUnavailable
    case missingParameter(String)
    case tagNotFound(String)
    case alarmConfigNotFound(String)
    case hmiObjectNotFound(String)
    case invalidResponse
    case apiError(Int, String)
    case keychainFailed(OSStatus)
    case encodingFailed
    case noAPIKey

    var errorDescription: String? {
        switch self {
        case .serviceUnavailable:          return "Required service is not available."
        case .missingParameter(let p):     return "Missing required parameter: \(p)"
        case .tagNotFound(let n):          return "Tag not found: \(n)"
        case .alarmConfigNotFound(let n):  return "No alarm config found for: \(n)"
        case .hmiObjectNotFound(let id):   return "HMI object not found: \(id)"
        case .invalidResponse:             return "Invalid API response."
        case .apiError(let code, let msg): return "API error \(code): \(msg)"
        case .keychainFailed(let s):       return "Keychain error (OSStatus \(s))"
        case .encodingFailed:              return "Failed to encode request."
        case .noAPIKey:                    return "No API key configured."
        }
    }
}

// MARK: - AnyCodable

/// Bridges heterogeneous JSON values ([String: Any]) through Codable.
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self)                      { value = v; return }
        if let v = try? c.decode(Int.self)                       { value = v; return }
        if let v = try? c.decode(Double.self)                    { value = v; return }
        if let v = try? c.decode(String.self)                    { value = v; return }
        if let v = try? c.decode([String: AnyCodable].self)      { value = v.mapValues { $0.value }; return }
        if let v = try? c.decode([AnyCodable].self)              { value = v.map { $0.value }; return }
        value = NSNull()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as Bool:             try c.encode(v)
        case let v as Int:              try c.encode(v)
        case let v as Double:           try c.encode(v)
        case let v as String:           try c.encode(v)
        case let v as [String: Any]:    try c.encode(v.mapValues { AnyCodable($0) })
        case let v as [Any]:            try c.encode(v.map { AnyCodable($0) })
        default:                        try c.encodeNil()
        }
    }
}

// MARK: - Anthropic API Wire Types

/// Matches the Anthropic content block discriminated union.
enum ContentBlock: Codable {
    case text(TextBlock)
    case image(ImageBlock)
    case toolUse(ToolUseBlock)
    case toolResult(ToolResultBlock)

    private enum TypeKey: String, CodingKey { case type }

    init(from decoder: Decoder) throws {
        let type = try decoder.container(keyedBy: TypeKey.self).decode(String.self, forKey: .type)
        switch type {
        case "text":        self = .text(try TextBlock(from: decoder))
        case "image":       self = .image(try ImageBlock(from: decoder))
        case "tool_use":    self = .toolUse(try ToolUseBlock(from: decoder))
        case "tool_result": self = .toolResult(try ToolResultBlock(from: decoder))
        default:            self = .text(TextBlock(text: "(unknown block type: \(type))"))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let b):        try b.encode(to: encoder)
        case .image(let b):       try b.encode(to: encoder)
        case .toolUse(let b):     try b.encode(to: encoder)
        case .toolResult(let b):  try b.encode(to: encoder)
        }
    }

    var isImage: Bool {
        if case .image = self { return true }
        return false
    }
}

struct TextBlock: Codable {
    var type: String = "text"
    var text: String
}

struct ImageBlock: Codable {
    var type: String = "image"
    var source: ImageSource

    struct ImageSource: Codable {
        var type: String        = "base64"
        var mediaType: String                      // "image/png"
        var data: String                           // base64 encoded

        enum CodingKeys: String, CodingKey {
            case type, mediaType = "media_type", data
        }
    }
}

struct ToolUseBlock: Codable {
    var type: String = "tool_use"
    var id: String
    var name: String
    var input: [String: AnyCodable]
}

struct ToolResultBlock: Codable {
    var type: String = "tool_result"
    var toolUseId: String
    var content: String          // JSON string or plain text

    enum CodingKeys: String, CodingKey {
        case type, toolUseId = "tool_use_id", content
    }
}

/// A single turn in the Anthropic conversation history.
struct APIMessage: Codable {
    var role: String             // "user" | "assistant"
    var content: [ContentBlock]
}

/// Anthropic /v1/messages response.
struct MessagesResponse: Codable {
    var id: String
    var type: String
    var role: String
    var content: [ContentBlock]
    var stopReason: String?
    var usage: TokenUsage

    enum CodingKeys: String, CodingKey {
        case id, type, role, content, stopReason = "stop_reason", usage
    }
}

struct TokenUsage: Codable {
    var inputTokens: Int
    var outputTokens: Int

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens", outputTokens = "output_tokens"
    }
}

// MARK: - UI Message Model

enum AgentMessageKind {
    case user(text: String, imageBase64: String?)
    case assistant(text: String)
    case toolCall(toolName: String, inputSummary: String)
    case toolResult(toolName: String, resultSummary: String, isError: Bool)
    case error(String)
}

struct AgentMessage: Identifiable {
    let id:        UUID             = UUID()
    let kind:      AgentMessageKind
    let timestamp: Date             = Date()
}
