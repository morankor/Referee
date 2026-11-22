import Foundation
import Testing
import RefereeCore
@testable import AppCore
import TestSupport

/// Counts the settings notifications whose object is one given model; tests run in parallel and share the centre.
final class SettingsNotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var received = 0
    private var observer: NSObjectProtocol?

    init(for model: SettingsModel) {
        observer = NotificationCenter.default.addObserver(forName: .refereeSettingsDidChange, object: model, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { self.received += 1 }
        }
    }

    var count: Int { lock.withLock { received } }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}

/// Acceptance row "settings model" (plan.md section 11.4, WP8b; sections 5.8, 9.6, 13.2 Q2).
@Suite struct SettingsModelTests {
    struct Parts {
        let model: SettingsModel
        let store: InMemorySettingsStore
        let secrets: InMemorySecretStore
        let clock: ManualModelClock
    }

    @MainActor static func make(settings: AppSettings = DefaultSettings.make(), providers: [any LLMProvider] = [],
                                secrets: InMemorySecretStore = InMemorySecretStore()) throws -> Parts {
        let store = InMemorySettingsStore(settings)
        let paper = LoadedPaper(ref: DocumentRef(sha256: String(repeating: "0", count: 64), fileName: "none.pdf", byteCount: 0, pageCount: 0),
                                data: Data(), isEncrypted: false, text: PaperText(hasTextLayer: false, hasMarginLineNumbers: false))
        let dependencies = AppDependencies(paperService: FakePaperService(paper: paper), matcherFactory: { FakeQuoteMatcher(paper: $0) },
                                           citationIndexer: FakeCitationIndexer(), engine: ScriptedReviewEngine(plan: ModelSample.localPlan),
                                           resolver: FakeResolver(), sessions: InMemorySessionStore(), settings: store,
                                           providers: ProviderRegistry(providers), secrets: secrets)
        let clock = ManualModelClock()
        return Parts(model: SettingsModel(dependencies: dependencies, settings: settings, clock: clock), store: store, secrets: secrets, clock: clock)
    }

    @Test @MainActor func updateSavesAfterTheDebounceAndPostsTheNotification() async throws {
        let parts = try Self.make()
        let counter = SettingsNotificationCounter(for: parts.model)
        defer { counter.stop() }
        parts.model.update { $0.privacy.localOnly = true }
        parts.model.update { $0.ui.autoAdvanceAfterTriage = false }
        #expect(parts.model.settings.privacy.localOnly)
        #expect(counter.count == 2)                                      // at once, with the model as the object
        #expect(await parts.store.load() == DefaultSettings.make())      // the save waits 0.5 s after the last change
        parts.clock.advance(by: 0.3)
        await Task.yield()
        #expect(await parts.store.load() == DefaultSettings.make())
        let pending = parts.model.saveTask
        parts.clock.advance(by: 0.3)
        await pending?.value
        #expect(await parts.store.load() == parts.model.settings)

        parts.model.update { $0.privacy.localOnly = true }               // no change: no notification, no save
        #expect(counter.count == 2)
    }

    @Test @MainActor func setSecretRecordsTheKeyNameOnly() async throws {
        let parts = try Self.make()
        let model = parts.model
        let value = "sk-test-0123456789"
        await model.setSecret(value, for: "anthropic-api")
        #expect(model.storedSecrets == ["anthropic-api"])
        #expect(try parts.secrets.secret(for: "anthropic-api") == value)
        // The value appears in no published state.
        let encoded = String(decoding: try JSONEncoder().encode(model.settings), as: UTF8.self)
        #expect(!encoded.contains(value))
        #expect(!model.modelErrors.values.contains { $0.contains(value) })
        #expect(!model.secretErrors.values.contains { $0.contains(value) })
        #expect(!"\(model.availability)".contains(value))
        #expect(!"\(model.models)".contains(value))

        await model.setSecret("  \n", for: "anthropic-api")                    // blank: removed
        #expect(model.storedSecrets.isEmpty)
        #expect(try parts.secrets.secret(for: "anthropic-api") == nil)
        await model.setSecret("  key-with-a-newline\n", for: "openai-api")
        #expect(try parts.secrets.secret(for: "openai-api") == "key-with-a-newline")
        await model.setSecret(nil, for: "openai-api")
        #expect(model.storedSecrets.isEmpty)
    }

