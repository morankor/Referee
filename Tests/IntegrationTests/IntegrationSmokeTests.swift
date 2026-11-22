import Foundation
import Testing
import RefereeCore
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

    /// Snapshot mode (plan section 10.1): the whole graph stands on mock and static providers and the fake resolver.
    @Test func theSnapshotGraphHasTheFourMocksAndNoRealProvider() async throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dependencies = await LiveDependencies.make(environment: ["REFEREE_HOME": home.path, "REFEREE_SNAPSHOT": "1", "REFEREE_NO_KEYCHAIN": "1"])
        #expect(dependencies.providers.all.map(\.descriptor.id) == ["mock", "mock-remote", "mock-fail", "mock-stall"] + Self.realProviderIDs)
        #expect(dependencies.providers.provider(id: "mock-remote")?.descriptor.destination == "mock.example.org")

        // The real provider ids are rows with a status: none of them can send anything.
        let request = LLMRequest(system: "s", parts: [.text("t")], purpose: .ping)
        for id in Self.realProviderIDs {
            let provider = try #require(dependencies.providers.provider(id: id))
            do {
                for try await _ in provider.stream(request) {}
                Issue.record("\(id) should not stream in snapshot mode")
            } catch LLMError.notConfigured {
                // expected
            } catch {
                Issue.record("\(id): expected LLMError.notConfigured, got \(error)")
            }
        }

        // The mock answers through the registry, and references resolve without the network.
        var answer = ""
        for try await event in try #require(dependencies.providers.provider(id: "mock")).stream(request) {
            if case .textDelta(let delta) = event { answer += delta }
        }
        #expect(answer == "OK")
        let entry = BibEntry(id: 0, rawText: "Lee, J. (2021). Observational learning with heterogeneous priors.", parsed: ParsedReference())
        let reference = await dependencies.resolver.resolve(entry, documentSHA256: String(repeating: "0", count: 64))
        #expect(reference.status == .resolved)
        #expect(reference.landingURL?.hasPrefix("https://example.org/") == true)
    }

    @Test func theSharedURLSessionToleratesTenMinutesOfSilence() {
        let configuration = LiveDependencies.makeURLSession().configuration
        #expect(configuration.timeoutIntervalForRequest == 600)
        #expect(configuration.timeoutIntervalForResource == 3600)
        #expect(configuration.urlCache == nil)
    }
}
