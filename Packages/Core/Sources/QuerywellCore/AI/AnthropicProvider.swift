import Foundation

/// Anthropic Messages API (`POST /v1/messages`, `stream: true`).
public struct AnthropicProvider: AIProvider {
    public let id = AIProviderID.anthropic
    public static let defaultBaseURL = URL(string: "https://api.anthropic.com")!
    public static let apiVersion = "2023-06-01"

    private let apiKey: String
    private let baseURL: URL
    private let transport: any AITransport

    public init(apiKey: String, baseURL: URL = AnthropicProvider.defaultBaseURL, transport: any AITransport = URLSessionTransport()) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.transport = transport
    }

    func urlRequest(for request: AIRequest) throws -> URLRequest {
        var body: [String: Any] = [
            "model": request.model,
            "max_tokens": request.maxTokens,
            "messages": request.messages.map { ["role": $0.role.rawValue, "content": $0.text] },
            "stream": true,
        ]
        if !request.system.isEmpty { body["system"] = request.system }
        if let t = request.temperature { body["temperature"] = t }
        var r = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        r.httpMethod = "POST"
        r.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        applyHeaders(&r)
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.setValue("text/event-stream", forHTTPHeaderField: "accept")
        return r
    }

    private func applyHeaders(_ r: inout URLRequest) {
        r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        r.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
    }

    public func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        do {
            return AIHTTP.stream(transport: transport, request: try urlRequest(for: request), provider: id,
                                 model: request.model, decoder: Decoder(model: request.model))
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: AIHTTP.map(error)) }
        }
    }

    public func listModels() async throws -> [AIModelInfo] {
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/models"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "limit", value: "1000")]
        var r = URLRequest(url: components.url!)
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
                return AIModelInfo(id: mid, displayName: m["display_name"] as? String)
            }
        } catch {
            throw AIHTTP.map(error)
        }
    }

    // MARK: Stream decoding

    struct Decoder: AIStreamDecoder {
        let model: String
        private(set) var isFinished = false
        private(set) var receivedText = false
        private(set) var usage: AIUsage?

        init(model: String) { self.model = model }

        mutating func decode(_ event: SSEEvent) throws -> [AIStreamEvent] {
            guard let json = AIHTTP.jsonObject(event.data) else { return [] }
            let type = (json["type"] as? String) ?? event.event ?? ""
            switch type {
            case "message_start":
                if let message = json["message"] as? [String: Any], let u = message["usage"] as? [String: Any] {
                    merge(u)
                }
                return []
            case "content_block_delta":
                guard let delta = json["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                      let text = delta["text"] as? String, !text.isEmpty else { return [] }
                receivedText = true
                return [.textDelta(text)]
            case "message_delta":
                if let u = json["usage"] as? [String: Any] { merge(u) }
                return []
            case "message_stop":
                isFinished = true
                return [.done(usage)]
            case "error":
                let body = AIHTTP.ErrorBody(json: json)
                throw AIHTTP.map(status: 0, type: body.type, code: body.code, message: body.message, retryAfter: nil,
                                 provider: .anthropic, model: model)
            default:
                return []  // ping, content_block_start/stop, …
            }
        }

        private mutating func merge(_ u: [String: Any]) {
            var current = usage ?? AIUsage()
            if let i = (u["input_tokens"] as? NSNumber)?.intValue { current.inputTokens = i }
            if let o = (u["output_tokens"] as? NSNumber)?.intValue { current.outputTokens = o }
            usage = current
        }
    }
}
