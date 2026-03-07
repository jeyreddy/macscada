import Foundation

// MARK: - AgentMessage.swift
//
// Data types used by AgentService and AgentView for the Claude AI integration.
//
// ── Layers of representation ──────────────────────────────────────────────────
//
//   1. Wire types (Anthropic API JSON):
//        APIMessage       → a single turn in the conversation history
//        ContentBlock     → discriminated union: text | image | tool_use | tool_result
//        TextBlock        → { "type": "text", "text": "..." }
//        ImageBlock       → { "type": "image", "source": { "type": "base64", ... } }
//        ToolUseBlock     → { "type": "tool_use", "id": ..., "name": ..., "input": {...} }
//        ToolResultBlock  → { "type": "tool_result", "tool_use_id": ..., "content": "..." }
//        MessagesResponse → Anthropic /v1/messages response envelope
//        TokenUsage       → input_tokens / output_tokens
//
//   2. UI model:
//        AgentMessage     → displayed in AgentView's conversation list
//        AgentMessageKind → enum of visual categories (user, assistant, toolCall, etc.)
//
//   3. Error type:
//        AgentError       → typed errors thrown by AgentService
//
// ── AnyCodable ────────────────────────────────────────────────────────────────
//   The Anthropic API sends tool inputs as heterogeneous JSON objects
//   (e.g. `{ "tag_name": "Flow_01", "value": 42.5, "confirmed": true }`).
//   Swift's Codable requires a concrete type, so AnyCodable bridges the gap:
//   it encodes/decodes any JSON-compatible Swift value (Bool, Int, Double,
//   String, [String: Any], [Any]) without type erasure boilerplate.

// MARK: - AgentError

/// Typed errors thrown by AgentService for all failure paths.
/// Conforms to LocalizedError so error messages can be shown directly in SwiftUI alerts.
enum AgentError: LocalizedError {

    /// A required EnvironmentObject (TagEngine, AlarmManager, etc.) is nil.
    case serviceUnavailable

    /// A tool was called without a required input parameter.
    case missingParameter(String)

    /// A tool referenced a tag name that does not exist in TagEngine.
    case tagNotFound(String)

    /// A tool referenced an alarm config that does not exist in AlarmManager.
    case alarmConfigNotFound(String)

    /// A tool referenced an HMI object UUID that does not exist in the current screen.
    case hmiObjectNotFound(String)

    /// The API returned a response that could not be parsed.
    case invalidResponse

    /// The API returned a non-2xx HTTP status code with an error body.
    case apiError(Int, String)

    /// A macOS Keychain operation failed (storing/reading the API key).
    case keychainFailed(OSStatus)

    /// The request payload could not be JSON-encoded.
    case encodingFailed

    /// No API key is stored — the user needs to sign in via ClaudeSignInSheet.
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
//
// Bridges heterogeneous JSON values through Swift's Codable protocol.
//
// The Anthropic API sends tool call inputs as `[String: Any]` dictionaries whose
// values may be Bool, Int, Double, String, nested objects, or arrays.  Swift cannot
// Codable-decode `Any` directly, so AgentService uses `[String: AnyCodable]` for
// tool input fields and later extracts typed values with `as?` casts.
//
// Decoding priority (singleValueContainer):
//   Bool → Int → Double → String → [String: AnyCodable] → [AnyCodable] → NSNull

/// Type-erased Codable wrapper for heterogeneous JSON values.
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        // Attempt each primitive type in order; the first success wins.
        // Bool must come before Int because JSON true/false would decode as Int(1/0).
        if let v = try? c.decode(Bool.self)                      { value = v; return }
        if let v = try? c.decode(Int.self)                       { value = v; return }
        if let v = try? c.decode(Double.self)                    { value = v; return }
        if let v = try? c.decode(String.self)                    { value = v; return }
        // Nested object: decode recursively, then unwrap to [String: Any]
        if let v = try? c.decode([String: AnyCodable].self)      { value = v.mapValues { $0.value }; return }
        // Array: decode recursively, then unwrap to [Any]
        if let v = try? c.decode([AnyCodable].self)              { value = v.map { $0.value }; return }
        // Fall back to null for JSON null values
        value = NSNull()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as Bool:             try c.encode(v)
        case let v as Int:              try c.encode(v)
        case let v as Double:           try c.encode(v)
        case let v as String:           try c.encode(v)
        // Nested dictionary: wrap values back into AnyCodable for recursive encoding
        case let v as [String: Any]:    try c.encode(v.mapValues { AnyCodable($0) })
        case let v as [Any]:            try c.encode(v.map { AnyCodable($0) })
        default:                        try c.encodeNil()
        }
    }
}

