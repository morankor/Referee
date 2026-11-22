import Foundation
import Testing
import RefereeCore
import TestSupport
@testable import LLMKit

/// WP4 "request shape, per provider": URL, method, headers and JSON body exactly as in plan section 5.4.
@Suite struct LLMKitRequestShapeTests {
    /// Sends `request` through the provider, answered with the provider's Appendix D stream, and returns what was sent.
    private func send(_ request: LLMRequest, to id: ProviderID, settings: ProviderSettings? = nil) async throws -> URLRequest {
        StubURLProtocol.setHandler { _ in Stub.stream(Stub.appendixD(id), for: id) }
        let harness = Harness()
        if let settings { harness.settings.set(id, settings) }
        let outcome = await collect(harness.provider(id).stream(request))
        #expect(outcome.error == nil, "\(id): \(String(describing: outcome.error))")
        #expect(outcome.finishes.count == 1)
        let recorded = StubURLProtocol.recordedRequests
        #expect(recorded.count == 1)
        return try #require(recorded.first)
    }

    private func settings(_ id: ProviderID, _ change: (inout ProviderSettings) -> Void) -> ProviderSettings {
        var settings = Harness.defaultSettings(for: id)
        change(&settings)
        return settings
    }

    private var base64: String { Requests.pdfBytes.base64EncodedString() }

    // ---- Anthropic (5.4.1) ----

