import Foundation
import Testing
import os

@testable import QuerywellCore

// MARK: - Test doubles

/// Replays a canned HTTP response; the body is delivered in the chunks given (so tests control splitting).
final class MockTransport: AITransport {
    struct Canned: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var chunks: [Data] = []
        var error: URLError?
    }
    private let canned: Canned
    private let seen = OSAllocatedUnfairLock(initialState: [URLRequest]())

    init(_ canned: Canned) { self.canned = canned }

    convenience init(status: Int = 200, headers: [String: String] = [:], sse: String, chunkSize: Int? = nil) {
        let bytes = Array(sse.utf8)
        var chunks: [Data] = []
        if let n = chunkSize {
            var i = 0
            while i < bytes.count { chunks.append(Data(bytes[i..<min(i + n, bytes.count)])); i += n }
        } else {
            chunks = [Data(bytes)]
        }
        self.init(Canned(status: status, headers: headers, chunks: chunks))
    }

    var requests: [URLRequest] { seen.withLock { $0 } }

    private func response(for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: canned.status, httpVersion: "HTTP/1.1", headerFields: canned.headers)!
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        seen.withLock { $0.append(request) }
        if let e = canned.error { throw e }
        return (canned.chunks.reduce(Data(), +), response(for: request))
    }

    func bytes(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        seen.withLock { $0.append(request) }
        if let e = canned.error { throw e }
        let chunks = canned.chunks
        return (response(for: request), AsyncThrowingStream { c in
            for chunk in chunks { c.yield(chunk) }
            c.finish()
        })
    }
}

func collect(_ stream: AsyncThrowingStream<AIStreamEvent, Error>) async throws -> (text: String, usage: AIUsage?, doneCount: Int) {
    var text = "", usage: AIUsage?, done = 0
    for try await e in stream {
        switch e {
        case .textDelta(let d): text += d
        case .done(let u): usage = u; done += 1
        }
    }
    return (text, usage, done)
}

private let request = AIRequest(system: "SYS", messages: [.user("hi"), .assistant("yo"), .user("again")], model: "m-1", maxTokens: 321, temperature: 0.2)

private func body(_ t: MockTransport) throws -> [String: Any] {
    let data = try #require(t.requests.last?.httpBody)
    let object = try JSONSerialization.jsonObject(with: data)
    return try #require(object as? [String: Any])
}

// MARK: - SSE parser

@Suite("SSE parser")
struct SSEParserTests {
    private func parse(_ chunks: [String]) -> [SSEEvent] {
        var p = SSEParser()
        var out: [SSEEvent] = []
        for c in chunks { out += p.feed(Array(c.utf8)) }
        out += p.finish()
        return out
    }

    @Test func basicEvents() {
        let e = parse(["event: ping\ndata: {}\n\ndata: hello\n\n"])
        #expect(e == [SSEEvent(event: "ping", data: "{}"), SSEEvent(data: "hello")])
    }

    @Test func lineEndingsLFCRLFAndCR() {
        for sep in ["\n", "\r\n", "\r"] {
            let e = parse(["event: a\(sep)data: 1\(sep)\(sep)data: 2\(sep)\(sep)"])
            #expect(e.map(\.data) == ["1", "2"], "separator \(sep.debugDescription)")
            #expect(e[0].event == "a")
        }
    }

    @Test func crlfSplitAcrossChunks() {
        let e = parse(["data: 1\r", "\n\r", "\ndata: 2\r\n\r\n"])
        #expect(e.map(\.data) == ["1", "2"])
    }