// MARK: - Anthropic API Wire Types
//
// These structs mirror the Anthropic Messages API JSON schema exactly.
// They are only used for serialization/deserialization — not displayed in the UI.
//
// Reference: https://docs.anthropic.com/en/api/messages
//
// Request body:
//   { "model": "...", "max_tokens": ..., "system": "...", "tools": [...], "messages": [APIMessage] }
//
// Response body:
//   MessagesResponse { id, type, role, content: [ContentBlock], stop_reason, usage }

/// Discriminated union of all Anthropic content block types.
/// Used in both request messages (user/assistant turns) and API responses.
enum ContentBlock: Codable {
    case text(TextBlock)
    case image(ImageBlock)
    case toolUse(ToolUseBlock)
    case toolResult(ToolResultBlock)

    // The "type" key discriminates which concrete type to decode.
    private enum TypeKey: String, CodingKey { case type }

    init(from decoder: Decoder) throws {
        let type = try decoder.container(keyedBy: TypeKey.self).decode(String.self, forKey: .type)
        switch type {
        case "text":        self = .text(try TextBlock(from: decoder))
        case "image":       self = .image(try ImageBlock(from: decoder))
        case "tool_use":    self = .toolUse(try ToolUseBlock(from: decoder))
        case "tool_result": self = .toolResult(try ToolResultBlock(from: decoder))
        // Graceful degradation: unknown block types become visible text
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

    /// Convenience: true for image blocks (used when filtering content for display).
    var isImage: Bool {
        if case .image = self { return true }
        return false
    }
}

/// Plain text content block — the most common block type in responses.
struct TextBlock: Codable {
    var type: String = "text"
    var text: String
}

/// Base64-encoded image content block — used when the user sends a screenshot.
struct ImageBlock: Codable {
    var type: String = "image"
    var source: ImageSource

    /// Describes the image format and data.
    struct ImageSource: Codable {
        var type: String      = "base64"
        var mediaType: String              // always "image/png" in this app
        var data: String                   // base64-encoded PNG bytes

        enum CodingKeys: String, CodingKey {
            case type, mediaType = "media_type", data
        }
    }
}

/// Tool call block — returned by Claude when it wants to invoke a registered tool.
/// AgentService reads `name` and `input` to dispatch to the appropriate handler.
struct ToolUseBlock: Codable {
    var type: String = "tool_use"
    var id: String                          // opaque ID referenced in the matching ToolResultBlock
    var name: String                        // matches one of the tool names in AgentService.tools
    var input: [String: AnyCodable]         // tool-specific parameters
}

/// Tool result block — sent back to Claude after AgentService executes a tool.
/// `content` is typically a compact JSON string summarising the outcome.
struct ToolResultBlock: Codable {
    var type: String = "tool_result"
    var toolUseId: String                   // matches the ToolUseBlock.id from Claude's request
    var content: String                     // result text or JSON string returned to Claude

    enum CodingKeys: String, CodingKey {
        case type, toolUseId = "tool_use_id", content
    }
}

/// A single conversation turn in the Anthropic API format.
/// The `content` array may contain multiple blocks (e.g. text + image).
struct APIMessage: Codable {
    var role: String             // "user" | "assistant"
    var content: [ContentBlock]
}

/// Anthropic /v1/messages response envelope.
struct MessagesResponse: Codable {
    var id: String
    var type: String             // always "message"
    var role: String             // always "assistant"
    var content: [ContentBlock]  // Claude's reply — may include text and tool_use blocks
    var stopReason: String?      // "end_turn" | "tool_use" | "max_tokens" | "stop_sequence"
    var usage: TokenUsage

    enum CodingKeys: String, CodingKey {
        case id, type, role, content, stopReason = "stop_reason", usage
    }
}

/// Input/output token counts from a single API call — used for cost monitoring.
struct TokenUsage: Codable {
    var inputTokens: Int
    var outputTokens: Int

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens", outputTokens = "output_tokens"
    }
}

// MARK: - UI Message Model
//
// AgentMessage is the view-layer representation of a conversation turn.
// It is independent of the Anthropic wire format and carries only what
// AgentView needs to render each row in the chat list.
//
// Kinds:
//   .user(text, imageBase64?)  — operator's message (text + optional screenshot)
//   .assistant(text)           — Claude's final text reply
//   .toolCall(name, summary)   — tool invocation, shown collapsed in the UI
//   .toolResult(name, summary, isError) — tool outcome, shown below the call
//   .error(description)        — network / API / logic error displayed inline

/// Visual category of a chat row in AgentView.
enum AgentMessageKind {
    case user(text: String, imageBase64: String?)
    case assistant(text: String)
    case toolCall(toolName: String, inputSummary: String)
    case toolResult(toolName: String, resultSummary: String, isError: Bool)
    case error(String)
}

/// A single displayable row in the AgentView conversation list.
/// Conforms to Identifiable using a stable UUID so SwiftUI can diff the list efficiently.
struct AgentMessage: Identifiable {
    let id:        UUID             = UUID()
    let kind:      AgentMessageKind
    let timestamp: Date             = Date()
}
