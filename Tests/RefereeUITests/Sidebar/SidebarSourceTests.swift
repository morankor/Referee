import Foundation
import Testing
import RefereeCore
import AppCore
import TestSupport
@testable import RefereeUI

/// Which provider and model wrote a comment or an answer (step 5b): "Claude Code · Sonnet", "Codex · default model".
@Suite struct SidebarSourceTests {
    typealias Sample = SidebarTestData

    static let claude = Sample.descriptor("claude-cli", "Claude Code (subscription)", .subscriptionCLI)
    static let codex = Sample.descriptor("codex-cli", "Codex (ChatGPT plan)", .subscriptionCLI)
    static let openAI = Sample.descriptor("openai-api", "OpenAI API", .apiKey)
    static let claudeModels = [ModelInfo(id: "sonnet", displayName: "Sonnet"), ModelInfo(id: "opus", displayName: "Opus")]

    @Test func aProviderAndTheModelItWasAskedFor() {
        let names = SidebarSourceNames(descriptors: [Self.claude, Self.openAI], cachedModels: ["claude-cli": Self.claudeModels])
        let claude = names.source(of: ProviderRef(providerID: "claude-cli", model: "sonnet"))
        #expect(claude.text == "Claude Code · Sonnet")
        #expect(claude.help == "Written by claude-cli, model sonnet")
        #expect(claude.spoken == "Written by Claude Code, model Sonnet")
        // A model the cached list does not have reads as its id.
        #expect(names.source(of: ProviderRef(providerID: "openai-api", model: "gpt-5.1")).text == "OpenAI API · gpt-5.1")
    }

    @Test func noModelIsTheProvidersDefault() {
        let codex = SidebarSourceNames(descriptors: [Self.codex]).source(of: ProviderRef(providerID: "codex-cli", model: nil))
        #expect(codex.text == "Codex · default model")
        #expect(codex.help == "Written by codex-cli, model not named (the provider's default)")
    }

    /// A provider switched off since its review is still named by its descriptor: the window has every registered
    /// provider (`registeredProviders`, step 5c). One that is not registered at all shows its id.
    @Test @MainActor func aProviderThatIsNoLongerOnIsStillNamed() async throws {
        let paper = try makeSamplePaper()
        let dependencies = AppDependencies(paperService: FakePaperService(paper: paper), matcherFactory: { FakeQuoteMatcher(paper: $0) },
                                           citationIndexer: FakeCitationIndexer(), engine: ScriptedReviewEngine(plan: Sample.plan),
                                           resolver: FakeResolver(), sessions: InMemorySessionStore(), settings: InMemorySettingsStore(),
                                           providers: ProviderRegistry(SnapshotSupport.providers()), secrets: InMemorySecretStore())
        let settings = SnapshotSupport.settings()               // the four mocks on, the nine real providers off
        #expect(settings.providers["claude-cli"]?.enabled != true)
        let model = ReviewSessionModel(dependencies: dependencies, settings: settings)
        #expect(!model.selectableProviders.contains { $0.id == "claude-cli" })
        let names = SidebarSourceNames(model: model)
        #expect(names.source(of: ProviderRef(providerID: "claude-cli", model: "sonnet")).text == "Claude Code · sonnet")
        #expect(names.source(of: ProviderRef(providerID: "ollama", model: "gemma4:e4b")).text == "Ollama · gemma4:e4b")
        #expect(names.source(of: ProviderRef(providerID: "grok-cli", model: nil)).text == "Grok Build · default model")
        #expect(names.source(of: ProviderRef(providerID: "anthropic-api", model: "m")).text == "Anthropic API · m")
        #expect(names.source(of: ProviderRef(providerID: "some-future-provider", model: "m")).text == "some-future-provider · m")
    }

