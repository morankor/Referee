import Foundation
import Observation
import RefereeCore

// The app's one settings model (plan.md sections 9.6, 5.8, 13.2 Q2; Appendix A.9; WP8b), held by the WindowManager.
//
// Where the plan leaves a choice, this file decides (also listed in docs/contract-notes/wp8b-models.md):
// - `update` posts .refereeSettingsDidChange at once, with the model as the notification's object, so open windows
//   follow without delay; the save to the settings store follows 0.5 s after the last change. A mutation that changes
//   nothing neither saves nor posts.
// - `models` starts from each provider's `cachedModels`. `refreshModels` also preselects the first model a provider
//   lists when none is chosen, except for subscription CLIs, whose default is the CLI's own (section 5.2).
// - `storedSecrets` is read in `refreshAvailability` for the API-key providers (whose key name is the provider id,
//   section 5.8), not at init, so that launching the app does not touch the Keychain.
// - A secret-store failure is reported in `modelErrors[key]`, the one per-provider error text the model has.
// - With Local only on, `refreshModels` and `sendTestPrompt` do not contact a non-local provider.
// - The test prompt is one user part "Reply with exactly: OK" with an empty system prompt, purpose `.ping`.

public extension Notification.Name {
    static let refereeSettingsDidChange = Notification.Name("local.referee.app.settingsDidChange")
}

@MainActor @Observable
public final class SettingsModel {
    private let dependencies: AppDependencies
    /// Dates and the save debounce (tests inject a clock they advance by hand).
    let clock: any ModelClock

    public private(set) var settings: AppSettings
    public private(set) var availability: [ProviderID: ProviderAvailability] = [:]
    public private(set) var models: [ProviderID: [ModelInfo]] = [:]
    public private(set) var modelErrors: [ProviderID: String] = [:]
    public private(set) var storedSecrets: Set<String> = []       // keys that currently have a value in the Keychain
    public var providers: [ProviderDescriptor] { dependencies.providers.all.map(\.descriptor) }

    @ObservationIgnored private(set) var saveTask: Task<Void, Never>?
    @ObservationIgnored private var saveChain: Task<Void, Never>?
    @ObservationIgnored private var hasUnsavedChanges = false
    @ObservationIgnored private var secretErrorKeys: Set<String> = []     // keys whose modelErrors entry is a secret-store failure

    static let saveDelay: TimeInterval = 0.5
    static let testPrompt = "Reply with exactly: OK"
    static let localOnlyMessage = "Remote providers are blocked by Local only"

    public init(dependencies: AppDependencies, settings: AppSettings) {
        self.dependencies = dependencies
        self.settings = settings
        self.clock = SystemModelClock()
        self.models = Self.cachedLists(in: settings)
    }

    /// For tests: the same model on a clock of the caller's.
    init(dependencies: AppDependencies, settings: AppSettings, clock: any ModelClock) {
        self.dependencies = dependencies
        self.settings = settings
        self.clock = clock
        self.models = Self.cachedLists(in: settings)
    }

    public func update(_ mutate: (inout AppSettings) -> Void) {     // saves (debounced 0.5 s) and posts .refereeSettingsDidChange
        var changed = settings
        mutate(&changed)
        guard changed != settings else { return }
        settings = changed
        scheduleSave()
        NotificationCenter.default.post(name: .refereeSettingsDidChange, object: self)
    }