    @Test func partialLinesAcrossChunks() {
        let text = "event: content_block_delta\ndata: {\"a\": \"hel"
        let e = parse([text, "lo\"}\n", "\n"])
        #expect(e == [SSEEvent(event: "content_block_delta", data: "{\"a\": \"hello\"}")])
        // every possible split point gives the same result
        let full = "event: x\ndata: first\ndata: second\n\n: keep-alive\n\ndata: 日本語 😀\n\n"
        let expected = parse([full])
        let bytes = Array(full.utf8)
        for cut in 1..<bytes.count {
            var p = SSEParser()
            var out = p.feed(Array(bytes[..<cut]))
            out += p.feed(Array(bytes[cut...]))
            out += p.finish()
            #expect(out == expected, "cut at \(cut)")
        }
        #expect(expected.map(\.data) == ["first\nsecond", "日本語 😀"])
    }

    @Test func commentsAreIgnoredAndBlankCommentOnlyEventsDropped() {
        let e = parse([": OPENROUTER PROCESSING\n\n: another\ndata: x\n\n"])
        #expect(e == [SSEEvent(data: "x")])
    }

    @Test func multiLineDataJoinedWithNewline() {
        #expect(parse(["data: a\ndata: b\ndata:\ndata: c\n\n"]).map(\.data) == ["a\nb\n\nc"])
    }

    @Test func spaceAfterColonIsOptionalAndOnlyOneIsStripped() {
        #expect(parse(["data:nospace\n\ndata:  two\n\n"]).map(\.data) == ["nospace", " two"])
    }

    @Test func eventWithoutDataIsDroppedAndTypeDoesNotLeak() {
        let e = parse(["event: lonely\n\ndata: x\n\n"])
        #expect(e == [SSEEvent(data: "x")])
    }

    @Test func unterminatedFinalEventFlushedOnFinish() {
        #expect(parse(["data: tail"]).map(\.data) == ["tail"])
        #expect(parse(["data: tail\n"]).map(\.data) == ["tail"])
    }

    @Test func bomAndIDAndRetry() {
        let e = parse(["\u{FEFF}retry: 100\nid: 7\ndata: x\n\n"])
        #expect(e == [SSEEvent(data: "x", id: "7")])
        var p = SSEParser()
        var out = p.feed([0xEF])
        out += p.feed([0xBB, 0xBF, 0x64, 0x61, 0x74, 0x61, 0x3A, 0x20, 0x79, 0x0A, 0x0A])
        #expect(out.map(\.data) == ["y"])
    }
}

// MARK: - Anthropic

private let anthropicStream = """
event: message_start
data: {"type":"message_start","message":{"id":"msg_1","role":"assistant","usage":{"input_tokens":25,"output_tokens":1}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: ping
data: {"type": "ping"}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"SELECT"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" 1;"}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{}"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":15}}

event: message_stop
data: {"type":"message_stop"}


"""

@Suite("Anthropic provider")
struct AnthropicProviderTests {
    @Test func requestShape() async throws {
        let t = MockTransport(sse: anthropicStream)
        _ = try await collect(AnthropicProvider(apiKey: "sk-ant-x", transport: t).stream(request))
        let r = try #require(t.requests.last)
        #expect(r.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(r.httpMethod == "POST")
        #expect(r.value(forHTTPHeaderField: "x-api-key") == "sk-ant-x")
        #expect(r.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(r.value(forHTTPHeaderField: "content-type") == "application/json")
        #expect(r.value(forHTTPHeaderField: "Authorization") == nil)
        let b = try body(t)
        #expect(b["model"] as? String == "m-1" && b["max_tokens"] as? Int == 321 && b["stream"] as? Bool == true)
        #expect(b["system"] as? String == "SYS" && b["temperature"] as? Double == 0.2)
        let msgs = try #require(b["messages"] as? [[String: String]])
        #expect(msgs == [["role": "user", "content": "hi"], ["role": "assistant", "content": "yo"], ["role": "user", "content": "again"]])
    }

    @Test func streamsTextAndUsage() async throws {
        for size in [nil, 7, 1] as [Int?] {
            let t = MockTransport(sse: anthropicStream, chunkSize: size)
            let r = try await collect(AnthropicProvider(apiKey: "k", transport: t).stream(request))
            #expect(r.text == "SELECT 1;", "chunk \(String(describing: size))")
            #expect(r.usage == AIUsage(inputTokens: 25, outputTokens: 15))
            #expect(r.doneCount == 1)
        }
    }