    @Test func namesLoseTheirPlanButStandInsKeepTheirBracket() {
        #expect(SidebarSourceNames.shortName(Self.claude) == "Claude Code")
        #expect(SidebarSourceNames.shortName(Sample.descriptor("ollama", "Ollama (local)", .local)) == "Ollama")
        #expect(SidebarSourceNames.shortName(Sample.descriptor("codex-cli", "Codex (ChatGPT plan)", .subscriptionCLI)) == "Codex")
        #expect(SidebarSourceNames.shortName(Self.openAI) == "OpenAI API")
        #expect(SidebarSourceNames.shortName(Sample.descriptor("mock-remote", "Mock (remote)", .none)) == "Mock (remote)")
    }

    @Test func aCommentNamesItsRunAndTheRefereesOwnNamesNothing() {
        let claudeRun = Sample.run("claude-cli", model: "sonnet")
        let codexRun = Sample.run("codex-cli", model: nil)
        let names = SidebarSourceNames(descriptors: [Self.claude, Self.codex], cachedModels: ["claude-cli": Self.claudeModels],
                                       runs: [claudeRun, codexRun])
        #expect(names.source(of: Sample.comment(origin: .ai(runID: claudeRun.id)))?.text == "Claude Code · Sonnet")
        #expect(names.source(of: Sample.comment(origin: .ai(runID: codexRun.id)))?.text == "Codex · default model")
        #expect(names.source(of: Sample.comment(origin: .user)) == nil)
        let all = names.sources(of: [Sample.comment(origin: .ai(runID: claudeRun.id)), Sample.comment(origin: .user)])
        #expect(all.count == 1)
    }

    /// A run is recorded when it ends: the comments of the review that is running name the active provider; an AI
    /// comment whose run the session does not have says so.
    @Test func aRunningReviewAndARunTheSessionDoesNotHave() {
        let start = Sample.created
        let running = SidebarSourceNames.Running(since: start, ref: ProviderRef(providerID: "claude-cli", model: "opus"))
        let names = SidebarSourceNames(descriptors: [Self.claude], cachedModels: ["claude-cli": Self.claudeModels], running: running)
        let fresh = Sample.comment(origin: .ai(runID: UUID()), createdAt: start.addingTimeInterval(5))
        #expect(names.source(of: fresh)?.text == "Claude Code · Opus")
        #expect(names.runningSource?.text == "Claude Code · Opus")
        let older = Sample.comment(origin: .ai(runID: UUID()), createdAt: start.addingTimeInterval(-5))
        #expect(names.source(of: older) == .unrecorded)
        #expect(SidebarSource.unrecorded.text == "Model not recorded")
        #expect(SidebarSourceNames().source(of: fresh) == .unrecorded)
        #expect(SidebarSourceNames().runningSource == nil)
    }

    @Test func anAnswerNamesItsProviderAndTheRefereesMessagesNothing() {
        let names = SidebarSourceNames(descriptors: [Self.claude], cachedModels: ["claude-cli": Self.claudeModels])
        let answer = ThreadMessage(id: UUID(), role: .assistant, text: "Partly.", createdAt: Sample.created,
                                   provider: ProviderRef(providerID: "claude-cli", model: "sonnet"))
        #expect(names.source(of: answer)?.text == "Claude Code · Sonnet")
        let question = ThreadMessage(id: UUID(), role: .user, text: "Is it fair?", createdAt: Sample.created)
        #expect(names.source(of: question) == nil)
        let unknown = ThreadMessage(id: UUID(), role: .assistant, text: "Partly.", createdAt: Sample.created)
        #expect(names.source(of: unknown) == nil)
    }

    /// Room for the model a provider reports it used, once that is recorded: it wins over the one asked for.
    @Test func aReportedModelWinsOverTheRequestedOne() {
        var source = SidebarSourceNames(descriptors: [Self.codex]).source(of: ProviderRef(providerID: "codex-cli", model: nil))
        source.reportedModel = "gpt-5.1-codex"
        #expect(source.text == "Codex · gpt-5.1-codex")
        #expect(source.help == "Written by codex-cli, model gpt-5.1-codex")
    }
}
