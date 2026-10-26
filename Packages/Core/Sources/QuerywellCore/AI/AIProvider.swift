import Foundation

// One interface over the hosted LLM APIs the query assistant can use. Providers only translate
// requests/streams; prompts and SQL handling live in QueryAssistant, and nothing here touches a
// database. The assistant's output is text that is inserted into the editor — executing it always goes
// through QueryRunner and the WriteGuard.

public struct AIModelInfo: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    public var displayName: String

    public init(id: String, displayName: String? = nil) {
        self.id = id
        self.displayName = displayName ?? id
    }
}

public struct AIMessage: Sendable, Hashable, Codable {
    public enum Role: String, Sendable, Hashable, Codable { case user, assistant }
    public var role: Role
    public var text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }

    public static func user(_ text: String) -> AIMessage { AIMessage(role: .user, text: text) }
    public static func assistant(_ text: String) -> AIMessage { AIMessage(role: .assistant, text: text) }
}

public struct AIRequest: Sendable, Hashable {
    public var system: String
    public var messages: [AIMessage]
    public var model: String
    public var maxTokens: Int
    public var temperature: Double?

    public init(system: String, messages: [AIMessage], model: String, maxTokens: Int = 4096, temperature: Double? = nil) {
        self.system = system
        self.messages = messages
        self.model = model
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}

public struct AIUsage: Sendable, Hashable {
    public var inputTokens: Int?
    public var outputTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public enum AIStreamEvent: Sendable, Hashable {
    case textDelta(String)
    case done(AIUsage?)
}

public protocol AIProvider: Sendable {
    var id: AIProviderID { get }
    /// Models the key can use, best-effort filtered to chat-capable ones. Users can always type any id.
    func listModels() async throws -> [AIModelInfo]
    /// Streams the reply. The stream finishes after `.done`; failures end it by throwing an ``AIError``.
    /// Cancelling the consuming task (or dropping the stream) cancels the HTTP request.
    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error>
}

public extension AIProvider {
    /// Collects a whole reply (tests, non-interactive callers).
    func complete(_ request: AIRequest) async throws -> String {
        var text = ""
        for try await event in stream(request) {
            if case .textDelta(let d) = event { text += d }
        }
        return text
    }
}

/// Failures with messages written for the user.
public enum AIError: Error, Equatable, Sendable {
    case missingAPIKey(AIProviderID)
    case unauthorized(AIProviderID)
    case rateLimited(retryAfter: TimeInterval?)
    case quotaExceeded
    case modelNotFound(String)
    case network(String)
    case server(status: Int, message: String)
    case cancelled
    /// The reply didn't have the expected shape.
    case invalidResponse(String)
}

extension AIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let p):
            "No \(p.displayName) API key is set. Add one in Settings → AI."
        case .unauthorized(let p):
            "\(p.displayName) rejected the API key. Check it in Settings → AI."
        case .rateLimited(let retry):
            if let retry, retry >= 1 { "Rate limited. Try again in \(Int(retry.rounded(.up))) seconds." }
            else { "Rate limited. Wait a moment and try again." }
        case .quotaExceeded:
            "The account is out of credit or over its usage limit. Check billing with your AI provider."
        case .modelNotFound(let m):
            "The model “\(m)” wasn't found for this key. Pick another model in Settings → AI."
        case .network(let m):
            "Couldn't reach the AI service: \(m)"
        case .server(let status, let message):
            status > 0 ? "The AI service returned an error (\(status)): \(message)" : "The AI service reported an error: \(message)"
        case .cancelled:
            "Cancelled."
        case .invalidResponse(let m):
            "Unexpected reply from the AI service: \(m)"
        }
    }
}

public extension AIProviderID {
    var displayName: String {
        switch self {
        case .openai: "OpenAI"
        case .anthropic: "Anthropic"
        case .openrouter: "OpenRouter"
        }
    }

    /// A reasonable default for the model picker; the user can type any model id.
    var suggestedModel: String {
        switch self {
        case .anthropic: "claude-sonnet-5-5"
        case .openai: "gpt-5"
        case .openrouter: "anthropic/claude-sonnet-5.5"
        }
    }
}