    @Test func inStreamErrorEvent() async throws {
        let sse = """
        event: content_block_delta
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"SEL"}}

        event: error
        data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}


        """
        var received = ""
        do {
            for try await e in AnthropicProvider(apiKey: "k", transport: MockTransport(sse: sse)).stream(request) {
                if case .textDelta(let d) = e { received += d }
            }
            Issue.record("expected an error")
        } catch let e as AIError {
            #expect(received == "SEL")
            #expect(e == .server(status: 0, message: "Overloaded"))
        }
        let rl = #"event: error\#ndata: {"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}\#n\#n"#
        await #expect(throws: AIError.rateLimited(retryAfter: nil)) { _ = try await collect(AnthropicProvider(apiKey: "k", transport: MockTransport(sse: rl)).stream(request)) }
    }

    @Test(arguments: [
        (401, #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#, AIError.unauthorized(.anthropic)),
        (403, #"{"type":"error","error":{"type":"permission_error","message":"no"}}"#, AIError.unauthorized(.anthropic)),
        (404, #"{"type":"error","error":{"type":"not_found_error","message":"model: nope"}}"#, AIError.modelNotFound("m-1")),
        (400, #"{"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is too low to access the API."}}"#, AIError.quotaExceeded),
        (529, #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#, AIError.server(status: 529, message: "Overloaded")),
        (500, #"{"type":"error","error":{"type":"api_error","message":"Internal"}}"#, AIError.server(status: 500, message: "Internal")),
        (400, #"{"type":"error","error":{"type":"invalid_request_error","message":"max_tokens: too big"}}"#, AIError.server(status: 400, message: "max_tokens: too big")),
    ] as [(Int, String, AIError)])
    func httpErrors(status: Int, body: String, expected: AIError) async {
        let t = MockTransport(status: status, sse: body)
        await #expect(throws: expected) { _ = try await collect(AnthropicProvider(apiKey: "k", transport: t).stream(request)) }
    }

    @Test func rateLimitCarriesRetryAfter() async {
        let t = MockTransport(status: 429, headers: ["retry-after": "17"], sse: #"{"type":"error","error":{"type":"rate_limit_error","message":"slow"}}"#)
        await #expect(throws: AIError.rateLimited(retryAfter: 17)) { _ = try await collect(AnthropicProvider(apiKey: "k", transport: t).stream(request)) }
    }

    @Test func networkFailureAndEmptyReply() async {
        let t = MockTransport(MockTransport.Canned(error: URLError(.notConnectedToInternet)))
        do { _ = try await collect(AnthropicProvider(apiKey: "k", transport: t).stream(request)); Issue.record("expected error") }
        catch let e as AIError { if case .network = e {} else { Issue.record("wrong error \(e)") } } catch { Issue.record("\(error)") }
        await #expect(throws: AIError.self) { _ = try await collect(AnthropicProvider(apiKey: "k", transport: MockTransport(sse: "")).stream(request)) }
    }

    @Test func missingMessageStopStillFinishesWhenTextArrived() async throws {
        let sse = "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}\n\n"
        let r = try await collect(AnthropicProvider(apiKey: "k", transport: MockTransport(sse: sse)).stream(request))
        #expect(r.text == "ok" && r.doneCount == 1)
    }

    @Test func listModels() async throws {
        let json = #"{"data":[{"type":"model","id":"claude-sonnet-5-5","display_name":"Claude Sonnet 5.5","created_at":"2026-01-01T00:00:00Z"},{"id":"claude-haiku-5-5"}],"has_more":false}"#
        let t = MockTransport(sse: json)
        let models = try await AnthropicProvider(apiKey: "k", transport: t).listModels()
        #expect(models == [AIModelInfo(id: "claude-sonnet-5-5", displayName: "Claude Sonnet 5.5"), AIModelInfo(id: "claude-haiku-5-5")])
        #expect(t.requests.last?.url?.path == "/v1/models")
        #expect(t.requests.last?.value(forHTTPHeaderField: "x-api-key") == "k")
        await #expect(throws: AIError.unauthorized(.anthropic)) {
            _ = try await AnthropicProvider(apiKey: "bad", transport: MockTransport(status: 401, sse: #"{"error":{"type":"authentication_error","message":"x"}}"#)).listModels()
        }
    }
}

// MARK: - OpenAI / OpenRouter

private let openAIStream = """
data: {"id":"1","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}

data: {"id":"1","choices":[{"index":0,"delta":{"content":"SELECT"},"finish_reason":null}]}

data: {"id":"1","choices":[{"index":0,"delta":{"content":" 2"},"finish_reason":null}]}

data: {"id":"1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

data: {"id":"1","choices":[],"usage":{"prompt_tokens":11,"completion_tokens":4,"total_tokens":15}}

data: [DONE]


"""

@Suite("OpenAI providers")
struct OpenAIProviderTests {
    @Test func openAIRequestShape() async throws {
        let t = MockTransport(sse: openAIStream)
        _ = try await collect(OpenAIProvider(apiKey: "sk-1", transport: t).stream(request))
        let r = try #require(t.requests.last)
        #expect(r.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer sk-1")
        let b = try body(t)
        #expect(b["max_completion_tokens"] as? Int == 321 && b["max_tokens"] == nil && b["stream"] as? Bool == true)
        let msgs = try #require(b["messages"] as? [[String: String]])
        #expect(msgs.first == ["role": "system", "content": "SYS"])
        #expect(msgs.count == 4 && msgs.last == ["role": "user", "content": "again"])
        #expect((b["stream_options"] as? [String: Bool])?["include_usage"] == true)
    }

    @Test func openAIStreams() async throws {
        for size in [nil, 5] as [Int?] {
            let r = try await collect(OpenAIProvider(apiKey: "k", transport: MockTransport(sse: openAIStream, chunkSize: size)).stream(request))
            #expect(r.text == "SELECT 2" && r.usage == AIUsage(inputTokens: 11, outputTokens: 4) && r.doneCount == 1)
        }
    }

    @Test func noSystemMessageWhenEmpty() async throws {
        let t = MockTransport(sse: openAIStream)
        _ = try await collect(OpenAIProvider(apiKey: "k", transport: t).stream(AIRequest(system: "", messages: [.user("x")], model: "m")))
        let msgs = try #require(try body(t)["messages"] as? [[String: String]])
        #expect(msgs == [["role": "user", "content": "x"]])
        #expect(try body(t)["temperature"] == nil)
    }

    @Test func openRouterRequestShape() async throws {
        let t = MockTransport(sse: openAIStream)
        let r = try await collect(OpenRouterProvider(apiKey: "or-1", transport: t).stream(request))
        #expect(r.text == "SELECT 2")
        let req = try #require(t.requests.last)
        #expect(req.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer or-1")
        #expect(req.value(forHTTPHeaderField: "HTTP-Referer") == "https://github.com/jeremyhaber/Querywell")
        #expect(req.value(forHTTPHeaderField: "X-Title") == "Querywell")
        #expect(try body(t)["max_tokens"] as? Int == 321)
    }

    @Test func openRouterKeepAliveCommentsAreIgnored() async throws {
        let sse = ": OPENROUTER PROCESSING\n\n" + openAIStream
        let r = try await collect(OpenRouterProvider(apiKey: "k", transport: MockTransport(sse: sse, chunkSize: 3)).stream(request))
        #expect(r.text == "SELECT 2")
    }

    @Test func inStreamErrorObject() async {
        let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"A\"}}]}\n\ndata: {\"error\":{\"message\":\"Provider returned error\",\"code\":502}}\n\n"
        await #expect(throws: AIError.server(status: 502, message: "Provider returned error")) {
            _ = try await collect(OpenRouterProvider(apiKey: "k", transport: MockTransport(sse: sse)).stream(request))
        }
    }

    @Test(arguments: [
        (401, #"{"error":{"message":"Incorrect API key provided","type":"invalid_request_error","code":"invalid_api_key"}}"#, AIError.unauthorized(.openai)),
        (429, #"{"error":{"message":"You exceeded your current quota","type":"insufficient_quota","code":"insufficient_quota"}}"#, AIError.quotaExceeded),
        (404, #"{"error":{"message":"The model `m-1` does not exist","type":"invalid_request_error","code":"model_not_found"}}"#, AIError.modelNotFound("m-1")),
        (500, #"{"error":{"message":"The server had an error","type":"server_error"}}"#, AIError.server(status: 500, message: "The server had an error")),
        (503, "upstream connect error", AIError.server(status: 503, message: "upstream connect error")),
    ] as [(Int, String, AIError)])
    func openAIHttpErrors(status: Int, body: String, expected: AIError) async {
        await #expect(throws: expected) { _ = try await collect(OpenAIProvider(apiKey: "k", transport: MockTransport(status: status, sse: body)).stream(request)) }
    }

    @Test func openRouterHttpErrors() async {
        await #expect(throws: AIError.quotaExceeded) {
            _ = try await collect(OpenRouterProvider(apiKey: "k", transport: MockTransport(status: 402, sse: #"{"error":{"message":"Insufficient credits","code":402}}"#)).stream(request))
        }
        await #expect(throws: AIError.modelNotFound("m-1")) {
            _ = try await collect(OpenRouterProvider(apiKey: "k", transport: MockTransport(status: 404, sse: #"{"error":{"message":"No endpoints found for m-1.","code":404}}"#)).stream(request))
        }
        await #expect(throws: AIError.rateLimited(retryAfter: 3)) {
            _ = try await collect(OpenRouterProvider(apiKey: "k", transport: MockTransport(status: 429, headers: ["Retry-After": "3"], sse: #"{"error":{"message":"Rate limit exceeded","code":429}}"#)).stream(request))
        }
    }

    @Test func openAIModelListIsFilteredToChatModels() async throws {
        let json = """
        {"data":[{"id":"gpt-5","created":300},{"id":"text-embedding-3-small","created":1},{"id":"whisper-1","created":2},{"id":"o3-mini","created":200},
                 {"id":"dall-e-3","created":3},{"id":"gpt-4o-audio-preview","created":4},{"id":"gpt-3.5-turbo-instruct","created":5},{"id":"gpt-4o","created":100},
                 {"id":"omni-moderation-latest","created":6},{"id":"tts-1","created":7},{"id":"chatgpt-4o-latest","created":50},{"id":"gpt-image-1","created":8}]}
        """
        let models = try await OpenAIProvider(apiKey: "k", transport: MockTransport(sse: json)).listModels()
        #expect(models.map(\.id) == ["gpt-5", "o3-mini", "gpt-4o", "chatgpt-4o-latest"])
    }

    @Test func openRouterModelList() async throws {
        let json = #"{"data":[{"id":"openai/gpt-5","name":"OpenAI: GPT-5"},{"id":"anthropic/claude-sonnet-5.5","name":"Anthropic: Claude Sonnet 5.5"}]}"#
        let t = MockTransport(sse: json)
        let models = try await OpenRouterProvider(apiKey: "k", transport: t).listModels()
        #expect(models.map(\.id) == ["anthropic/claude-sonnet-5.5", "openai/gpt-5"])
        #expect(models[0].displayName == "Anthropic: Claude Sonnet 5.5")
        #expect(t.requests.last?.url?.absoluteString == "https://openrouter.ai/api/v1/models")
    }
}

// MARK: - Cancellation, errors, registry, keys

@Suite("AI plumbing")
struct AIPlumbingTests {
    @Test func cancellingTheConsumerStopsTheStream() async {
        // A transport whose body never ends.
        struct Endless: AITransport {
            func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw AIError.cancelled }
            func bytes(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
                (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                 AsyncThrowingStream { c in
                    let t = Task {
                        while !Task.isCancelled {
                            c.yield(Data("data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n".utf8))
                            try? await Task.sleep(for: .milliseconds(5))
                        }
                        c.finish()
                    }
                    c.onTermination = { _ in t.cancel() }
                 })
            }
        }
        let task = Task { () -> Int in
            var n = 0
            for try await _ in OpenAIProvider(apiKey: "k", transport: Endless()).stream(request) { n += 1; if n == 3 { break } }
            return n
        }
        #expect((try? await task.value) == 3)
    }

    @Test func errorMessagesAreUserFacing() {
        #expect(AIError.missingAPIKey(.openai).errorDescription == "No OpenAI API key is set. Add one in Settings → AI.")
        #expect(AIError.unauthorized(.anthropic).errorDescription?.contains("rejected the API key") == true)
        #expect(AIError.rateLimited(retryAfter: 12).errorDescription?.contains("12 seconds") == true)
        #expect(AIError.rateLimited(retryAfter: nil).errorDescription?.contains("Wait a moment") == true)
        #expect(AIError.quotaExceeded.errorDescription?.contains("billing") == true)
        #expect(AIError.modelNotFound("zzz").errorDescription?.contains("zzz") == true)
        #expect(AIError.network("offline").errorDescription?.contains("offline") == true)
        #expect(AIError.server(status: 500, message: "boom").errorDescription?.contains("500") == true)
        #expect(AIError.cancelled.errorDescription == "Cancelled.")
    }

    @Test func registryBuildsTheRightProvider() {
        #expect(AIProviderRegistry.provider(for: .anthropic, apiKey: " k \n").id == .anthropic)
        #expect(AIProviderRegistry.provider(for: .openai, apiKey: "k") is OpenAIProvider)
        #expect(AIProviderRegistry.provider(for: .openrouter, apiKey: "k") is OpenRouterProvider)
        for id in AIProviderID.allCases { #expect(!id.displayName.isEmpty && !id.suggestedModel.isEmpty) }
        #expect(AIProviderID.anthropic.suggestedModel == "claude-sonnet-5-5")
    }

    @Test func registryTrimsTheKey() async throws {
        let t = MockTransport(sse: openAIStream)
        _ = try await collect(AIProviderRegistry.provider(for: .openai, apiKey: "  sk-z\n", transport: t).stream(request))
        #expect(t.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-z")
    }

    @Test func keyStoreUsesKeychainAddressing() throws {
        let secrets = InMemorySecretStore()
        let keys = AIKeyStore(store: secrets)
        #expect(!keys.hasKey(for: .openai))
        #expect(throws: AIError.missingAPIKey(.openai)) { try keys.provider(for: .openai) }
        try keys.setAPIKey("  sk-abc \n", for: .openai)
        #expect(try keys.apiKey(for: .openai) == "sk-abc")
        #expect(try secrets.read(SecretKey(ownerID: SecretKey.globalOwnerID, kind: .aiAPIKey(provider: "openai"))) == "sk-abc")
        #expect(SecretKey(ownerID: SecretKey.globalOwnerID, kind: .aiAPIKey(provider: "openai")).account == "global.ai.openai")
        #expect(try keys.provider(for: .openai).id == .openai)
        #expect(!keys.hasKey(for: .anthropic))
        try keys.setAPIKey("   ", for: .openai)  // blank deletes
        #expect(!keys.hasKey(for: .openai))
        try keys.setAPIKey("k", for: .anthropic)
        try keys.deleteAPIKey(for: .anthropic)
        #expect(try keys.apiKey(for: .anthropic) == nil)
    }
}
