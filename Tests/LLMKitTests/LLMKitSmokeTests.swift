import Foundation
import Testing
import RefereeCore
import LLMKit
import TestSupport

/// Wave 0a smoke tests. They hold for the placeholders and keep holding for the real implementation (WP4). They use
/// the public surface only. No request can leave the machine: the session only talks to StubURLProtocol.
@Suite struct LLMKitSmokeTests {
    private func environment() -> ProviderEnvironment {
        ProviderEnvironment(settings: { _ in ProviderSettings(enabled: false, inputMode: .auto) }, secrets: InMemorySecretStore(),
                            urlSession: StubURLProtocol.session(), processEnvironment: [:])
    }

    @Test func factoryMakesTheFiveHTTPProvidersInOrder() {
        StubURLProtocol.setHandler(nil)
        let ids = LLMKitFactory.makeProviders(environment: environment()).map(\.descriptor.id)
        #expect(ids == ["anthropic-api", "openai-api", "gemini-api", "xai-api", "ollama"])
    }

    @Test func aProviderWithoutAKeyIsNotConfigured() async {
        StubURLProtocol.setHandler(nil)
        let providers = LLMKitFactory.makeProviders(environment: environment())
        guard let anthropic = providers.first(where: { $0.descriptor.id == "anthropic-api" }) else {
            Issue.record("anthropic-api is missing")
            return
        }
        do {
            for try await _ in anthropic.stream(LLMRequest(system: "Reply with exactly: OK", parts: [.text("OK?")], purpose: .ping)) {}
            Issue.record("the stream ended without an error")
        } catch LLMError.notConfigured {
            // expected: no key is stored, so nothing is sent
        } catch {
            Issue.record("expected LLMError.notConfigured, got \(error)")
        }
        #expect(StubURLProtocol.recordedRequests.isEmpty)
    }
}
