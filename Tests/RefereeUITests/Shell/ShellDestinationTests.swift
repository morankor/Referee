import Foundation
import Testing
import RefereeCore
import AppCore
import TestSupport
@testable import RefereeUI

/// The destination indicator (plan.md section 9.7): icon, text and tint for every row of the table.
@Suite struct ShellDestinationTests {
    private typealias Sample = ShellTestData

    @Test func nothingUsableIsGreyAndOpensSettings() {
        let state = ShellDestination.state(provider: nil, model: nil, plan: nil, verifiedAt: nil, localOnly: false, debugDump: false)
        #expect(state == ShellDestinationState(symbol: "nosign", text: "No AI provider", tint: .grey, opensSettings: true, debugDump: false))
    }

    @Test func aLocalProviderIsGreenWithItsModel() {
        let plan = Sample.plan(pdf: false, tokens: 900, to: "127.0.0.1:11434", local: true)
        let state = ShellDestination.state(provider: Sample.ollama, model: "gemma4:e4b", plan: plan, verifiedAt: nil, localOnly: false, debugDump: false)
        #expect(state.text == "Local · gemma4:e4b")       // a local text plan says nothing of text: nothing leaves the Mac
        #expect(state.symbol == "laptopcomputer")
        #expect(state.tint == .green)
        #expect(!state.opensSettings)
    }

    @Test func anAPIProviderIsOrangeWithItsNameAndModel() {
        let pdf = Sample.plan(pdf: true, tokens: 153_000, to: "api.anthropic.com")
        let state = ShellDestination.state(provider: Sample.anthropic, model: "example-large", plan: pdf, verifiedAt: nil, localOnly: false, debugDump: false)
        #expect(state.text == "Anthropic API · example-large")
        #expect(state.symbol == "cloud")
        #expect(state.tint == .orange)
    }

    @Test func aSubscriptionCLIShowsItsShortNameAndDefault() {
        let pdf = Sample.plan(pdf: true, tokens: 40_000, to: "claude")
        let state = ShellDestination.state(provider: Sample.claude, model: nil, plan: pdf, verifiedAt: nil, localOnly: false, debugDump: false)
        #expect(state.text == "Claude Code · default")
        #expect(state.symbol == "terminal")
        #expect(state.tint == .orange)
    }

    @Test func aRemoteTextPlanSaysTextOnly() {
        let text = Sample.plan(pdf: false, tokens: 9_000, to: "api.x.ai")
        let state = ShellDestination.state(provider: Sample.xai, model: "example-chat", plan: text, verifiedAt: nil, localOnly: false, debugDump: false)
        #expect(state.text == "xAI API · example-chat · text only")
        #expect(state.tint == .orange)
        // Until the plan is known nothing is said about it.
        let unknown = ShellDestination.state(provider: Sample.xai, model: "example-chat", plan: nil, verifiedAt: nil, localOnly: false, debugDump: false)
        #expect(unknown.text == "xAI API · example-chat")
    }

    @Test func anUnverifiedExperimentalProviderSaysSo() {
        let text = Sample.plan(pdf: false, tokens: 9_000, to: "agy")
        let unverified = ShellDestination.state(provider: Sample.antigravity, model: nil, plan: text, verifiedAt: nil, localOnly: false, debugDump: false)
        #expect(unverified.text == "Antigravity · default · text only · experimental")
        #expect(unverified.tint == .orange)
        let verified = ShellDestination.state(provider: Sample.antigravity, model: nil, plan: text, verifiedAt: Sample.date, localOnly: false,
                                              debugDump: false)
        #expect(verified.text == "Antigravity · default · text only")
    }

    @Test func localOnlyBlocksARemoteProviderInRed() {
        let state = ShellDestination.state(provider: Sample.anthropic, model: "example-large", plan: nil, verifiedAt: nil, localOnly: true,
                                           debugDump: false)
        #expect(state == ShellDestinationState(symbol: "lock.fill", text: "Remote blocked (Local only)", tint: .red, opensSettings: false,
                                               debugDump: false))
        let local = ShellDestination.state(provider: Sample.ollama, model: "phi4", plan: nil, verifiedAt: nil, localOnly: true, debugDump: false)
        #expect(local.text == "Local · phi4")
        #expect(local.tint == .green)
    }

    @Test func theDebugDumpTagFollowsTheEnvironment() {
        #expect(ShellDestination.debugDumpIsOn(["REFEREE_DEBUG_DUMP": "/private/tmp/dump"]))
        #expect(!ShellDestination.debugDumpIsOn(["REFEREE_DEBUG_DUMP": ""]))
        #expect(!ShellDestination.debugDumpIsOn([:]))
        let state = ShellDestination.state(provider: Sample.ollama, model: "phi4", plan: nil, verifiedAt: nil, localOnly: false, debugDump: true)
        #expect(state.debugDump)
        #expect(state.text == "Local · phi4")
    }

    @Test func shortNamesDropTheBracketedPlan() {
        #expect(ShellDestination.shortName(Sample.claude) == "Claude Code")
        #expect(ShellDestination.shortName(Sample.codex) == "Codex")
        #expect(ShellDestination.shortName(Sample.anthropic) == "Anthropic API")
        #expect(ShellProviderRows.listName(Sample.antigravity) == "Antigravity")
        #expect(ShellProviderRows.listName(Sample.ollama) == "Ollama (local)")      // only subscription CLIs are shortened in the list
    }

    @Test func theWelcomeLineNamesTheReviewDefault() {
        var settings = DefaultSettings.make()
        let providers = [Sample.ollama, Sample.anthropic]
        #expect(ShellDestination.welcomeLine(settings: settings, providers: providers) == .notSetUp)
        settings.defaults.review = ProviderRef(providerID: "ollama", model: nil)
        settings.providers["ollama"]?.model = "gemma4:e4b"
        #expect(ShellDestination.welcomeLine(settings: settings, providers: providers) == .configured("AI: Local · gemma4:e4b", isLocal: true))
        settings.defaults.review = ProviderRef(providerID: "anthropic-api", model: "example-large")
        #expect(ShellDestination.welcomeLine(settings: settings, providers: providers) == .notSetUp)        // not enabled
        settings.providers["anthropic-api"]?.enabled = true
        #expect(ShellDestination.welcomeLine(settings: settings, providers: providers)
                == .configured("AI: Anthropic API · example-large", isLocal: false))
    }

    /// The indicator of a real model in the snapshot graph's settings: "Local · mock" (scene review-empty).
    @Test @MainActor func theIndicatorOfAModelUsesItsActiveProviderAndPlan() async throws {
        let paper = try makeSamplePaper()
        let plan = SendPlan(sendsPDF: false, requestCount: 1, estimatedInputTokens: 900, destination: "this Mac", isLocal: true)
        let dependencies = AppDependencies(paperService: FakePaperService(paper: paper), matcherFactory: { FakeQuoteMatcher(paper: $0) },
                                           citationIndexer: FakeCitationIndexer(), engine: ScriptedReviewEngine(plan: plan), resolver: FakeResolver(),
                                           sessions: InMemorySessionStore(), settings: InMemorySettingsStore(),
                                           providers: ProviderRegistry(SnapshotSupport.providers()), secrets: InMemorySecretStore())
        let model = ReviewSessionModel(dependencies: dependencies, settings: SnapshotSupport.settings())
        await model.open(url: Fixtures.url("pdf/ay_round_nolinks.pdf"))
        let state = ShellDestination.state(of: model, environment: [:])
        #expect(state.text == "Local · mock")
        #expect(state.tint == .green)
        #expect(!state.debugDump)
    }
}
