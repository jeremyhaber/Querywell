import Foundation

/// Shared implementation of the OpenAI chat-completions wire format (OpenAI itself and OpenRouter).
struct ChatCompletionsClient: Sendable {
    var id: AIProviderID
    var baseURL: URL
    var apiKey: String
    var extraHeaders: [String: String]
    /// OpenAI's newer models require `max_completion_tokens`; OpenRouter documents `max_tokens`.
    var tokenParameter: String
    var includeUsageOption: Bool
    var transport: any AITransport

    func urlRequest(for request: AIRequest) throws -> URLRequest {
        var messages: [[String: String]] = []
        if !request.system.isEmpty { messages.append(["role": "system", "content": request.system]) }
        messages += request.messages.map { ["role": $0.role.rawValue, "content": $0.text] }
        var body: [String: Any] = [
            "model": request.model,
            "messages": messages,
            "stream": true,
            tokenParameter: request.maxTokens,
        ]
        if includeUsageOption { body["stream_options"] = ["include_usage": true] }
        if let t = request.temperature { body["temperature"] = t }
        var r = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        r.httpMethod = "POST"
        r.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        applyHeaders(&r)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        return r
    }

    func applyHeaders(_ r: inout URLRequest) {
        r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        for (k, v) in extraHeaders { r.setValue(v, forHTTPHeaderField: k) }
    }

    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        do {
            return AIHTTP.stream(transport: transport, request: try urlRequest(for: request), provider: id,
                                 model: request.model, decoder: Decoder(provider: id, model: request.model))
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: AIHTTP.map(error)) }
        }
    }

    /// GET `<base>/models` → `data[]` with `id` and optional `name`, `created`.
    func fetchModels() async throws -> [(id: String, name: String?, created: Double)] {
        var r = URLRequest(url: baseURL.appendingPathComponent("models"))
        applyHeaders(&r)
        do {
            let (data, response) = try await transport.data(for: r)
            guard (200..<300).contains(response.statusCode) else {
                throw AIHTTP.error(status: response.statusCode, retryAfter: AIHTTP.retryAfter(response), body: data,
                                   provider: id, model: "")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = json["data"] as? [[String: Any]] else {
                throw AIError.invalidResponse("model list")
            }
            return list.compactMap { m in
                guard let mid = m["id"] as? String else { return nil }
                return (mid, m["name"] as? String, (m["created"] as? NSNumber)?.doubleValue ?? 0)
            }
        } catch {
            throw AIHTTP.map(error)
        }
    }

    struct Decoder: AIStreamDecoder {
        let provider: AIProviderID
        let model: String
        private(set) var isFinished = false
        private(set) var receivedText = false
        private(set) var usage: AIUsage?

        init(provider: AIProviderID, model: String) {
            self.provider = provider
            self.model = model
        }

        mutating func decode(_ event: SSEEvent) throws -> [AIStreamEvent] {
            let data = event.data.trimmingCharacters(in: .whitespaces)
            if data == "[DONE]" {
                isFinished = true
                return [.done(usage)]
            }
            guard let json = AIHTTP.jsonObject(data) else { return [] }
            if json["error"] != nil {
                let body = AIHTTP.ErrorBody(json: json)
                let status = Int(body.code ?? "") ?? 0
                throw AIHTTP.map(status: status, type: body.type, code: body.code, message: body.message, retryAfter: nil,
                                 provider: provider, model: model)
            }
            if let u = json["usage"] as? [String: Any] {
                usage = AIUsage(inputTokens: (u["prompt_tokens"] as? NSNumber)?.intValue,
                                outputTokens: (u["completion_tokens"] as? NSNumber)?.intValue)
            }
            guard let choices = json["choices"] as? [[String: Any]], let first = choices.first,
                  let delta = first["delta"] as? [String: Any], let text = delta["content"] as? String, !text.isEmpty else {
                return []
            }
            receivedText = true
            return [.textDelta(text)]
        }
    }
}

/// OpenAI Chat Completions (`POST /v1/chat/completions`, SSE until `data: [DONE]`).
public struct OpenAIProvider: AIProvider {
    public let id = AIProviderID.openai
    public static let defaultBaseURL = URL(string: "https://api.openai.com/v1")!

    private let client: ChatCompletionsClient

    public init(apiKey: String, baseURL: URL = OpenAIProvider.defaultBaseURL, transport: any AITransport = URLSessionTransport()) {
        client = ChatCompletionsClient(id: .openai, baseURL: baseURL, apiKey: apiKey, extraHeaders: [:],
                                       tokenParameter: "max_completion_tokens", includeUsageOption: true, transport: transport)
    }

    public func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> { client.stream(request) }

    public func listModels() async throws -> [AIModelInfo] {
        try await client.fetchModels()
            .filter { Self.isChatModel($0.id) }
            .sorted { $0.created != $1.created ? $0.created > $1.created : $0.id < $1.id }
            .map { AIModelInfo(id: $0.id) }
    }

    /// Heuristic: the `/v1/models` list mixes chat models with embeddings, speech, image and legacy
    /// completion models. Users can still type any id.
    public static func isChatModel(_ id: String) -> Bool {
        let m = id.lowercased()
        let looksChat = m.hasPrefix("gpt-") || m.hasPrefix("chatgpt-")
            || m.range(of: #"^o\d"#, options: .regularExpression) != nil
        guard looksChat else { return false }
        let excluded = ["embedding", "whisper", "tts", "dall-e", "moderation", "audio", "realtime", "transcribe", "image",
                        "instruct", "davinci", "babbage", "search", "similarity", "edit"]
        return !excluded.contains { m.contains($0) }
    }
}

/// OpenRouter: OpenAI-compatible, many upstream models behind one key.
public struct OpenRouterProvider: AIProvider {
    public let id = AIProviderID.openrouter
    public static let defaultBaseURL = URL(string: "https://openrouter.ai/api/v1")!
    public static let referer = "https://github.com/jeremyhaber/Querywell"
    public static let title = "Querywell"

    private let client: ChatCompletionsClient

    public init(apiKey: String, baseURL: URL = OpenRouterProvider.defaultBaseURL, transport: any AITransport = URLSessionTransport()) {
        client = ChatCompletionsClient(
            id: .openrouter, baseURL: baseURL, apiKey: apiKey,
            extraHeaders: ["HTTP-Referer": Self.referer, "X-Title": Self.title],
            tokenParameter: "max_tokens", includeUsageOption: false, transport: transport)
    }

    public func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> { client.stream(request) }

    public func listModels() async throws -> [AIModelInfo] {
        try await client.fetchModels()
            .sorted { $0.id < $1.id }
            .map { AIModelInfo(id: $0.id, displayName: $0.name) }
    }
}
