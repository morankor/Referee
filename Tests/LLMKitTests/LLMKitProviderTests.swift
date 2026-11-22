import Foundation
import Testing
import RefereeCore
import TestSupport
@testable import LLMKit

/// The providers as the app sees them: roster, descriptors, availability, and Gemini's `/v1beta` fallback.
@Suite struct LLMKitProviderTests {
    @Test func theFactoryMakesTheRosterOfSection52() {
        StubURLProtocol.setHandler(nil)
        let providers = LLMKitFactory.makeProviders(environment: Harness().environment)
        let descriptors = providers.map(\.descriptor)
        #expect(descriptors.map(\.id) == ["anthropic-api", "openai-api", "gemini-api", "xai-api", "ollama"])
        #expect(descriptors.map(\.displayName) == ["Anthropic API", "OpenAI API", "Gemini API", "xAI API", "Ollama (local)"])
        #expect(descriptors.map(\.vendor) == ["Anthropic", "OpenAI", "Google", "xAI", "Ollama"])
        #expect(descriptors.map(\.destination) == ["api.anthropic.com", "api.openai.com", "generativelanguage.googleapis.com", "api.x.ai",
                                                   "127.0.0.1:11434"])
        #expect(descriptors.map(\.supportsNativePDF) == [true, true, true, false, false])
        #expect(descriptors.map(\.isLocal) == [false, false, false, false, true])
        #expect(descriptors.map(\.authMode) == [.apiKey, .apiKey, .apiKey, .apiKey, .local])
        #expect(descriptors.allSatisfy { $0.streaming == .token && !$0.isExperimental && $0.pdfDeliveryNote == nil && $0.maxPromptBytes == nil })
        #expect(descriptors.map(\.retentionNote) == [
            "Sent to Anthropic under your API account's data terms.",
            "Sent with store=false; not kept for retrieval by the API.",
            "Sent with store=false.",
            "Sent to an endpoint that does not store requests.",
            "Processed on this Mac; nothing is sent.",
        ])
    }

    @Test func theDestinationFollowsTheBaseURL() {
        StubURLProtocol.setHandler(nil)
        let harness = Harness()
        var settings = Harness.defaultSettings(for: "anthropic-api")
        settings.baseURL = "https://gateway.example.invalid:8443/anthropic"
        harness.settings.set("anthropic-api", settings)
        #expect(harness.provider("anthropic-api").descriptor.destination == "gateway.example.invalid:8443")
        settings.baseURL = ""
        harness.settings.set("anthropic-api", settings)
        #expect(harness.provider("anthropic-api").descriptor.destination == "api.anthropic.com")
    }

    @Test func anAPIProviderIsReadyWhenAKeyIsStoredAndSendsNothingToFindOut() async {
        StubURLProtocol.setHandler { _ in Stub.json("{}") }
        for id in ["anthropic-api", "openai-api", "gemini-api", "xai-api"] {
            #expect(await Harness().provider(id).availability() == .ready(detail: "Key set"))
            guard case .needsSetup(let reason, _) = await Harness(keys: [:]).provider(id).availability() else {
                Issue.record("\(id) without a key should need setting up")
                continue
            }
            #expect(reason == "No API key")
            let unreadable = Harness()
            unreadable.secrets.failReads = true
            guard case .needsSetup = await unreadable.provider(id).availability() else {
                Issue.record("\(id) with an unreadable key should need setting up")
                continue
            }
        }
        #expect(StubURLProtocol.recordedRequests.isEmpty)
    }

    @Test func geminiMovesToV1BetaOnceWhenV1InteractionsIsNotFound() async throws {
        StubURLProtocol.setHandler { request in
            request.url?.path == "/v1/interactions"
                ? Stub.json(#"{"error":{"code":"not_found","message":"Method not found."}}"#, status: 404)
                : Stub.stream(AppendixD.gemini, for: "gemini-api")
        }
        let provider = Harness().provider("gemini-api")
        let first = await collect(provider.stream(Requests.text()))
        #expect(first.error == nil)
        #expect(first.text == "1, 2, 3, 4, 5")
        let second = await collect(provider.stream(Requests.text()))       // remembered: straight to /v1beta
        #expect(second.finishes.count == 1)
        let paths = StubURLProtocol.recordedRequests.map { $0.url?.path }
        #expect(paths == ["/v1/interactions", "/v1beta/interactions", "/v1beta/interactions"])
        #expect(StubURLProtocol.recordedRequests.allSatisfy { $0.jsonBody?["store"] == false && $0.timeoutInterval == 600 })
    }

    @Test func aModelThatIsNotFoundDoesNotMoveGemini() async throws {
        StubURLProtocol.setHandler { _ in Stub.json(#"{"error":{"code":"model_not_found","message":"No model m1."}}"#, status: 404) }
        let outcome = await collect(Harness().provider("gemini-api").stream(Requests.text()))
        #expect(outcome.llmError == .modelNotFound("No model m1."))
        #expect(StubURLProtocol.recordedRequests.map { $0.url?.path } == ["/v1/interactions"])
    }

    @Test func eachProviderReadsOnlyItsOwnKey() async throws {
        StubURLProtocol.setHandler { request in
            let id: ProviderID
            switch request.url?.host {
            case "api.anthropic.com": id = "anthropic-api"
            case "api.openai.com": id = "openai-api"
            case "api.x.ai": id = "xai-api"
            default: id = "gemini-api"
            }
            return Stub.stream(Stub.appendixD(id), for: id)
        }
        let harness = Harness()
        for id in ["anthropic-api", "openai-api", "gemini-api", "xai-api"] {
            _ = await collect(harness.provider(id).stream(Requests.text()))
        }
        let sent = StubURLProtocol.recordedRequests
        #expect(sent.count == 4)
        for (request, id) in zip(sent, ["anthropic-api", "openai-api", "gemini-api", "xai-api"]) {
            let key = Harness.keys[id] ?? "?"
            let headers = (request.allHTTPHeaderFields ?? [:]).values.joined(separator: " ")
            #expect(headers.contains(key), "\(id) sends its own key")
            for (otherID, otherKey) in Harness.keys where otherID != id {
                #expect(!headers.contains(otherKey), "\(id) must not send the key of \(otherID)")
            }
            #expect(!String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains(key), "keys go in headers only")
        }
    }
}
