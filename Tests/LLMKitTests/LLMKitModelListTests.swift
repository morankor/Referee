import Foundation
import Testing
import RefereeCore
import TestSupport
@testable import LLMKit

/// WP4 "models": each vendor's list JSON → the expected `ModelInfo` (context window, PDF support, filters, pagination
/// across two pages).
@Suite struct LLMKitModelListTests {
    private func query(_ request: URLRequest?) -> [String: String] {
        guard let url = request?.url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [:] }
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
    }

    @Test func anthropicFollowsHasMoreWithAfterID() async throws {
        StubURLProtocol.setHandler { request in
            let page2 = request.url?.query?.contains("after_id=m") == true
            return Stub.json(page2 ? AppendixDVariants.anthropicModelsPage2 : AppendixDVariants.anthropicModelsPage1)
        }
        let models = try await Harness().provider("anthropic-api").listModels()
        #expect(models == [
            ModelInfo(id: "m", displayName: "M", contextWindow: 1_000_000, maxOutputTokens: 128_000, supportsPDFInput: true),
            ModelInfo(id: "small", displayName: "Small", contextWindow: 200_000, maxOutputTokens: 64_000, supportsPDFInput: false),
            ModelInfo(id: "legacy", displayName: "Legacy"),
        ])
        let sent = StubURLProtocol.recordedRequests
        #expect(sent.count == 2)
        #expect(sent.map { $0.url?.path } == ["/v1/models", "/v1/models"])
        #expect(query(sent.first) == ["limit": "1000"])
        #expect(query(sent.last) == ["limit": "1000", "after_id": "m"])
        #expect(sent.allSatisfy { $0.httpMethod == "GET" && $0.timeoutInterval == 30 })
        #expect(sent.allSatisfy { $0.value(forHTTPHeaderField: "x-api-key") == "test-key-anthropic-0001" })
        #expect(sent.allSatisfy { $0.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21" })
        #expect(sent.first?.url?.host == "api.anthropic.com")
    }

    /// Settings' "Show all" goes through the protocol (Gate 1): the provider's own implementation answers, not the
    /// protocol's default, which would apply the filter.
    @Test func showAllReachesTheProviderThroughTheProtocol() async throws {
        StubURLProtocol.setHandler { _ in Stub.json(AppendixDVariants.openaiModels) }
        let provider: any LLMProvider = Harness().provider("openai-api")
        #expect(try await provider.listModels(includeHidden: false).count == 3)
        #expect(try await provider.listModels(includeHidden: true).count == 15)
    }

    @Test func openAIIsSortedNewestFirstAndFiltered() async throws {
        StubURLProtocol.setHandler { _ in Stub.json(AppendixDVariants.openaiModels) }
        let provider = Harness().provider("openai-api")
        let models = try await provider.listModels()
        #expect(models == [ModelInfo(id: "newest", displayName: "newest"), ModelInfo(id: "middle", displayName: "middle"),
                           ModelInfo(id: "x", displayName: "x")])
        #expect(models.allSatisfy { $0.contextWindow == nil && $0.supportsPDFInput == nil })
        let request = try #require(StubURLProtocol.recordedRequests.first)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-openai-0001")
        #expect(request.timeoutInterval == 30)

        // "Show all" turns the filter off; the order stays newest first.
        let all = try await provider.listModels(includeHidden: true)
        #expect(all.count == 15)
        #expect(all.first?.id == "sora-2")
        #expect(all.last?.id == "whisper-1")
    }

    @Test func geminiFollowsNextPageTokenStripsThePrefixAndFilters() async throws {
        StubURLProtocol.setHandler { request in
            let page2 = request.url?.query?.contains("pageToken=t") == true
            return Stub.json(page2 ? AppendixDVariants.geminiModelsPage2 : AppendixDVariants.geminiModelsPage1)
        }
        let provider = Harness().provider("gemini-api")
        let models = try await provider.listModels()
        #expect(models == [
            ModelInfo(id: "m", displayName: "M", contextWindow: 1_048_576, maxOutputTokens: 65_536),
            ModelInfo(id: "flash", displayName: "Flash", contextWindow: 1_048_576, maxOutputTokens: 8_192),
        ])
        let sent = StubURLProtocol.recordedRequests
        #expect(sent.count == 2)
        #expect(query(sent.first) == ["pageSize": "1000"])
        #expect(query(sent.last) == ["pageSize": "1000", "pageToken": "t"])
        #expect(sent.allSatisfy { $0.url?.path == "/v1/models" && $0.timeoutInterval == 30 })
        #expect(sent.allSatisfy { $0.value(forHTTPHeaderField: "x-goog-api-key") == "test-key-gemini-0001" })

        let all = try await provider.listModels(includeHidden: true)
        #expect(all.map(\.id) == ["m", "text-embedding-004", "flash", "flash-tts", "flash-live", "veo-3", "flash-image"])
    }

    @Test func xAIReadsTheContextLength() async throws {
        StubURLProtocol.setHandler { _ in Stub.json(AppendixDVariants.xaiModels) }
        let models = try await Harness().provider("xai-api").listModels()
        #expect(models == [ModelInfo(id: "x", displayName: "x", contextWindow: 256_000), ModelInfo(id: "y", displayName: "y", contextWindow: 131_072)])
        let request = try #require(StubURLProtocol.recordedRequests.first)
        #expect(request.url?.absoluteString == "https://api.x.ai/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-xai-0001")
        #expect(request.timeoutInterval == 30)
    }

    @Test func ollamaReadsTagsAsksShowWhenTheContextIsMissingAndHidesNonCompletionModels() async throws {
        StubURLProtocol.setHandler { request in
            switch request.url?.path {
            case "/api/tags": return Stub.json(AppendixDVariants.ollamaTags)
            case "/api/show": return Stub.json(AppendixDVariants.ollamaShow)
            default: return nil
            }
        }
        let models = try await Harness().provider("ollama").listModels()
        #expect(models == [ModelInfo(id: "gemma4:e4b", displayName: "gemma4:e4b", contextWindow: 131_072),
                           ModelInfo(id: "phi4:latest", displayName: "phi4:latest", contextWindow: 16_384)])
        let sent = StubURLProtocol.recordedRequests
        #expect(sent.map { $0.url?.absoluteString } == ["http://127.0.0.1:11434/api/tags", "http://127.0.0.1:11434/api/show"])
        #expect(sent.last?.httpMethod == "POST")
        #expect(sent.last?.jsonBody == json(#"{"model":"phi4:latest"}"#))
        #expect(sent.allSatisfy { $0.timeoutInterval == 30 && $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    @Test func anOllamaModelWhoseShowFailsIsListedWithoutAContextWindow() async throws {
        StubURLProtocol.setHandler { request in
            request.url?.path == "/api/tags" ? Stub.json(AppendixDVariants.ollamaTags) : Stub.json(#"{"error":"boom"}"#, status: 500)
        }
        let models = try await Harness().provider("ollama").listModels()
        #expect(models.map(\.id) == ["gemma4:e4b", "phi4:latest"])
        #expect(models.last?.contextWindow == nil)
    }

    @Test func listsHonourTheBaseURL() async throws {
        StubURLProtocol.setHandler { _ in Stub.json(AppendixDVariants.xaiModels) }
        let harness = Harness()
        var settings = Harness.defaultSettings(for: "xai-api")
        settings.baseURL = "https://proxy.example.invalid:9000"
        harness.settings.set("xai-api", settings)
        _ = try await harness.provider("xai-api").listModels()
        #expect(StubURLProtocol.recordedRequests.first?.url?.absoluteString == "https://proxy.example.invalid:9000/v1/models")
    }

    @Test func listFailuresAreMappedLikeStreamFailures() async throws {
        StubURLProtocol.setHandler { _ in Stub.json(AppendixDVariants.anthropicHTTPError, status: 401) }
        do {
            _ = try await Harness().provider("anthropic-api").listModels()
            Issue.record("listModels should have failed")
        } catch {
            #expect(error as? LLMError == .auth("invalid x-api-key"))
        }
        StubURLProtocol.setHandler { _ in Stub.json("<html>not json</html>") }
        do {
            _ = try await Harness().provider("openai-api").listModels()
            Issue.record("listModels should have failed")
        } catch {
            #expect(error as? LLMError == .malformedResponse("the model list could not be read"))
        }
        StubURLProtocol.setHandler(nil)
        do {
            _ = try await Harness().provider("ollama").listModels()
            Issue.record("listModels should have failed")
        } catch {
            #expect(error as? LLMError == .notConfigured("Ollama is not running"))
        }
    }

    @Test func aVendorThatRepeatsItsPageTokenCannotKeepTheAppAsking() async throws {
        StubURLProtocol.setHandler { _ in Stub.json(AppendixDVariants.geminiModelsPage1) }      // always "nextPageToken": "t"
        let models = try await Harness().provider("gemini-api").listModels(includeHidden: true)
        #expect(StubURLProtocol.recordedRequests.count == 2)
        #expect(models.count == 4)
    }

    @Test func theFiltersArePlainSubstringsOfTheID() {
        let models = ["chat-1", "Text-Embedding-x", "a-TTS", "flash-lite"].map { ModelInfo(id: $0, displayName: $0) }
        #expect(ModelLists.hiding(models, idsContaining: OpenAIAdapter.hiddenModelWords, showAll: false).map(\.id) == ["chat-1", "flash-lite"])
        #expect(ModelLists.hiding(models, idsContaining: GeminiAdapter.hiddenModelWords, showAll: false).map(\.id) == ["chat-1", "flash-lite"])
        #expect(ModelLists.hiding(models, idsContaining: GeminiAdapter.hiddenModelWords, showAll: true) == models)
    }
}
