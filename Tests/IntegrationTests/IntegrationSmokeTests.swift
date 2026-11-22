import Foundation
import Testing
import Composition

/// Wave 0a smoke tests for the composition root. They hold for the placeholders and must keep holding for the real
/// implementations. REFEREE_HOME points at a temporary directory and the Keychain is left out, so nothing of the
/// user's is read or written.
@Suite struct IntegrationSmokeTests {
    private static let realProviderIDs = ["anthropic-api", "openai-api", "gemini-api", "xai-api", "ollama",
                                          "claude-cli", "codex-cli", "antigravity-cli", "grok-cli"]

    private func temporaryHome() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("referee-integration-smoke-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func liveDependenciesRegisterTheNineProvidersInOrder() async {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dependencies = await LiveDependencies.make(environment: ["REFEREE_HOME": home.path, "REFEREE_NO_KEYCHAIN": "1"])
        #expect(dependencies.providers.all.map(\.descriptor.id) == Self.realProviderIDs)
        #expect(dependencies.providers.provider(id: "mock") == nil)
    }

    @Test func theMockProviderJoinsOnlyWhenAskedFor() async {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dependencies = await LiveDependencies.make(environment: ["REFEREE_HOME": home.path, "REFEREE_NO_KEYCHAIN": "1",
                                                                     "REFEREE_ENABLE_MOCK": "1"])
        #expect(dependencies.providers.all.map(\.descriptor.id) == Self.realProviderIDs + ["mock"])
    }

    @Test func theSharedURLSessionToleratesTenMinutesOfSilence() {
        let configuration = LiveDependencies.makeURLSession().configuration
        #expect(configuration.timeoutIntervalForRequest == 600)
        #expect(configuration.timeoutIntervalForResource == 3600)
        #expect(configuration.urlCache == nil)
    }
}
