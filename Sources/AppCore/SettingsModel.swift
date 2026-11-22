import Foundation
import Observation
import RefereeCore

// Wave 0 placeholder (plan.md section 11.4, WP0a): every member of Appendix A.9, as printed there, with bodies that do
// nothing beyond holding the settings in memory. WP8b writes the model.

public extension Notification.Name {
    static let refereeSettingsDidChange = Notification.Name("local.referee.app.settingsDidChange")
}

@MainActor @Observable
public final class SettingsModel {
    private let dependencies: AppDependencies

    public private(set) var settings: AppSettings
    public private(set) var availability: [ProviderID: ProviderAvailability] = [:]
    public private(set) var models: [ProviderID: [ModelInfo]] = [:]
    public private(set) var modelErrors: [ProviderID: String] = [:]
    public private(set) var storedSecrets: Set<String> = []       // keys that currently have a value in the Keychain
    public var providers: [ProviderDescriptor] { dependencies.providers.all.map(\.descriptor) }

    public init(dependencies: AppDependencies, settings: AppSettings) {
        self.dependencies = dependencies
        self.settings = settings
    }

    public func update(_ mutate: (inout AppSettings) -> Void) { mutate(&settings) }     // saves (debounced 0.5 s) and posts .refereeSettingsDidChange
    public func setSecret(_ value: String?, for key: String) {}
    public func refreshAvailability(of id: ProviderID?) async {}    // nil = all
    public func refreshModels(of id: ProviderID) async {}
    /// Explicit button only; sends "Reply with exactly: OK" and spends a few tokens. Success stores ProviderSettings.verifiedAt.
    public func sendTestPrompt(to id: ProviderID) async -> Result<String, LLMError> { .failure(.notConfigured("not implemented")) }
    public func resetPromptsToDefaults() {}
    /// Called once by AppDelegate at launch. Acts on first launch only (no review default yet): if Ollama is running
    /// and has a model, enable it and make it the default. Never enables a remote provider by itself.
    public func applyFirstRunDefaultsIfNeeded() async {}
}