    @Test func anthropicTextOnly() async throws {
        let sent = try await send(Requests.text(), to: "anthropic-api")
        #expect(sent.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "x-api-key") == "test-key-anthropic-0001")
        #expect(sent.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        #expect(sent.value(forHTTPHeaderField: "content-type") == "application/json")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(sent.timeoutInterval == 600)
        #expect(sent.jsonBody == json(#"""
            {"model":"m1","max_tokens":16000,"stream":true,
             "system":[{"type":"text","text":"SYSTEM PROMPT"}],
             "messages":[{"role":"user","content":[{"type":"text","text":"TASK TEXT"}]}]}
            """#))
    }

    @Test func anthropicPDFTextAndCacheBoundary() async throws {
        let sent = try await send(Requests.pdfThenTask(), to: "anthropic-api")
        #expect(sent.jsonBody == json(#"""
            {"model":"m1","max_tokens":16000,"stream":true,
             "system":[{"type":"text","text":"SYSTEM PROMPT"}],
             "messages":[{"role":"user","content":[
                {"type":"document","source":{"type":"base64","media_type":"application/pdf","data":"\#(base64)"},
                 "cache_control":{"type":"ephemeral"}},
                {"type":"text","text":"TASK TEXT"}]}]}
            """#))
        let body = try #require(sent.jsonBody)
        for forbidden in ["temperature", "top_p", "top_k", "thinking"] { #expect(body[forbidden] == nil, "\(forbidden)") }
        #expect(!String(decoding: sent.httpBody ?? Data(), as: UTF8.self).contains("Real Name"))     // the file name is never sent
    }

    @Test func anthropicCacheBoundaryMarksTheBlockBeforeItAndOnlyOnce() async throws {
        var request = Requests.paperThenTask()
        request.parts += [.cacheBoundary, .text("MORE")]
        let sent = try await send(request, to: "anthropic-api")
        #expect(sent.jsonBody?["messages"]?[0]?["content"] == json(#"""
            [{"type":"text","text":"PAPER TEXT","cache_control":{"type":"ephemeral"}},{"type":"text","text":"TASK TEXT"},
             {"type":"text","text":"MORE"}]
            """#))
    }

    @Test func anthropicMaxTokens() async throws {
        // The request's value wins; then the setting; then the model's own limit (from the cached list), capped at 32,000.
        #expect(try await send(Requests.text(maxOutputTokens: 500), to: "anthropic-api").jsonBody?["max_tokens"] == 500)
        let configured = settings("anthropic-api") { $0.maxOutputTokens = 1_234 }
        #expect(try await send(Requests.text(), to: "anthropic-api", settings: configured).jsonBody?["max_tokens"] == 1_234)
        let cached = settings("anthropic-api") {
            $0.cachedModels = [ModelInfo(id: "m1", displayName: "M1", contextWindow: 1_000_000, maxOutputTokens: 128_000)]
        }
        #expect(try await send(Requests.text(), to: "anthropic-api", settings: cached).jsonBody?["max_tokens"] == 32_000)
        let small = settings("anthropic-api") { $0.cachedModels = [ModelInfo(id: "m1", displayName: "M1", maxOutputTokens: 8_192)] }
        #expect(try await send(Requests.text(), to: "anthropic-api", settings: small).jsonBody?["max_tokens"] == 8_192)
    }

    // ---- OpenAI (5.4.2) ----

    @Test func openAITextOnly() async throws {
        let sent = try await send(Requests.text(), to: "openai-api")
        #expect(sent.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-openai-0001")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(sent.timeoutInterval == 600)
        #expect(sent.jsonBody == json(#"""
            {"model":"m1","instructions":"SYSTEM PROMPT","stream":true,"store":false,
             "input":[{"role":"user","content":[{"type":"input_text","text":"TASK TEXT"}]}]}
            """#))
    }

    @Test func openAIPDFTextAndCacheBoundary() async throws {
        let sent = try await send(Requests.pdfThenTask(), to: "openai-api")
        #expect(sent.jsonBody == json(#"""
            {"model":"m1","instructions":"SYSTEM PROMPT","stream":true,"store":false,
             "input":[{"role":"user","content":[
                {"type":"input_file","filename":"manuscript.pdf","file_data":"data:application/pdf;base64,\#(base64)"},
                {"type":"input_text","text":"TASK TEXT"}]}]}
            """#))
        #expect(!String(decoding: sent.httpBody ?? Data(), as: UTF8.self).contains("Real Name"))
    }

    @Test func openAIMaxOutputTokensOnlyWhenSet() async throws {
        #expect(try await send(Requests.text(), to: "openai-api").jsonBody?["max_output_tokens"] == nil)
        #expect(try await send(Requests.text(maxOutputTokens: 700), to: "openai-api").jsonBody?["max_output_tokens"] == 700)
    }

    // ---- xAI (5.4.3) ----

    @Test func xAITextOnly() async throws {
        let sent = try await send(Requests.paperThenTask(), to: "xai-api")
        #expect(sent.url?.absoluteString == "https://api.x.ai/v1/chat/completions")
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-xai-0001")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(sent.timeoutInterval == 600)
        #expect(sent.jsonBody == json(#"""
            {"model":"m1","stream":true,
             "messages":[{"role":"system","content":"SYSTEM PROMPT"},{"role":"user","content":"PAPER TEXT\n\nTASK TEXT"}]}
            """#))
        #expect(try await send(Requests.text(maxOutputTokens: 900), to: "xai-api").jsonBody?["max_tokens"] == 900)
    }

    @Test func xAIRefusesAPDFWithoutSendingAnything() async throws {
        StubURLProtocol.setHandler { _ in Stub.stream(AppendixD.xai, for: "xai-api") }
        let outcome = await collect(Harness().provider("xai-api").stream(Requests.pdfThenTask()))
        #expect(ErrorKind(outcome.error) == .invalidRequest)
        #expect(StubURLProtocol.recordedRequests.isEmpty)
    }

    // ---- Gemini (5.4.4) ----

    @Test func geminiTextOnly() async throws {
        let sent = try await send(Requests.text(), to: "gemini-api")
        #expect(sent.url?.absoluteString == "https://generativelanguage.googleapis.com/v1/interactions")
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "x-goog-api-key") == "test-key-gemini-0001")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(sent.timeoutInterval == 600)
        #expect(sent.jsonBody == json(#"""
            {"model":"m1","system_instruction":"SYSTEM PROMPT","stream":true,"store":false,
             "input":[{"type":"text","text":"TASK TEXT"}]}
            """#))
    }

    @Test func geminiPDFTextAndCacheBoundary() async throws {
        let sent = try await send(Requests.pdfThenTask(), to: "gemini-api")
        #expect(sent.jsonBody == json(#"""
            {"model":"m1","system_instruction":"SYSTEM PROMPT","stream":true,"store":false,
             "input":[{"type":"document","data":"\#(base64)","mime_type":"application/pdf"},{"type":"text","text":"TASK TEXT"}]}
            """#))
        #expect(try await send(Requests.text(maxOutputTokens: 300), to: "gemini-api").jsonBody?["generation_config"]
                == json(#"{"max_output_tokens":300}"#))
    }

    // ---- Ollama (5.4.5) ----

    @Test func ollamaWithTheDefaultSettingsSendsThinkFalse() async throws {
        var defaults = try #require(DefaultSettings.make().providers["ollama"])
        defaults.model = "gemma:2b"
        let request = LLMRequest(system: Requests.system, parts: [.text(Requests.paper), .cacheBoundary, .text(Requests.task)],
                                 maxOutputTokens: 4_096, contextWindow: 8_192, purpose: .review)
        let sent = try await send(request, to: "ollama", settings: defaults)
        #expect(sent.url?.absoluteString == "http://127.0.0.1:11434/api/chat")
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(sent.timeoutInterval == 600)
        #expect(sent.jsonBody == json(#"""
            {"model":"gemma:2b","stream":true,"keep_alive":"10m","think":false,
             "options":{"num_ctx":8192,"num_predict":4096,"temperature":0.2},
             "messages":[{"role":"system","content":"SYSTEM PROMPT"},{"role":"user","content":"PAPER TEXT\n\nTASK TEXT"}]}
            """#))
    }

    @Test func ollamaWithoutExtraBodyJSONHasNoThinkField() async throws {
        let plain = settings("ollama") { $0.extraBodyJSON = nil }
        let body = try #require(try await send(Requests.text(contextWindow: 2_048), to: "ollama", settings: plain).jsonBody)
        #expect(body["think"] == nil)                     // "think": false comes from the settings, not from the adapter
        #expect(body["options"]?["num_predict"] == nil)   // only when a limit is given
    }

    @Test func ollamaRefusesAPDFWithoutSendingAnything() async throws {
        StubURLProtocol.setHandler { _ in Stub.stream(AppendixD.ollama, for: "ollama") }
        let outcome = await collect(Harness().provider("ollama").stream(Requests.pdfThenTask()))
        #expect(ErrorKind(outcome.error) == .invalidRequest)
        #expect(StubURLProtocol.recordedRequests.isEmpty)
    }

    // ---- shared rules (5.3) ----

    @Test func extraBodyJSONKeysAreMergedLastAndOverwrite() async throws {
        let extra = settings("openai-api") { $0.extraBodyJSON = #"{"reasoning":{"effort":"low"},"max_output_tokens":99,"service_tier":"flex"}"# }
        let body = try #require(try await send(Requests.text(maxOutputTokens: 5), to: "openai-api", settings: extra).jsonBody)
        #expect(body["reasoning"] == json(#"{"effort":"low"}"#))
        #expect(body["max_output_tokens"] == 99)          // top-level keys overwrite
        #expect(body["service_tier"] == "flex")
        #expect(body["store"] == false)

        let keepAlive = settings("ollama") { $0.extraBodyJSON = #"{"keep_alive":"1h","think":true}"# }
        let ollama = try #require(try await send(Requests.text(contextWindow: 2_048), to: "ollama", settings: keepAlive).jsonBody)
        #expect(ollama["keep_alive"] == "1h")
        #expect(ollama["think"] == true)
    }

    @Test(arguments: ["not json", "[1, 2]", "\"text\"", "", "{\"unclosed\": "])
    func extraBodyJSONThatIsNotAnObjectIsIgnored(_ extra: String) async throws {
        let plain = try await send(Requests.text(), to: "anthropic-api")
        let odd = try await send(Requests.text(), to: "anthropic-api", settings: settings("anthropic-api") { $0.extraBodyJSON = extra })
        #expect(odd.jsonBody == plain.jsonBody)
    }

    @Test func theBaseURLReplacesSchemeHostAndPortOfEveryEndpoint() async throws {
        let cases: [(ProviderID, String, String)] = [
            ("anthropic-api", "http://127.0.0.1:8080", "http://127.0.0.1:8080/v1/messages"),
            ("openai-api", "https://proxy.example.invalid:8443/ignored/path", "https://proxy.example.invalid:8443/v1/responses"),
            ("gemini-api", "https://gemini.example.invalid", "https://gemini.example.invalid/v1/interactions"),
            ("xai-api", "  https://xai.example.invalid  ", "https://xai.example.invalid/v1/chat/completions"),
            ("ollama", "192.168.1.5:11434", "http://192.168.1.5:11434/api/chat"),
        ]
        for (id, baseURL, expected) in cases {
            let sent = try await send(Requests.text(contextWindow: 2_048), to: id, settings: settings(id) { $0.baseURL = baseURL })
            #expect(sent.url?.absoluteString == expected)
            #expect(sent.timeoutInterval == 600)
        }
    }

    @Test func aBaseURLThatIsNotAnAddressFailsWithoutARequest() async throws {
        StubURLProtocol.setHandler { _ in Stub.stream(AppendixD.anthropic, for: "anthropic-api") }
        let harness = Harness()
        harness.settings.set("anthropic-api", settings("anthropic-api") { $0.baseURL = "ftp://files.example.invalid" })
        let outcome = await collect(harness.provider("anthropic-api").stream(Requests.text()))
        #expect(ErrorKind(outcome.error) == .invalidRequest)
        #expect(StubURLProtocol.recordedRequests.isEmpty)
    }

    @Test(arguments: ["anthropic-api", "openai-api", "gemini-api", "xai-api"])
    func noKeyIsNotConfiguredWithoutARequest(_ id: ProviderID) async throws {
        StubURLProtocol.setHandler { _ in Stub.stream(Stub.appendixD(id), for: id) }
        let harness = Harness(keys: [:])
        let outcome = await collect(harness.provider(id, retry: .standard).stream(Requests.text()))
        #expect(ErrorKind(outcome.error) == .notConfigured)
        #expect(outcome.events.isEmpty)
        do {
            _ = try await harness.provider(id).listModels()
            Issue.record("listModels should have failed")
        } catch {
            #expect(ErrorKind(error) == .notConfigured)
        }
        // A key of spaces is no key either.
        let blank = Harness(keys: [id: "   \n"])
        #expect(ErrorKind(await collect(blank.provider(id).stream(Requests.text())).error) == .notConfigured)
        #expect(StubURLProtocol.recordedRequests.isEmpty)
    }

    @Test func aKeyThatCannotBeReadIsNotConfiguredWithoutARequest() async throws {
        StubURLProtocol.setHandler { _ in Stub.stream(AppendixD.anthropic, for: "anthropic-api") }
        let harness = Harness()
        harness.secrets.failReads = true
        let outcome = await collect(harness.provider("anthropic-api").stream(Requests.text()))
        #expect(ErrorKind(outcome.error) == .notConfigured)
        #expect(StubURLProtocol.recordedRequests.isEmpty)
    }

    @Test func noModelIsNotConfiguredWithoutARequest() async throws {
        StubURLProtocol.setHandler { _ in Stub.stream(AppendixD.openai, for: "openai-api") }
        let harness = Harness()
        harness.settings.set("openai-api", settings("openai-api") { $0.model = nil })
        let outcome = await collect(harness.provider("openai-api").stream(Requests.text(model: nil)))
        #expect(ErrorKind(outcome.error) == .notConfigured)
        #expect(StubURLProtocol.recordedRequests.isEmpty)
        // With a model in the settings and none in the request, the setting is used.
        harness.settings.set("openai-api", settings("openai-api") { $0.model = "from-settings" })
        _ = await collect(harness.provider("openai-api").stream(Requests.text(model: nil)))
        #expect(StubURLProtocol.recordedRequests.first?.jsonBody?["model"] == "from-settings")
    }

    @Test func theStreamIsColdAndReadsSettingsWhenIterated() async throws {
        StubURLProtocol.setHandler { _ in Stub.stream(AppendixD.anthropic, for: "anthropic-api") }
        let harness = Harness()
        let stream = harness.provider("anthropic-api").stream(Requests.text(model: nil))
        try await Task.sleep(for: .milliseconds(50))
        #expect(StubURLProtocol.recordedRequests.isEmpty)          // nothing is sent before the stream is iterated
        harness.settings.set("anthropic-api", settings("anthropic-api") { $0.model = "changed-later" })
        let outcome = await collect(stream)
        #expect(outcome.finishes.count == 1)
        #expect(StubURLProtocol.recordedRequests.first?.jsonBody?["model"] == "changed-later")
    }

    @Test func everyRequestIsLoggedWithItsSizeAndNothingElse() async throws {
        final class Seen: @unchecked Sendable {
            let lock = NSLock()
            var fields: [[String: LogValue]] = []
        }
        let seen = Seen()
        let sink = Log.addTestSink { name, fields in
            if name == "llm.request" { seen.lock.withLock { seen.fields.append(fields) } }
        }
        defer { Log.removeTestSink(sink) }
        _ = try await send(Requests.pdfThenTask(), to: "gemini-api")
        let events = seen.lock.withLock { seen.fields }
        #expect(!events.isEmpty)
        // Other tests log the same event at the same time, so only what holds for every event is asserted.
        for fields in events {
            #expect(Set(fields.keys) == ["provider", "bytes", "pdf"])
        }
        #expect(events.contains { $0["provider"] == .id("gemini-api") && $0["pdf"] == .bool(true) })
    }
}