    /// nil (or only white space) removes the key. The value itself is never kept: only whether the key has one.
    /// When the secret store fails, nothing is changed and the error is shown in `modelErrors[key]`.
    public func setSecret(_ value: String?, for key: String) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed?.isEmpty == false ? trimmed : nil
        do {
            try dependencies.secrets.setSecret(cleaned, for: key)
        } catch {
            modelErrors[key] = Self.message(for: error, otherwise: "The key could not be saved.")
            secretErrorKeys.insert(key)
            Log.event("settings.secret.failed", ["key": .id(key)])
            return
        }
        if cleaned == nil { storedSecrets.remove(key) } else { storedSecrets.insert(key) }
        if secretErrorKeys.remove(key) != nil { modelErrors[key] = nil }
    }

    public func refreshAvailability(of id: ProviderID?) async {    // nil = all
        let targets = dependencies.providers.all.filter { id == nil || $0.descriptor.id == id }
        for (providerID, status) in await Self.availability(of: targets) { availability[providerID] = status }
        for descriptor in targets.map(\.descriptor) where descriptor.authMode == .apiKey {
            do {
                if try dependencies.secrets.secret(for: descriptor.id)?.isEmpty == false {
                    storedSecrets.insert(descriptor.id)
                } else {
                    storedSecrets.remove(descriptor.id)
                }
            } catch {
                // The store could not be read: what is known about the key stays as it is.
            }
        }
    }

    /// Fills `models` (and `cachedModels`, with the time) or `modelErrors`.
    public func refreshModels(of id: ProviderID) async {
        guard let provider = dependencies.providers.provider(id: id) else {
            modelErrors[id] = LLMError.notConfigured("no provider with the id \(id) is registered").userMessage
            return
        }
        if settings.privacy.localOnly && !provider.descriptor.isLocal {
            modelErrors[id] = Self.localOnlyMessage
            return
        }
        let list: [ModelInfo]
        do {
            list = try await provider.listModels()
        } catch {
            modelErrors[id] = Self.message(for: error, otherwise: "The model list could not be read.")
            secretErrorKeys.remove(id)
            return
        }
        models[id] = list
        modelErrors[id] = nil
        secretErrorKeys.remove(id)
        let now = clock.now()
        let choosesFirst = provider.descriptor.authMode != .subscriptionCLI
        update { settings in
            var entry = settings.providers[id] ?? ProviderSettings(enabled: false, inputMode: .auto)
            entry.cachedModels = list
            entry.cachedModelsAt = now
            if entry.model == nil, choosesFirst, let first = list.first { entry.model = first.id }
            settings.providers[id] = entry
        }
    }

    /// Explicit button only; sends "Reply with exactly: OK" and spends a few tokens. Success stores ProviderSettings.verifiedAt.
    public func sendTestPrompt(to id: ProviderID) async -> Result<String, LLMError> {
        guard let provider = dependencies.providers.provider(id: id) else {
            return .failure(.notConfigured("no provider with the id \(id) is registered"))
        }
        if settings.privacy.localOnly && !provider.descriptor.isLocal { return .failure(.notConfigured(Self.localOnlyMessage)) }
        let request = LLMRequest(model: settings.providers[id]?.model, system: "", parts: [.text(Self.testPrompt)], purpose: .ping)
        var answer = ""
        var finished = false
        do {
            for try await event in provider.stream(request) {
                switch event {
                case .textDelta(let text): answer += text
                case .status: break
                case .finished: finished = true
                }
            }
        } catch let error as LLMError {
            return .failure(error)
        } catch {
            return .failure(Task.isCancelled ? .cancelled : .malformedResponse("the provider failed in an unexpected way"))
        }
        if Task.isCancelled { return .failure(.cancelled) }
        guard finished else { return .failure(.malformedResponse("stream ended early")) }
        let now = clock.now()
        update { settings in
            var entry = settings.providers[id] ?? ProviderSettings(enabled: false, inputMode: .auto)
            entry.verifiedAt = now
            settings.providers[id] = entry
        }
        return .success(answer.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The prompts, the quick questions and the rubric of Appendix B (everything on the Prompts tab).
    public func resetPromptsToDefaults() {
        let defaults = DefaultSettings.make()
        update { settings in
            settings.prompts = defaults.prompts
            settings.rubric = defaults.rubric
        }
    }

    /// Called once by AppDelegate at launch. Acts on first launch only (no review default yet): if Ollama is running
    /// and has a model, enable it and make it the default. Never enables a remote provider by itself.
    public func applyFirstRunDefaultsIfNeeded() async {
        let id: ProviderID = "ollama"
        guard settings.defaults.review == nil, let ollama = dependencies.providers.provider(id: id), ollama.descriptor.isLocal else { return }
        let status = await ollama.availability()
        availability[id] = status
        guard case .ready = status, let list = try? await ollama.listModels(), let first = list.first else { return }
        models[id] = list
        guard settings.defaults.review == nil else { return }      // chosen in the meantime
        let now = clock.now()
        update { settings in
            var entry = settings.providers[id] ?? ProviderSettings(enabled: false, inputMode: .auto)
            let model = entry.model.flatMap { chosen in list.contains { $0.id == chosen } ? chosen : nil } ?? first.id
            entry.enabled = true
            entry.model = model
            entry.cachedModels = list
            entry.cachedModelsAt = now
            settings.providers[id] = entry
            settings.defaults.review = ProviderRef(providerID: id, model: model)
        }
    }

    /// Writes a pending change now (the app has no caller for it yet; tests use it).
    func flushPendingSave() async {
        saveTask?.cancel()
        saveTask = nil
        if hasUnsavedChanges { await save() } else { await saveChain?.value }
    }

    // ---- private ----

    private static func cachedLists(in settings: AppSettings) -> [ProviderID: [ModelInfo]] {
        settings.providers.filter { !$0.value.cachedModels.isEmpty }.mapValues(\.cachedModels)
    }

    private func scheduleSave() {
        hasUnsavedChanges = true
        saveTask?.cancel()
        let deadline = clock.now().addingTimeInterval(Self.saveDelay)
        let clock = self.clock
        saveTask = Task { [weak self] in
            do { try await clock.sleep(until: deadline) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }

    /// Saves run one after another, each writing the settings as they are then.
    private func save() async {
        let previous = saveChain
        let task = Task { [weak self] in
            await previous?.value
            guard let self, self.hasUnsavedChanges else { return }
            self.hasUnsavedChanges = false
            do {
                try await self.dependencies.settings.save(self.settings)
            } catch {
                self.hasUnsavedChanges = true
                Log.event("settings.save.failed")
            }
        }
        saveChain = task
        await task.value
    }

    @concurrent nonisolated private static func availability(of providers: [any LLMProvider]) async -> [(ProviderID, ProviderAvailability)] {
        await withTaskGroup(of: (ProviderID, ProviderAvailability).self) { group in
            for provider in providers {
                group.addTask { (provider.descriptor.id, await provider.availability()) }
            }
            var results: [(ProviderID, ProviderAvailability)] = []
            for await result in group { results.append(result) }
            return results
        }
    }

    static func message(for error: Error, otherwise fallback: String) -> String {
        if let error = error as? any RefereeError { return error.userMessage }
        return fallback
    }
}
