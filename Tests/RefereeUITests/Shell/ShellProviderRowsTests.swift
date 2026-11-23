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

    /// In the snapshot graph the four mocks come last, under "Built in".
    @Test func theSnapshotRegistryHasEveryStatusAndTheBuiltInsLast() async {
        let providers = SnapshotSupport.providers()
        let groups = ShellProviderRows.grouped(providers.map(\.descriptor))
        #expect(groups.map(\.group) == [.apiKey, .subscription, .local, .builtIn])
        #expect(groups.last?.providers.map(\.id) == ["mock", "mock-remote", "mock-fail", "mock-stall"])
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
        #expect(ShellProviderRows.testPromptNote == "sends 'Reply with exactly: OK'; uses a few tokens")
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
