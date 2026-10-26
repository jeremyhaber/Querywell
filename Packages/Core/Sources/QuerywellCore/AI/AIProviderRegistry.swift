import Foundation

public enum AIProviderRegistry {
    /// Builds the provider for `id` using `apiKey`.
    public static func provider(
        for id: AIProviderID, apiKey: String, transport: any AITransport = URLSessionTransport()
    ) -> any AIProvider {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        switch id {
        case .anthropic: return AnthropicProvider(apiKey: key, transport: transport)
        case .openai: return OpenAIProvider(apiKey: key, transport: transport)
        case .openrouter: return OpenRouterProvider(apiKey: key, transport: transport)
        }
    }
}

/// API keys live in the Keychain (through a ``SecretStore``), never in settings files:
/// `SecretKey(ownerID: SecretKey.globalOwnerID, kind: .aiAPIKey(provider: id.rawValue))`.
public struct AIKeyStore: Sendable {
    private let store: any SecretStore

    public init(store: any SecretStore) { self.store = store }

    static func secretKey(_ id: AIProviderID) -> SecretKey {
        SecretKey(ownerID: SecretKey.globalOwnerID, kind: .aiAPIKey(provider: id.rawValue))
    }

    /// The stored key, trimmed; nil if none (or blank).
    public func apiKey(for id: AIProviderID) throws -> String? {
        guard let raw = try store.read(Self.secretKey(id)) else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    public func hasKey(for id: AIProviderID) -> Bool { ((try? apiKey(for: id)) ?? nil) != nil }

    /// Saves a pasted key (surrounding whitespace removed); a blank key deletes the entry.
    public func setAPIKey(_ key: String, for id: AIProviderID) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { try store.delete(Self.secretKey(id)) } else { try store.write(trimmed, for: Self.secretKey(id)) }
    }

    public func deleteAPIKey(for id: AIProviderID) throws { try store.delete(Self.secretKey(id)) }

    /// A ready provider, or ``AIError/missingAPIKey(_:)``.
    public func provider(for id: AIProviderID, transport: any AITransport = URLSessionTransport()) throws -> any AIProvider {
        guard let key = try apiKey(for: id) else { throw AIError.missingAPIKey(id) }
        return AIProviderRegistry.provider(for: id, apiKey: key, transport: transport)
    }
}
