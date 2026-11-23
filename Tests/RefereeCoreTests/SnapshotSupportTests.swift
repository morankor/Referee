import Foundation
import Testing
import RefereeCore
import TestSupport

/// SnapshotSupport (plan.md sections 5.9 and 10.1): the registry and the settings of the snapshot mode.
@Suite struct SnapshotSupportTests {
    private static let mockIDs = ["mock", "mock-remote", "mock-fail", "mock-stall"]
    private static let realIDs = ["anthropic-api", "openai-api", "gemini-api", "xai-api", "ollama",
                                  "claude-cli", "codex-cli", "antigravity-cli", "grok-cli"]
    private static let standInIDs = ["mock-slow", "mock-offline"]                      // step 5 (design review O3)

    @Test func theRegistryIsTheFourMocksThenTheNineRealIdsThenTheTwoStandIns() {
        let providers = SnapshotSupport.providers()
        #expect(providers.map(\.descriptor.id) == Self.mockIDs + Self.realIDs + Self.standInIDs)
        #expect(providers.prefix(4).allSatisfy { $0 is MockLLMProvider })
        #expect(providers.dropFirst(4).prefix(9).allSatisfy { $0 is StaticProvider })
        #expect(Set(providers.map(\.descriptor.displayName)).count == providers.count)      // a menu can tell them apart
    }

    /// Step 5 (O3): "mock-slow" plays the sample script with 40 ms between deltas, for the report mid-generation;
    /// "mock-offline" is a local provider that reports Ollama's "not running" and can send nothing. Both are built in,
    /// local, and off in the snapshot settings.
    @Test func theTwoStandInsAreASlowMockAndALocalProviderThatIsNotRunning() async throws {
        let registry = ProviderRegistry(SnapshotSupport.providers())
        let slow = try #require(registry.provider(id: "mock-slow") as? MockLLMProvider)
        let offline = try #require(registry.provider(id: "mock-offline") as? StaticProvider)
        for descriptor in [slow.descriptor, offline.descriptor] {
            #expect(descriptor.isLocal)
            #expect(descriptor.authMode == .none)
            #expect(descriptor.vendor == "Mock")
        }
        #expect(slow.descriptor.displayName == "Mock (slow)")
        #expect(offline.descriptor.displayName == "Mock (offline)")

        // The sample's answer to a test prompt is one delta, which comes no sooner than 40 ms (a sleep never ends early).
        let clock = ContinuousClock()
        let started = clock.now
        var answer = ""
        for try await event in slow.stream(LLMRequest(system: "", parts: [.text("Reply with exactly: OK")], purpose: .ping)) {
            if case .textDelta(let delta) = event { answer += delta }
        }
        #expect(answer == "OK")
        #expect(clock.now - started >= .milliseconds(40))

        #expect(await offline.availability() == .needsSetup(reason: "Ollama is not running", hint: "Start the Ollama app or run `ollama serve`."))
        #expect(try await offline.listModels().map(\.id) == ["mock"])
        do {
            for try await _ in offline.stream(LLMRequest(system: "s", parts: [.text("t")], purpose: .review)) {}
            Issue.record("mock-offline should not stream")
        } catch {
            #expect(error is LLMError)
        }

        let settings = SnapshotSupport.settings()
        for id in Self.standInIDs { #expect(settings.providers[id] == nil, "\(id) has an entry in the snapshot settings") }
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

        // A stalled stream stays open and never sends .finished. How it ends once cancelled depends on the moment: inside
        // the stall it throws .cancelled, between two deltas it just ends (a busy machine can delay the consumer that
        // long). So the test asks only what holds either way.
        let stalling = try #require(registry.provider(id: "mock-stall") as? MockLLMProvider)
        final class Ended: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            func set() { lock.withLock { value = true } }
            var isSet: Bool { lock.withLock { value } }
        }
        let ended = Ended()
        let consumer = Task { () -> Bool in             // true: the stream sent .finished
            defer { ended.set() }
            do {
                for try await event in stalling.stream(request) {
                    if case .finished = event { return true }
                }
            } catch {}
            return false
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!ended.isSet)                           // still open
        consumer.cancel()
        #expect(await consumer.value == false)          // and it never finished on its own
    }

    @Test func theStaticRowsCarryTheRosterAndShowEveryStatus() async throws {
        let rows = SnapshotSupport.providers().dropFirst(4).prefix(9)
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
        // The two subscription CLIs take the PDF since the delivery experiment of section 5.6.6 (WP5, applied at Gate 1).
        #expect(rows.filter(\.descriptor.supportsNativePDF).map(\.descriptor.id) == ["anthropic-api", "openai-api", "gemini-api", "claude-cli", "codex-cli"])
        #expect(byID["codex-cli"]?.pdfDeliveryNote == "sent as page images")
        #expect(byID["claude-cli"]?.pdfDeliveryNote == nil)
        #expect(rows.map(\.descriptor.maxPromptBytes) == [nil, nil, nil, nil, nil, 9_000_000, 4_000_000, 4_000_000, 4_000_000])
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
