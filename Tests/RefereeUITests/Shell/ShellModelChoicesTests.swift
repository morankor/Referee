import Foundation
import Testing
import RefereeCore
import AppCore
import TestSupport
@testable import RefereeUI

/// Choosing a model wherever a provider is chosen (step 5b, the user's "in the providers, let me also choose a model"):
/// the destination menu's list, built from the list Settings keeps; the choice handed to `setActiveProvider`; the
/// default bar's references with a model; the model under each provider's name in Settings.
@Suite @MainActor struct ShellModelChoicesTests {
    private typealias Sample = ShellTestData

    private static let anthropicModels = [ModelInfo(id: "example-large", displayName: "Example Large", contextWindow: 1_000_000),
                                          ModelInfo(id: "example-small", displayName: "Example Small", contextWindow: 200_000),
                                          ModelInfo(id: "example-raw", displayName: "example-raw")]

    private static func settings(model: String? = nil, cached: [ModelInfo]) -> AppSettings {
        var settings = DefaultSettings.make()
        settings.providers["anthropic-api"] = ProviderSettings(enabled: true, model: model, inputMode: .auto, cachedModels: cached)
        return settings
    }

    @Test func theMenuListsTheDefaultThenTheModelsByTheirNames() {
        let settings = Self.settings(model: "example-large", cached: Self.anthropicModels)
        let menu = ShellModelChoices.menu(for: "anthropic-api", settings: settings, current: nil)
        #expect(menu.choices == [
            ShellModelChoice(title: "Default model (Example Large)", ref: ProviderRef(providerID: "anthropic-api", model: nil)),
            ShellModelChoice(title: "Example Large", ref: ProviderRef(providerID: "anthropic-api", model: "example-large")),
            ShellModelChoice(title: "Example Small", ref: ProviderRef(providerID: "anthropic-api", model: "example-small")),
            ShellModelChoice(title: "example-raw", ref: ProviderRef(providerID: "anthropic-api", model: "example-raw")),
        ])
        #expect(menu.settingsRow == nil)
    }

    @Test func withoutAListTheMenuOffersTheDefaultAndSettings() {
        let menu = ShellModelChoices.menu(for: "anthropic-api", settings: Self.settings(cached: []), current: nil)
        #expect(menu.choices.map(\.title) == ["Default model"])
        #expect(menu.settingsRow == "Choose in Settings…")
        // A CLI without a model of its own uses its default, whose name is not known.
        var cli = DefaultSettings.make()
        cli.providers["claude-cli"] = ProviderSettings(enabled: true, inputMode: .auto)
        #expect(ShellModelChoices.menu(for: "claude-cli", settings: cli, current: nil).choices.map(\.title) == ["Default model"])
    }

    /// At most eight models, then "More in Settings…"; the model in force is shown even when it is further down.
    @Test func aLongListIsShortenedButKeepsTheModelInForce() {
        let many = (1...12).map { ModelInfo(id: "m\($0)", displayName: "Model \($0)") }
        let settings = Self.settings(model: "m1", cached: many)
        let current = ProviderRef(providerID: "anthropic-api", model: "m11")
        let menu = ShellModelChoices.menu(for: "anthropic-api", settings: settings, current: current)
        #expect(menu.choices.count == 1 + 8 + 1)
        #expect(menu.choices.dropFirst().prefix(8).map(\.title) == (1...8).map { "Model \($0)" })
        #expect(menu.choices.last == ShellModelChoice(title: "Model 11", ref: current))
        #expect(menu.settingsRow == "More in Settings…")
        // A model typed in Settings that the list does not have is shown by its id.
        let typed = ProviderRef(providerID: "anthropic-api", model: "custom-id")
        #expect(ShellModelChoices.menu(for: "anthropic-api", settings: settings, current: typed).choices.last?.title == "custom-id")
        // The whole list where there is room (the default bar's menus).
        #expect(ShellModelChoices.menu(for: "anthropic-api", settings: settings, current: nil, limit: nil).choices.count == 13)
    }

    @Test func theModelUnderEachProvidersNameInSettings() {
        let listed = Self.anthropicModels
        #expect(ShellModelChoices.chosenModelLine(Sample.anthropic, entry: ProviderSettings(enabled: true, model: "example-large", inputMode: .auto),
                                                  listed: listed) == "Example Large")
        #expect(ShellModelChoices.chosenModelLine(Sample.anthropic, entry: ProviderSettings(enabled: true, model: "example-small", inputMode: .auto,
                                                                                            cachedModels: listed), listed: []) == "Example Small")
        #expect(ShellModelChoices.chosenModelLine(Sample.ollama, entry: ProviderSettings(enabled: true, model: "gemma4:e4b", inputMode: .auto),
                                                  listed: []) == "gemma4:e4b")
        #expect(ShellModelChoices.chosenModelLine(Sample.claude, entry: ProviderSettings(enabled: true, inputMode: .auto), listed: []) == "CLI default")
        #expect(ShellModelChoices.chosenModelLine(Sample.anthropic, entry: nil, listed: listed) == "Not chosen")
    }

    /// The menu's choice reaches the paper: provider and model in `session.preferredProvider`, the model in force.
    @Test func aModelChosenInTheMenuIsThePapersModel() async throws {
        var settings = SnapshotSupport.settings()
        settings.providers["ollama"] = ProviderSettings(enabled: true, model: "gemma4:e4b", inputMode: .auto,
                                                        cachedModels: [ModelInfo(id: "gemma4:e4b", displayName: "gemma4:e4b"),
                                                                       ModelInfo(id: "phi4", displayName: "phi4")])
        let model = try await ShellTestModels.openedOnTheSnapshotRegistry(settings: settings)
        let windowState = ShellReviewWindowState()
        windowState.toggleDestinationMenu(chosen: model.session?.preferredProvider)
        #expect(windowState.destinationMenuOpen)
        #expect(windowState.expandedProvider == nil)                         // Custom: no provider's models listed at first
        #expect(model.usesCustomProviders)
        #expect(ShellDestinationMenu.chosenRef(model) == nil)

        let menu = ShellModelChoices.menu(for: "ollama", settings: model.settings, current: ShellDestinationMenu.chosenRef(model))
        let phi4 = try #require(menu.choices.first { $0.title == "phi4" })
        ShellDestinationMenu.choose(phi4.ref, in: model, windowState: windowState)
        #expect(model.session?.preferredProvider == ProviderRef(providerID: "ollama", model: "phi4"))
        #expect(model.activeProvider?.id == "ollama")
        #expect(model.activeModel == "phi4")
        #expect(model.chatProvider?.id == "ollama")                          // every job's
        #expect(model.reportProvider?.id == "ollama")
        #expect(!windowState.destinationMenuOpen)
        #expect(ShellDestinationMenu.chosenRef(model) == phi4.ref)
        windowState.toggleDestinationMenu(chosen: model.session?.preferredProvider)
        #expect(windowState.expandedProvider == "ollama")                    // reopened: the chosen provider's models

        // "Default model": the model chosen for the provider in Settings.
        let menuAgain = ShellModelChoices.menu(for: "ollama", settings: model.settings, current: ShellDestinationMenu.chosenRef(model))
        let byDefault = try #require(menuAgain.choices.first)
        #expect(byDefault.title == "Default model (gemma4:e4b)")
        ShellDestinationMenu.choose(byDefault.ref, in: model, windowState: windowState)
        #expect(model.session?.preferredProvider == ProviderRef(providerID: "ollama", model: nil))
        #expect(model.activeModel == "gemma4:e4b")

        // Custom: the paper's choice goes, each job to its default again.
        windowState.toggleDestinationMenu(chosen: model.session?.preferredProvider)
        ShellDestinationMenu.chooseCustom(in: model, windowState: windowState)
        #expect(model.usesCustomProviders)
        #expect(model.session?.preferredProvider == nil)
        #expect(model.activeProvider?.id == "mock")
        #expect(!windowState.destinationMenuOpen)
    }

    /// The keyboard walks Custom, every provider, and the models of the one whose models are shown.
    @Test func theKeyboardWalksCustomTheProvidersAndTheModelsShown() {
        let settings = Self.settings(model: "example-large", cached: Self.anthropicModels)
        let rows = ShellDestinationMenu.keyboardRows(providers: [Sample.ollama, Sample.anthropic, Sample.claude], expanded: "anthropic-api",
                                                     settings: settings, current: nil)
        #expect(rows == [.custom, .provider("ollama"), .provider("anthropic-api"),
                         .model(ProviderRef(providerID: "anthropic-api", model: nil)),
                         .model(ProviderRef(providerID: "anthropic-api", model: "example-large")),
                         .model(ProviderRef(providerID: "anthropic-api", model: "example-small")),
                         .model(ProviderRef(providerID: "anthropic-api", model: "example-raw")),
                         .provider("claude-cli")])
    }

    /// Custom's three lines: each job's default, by the provider's short name and the model's name.
    @Test func customSaysWhereEachJobGoes() {
        var settings = Self.settings(model: "example-large", cached: Self.anthropicModels)
        settings.providers["ollama"] = ProviderSettings(enabled: true, model: "gemma4:e4b", inputMode: .auto)
        settings.providers["claude-cli"] = ProviderSettings(enabled: true, inputMode: .auto)
        settings.defaults = TaskDefaults(review: ProviderRef(providerID: "claude-cli", model: "sonnet"),
                                         chat: ProviderRef(providerID: "ollama", model: nil),
                                         report: ProviderRef(providerID: "anthropic-api", model: "example-small"))
        let providers = [Sample.anthropic, Sample.ollama, Sample.claude]
        #expect(ShellCustomDestinations.lines(settings: settings, providers: providers)
                == ["Review: Claude Code · sonnet", "Chat: Ollama · gemma4:e4b", "Report: Anthropic API · Example Small"])
        // Chat and report without a default of their own: the review's. A CLI without a model: "default".
        settings.defaults = TaskDefaults(review: ProviderRef(providerID: "claude-cli", model: nil))
        #expect(ShellCustomDestinations.lines(settings: settings, providers: providers)
                == ["Review: Claude Code · default", "Chat: Claude Code · default", "Report: Claude Code · default"])
        // A default that names a provider switched off, or none at all; a remote one under Local only.
        settings.providers["claude-cli"]?.enabled = false
        settings.defaults.report = ProviderRef(providerID: "anthropic-api", model: nil)
        settings.privacy.localOnly = true
        #expect(ShellCustomDestinations.lines(settings: settings, providers: providers)
                == ["Review: not set up", "Chat: not set up", "Report: Anthropic API · Example Large (blocked by Local only)"])
        #expect(ShellCustomDestinations.lines(settings: Self.settings(cached: []), providers: providers)
                == ["Review: not set up", "Chat: not set up", "Report: not set up"])
        #expect([ShellCustomDestinations.title, ShellCustomDestinations.caption, ShellCustomDestinations.editInSettings]
                == ["Custom", "Per action, as set in Settings", "Edit in Settings…"])
    }

    /// The default bar writes a reference with a model, or without one ("Default model"), or none ("Same as Review").
    @Test func theDefaultBarWritesTheModelOfEachJob() {
        var settings = Self.settings(model: "example-large", cached: Self.anthropicModels)
        ShellTaskDefaultsBar.set(ProviderRef(providerID: "anthropic-api", model: "example-small"), for: .review, in: &settings)
        ShellTaskDefaultsBar.set(ProviderRef(providerID: "anthropic-api", model: nil), for: .chat, in: &settings)
        ShellTaskDefaultsBar.set(nil, for: .report, in: &settings)
        #expect(settings.defaults == TaskDefaults(review: ProviderRef(providerID: "anthropic-api", model: "example-small"),
                                                  chat: ProviderRef(providerID: "anthropic-api", model: nil), report: nil))
        let providers = [Sample.anthropic, Sample.claude]
        #expect(ShellTaskDefaultsBar.label(settings.defaults.review, job: .review, providers: providers, settings: settings)
                == "Anthropic API · Example Small")
        #expect(ShellTaskDefaultsBar.label(settings.defaults.chat, job: .chat, providers: providers, settings: settings)
                == "Anthropic API · Default model")
        #expect(ShellTaskDefaultsBar.label(nil, job: .report, providers: providers, settings: settings) == "Same as Review")
        #expect(ShellTaskDefaultsBar.label(nil, job: .review, providers: providers, settings: settings) == "None")
        #expect(ShellTaskDefaultsBar.label(ProviderRef(providerID: "claude-cli", model: "sonnet"), job: .chat, providers: providers, settings: settings)
                == "Claude Code (off) · sonnet")
    }
}
