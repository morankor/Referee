import Foundation
import Testing
import RefereeCore
import TestSupport

/// SnapshotSupport (plan.md sections 5.9 and 10.1): the registry and the settings of the snapshot mode.
@Suite struct SnapshotSupportTests {
    private static let mockIDs = ["mock", "mock-remote", "mock-fail", "mock-stall"]
    private static let realIDs = ["anthropic-api", "openai-api", "gemini-api", "xai-api", "ollama",
                                  "claude-cli", "codex-cli", "antigravity-cli", "grok-cli"]

    @Test func theRegistryIsTheFourMocksThenTheNineRealIds() {
        let providers = SnapshotSupport.providers()
        #expect(providers.map(\.descriptor.id) == Self.mockIDs + Self.realIDs)
        #expect(providers.prefix(4).allSatisfy { $0 is MockLLMProvider })
        #expect(providers.dropFirst(4).allSatisfy { $0 is StaticProvider })
        #expect(Set(providers.map(\.descriptor.displayName)).count == providers.count)      // a menu can tell them apart
    }

    @Test func onlyMockRemoteIsNotLocalAmongTheMocks() {
        let registry = ProviderRegistry(SnapshotSupport.providers())
        #expect(registry.provider(id: "mock")?.descriptor.isLocal == true)
        #expect(registry.provider(id: "mock-fail")?.descriptor.isLocal == true)     // a scene reviews through it without a consent card
        #expect(registry.provider(id: "mock-stall")?.descriptor.isLocal == true)
        #expect(registry.provider(id: "mock-remote")?.descriptor.isLocal == false)
        #expect(registry.provider(id: "mock-remote")?.descriptor.destination == "mock.example.org")
    }

    @Test func mockFailAndMockStallPlayTheirScripts() async throws {
        let registry = ProviderRegistry(SnapshotSupport.providers())
        let request = LLMRequest(system: "s", parts: [.text("t")], purpose: .review)

        let failing = try #require(registry.provider(id: "mock-fail"))
        var text = ""
        do {
            for try await event in failing.stream(request) {
                if case .textDelta(let delta) = event { text += delta }
            }
            Issue.record("mock-fail should throw")
        } catch {
            #expect(error as? LLMError == .overloaded(retryAfter: nil))
        }
        #expect(text.components(separatedBy: "\n@@END\n").count - 1 == 2)

        let stalling = try #require(registry.provider(id: "mock-stall") as? MockLLMProvider)
        let consumer = Task { () -> Bool in
            do {
                for try await event in stalling.stream(request) {
                    if case .finished = event { return true }
                }
                return true
            } catch {
                return false
            }
        }
        try await Task.sleep(for: .milliseconds(200))
        consumer.cancel()
        #expect(await consumer.value == false)          // it ended because it was cancelled, not because it finished
    }

    @Test func theStaticRowsCarryTheRosterAndShowEveryStatus() async throws {
        let rows = SnapshotSupport.providers().dropFirst(4)
        var ready = 0, needsSetup = 0, unavailable = 0
        for row in rows {
            switch await row.availability() {
            case .ready:
                ready += 1
                #expect(try await !row.listModels().isEmpty)
            case .needsSetup: needsSetup += 1
            case .unavailable: unavailable += 1
            }
        }
        #expect(ready >= 1)
        #expect(needsSetup >= 1)
        #expect(unavailable >= 1)

        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.descriptor.id, $0.descriptor) })
        #expect(rows.filter(\.descriptor.isLocal).map(\.descriptor.id) == ["ollama"])
        #expect(rows.filter(\.descriptor.isExperimental).map(\.descriptor.id) == ["antigravity-cli", "grok-cli"])
        #expect(rows.filter(\.descriptor.supportsNativePDF).map(\.descriptor.id) == ["anthropic-api", "openai-api", "gemini-api"])
        #expect(rows.filter { $0.descriptor.authMode == .apiKey }.map(\.descriptor.id) == ["anthropic-api", "openai-api", "gemini-api", "xai-api"])
        #expect(rows.filter { $0.descriptor.authMode == .subscriptionCLI }.map(\.descriptor.id)
                    == ["claude-cli", "codex-cli", "antigravity-cli", "grok-cli"])
        #expect(byID["ollama"]?.authMode == .local)
        #expect(byID["codex-cli"]?.streaming == .message)
        #expect(byID["anthropic-api"]?.destination == "api.anthropic.com")
        #expect(rows.allSatisfy { !$0.descriptor.retentionNote.isEmpty })
    }

    @Test func theSettingsAreTheDefaultsWithTheMocksEnabledAndMockAsReviewDefault() {
        let settings = SnapshotSupport.settings()
        let defaults = DefaultSettings.make()
        #expect(Set(settings.providers.keys) == Set(Self.mockIDs + Self.realIDs))
        for id in Self.mockIDs {
            #expect(settings.providers[id]?.enabled == true)
            #expect(settings.providers[id]?.model == "mock")
        }
        for id in Self.realIDs { #expect(settings.providers[id] == defaults.providers[id]) }
        #expect(settings.defaults == TaskDefaults(review: ProviderRef(providerID: "mock", model: "mock")))

        // Nothing else differs from the defaults.
        var rest = settings
        rest.providers = defaults.providers
        rest.defaults = defaults.defaults
        #expect(rest == defaults)
        #expect(SnapshotSupport.settings() == settings)
    }
}
