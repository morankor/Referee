import Foundation
import Testing
import RefereeCore
import AppCore
import TestSupport
@testable import RefereeUI

/// Settings ▸ Providers (plan.md section 9.6): status lights, setup hints, groups, the experimental warning.
@Suite @MainActor struct ShellProviderRowsTests {
    private typealias Sample = ShellTestData

    @Test func eachAvailabilityHasItsLightAndWords() {
        #expect(ShellProviderRows.status(nil) == ShellProviderStatus(light: .grey, headline: "Checking…", detail: nil, hint: nil))
        #expect(ShellProviderRows.status(.ready(detail: "Logged in · claude 2.1.330"))
                == ShellProviderStatus(light: .green, headline: "Ready", detail: "Logged in · claude 2.1.330", hint: nil))
        #expect(ShellProviderRows.status(.needsSetup(reason: "No API key", hint: "Add your Anthropic key in Settings ▸ Providers."))
                == ShellProviderStatus(light: .yellow, headline: "Needs setup", detail: "No API key",
                                       hint: "Add your Anthropic key in Settings ▸ Providers."))
        #expect(ShellProviderRows.status(.unavailable(reason: "Ollama at 127.0.0.1:11434 did not answer."))
                == ShellProviderStatus(light: .red, headline: "Unavailable", detail: "Ollama at 127.0.0.1:11434 did not answer.", hint: nil))
        #expect(ShellProviderRows.status(.ready(detail: "")).detail == nil)
    }

    /// The hints the real providers give (CLIProviders, LLMKit): a bare install command, commands in back quotes, prose.
    @Test func setupHintsOfferTheirCommandsForCopying() {
        #expect(ShellProviderRows.setupHint("npm install -g @openai/codex", isCLI: true)
                == ShellSetupHint(text: nil, commands: ["npm install -g @openai/codex"]))
        #expect(ShellProviderRows.setupHint("curl -fsSL https://claude.ai/install.sh | bash", isCLI: true)
                == ShellSetupHint(text: nil, commands: ["curl -fsSL https://claude.ai/install.sh | bash"]))
        #expect(ShellProviderRows.setupHint("Run `codex login`", isCLI: true) == ShellSetupHint(text: "Run `codex login`", commands: ["codex login"]))
        #expect(ShellProviderRows.setupHint("Run `claude` in Terminal and use /login", isCLI: true)
                == ShellSetupHint(text: "Run `claude` in Terminal and use /login", commands: ["claude"]))
        #expect(ShellProviderRows.setupHint("Start the Ollama app or run `ollama serve`.", isCLI: false)
                == ShellSetupHint(text: "Start the Ollama app or run `ollama serve`.", commands: ["ollama serve"]))
        #expect(ShellProviderRows.setupHint("Add your OpenAI key in Settings ▸ Providers.", isCLI: false)
                == ShellSetupHint(text: "Add your OpenAI key in Settings ▸ Providers.", commands: []))
        #expect(ShellProviderRows.setupHint("Paste an API key to use this provider.", isCLI: false).commands.isEmpty)
        #expect(ShellProviderRows.setupHint("  ", isCLI: true) == ShellSetupHint(text: nil, commands: []))
    }

    @Test func providersAreGroupedAsSection96Says() {
        let groups = ShellProviderRows.grouped([Sample.claude, Sample.anthropic, Sample.ollama, Sample.codex, Sample.xai])
        #expect(groups.map(\.group) == [.apiKey, .subscription, .local])
        #expect(groups.map { $0.providers.map(\.id) } == [["anthropic-api", "xai-api"], ["claude-cli", "codex-cli"], ["ollama"]])
        #expect(groups.map(\.group.title) == ["API key", "Subscription through an installed CLI", "Local"])
    }

    /// In the snapshot graph the four mocks come last, under "Built in", with the two stand-ins of step 5 (O3) after them.
    @Test func theSnapshotRegistryHasEveryStatusAndTheBuiltInsLast() async {
        let providers = SnapshotSupport.providers()
        let groups = ShellProviderRows.grouped(providers.map(\.descriptor))
        #expect(groups.map(\.group) == [.apiKey, .subscription, .local, .builtIn])
        #expect(groups.last?.providers.map(\.id) == ["mock", "mock-remote", "mock-fail", "mock-stall", "mock-slow", "mock-offline"])
        var lights: Set<ShellProviderStatus.Light> = []
        for provider in providers { lights.insert(ShellProviderRows.status(await provider.availability()).light) }
        #expect(lights == [.green, .yellow, .red])
    }

    @Test func theExperimentalWarningStaysUntilATestPromptSucceeds() {
        let unverified = ProviderSettings(enabled: true, inputMode: .auto)
        var verified = unverified
        verified.verifiedAt = Sample.date
        #expect(ShellProviderRows.showsExperimentalWarning(Sample.antigravity, settings: unverified))
        #expect(ShellProviderRows.showsExperimentalWarning(Sample.antigravity, settings: nil))
        #expect(!ShellProviderRows.showsExperimentalWarning(Sample.antigravity, settings: verified))
        #expect(!ShellProviderRows.showsExperimentalWarning(Sample.claude, settings: unverified))
        #expect(ShellProviderRows.experimentalWarning == "Experimental — not yet verified against the real CLI on this machine")
    }

    // ---- D21: Send Test Prompt ----

    /// What the test prompt does and costs, by kind of provider.
    @Test func theTestPromptsNoteFitsTheKindOfProvider() {
        #expect(ShellProviderRows.testPromptNote(for: Sample.anthropic) == "Sends “Reply with exactly: OK” to api.anthropic.com; costs a few tokens.")
        #expect(ShellProviderRows.testPromptNote(for: Sample.claude) == "Runs Claude Code once with “Reply with exactly: OK”; uses one message of your plan.")
        #expect(ShellProviderRows.testPromptNote(for: Sample.ollama) == "Sends “Reply with exactly: OK” to the model on this Mac; costs nothing.")
        let mock = SnapshotSupport.providers().map(\.descriptor).first { $0.id == "mock-offline" }
        #expect(mock.map(ShellProviderRows.testPromptNote(for:)) == "Sends “Reply with exactly: OK” to the built-in stand-in.")
    }

    /// Pressable only for a ready provider; otherwise its tooltip says why not.
    @Test func theTestPromptWaitsForAReadyProvider() {
        #expect(ShellProviderRows.canSendTestPrompt(.ready(detail: "Key set")))
        #expect(ShellProviderRows.testPromptHelp(.ready(detail: "Key set")) == nil)
        #expect(!ShellProviderRows.canSendTestPrompt(.needsSetup(reason: "Antigravity is not installed", hint: "curl …")))
        #expect(ShellProviderRows.testPromptHelp(.needsSetup(reason: "Antigravity is not installed", hint: "curl …"))
                == "Needs setup: Antigravity is not installed")
        #expect(ShellProviderRows.testPromptHelp(.unavailable(reason: "grok does not list an option")) == "Unavailable: grok does not list an option")
        #expect(!ShellProviderRows.canSendTestPrompt(nil))
        #expect(ShellProviderRows.testPromptHelp(nil) == "Checking…")
    }

    @Test func aStoredKeyOfAProviderThatIsOffAsksToSwitchItOn() {
        let off = ProviderSettings(enabled: false, inputMode: .auto)
        let on = ProviderSettings(enabled: true, inputMode: .auto)
        #expect(ShellProviderRows.keyWaitsForSwitch(Sample.anthropic, storedSecrets: ["anthropic-api"], settings: off))
        #expect(ShellProviderRows.keyWaitsForSwitch(Sample.anthropic, storedSecrets: ["anthropic-api"], settings: nil))
        #expect(!ShellProviderRows.keyWaitsForSwitch(Sample.anthropic, storedSecrets: ["anthropic-api"], settings: on))
        #expect(!ShellProviderRows.keyWaitsForSwitch(Sample.anthropic, storedSecrets: [], settings: off))
        #expect(!ShellProviderRows.keyWaitsForSwitch(Sample.claude, storedSecrets: ["claude-cli"], settings: off))     // no key
        #expect(ShellProviderRows.switchOnNote(Sample.anthropic) == "Switch on Anthropic API to use it.")
    }

    /// With nothing switched on, the pane starts at Ollama, under the box that says why.
    @Test func withNothingOnThePaneStartsAtOllama() {
        let providers = [Sample.anthropic, Sample.claude, Sample.ollama]
        var settings = DefaultSettings.make()
        for id in Array(settings.providers.keys) { settings.providers[id]?.enabled = false }
        #expect(ShellProviderRows.noneSwitchedOn(providers, settings: settings))
        #expect(ShellProviderRows.shownProvider(in: providers, chosen: nil, settings: settings)?.id == "ollama")
        #expect(ShellProviderRows.shownProvider(in: providers, chosen: "claude-cli", settings: settings)?.id == "claude-cli")
        settings.providers["claude-cli"]?.enabled = true
        #expect(!ShellProviderRows.noneSwitchedOn(providers, settings: settings))
        #expect(ShellProviderRows.shownProvider(in: providers, chosen: nil, settings: settings)?.id == "anthropic-api")
        #expect(ShellProviderRows.startWithLocal == "Start with a local model: Ollama keeps manuscripts on this Mac.")
    }

    // ---- D5: switching a provider on or off ----

    private static let registry = [Sample.anthropic, Sample.ollama, Sample.claude, Sample.xai]

    private static func allOff() -> AppSettings {
        var settings = DefaultSettings.make()
        for id in Array(settings.providers.keys) { settings.providers[id]?.enabled = false }
        return settings
    }

    @Test func switchingOnWithNoReviewDefaultMakesItTheDefault() {
        var settings = Self.allOff()
        settings.providers["ollama"]?.model = "gemma4:e4b"
        ShellProviderBindings.setEnabled(true, "ollama", in: &settings, providers: Self.registry)
        #expect(settings.providers["ollama"]?.enabled == true)
        #expect(settings.defaults.review == ProviderRef(providerID: "ollama", model: "gemma4:e4b"))
        // A second provider switched on leaves the default alone, and switches nothing else on.
        ShellProviderBindings.setEnabled(true, "anthropic-api", in: &settings, providers: Self.registry)
        #expect(settings.defaults.review == ProviderRef(providerID: "ollama", model: "gemma4:e4b"))
        #expect(settings.providers.filter { $0.value.enabled }.map(\.key).sorted() == ["anthropic-api", "ollama"])
    }

    @Test func switchingOnNeverReplacesAnExistingDefault() {
        var settings = Self.allOff()
        settings.defaults.review = ProviderRef(providerID: "claude-cli", model: nil)       // off, but chosen: it stays
        ShellProviderBindings.setEnabled(true, "anthropic-api", in: &settings, providers: Self.registry)
        #expect(settings.defaults.review == ProviderRef(providerID: "claude-cli", model: nil))
    }

    @Test func switchingTheReviewDefaultOffMovesItToAnotherProviderLocalFirst() {
        var settings = Self.allOff()
        for id: ProviderID in ["anthropic-api", "ollama", "claude-cli"] { settings.providers[id]?.enabled = true }
        settings.providers["ollama"]?.model = "phi4"
        settings.defaults = TaskDefaults(review: ProviderRef(providerID: "claude-cli", model: nil),
                                         chat: ProviderRef(providerID: "claude-cli", model: "sonnet"),
                                         report: ProviderRef(providerID: "anthropic-api", model: "example-large"))
        ShellProviderBindings.setEnabled(false, "claude-cli", in: &settings, providers: Self.registry)
        #expect(settings.providers["claude-cli"]?.enabled == false)
        #expect(settings.defaults.review == ProviderRef(providerID: "ollama", model: "phi4"))    // the local one, though listed after
        #expect(settings.defaults.chat == nil)                                                  // "Same as Review"
        #expect(settings.defaults.report == ProviderRef(providerID: "anthropic-api", model: "example-large"))
        // Without another local provider, the first other one switched on; without any, none.
        ShellProviderBindings.setEnabled(false, "ollama", in: &settings, providers: Self.registry)
        #expect(settings.defaults.review == ProviderRef(providerID: "anthropic-api", model: nil))
        ShellProviderBindings.setEnabled(false, "anthropic-api", in: &settings, providers: Self.registry)
        #expect(settings.defaults.review == nil)
        #expect(settings.defaults.report == nil)
        #expect(!settings.providers.values.contains { $0.enabled })
    }

    @Test func switchingAnotherProviderOffLeavesTheDefaultsAlone() {
        var settings = Self.allOff()
        for id: ProviderID in ["anthropic-api", "ollama"] { settings.providers[id]?.enabled = true }
        settings.defaults = TaskDefaults(review: ProviderRef(providerID: "ollama", model: nil))
        ShellProviderBindings.setEnabled(false, "anthropic-api", in: &settings, providers: Self.registry)
        #expect(settings.defaults == TaskDefaults(review: ProviderRef(providerID: "ollama", model: nil)))
    }

    /// The binding the switches use goes through the same rule, on a settings model.
    @Test func theSwitchOfASettingsModelMakesTheFirstProviderTheDefault() throws {
        let dependencies = AppDependencies(paperService: FakePaperService(paper: try makeSamplePaper()), matcherFactory: { FakeQuoteMatcher(paper: $0) },
                                           citationIndexer: FakeCitationIndexer(), engine: ScriptedReviewEngine(plan: Sample.plan(pdf: false, tokens: 1, to: "")),
                                           resolver: FakeResolver(), sessions: InMemorySessionStore(), settings: InMemorySettingsStore(),
                                           providers: ProviderRegistry(SnapshotSupport.providers()), secrets: InMemorySecretStore())
        let model = SettingsModel(dependencies: dependencies, settings: Self.allOff())
        ShellProviderBindings.enabled(model, "ollama").wrappedValue = true
        #expect(model.settings.providers["ollama"]?.enabled == true)
        #expect(model.settings.defaults.review?.providerID == "ollama")
    }

    /// Choosing the provider's model moves the job defaults that had its old model, not one given a model of its own.
    @Test func aJobDefaultWithAModelOfItsOwnKeepsIt() {
        var settings = Self.allOff()
        settings.providers["claude-cli"] = ProviderSettings(enabled: true, model: "opus", inputMode: .auto)
        settings.defaults = TaskDefaults(review: ProviderRef(providerID: "claude-cli", model: "opus"),
                                         chat: ProviderRef(providerID: "claude-cli", model: "haiku"),
                                         report: ProviderRef(providerID: "claude-cli", model: nil))
        ShellProviderBindings.chooseModel("sonnet", for: "claude-cli", in: &settings)
        #expect(settings.providers["claude-cli"]?.model == "sonnet")
        #expect(settings.defaults.review == ProviderRef(providerID: "claude-cli", model: "sonnet"))      // it followed the old choice
        #expect(settings.defaults.chat == ProviderRef(providerID: "claude-cli", model: "haiku"))        // its own
        #expect(settings.defaults.report == ProviderRef(providerID: "claude-cli", model: nil))          // "Default model" follows by itself
    }

    @Test func keysAndShowAllBelongToTheProvidersThatHaveThem() {
        #expect(ShellProviderRows.secretKey(for: Sample.anthropic) == "anthropic-api")
        #expect(ShellProviderRows.secretKey(for: Sample.claude) == nil)
        #expect(ShellProviderRows.secretKey(for: Sample.ollama) == nil)
        let openAI = ProviderDescriptor(id: "openai-api", displayName: "OpenAI API", vendor: "OpenAI", authMode: .apiKey, isLocal: false,
                                        destination: "api.openai.com", supportsNativePDF: true, streaming: .token, retentionNote: "", isExperimental: false)
        #expect(ShellProviderRows.hasShowAll(openAI))
        #expect(!ShellProviderRows.hasShowAll(Sample.anthropic))
    }

    @Test func rubricIDsAreSlugs() {
        #expect(ShellRubricEditor.slug("Claims vs. evidence") == "claims-vs-evidence")
        #expect(ShellRubricEditor.slug("  data  ") == "data")
        #expect(ShellRubricEditor.slug("--") == "")
        #expect(ShellRubricEditor.newID(existing: ["claims", "category-1"]) == "category-2")
    }
}