    @Test @MainActor func anUnreadableSecretStoreChangesNothingAndSaysSo() async throws {
        let secrets = InMemorySecretStore(["anthropic-api": "old"])
        let parts = try Self.make(secrets: secrets)
        let model = parts.model
        await model.setSecret("first", for: "xai-api")
        #expect(model.storedSecrets == ["xai-api"])
        secrets.failReads = true
        await model.setSecret("new", for: "anthropic-api")
        #expect(model.storedSecrets == ["xai-api"])                      // unchanged
        #expect(model.secretErrors["anthropic-api"] == SecretError.unreadable(status: -25293).userMessage)
        #expect(model.modelErrors["anthropic-api"] == nil)               // a Keychain error is not a model-list error (Gate 1)
        await model.setSecret(nil, for: "xai-api")
        #expect(model.storedSecrets == ["xai-api"])                      // a removal that failed removes nothing
        secrets.failReads = false
        #expect(try secrets.secret(for: "anthropic-api") == "old")       // the other key survived
        await model.setSecret("new", for: "anthropic-api")
        #expect(model.secretErrors["anthropic-api"] == nil)              // the error goes once the key is stored
        #expect(model.storedSecrets == ["xai-api", "anthropic-api"])
    }

    @Test @MainActor func refreshAvailabilityAsksEveryProviderAndReadsWhichKeysAreStored() async throws {
        let api = CountingModelProvider(id: "anthropic-api", isLocal: false, authMode: .apiKey, status: .ready(detail: "Key set"))
        let local = CountingModelProvider(id: "ollama", status: .unavailable(reason: "Ollama is not running"))
        let parts = try Self.make(providers: [api, local], secrets: InMemorySecretStore(["anthropic-api": "stored"]))
        await parts.model.refreshAvailability(of: nil)
        #expect(parts.model.availability["anthropic-api"] == .ready(detail: "Key set"))
        #expect(parts.model.availability["ollama"] == .unavailable(reason: "Ollama is not running"))
        #expect(parts.model.storedSecrets == ["anthropic-api"])
        #expect(parts.model.providers.map(\.id) == ["anthropic-api", "ollama"])
        try parts.secrets.setSecret(nil, for: "anthropic-api")
        await parts.model.refreshAvailability(of: "ollama")
        #expect(parts.model.storedSecrets == ["anthropic-api"])           // only the provider asked about is looked at
        await parts.model.refreshAvailability(of: "anthropic-api")
        #expect(parts.model.storedSecrets.isEmpty)
    }

    @Test @MainActor func refreshModelsFillsTheListAndTheCacheOrTheError() async throws {
        let models = [ModelInfo(id: "first", displayName: "First", contextWindow: 200_000), ModelInfo(id: "second", displayName: "Second")]
        let good = CountingModelProvider(id: "anthropic-api", isLocal: false, authMode: .apiKey, models: models)
        let bad = CountingModelProvider(id: "openai-api", isLocal: false, authMode: .apiKey, listFailure: .auth("invalid key"))
        let cli = CountingModelProvider(id: "codex-cli", isLocal: false, authMode: .subscriptionCLI, models: models)
        let parts = try Self.make(providers: [good, bad, cli])
        let model = parts.model
        let counter = SettingsNotificationCounter(for: model)
        defer { counter.stop() }

        await model.refreshModels(of: "anthropic-api")
        #expect(model.models["anthropic-api"] == models)
        #expect(model.modelErrors["anthropic-api"] == nil)
        #expect(model.settings.providers["anthropic-api"]?.cachedModels == models)
        #expect(model.settings.providers["anthropic-api"]?.cachedModelsAt == parts.clock.now())
        #expect(model.settings.providers["anthropic-api"]?.model == "first")      // the first entry is preselected
        #expect(counter.count == 1)

        await model.refreshModels(of: "openai-api")
        #expect(model.models["openai-api"] == nil)
        #expect(model.modelErrors["openai-api"] == LLMError.auth("invalid key").userMessage)
        #expect(model.settings.providers["openai-api"]?.cachedModels.isEmpty == true)

        await model.refreshModels(of: "codex-cli")
        #expect(model.settings.providers["codex-cli"]?.cachedModels == models)
        #expect(model.settings.providers["codex-cli"]?.model == nil)              // a CLI keeps its own default

        await model.refreshModels(of: "no-such-provider")
        #expect(model.modelErrors["no-such-provider"] != nil)

        parts.clock.advance(by: 1)
        await model.flushPendingSave()
        #expect(await parts.store.load().providers["anthropic-api"]?.cachedModels == models)
    }

