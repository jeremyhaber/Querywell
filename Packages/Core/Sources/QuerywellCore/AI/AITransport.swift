import Foundation

/// The HTTP layer the providers talk through. Production uses ``URLSessionTransport``; tests inject a
/// mock that replays canned (and arbitrarily chunked) responses, so no test ever calls a live API.
public protocol AITransport: Sendable {
    /// A whole response.
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Response head, then the body as it arrives (chunk boundaries are arbitrary).
    func bytes(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>)
}

public struct URLSessionTransport: AITransport {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse("not an HTTP response") }
        return (data, http)
    }

    public func bytes(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse("not an HTTP response") }
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    // Hand over a chunk per line (SSE is line-based) instead of one byte at a time.
                    var chunk = Data()
                    for try await byte in bytes {
                        chunk.append(byte)
                        if byte == 0x0A || chunk.count >= 8192 {
                            continuation.yield(chunk)
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    if !chunk.isEmpty { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (http, stream)
    }
}

// MARK: - Shared plumbing for the providers

/// Decodes the provider-specific JSON payload of each SSE event.
protocol AIStreamDecoder: Sendable {
    /// Turns one event into zero or more stream events. Throws an ``AIError`` for in-stream errors.
    mutating func decode(_ event: SSEEvent) throws -> [AIStreamEvent]
    /// The provider signalled the end of the reply.
    var isFinished: Bool { get }
    var receivedText: Bool { get }
    var usage: AIUsage? { get }
}

enum AIHTTP {
    /// Maps a non-2xx response to a user-facing error.
    static func error(status: Int, retryAfter: TimeInterval?, body: Data, provider: AIProviderID, model: String) -> AIError {
        let info = ErrorBody(body)
        return map(status: status, type: info.type, code: info.code, message: info.message, retryAfter: retryAfter,
                   provider: provider, model: model)
    }

    static func map(status: Int, type: String?, code: String?, message: String?, retryAfter: TimeInterval?,
                    provider: AIProviderID, model: String) -> AIError {
        let text = message ?? ""
        let lower = text.lowercased()
        let kind = "\(type ?? "") \(code ?? "")".lowercased()

        if kind.contains("insufficient_quota") || kind.contains("billing") || lower.contains("credit balance")
            || lower.contains("insufficient credits") || lower.contains("exceeded your current quota") {
            return .quotaExceeded
        }
        if kind.contains("authentication") || kind.contains("invalid_api_key") || kind.contains("permission") { return .unauthorized(provider) }
        if kind.contains("model_not_found") || kind.contains("not_found") && lower.contains("model") { return .modelNotFound(model) }
        if kind.contains("rate_limit") { return .rateLimited(retryAfter: retryAfter) }

        switch status {
        case 401, 403: return .unauthorized(provider)
        case 402: return .quotaExceeded
        case 404:
            if lower.contains("model") || lower.contains("no endpoints") || message == nil { return .modelNotFound(model) }
            return .server(status: status, message: text)
        case 429: return .rateLimited(retryAfter: retryAfter)
        case 400:
            if lower.contains("model"), lower.contains("not exist") || lower.contains("not found") || lower.contains("invalid model") {
                return .modelNotFound(model)
            }
            return .server(status: status, message: text.isEmpty ? "Bad request" : text)
        default:
            return .server(status: status, message: text.isEmpty ? (HTTPURLResponse.localizedString(forStatusCode: status)) : text)
        }
    }

    /// Normalises whatever went wrong into an ``AIError``.
    static func map(_ error: any Error) -> AIError {
        if let e = error as? AIError { return e }
        if error is CancellationError { return .cancelled }
        if let u = error as? URLError {
            if u.code == .cancelled { return .cancelled }
            return .network(u.localizedDescription)
        }
        return .network((error as NSError).localizedDescription)
    }

    static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        response.value(forHTTPHeaderField: "retry-after").flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// `{error:{message,type,code}}`, `{error:"text"}`, `{message:"…"}` or plain text.
    struct ErrorBody {
        var message: String?
        var type: String?
        var code: String?

        init(_ data: Data) {
            if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                self.init(json: json)
            } else {
                let s = String(decoding: data.prefix(500), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                self.init(message: s.isEmpty ? nil : s)
            }
        }

        init(message: String?) { self.message = message }

        init(json: [String: Any]) {
            if let e = json["error"] as? [String: Any] {
                message = e["message"] as? String
                type = e["type"] as? String
                if let c = e["code"] as? String { code = c } else if let n = e["code"] as? NSNumber { code = n.stringValue }
                // OpenRouter nests the upstream error in metadata.raw.
                if message == nil, let meta = e["metadata"] as? [String: Any], let raw = meta["raw"] as? String { message = raw }
            } else if let e = json["error"] as? String {
                message = e
            } else {
                message = json["message"] as? String
            }
        }
    }

    /// The shared streaming driver: POST, check status, feed the body through the SSE parser and the decoder.
    static func stream<D: AIStreamDecoder>(
        transport: any AITransport, request: URLRequest, provider: AIProviderID, model: String, decoder: D
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (response, body) = try await transport.bytes(for: request)
                    guard (200..<300).contains(response.statusCode) else {
                        var data = Data()
                        for try await chunk in body {
                            data.append(chunk)
                            if data.count > 64 * 1024 { break }
                        }
                        throw error(status: response.statusCode, retryAfter: retryAfter(response), body: data,
                                    provider: provider, model: model)
                    }
                    var parser = SSEParser()
                    var decoder = decoder
                    outer: for try await chunk in body {
                        try Task.checkCancellation()
                        for event in parser.feed(chunk) {
                            for out in try decoder.decode(event) { continuation.yield(out) }
                            if decoder.isFinished { break outer }
                        }
                    }
                    if !decoder.isFinished {
                        for event in parser.finish() {
                            for out in try decoder.decode(event) { continuation.yield(out) }
                            if decoder.isFinished { break }
                        }
                    }
                    if !decoder.isFinished {
                        // The connection closed without the provider's end marker.
                        guard decoder.receivedText else { throw AIError.invalidResponse("the reply was empty") }
                        continuation.yield(.done(decoder.usage))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func jsonObject(_ s: String) -> [String: Any]? {
        guard let d = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
}
