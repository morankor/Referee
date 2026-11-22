import Foundation
import Testing
import RefereeCore
import TestSupport
@testable import LLMKit

/// WP4 "Ollama context" and the Ollama specifics of plan section 5.4.5: `num_ctx`, the "context full" status,
/// availability and locality.
@Suite struct LLMKitOllamaTests {
    @Test func numCtxIsTheRequestsContextWindow() async throws {
        for window in [2_048, 8_192, 32_768] {
            StubURLProtocol.setHandler { _ in Stub.stream(AppendixD.ollama, for: "ollama") }
            let request = LLMRequest(model: "gemma:2b", system: "S", parts: [.text("T")], maxOutputTokens: window / 4, contextWindow: window,
                                     purpose: .review)
            _ = await collect(Harness().provider("ollama").stream(request))
            let options = StubURLProtocol.recordedRequests.first?.jsonBody?["options"]
            #expect(options?["num_ctx"] == .int(window))
            #expect(options?["num_predict"] == .int(window / 4))
        }
    }

    @Test func numCtxFallsBackToTheOverrideThenToAFixedDefault() async throws {
        StubURLProtocol.setHandler { _ in Stub.stream(AppendixD.ollama, for: "ollama") }
        let harness = Harness()
        var settings = Harness.defaultSettings(for: "ollama")
        settings.contextWindowOverride = 12_000
        harness.settings.set("ollama", settings)
        _ = await collect(harness.provider("ollama").stream(Requests.text()))
        settings.contextWindowOverride = nil
        harness.settings.set("ollama", settings)
        _ = await collect(harness.provider("ollama").stream(Requests.text()))
        let windows = StubURLProtocol.recordedRequests.map { $0.jsonBody?["options"]?["num_ctx"] }
        #expect(windows == [.int(12_000), .int(OllamaAdapter.fallbackContextWindow)])
    }

    @Test func theContextFullStatusComesWhenTheCountsSaySo() async throws {
        // D.4 counts 33 prompt and 2 output tokens: 35 ≥ num_ctx − 16 exactly when num_ctx ≤ 51.
        for (window, full) in [(51, true), (50, true), (52, false), (8_192, false)] {
            StubURLProtocol.setHandler { _ in Stub.stream(AppendixD.ollama, for: "ollama") }
            let outcome = await collect(Harness().provider("ollama").stream(Requests.text(contextWindow: window)))
            #expect(outcome.statuses == (full ? [OllamaAdapter.contextFullStatus] : []), "num_ctx \(window)")
            #expect(outcome.finishes == [.finished(.endOfTurn, Usage(inputTokens: 33, outputTokens: 2))])
            if full {
                #expect(outcome.events.suffix(2).first == .status("context window full; input may have been truncated"))   // before .finished
            }
        }
    }

    @Test func availabilityAsksForTheVersionWithATwoSecondTimeout() async throws {
        StubURLProtocol.setHandler { _ in Stub.json(AppendixDVariants.ollamaVersion) }
        #expect(await Harness().provider("ollama").availability() == .ready(detail: "Ollama 0.40.17"))
        let request = try #require(StubURLProtocol.recordedRequests.first)
        #expect(request.url?.absoluteString == "http://127.0.0.1:11434/api/version")
        #expect(request.timeoutInterval == 2)

        StubURLProtocol.setHandler(nil)                                                 // connection refused
        #expect(await Harness().provider("ollama").availability()
                == .needsSetup(reason: "Ollama is not running", hint: "Start the Ollama app or run `ollama serve`."))