    @Test @MainActor func cachedListsAreTheModelsAtFirst() throws {
        var settings = DefaultSettings.make()
        let cached = [ModelInfo(id: "gemma4:e4b", displayName: "gemma4:e4b", contextWindow: 131_072)]
        settings.providers["ollama"]?.cachedModels = cached
        let parts = try Self.make(settings: settings)
        #expect(parts.model.models == ["ollama": cached])
    }

    @Test @MainActor func aSuccessfulTestPromptStoresVerifiedAt() async throws {
        let mock = MockLLMProvider(id: "mock")                           // answers a .ping with "OK"
        let failing = CountingModelProvider(id: "grok-cli", isLocal: false, authMode: .subscriptionCLI, streamFailure: .cliExited(code: 1, stderrTail: "no"))
        let parts = try Self.make(providers: [mock, failing])
        let model = parts.model
        let result = await model.sendTestPrompt(to: "mock")
        #expect(result == .success("OK"))
        #expect(model.settings.providers["mock"]?.verifiedAt == parts.clock.now())
        let request = try #require(mock.recordedRequests.last)
        #expect(request.purpose == .ping)
        #expect(request.parts == [.text("Reply with exactly: OK")])

        let failed = await model.sendTestPrompt(to: "grok-cli")
        #expect(failed == .failure(.cliExited(code: 1, stderrTail: "no")))
        #expect(model.settings.providers["grok-cli"]?.verifiedAt == nil)

        let unknown = await model.sendTestPrompt(to: "no-such-provider")
        if case .failure(.notConfigured) = unknown {} else { Issue.record("expected notConfigured, got \(unknown)") }
    }

    @Test @MainActor func localOnlyKeepsRemoteProvidersQuiet() async throws {
        let remote = CountingModelProvider(id: "anthropic-api", isLocal: false, authMode: .apiKey, models: [ModelInfo(id: "m", displayName: "m")])
        let parts = try Self.make(settings: { var s = DefaultSettings.make(); s.privacy.localOnly = true; return s }(), providers: [remote])
        await parts.model.refreshModels(of: "anthropic-api")
        #expect(remote.listModelsCalls == 0)
        #expect(parts.model.modelErrors["anthropic-api"] == "Remote providers are blocked by Local only")
        let result = await parts.model.sendTestPrompt(to: "anthropic-api")
        if case .failure = result {} else { Issue.record("a remote test prompt was sent under Local only") }
    }

    @Test @MainActor func resettingPromptsRestoresTheDefaults() throws {
        let parts = try Self.make()
        parts.model.update { settings in
            settings.prompts.reviewSystem = "Something else"
            settings.prompts.quickQuestions = []
            settings.rubric.removeAll()
            settings.privacy.localOnly = true
        }
        parts.model.resetPromptsToDefaults()
        let defaults = DefaultSettings.make()
        #expect(parts.model.settings.prompts == defaults.prompts)
        #expect(parts.model.settings.rubric == defaults.rubric)
        #expect(parts.model.settings.privacy.localOnly)                  // the rest is left alone
    }