        StubURLProtocol.setHandler { _ in Stub.json("oops", status: 500) }
        guard case .unavailable = await Harness().provider("ollama").availability() else {
            Issue.record("a server error should make Ollama unavailable")
            return
        }
    }

    @Test func ollamaIsLocalOnlyOnLoopback() {
        let cases: [(String?, Bool, String, String)] = [
            (nil, true, "127.0.0.1:11434", "Processed on this Mac; nothing is sent."),
            ("http://localhost:11434", true, "localhost:11434", "Processed on this Mac; nothing is sent."),
            ("http://[::1]:11434", true, "[::1]:11434", "Processed on this Mac; nothing is sent."),
            ("http://127.0.0.1:8080", true, "127.0.0.1:8080", "Processed on this Mac; nothing is sent."),
            ("http://192.168.1.5:11434", false, "192.168.1.5:11434", "Sent to 192.168.1.5 on your network."),
            ("gpu-box.local:11434", false, "gpu-box.local:11434", "Sent to gpu-box.local on your network."),
            ("not a url at all", false, "not a url at all", "Sent to not a url at all on your network."),
        ]
        for (baseURL, local, destination, note) in cases {
            var settings = Harness.defaultSettings(for: "ollama")
            settings.baseURL = baseURL
            let descriptor = OllamaAdapter().descriptor(settings: settings)
            #expect(descriptor.isLocal == local, "\(String(describing: baseURL))")
            #expect(descriptor.destination == destination)
            #expect(descriptor.retentionNote == note)
        }
    }

    @Test func noKeyIsNeededAndNoneIsSent() async throws {
        StubURLProtocol.setHandler { _ in Stub.stream(AppendixD.ollama, for: "ollama") }
        let outcome = await collect(Harness(keys: [:]).provider("ollama").stream(Requests.text(contextWindow: 2_048)))
        #expect(outcome.finishes.count == 1)
        let headers = StubURLProtocol.recordedRequests.first?.allHTTPHeaderFields ?? [:]
        #expect(!headers.keys.contains { ["authorization", "x-api-key", "x-goog-api-key"].contains($0.lowercased()) })
    }
}

extension Tag {
    /// Talks to a real local service (plan section 3.5); skipped when it does not answer.
    @Tag static var live: Self
}

/// WP4 "live Ollama": only when the local server answers; a 16-token chat with the smallest installed model.
@Suite struct LLMKitLiveOllamaTests {
    static let base = "http://127.0.0.1:11434"

    /// `/api/version` answers within two seconds. The only real connection any LLMKit test makes, and only to this Mac.
    static func ollamaIsRunning() async -> Bool {
        guard let url = URL(string: base + "/api/version") else { return false }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    @Test(.tags(.live), .enabled("Ollama answers at 127.0.0.1:11434") { await LLMKitLiveOllamaTests.ollamaIsRunning() })
    func aSixteenTokenChatWithTheSmallestModelStreamsADelta() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        // The smallest installed model that can complete text, by size on disk.
        let tagsURL = try #require(URL(string: Self.base + "/api/tags"))
        let (data, _) = try await session.data(from: tagsURL)
        let models = try #require(JSONValue.parse(data)?["models"]?.arrayValue)
        let completing = models.filter { model in
            model["capabilities"]?.arrayValue.map { $0.contains("completion") } ?? true
        }
        let smallest = try #require(completing.min { ($0["size"]?.intValue ?? .max) < ($1["size"]?.intValue ?? .max) }?["name"]?.stringValue)

        var defaults = try #require(DefaultSettings.make().providers["ollama"])     // {"think": false}
        defaults.model = smallest
        let settings = defaults
        let environment = ProviderEnvironment(settings: { _ in settings }, secrets: InMemorySecretStore(), urlSession: session,
                                              processEnvironment: [:])
        let provider = try #require(LLMKitFactory.makeProviders(environment: environment).first { $0.descriptor.id == "ollama" })
        #expect(provider.descriptor.isLocal)
        guard case .ready(let detail) = await provider.availability() else {
            Issue.record("Ollama answered /api/version but is not ready")
            return
        }
        #expect(detail.hasPrefix("Ollama "))
        #expect(try await provider.listModels().contains { $0.id == smallest })

        let request = LLMRequest(system: "Reply with exactly: OK", parts: [.text("OK?")], maxOutputTokens: 16, contextWindow: 2_048,
                                 purpose: .ping)
        let outcome = await collect(provider.stream(request))
        #expect(outcome.error == nil, "\(String(describing: outcome.error))")
        #expect(!outcome.deltas.isEmpty, "model \(smallest) streamed no delta")
        #expect(outcome.finishes.count == 1)
        if case .finished(_, let usage)? = outcome.finishes.first {
            #expect((usage?.outputTokens ?? 0) <= 16)
        }
    }
}