    // ---- first run ----

    static func ollama(_ status: ProviderAvailability, models: [ModelInfo]) -> StaticProvider {
        StaticProvider(descriptor: ProviderDescriptor(id: "ollama", displayName: "Ollama (local)", vendor: "Ollama", authMode: .local, isLocal: true,
                                                      destination: "127.0.0.1:11434", supportsNativePDF: false, streaming: .token,
                                                      retentionNote: "Processed on this Mac; nothing is sent.", isExperimental: false),
                       availability: status, models: models)
    }

    static let remoteReady = StaticProvider(descriptor: ProviderDescriptor(id: "anthropic-api", displayName: "Anthropic API", vendor: "Anthropic",
                                                                           authMode: .apiKey, isLocal: false, destination: "api.anthropic.com",
                                                                           supportsNativePDF: true, streaming: .token,
                                                                           retentionNote: "Sent to Anthropic under your API account's data terms.",
                                                                           isExperimental: false),
                                            availability: .ready(detail: "Key set"),
                                            models: [ModelInfo(id: "example-large", displayName: "Example Large", contextWindow: 1_000_000)])

    @Test @MainActor func onFirstRunAReadyOllamaWithAModelBecomesTheDefault() async throws {
        let models = [ModelInfo(id: "gemma4:e4b", displayName: "gemma4:e4b", contextWindow: 131_072), ModelInfo(id: "phi4", displayName: "phi4")]
        var settings = DefaultSettings.make()
        settings.providers["ollama"]?.enabled = false
        let parts = try Self.make(settings: settings, providers: [Self.remoteReady, Self.ollama(.ready(detail: "Ollama 0.40.17"), models: models)])
        await parts.model.applyFirstRunDefaultsIfNeeded()
        let result = parts.model.settings
        #expect(result.defaults.review == ProviderRef(providerID: "ollama", model: "gemma4:e4b"))
        #expect(result.providers["ollama"]?.enabled == true)
        #expect(result.providers["ollama"]?.model == "gemma4:e4b")
        #expect(result.providers["ollama"]?.cachedModels == models)
        #expect(result.providers["anthropic-api"]?.enabled == false)    // never a remote provider
        #expect(result.defaults.chat == nil)
        #expect(result.defaults.report == nil)
    }

    @Test @MainActor func onFirstRunNothingIsChosenWithoutAReadyOllamaWithAModel() async throws {
        for ollama in [Self.ollama(.unavailable(reason: "Ollama is not running"), models: [ModelInfo(id: "phi4", displayName: "phi4")]),
                       Self.ollama(.needsSetup(reason: "Not installed", hint: "Install Ollama"), models: [ModelInfo(id: "phi4", displayName: "phi4")]),
                       Self.ollama(.ready(detail: "Ollama 0.40.17"), models: [])] {
            let parts = try Self.make(providers: [Self.remoteReady, ollama])
            await parts.model.applyFirstRunDefaultsIfNeeded()
            #expect(parts.model.settings == DefaultSettings.make())
        }
        let parts = try Self.make(providers: [Self.remoteReady])         // no Ollama at all
        await parts.model.applyFirstRunDefaultsIfNeeded()
        #expect(parts.model.settings.defaults.review == nil)
        #expect(parts.model.settings.providers["anthropic-api"]?.enabled == false)
    }

    @Test @MainActor func afterTheFirstRunNothingChanges() async throws {
        var settings = DefaultSettings.make()
        settings.defaults.review = ProviderRef(providerID: "anthropic-api", model: "example-large")
        let parts = try Self.make(settings: settings,
                                  providers: [Self.remoteReady, Self.ollama(.ready(detail: "Ollama 0.40.17"), models: [ModelInfo(id: "phi4", displayName: "phi4")])])
        await parts.model.applyFirstRunDefaultsIfNeeded()
        #expect(parts.model.settings == settings)
    }
}
