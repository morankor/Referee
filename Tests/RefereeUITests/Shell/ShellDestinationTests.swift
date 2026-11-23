import Foundation
import Testing
import RefereeCore
import AppCore
import TestSupport
@testable import RefereeUI

/// The destination indicator (plan.md section 9.7, design review D3, D4, D5, D13): symbol, title, detail, tint and
/// tooltip for every row of the table.
@Suite struct ShellDestinationTests {
    private typealias Sample = ShellTestData

    @Test func nothingUsableIsGreyAndOpensSettings() {
        let state = ShellDestination.state(provider: nil, model: nil, plan: nil, verifiedAt: nil, localOnly: false, debugDump: false)
        #expect(state == ShellDestinationState(symbol: "nosign", title: "No AI provider", detail: nil, tint: .grey, opensSettings: true,
                                               debugDump: false, help: "Where this document is sent: No AI provider"))
        #expect(state.text == "No AI provider")
    }

    /// D5: providers are switched on but none is chosen for the paper: a click opens the menu, not Settings.
    @Test func providersToChooseFromAskForAChoice() {
        let state = ShellDestination.state(provider: nil, model: nil, plan: nil, verifiedAt: nil, localOnly: false, debugDump: false,
                                           hasChoices: true)
        #expect(state.symbol == "questionmark.circle")
        #expect(state.title == "Choose AI provider")
        #expect(state.detail == nil)
        #expect(state.tint == .grey)
        #expect(!state.opensSettings)
    }

    @Test func aLocalProviderIsGreenWithItsModel() {
        let plan = Sample.plan(pdf: false, tokens: 900, to: "127.0.0.1:11434", local: true)
        let state = ShellDestination.state(provider: Sample.ollama, model: "gemma4:e4b", plan: plan, verifiedAt: nil, localOnly: false, debugDump: false)
        #expect(state.text == "Local · gemma4:e4b")       // a local text plan says nothing of text: nothing leaves the Mac
        #expect(state.title == "Local")
        #expect(state.detail == "gemma4:e4b")
        #expect(state.symbol == "laptopcomputer")
        #expect(state.tint == .green)
        #expect(!state.opensSettings)
        #expect(state.help == "Where this document is sent: Local · gemma4:e4b")
    }

    @Test func anAPIProviderIsOrangeWithItsNameAndModel() {
        let pdf = Sample.plan(pdf: true, tokens: 153_000, to: "api.anthropic.com")
        let state = ShellDestination.state(provider: Sample.anthropic, model: "example-large", plan: pdf, verifiedAt: nil, localOnly: false, debugDump: false)
        #expect(state.text == "Anthropic API · example-large")
        #expect(state.title == "Anthropic API")
        #expect(state.detail == "example-large")
        #expect(state.symbol == "cloud")
        #expect(state.tint == .orange)
    }

    @Test func aSubscriptionCLIShowsItsShortNameAndDefault() {
        let pdf = Sample.plan(pdf: true, tokens: 40_000, to: "claude")
        let state = ShellDestination.state(provider: Sample.claude, model: nil, plan: pdf, verifiedAt: nil, localOnly: false, debugDump: false)
        #expect(state.text == "Claude Code · default")
        #expect(state.title == "Claude Code")
        #expect(state.detail == "default")
        #expect(state.symbol == "terminal")
        #expect(state.tint == .orange)
    }

    @Test func aRemoteTextPlanSaysTextOnly() {
        let text = Sample.plan(pdf: false, tokens: 9_000, to: "api.x.ai")
        let state = ShellDestination.state(provider: Sample.xai, model: "example-chat", plan: text, verifiedAt: nil, localOnly: false, debugDump: false)
        #expect(state.text == "xAI API · example-chat · text only")
        #expect(state.detail == "example-chat · text only")
        #expect(state.tint == .orange)
        // Until the plan is known nothing is said about it.
        let unknown = ShellDestination.state(provider: Sample.xai, model: "example-chat", plan: nil, verifiedAt: nil, localOnly: false, debugDump: false)
        #expect(unknown.text == "xAI API · example-chat")
    }

    /// D3: the longest detail goes on the second line; the tooltip has all of it.
    @Test func anUnverifiedExperimentalProviderSaysSo() {
        let text = Sample.plan(pdf: false, tokens: 9_000, to: "agy")
        let unverified = ShellDestination.state(provider: Sample.antigravity, model: "example-extended-context-preview", plan: text, verifiedAt: nil,
                                                localOnly: false, debugDump: false)
        #expect(unverified.title == "Antigravity")
        #expect(unverified.detail == "example-extended-context-preview · text only · experimental")
        #expect(unverified.text == "Antigravity · example-extended-context-preview · text only · experimental")
        #expect(unverified.help == "Where this document is sent: " + unverified.text)
        #expect(unverified.tint == .orange)
        let verified = ShellDestination.state(provider: Sample.antigravity, model: nil, plan: text, verifiedAt: Sample.date, localOnly: false,
                                              debugDump: false)
        #expect(verified.text == "Antigravity · default · text only")
    }

    @Test func localOnlyBlocksARemoteProviderInRed() {
        let state = ShellDestination.state(provider: Sample.anthropic, model: "example-large", plan: nil, verifiedAt: nil, localOnly: true,
                                           debugDump: false)
        #expect(state == ShellDestinationState(symbol: "lock.fill", title: "Remote blocked", detail: "Local only is on", tint: .red,
                                               opensSettings: false, debugDump: false,
                                               help: "Where this document is sent: Remote blocked · Local only is on"))
        #expect(state.text == "Remote blocked · Local only is on")
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

    // ---- D4 and step 5c: chat and report elsewhere, "Custom" ----

    /// Step 5c: the jobs go to different places (Custom with per-job defaults): "Custom" over the three jobs in short form,
    /// cut at its end; orange when any of them leaves this Mac.
    @Test func jobsThatGoToDifferentPlacesReadCustom() {
        let state = ShellDestination.state(provider: Sample.ollama, model: "gemma4:e4b", plan: nil, verifiedAt: nil, localOnly: false,
                                           debugDump: false, chatProvider: Sample.claude, reportProvider: Sample.ollama)
        #expect(state.title == "Custom")
        #expect(state.detail == "Review: this Mac · Chat: Claude Code · Report: this Mac")
        #expect(state.text == "Custom · Review: this Mac · Chat: Claude Code · Report: this Mac")
        #expect(state.tint == .orange)
        #expect(state.symbol == "arrow.triangle.branch")
        #expect(state.detailTruncatesAtEnd)
        #expect(!state.opensSettings)
        #expect(state.help == "Where this document is sent: Custom · Review: this Mac · Chat: Claude Code · Report: this Mac")

        // The coordinator's example: a CLI by its short name, an API provider by its vendor.
        let each = ShellDestination.state(provider: Sample.ollama, model: "phi4", plan: nil, verifiedAt: nil, localOnly: false, debugDump: false,
                                          chatProvider: Sample.claude, reportProvider: Sample.anthropic)
        #expect(each.detail == "Review: this Mac · Chat: Claude Code · Report: Anthropic")
        let report = ShellDestination.state(provider: Sample.anthropic, model: "example-large", plan: nil, verifiedAt: nil, localOnly: false,
                                            debugDump: false, chatProvider: Sample.anthropic, reportProvider: Sample.ollama)
        #expect(report.detail == "Review: Anthropic · Chat: Anthropic · Report: this Mac")
        #expect(report.tint == .orange)
    }

    /// Jobs that all go to one place read as that one destination, also when their providers differ; a job without a
    /// provider sends nothing and is no place of its own.
    @Test func jobsThatGoToOnePlaceReadAsThatDestination() {
        let same = ShellDestination.state(provider: Sample.ollama, model: "phi4", plan: nil, verifiedAt: nil, localOnly: false, debugDump: false,
                                          chatProvider: Sample.ollama, reportProvider: nil)
        #expect(same.text == "Local · phi4")
        #expect(same.tint == .green)
        #expect(!same.detailTruncatesAtEnd)
        let mock = ProviderDescriptor(id: "mock", displayName: "Mock", vendor: "Mock", authMode: .none, isLocal: true, destination: "this Mac",
                                      supportsNativePDF: false, streaming: .token, retentionNote: "", isExperimental: false)
        let local = ShellDestination.state(provider: Sample.ollama, model: "gemma4:e4b", plan: nil, verifiedAt: nil, localOnly: false,
                                           debugDump: false, chatProvider: mock, reportProvider: mock)
        #expect(local.text == "Local · gemma4:e4b")                       // two providers, one place: this Mac
        #expect(local.tint == .green)
        let codex = ShellDestination.state(provider: Sample.codex, model: "gpt-x", plan: nil, verifiedAt: nil, localOnly: false, debugDump: false,
                                           chatProvider: Sample.codex, reportProvider: Sample.codex)
        #expect(codex.text == "Codex · gpt-x")
        // A job without a provider is listed as "not set up" once the others differ.
        let missing = ShellDestination.state(provider: Sample.ollama, model: "phi4", plan: nil, verifiedAt: nil, localOnly: false, debugDump: false,
                                             chatProvider: nil, reportProvider: Sample.codex)
        #expect(missing.detail == "Review: this Mac · Chat: not set up · Report: Codex")
    }

    /// With Local only on, a remote job sends nothing: "blocked", and the indicator stays green when the rest is local.
    @Test func aRemoteJobBlockedByLocalOnlyReadsBlocked() {
        let state = ShellDestination.state(provider: Sample.ollama, model: "phi4", plan: nil, verifiedAt: nil, localOnly: true, debugDump: false,
                                           chatProvider: Sample.claude, reportProvider: Sample.ollama)
        #expect(state.title == "Custom")
        #expect(state.detail == "Review: this Mac · Chat: blocked · Report: this Mac")
        #expect(state.tint == .green)
    }

    @Test func aNameCarriesOneBracketAtMost() {
        #expect(ShellDestination.nameWithPlace(Sample.claude) == "Claude Code (subscription)")
        #expect(ShellDestination.nameWithPlace(Sample.ollama) == "Ollama (local)")
        #expect(ShellDestination.nameWithPlace(Sample.anthropic) == "Anthropic API (api.anthropic.com)")
    }

    @Test func chatElsewhereIsNamedWithoutAReviewProviderToo() {
        let state = ShellDestination.state(provider: nil, model: nil, plan: nil, verifiedAt: nil, localOnly: false, debugDump: false,
                                           chatProvider: Sample.claude, reportProvider: nil, hasChoices: true)
        #expect(state.title == "Choose AI provider")
        #expect(state.detail == "chat: Claude Code")
        #expect(state.tint == .orange)
    }

    // ---- D13: a local provider that cannot run ----

    @Test func aLocalProviderThatNeedsSetupSaysWhyInOrange() {
        let state = ShellDestination.state(provider: Sample.ollama, model: "gemma4:e4b", plan: nil, verifiedAt: nil, localOnly: false,
                                           debugDump: false,
                                           availability: .needsSetup(reason: "Ollama is not running", hint: "Start the Ollama app or run `ollama serve`."))
        #expect(state.symbol == "exclamationmark.triangle.fill")
        #expect(state.tint == .orange)
        #expect(state.title == "Local")
        #expect(state.detail == "Ollama is not running")
        #expect(state.help == "Ollama is not running. Start the Ollama app or run ollama serve.")
        #expect(!state.opensSettings)
    }

    @Test func anUnavailableLocalProviderIsRed() {
        let state = ShellDestination.state(provider: Sample.ollama, model: "phi4", plan: nil, verifiedAt: nil, localOnly: false, debugDump: false,
                                           availability: .unavailable(reason: "Ollama at 127.0.0.1:11434 did not answer."))
        #expect(state.tint == .red)
        #expect(state.detail == "Ollama at 127.0.0.1:11434 did not answer.")
        #expect(state.help == "Ollama at 127.0.0.1:11434 did not answer.")
        let ready = ShellDestination.state(provider: Sample.ollama, model: "phi4", plan: nil, verifiedAt: nil, localOnly: false, debugDump: false,
                                           availability: .ready(detail: "Ollama 0.40.17"))
        #expect(ready.text == "Local · phi4")
        #expect(ready.tint == .green)
    }

    /// D13: a remote provider is never checked from the window; a status given for one changes nothing.
    @Test func aRemoteProvidersStatusIsNotShown() {
        let state = ShellDestination.state(provider: Sample.anthropic, model: "example-large", plan: nil, verifiedAt: nil, localOnly: false,
                                           debugDump: false, availability: .needsSetup(reason: "No API key", hint: "Paste an API key."))
        #expect(state.text == "Anthropic API · example-large")
        #expect(state.symbol == "cloud")
    }

    @Test func theTooltipOfAProblemReadsAsSentences() {
        #expect(ShellDestination.tooltip(reason: "Ollama is not running", hint: "Start the Ollama app or run `ollama serve`.")
                == "Ollama is not running. Start the Ollama app or run ollama serve.")
        #expect(ShellDestination.tooltip(reason: "No model.", hint: "") == "No model.")
        #expect(ShellDestination.tooltip(reason: "", hint: "Run `ollama pull gemma4:e4b`.") == "Run ollama pull gemma4:e4b.")
    }

    @Test func shortNamesDropTheBracketedPlan() {
        #expect(ShellDestination.shortName(Sample.claude) == "Claude Code")
        #expect(ShellDestination.shortName(Sample.codex) == "Codex")
        #expect(ShellDestination.shortName(Sample.anthropic) == "Anthropic API")
        #expect(ShellProviderRows.listName(Sample.antigravity) == "Antigravity")
        #expect(ShellProviderRows.listName(Sample.ollama) == "Ollama (local)")      // only subscription CLIs are shortened in the list
        #expect(ShellDestination.jobName(Sample.ollama) == "Local")
        #expect(ShellDestination.jobName(Sample.claude) == "Claude Code")
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

    /// The indicator of a real model in the snapshot graph's settings: "Local" over "mock" (scene review-empty).
    @Test @MainActor func theIndicatorOfAModelUsesItsActiveProviderAndPlan() async throws {
        let model = try await ShellTestModels.openedOnTheSnapshotRegistry(settings: SnapshotSupport.settings())
        let state = ShellDestination.state(of: model, environment: [:])
        #expect(state.text == "Local · mock")
        #expect(state.title == "Local")
        #expect(state.detail == "mock")
        #expect(state.tint == .green)
        #expect(!state.debugDump)
    }

    /// D4 and step 5c on a model (scene design-review-split-destinations): `defaults.chat` names Claude Code while the
    /// review stays on "mock": "Custom"; Claude Code is never asked for its status (O2 asks local providers only).
    @Test @MainActor func aModelWithAChatDefaultElsewhereNamesIt() async throws {
        var settings = SnapshotSupport.settings()
        settings.providers["claude-cli"] = ProviderSettings(enabled: true, inputMode: .auto)
        settings.defaults.chat = ProviderRef(providerID: "claude-cli", model: nil)
        let model = try await ShellTestModels.openedOnTheSnapshotRegistry(settings: settings)
        let state = ShellDestination.state(of: model, environment: [:])
        #expect(state.text == "Custom · Review: this Mac · Chat: Claude Code · Report: this Mac")
        #expect(state.tint == .orange)
        #expect(ShellDestinationMenu.otherJobLines(model) == ["Chat questions go to Claude Code (subscription)."])

        // The paper's own provider takes every job: one destination again.
        model.setActiveProvider(ProviderRef(providerID: "mock", model: "mock"))
        #expect(ShellDestination.state(of: model, environment: [:]).text == "Local · mock")
    }

    /// D13 on a model (scene design-review-provider-offline): O3's `mock-offline` chosen, its status arrives.
    @Test @MainActor func aModelWhoseLocalProviderIsNotRunningSaysSo() async throws {
        var settings = SnapshotSupport.settings()
        settings.providers["mock-offline"] = ProviderSettings(enabled: true, model: "mock", inputMode: .auto)
        let model = try await ShellTestModels.openedOnTheSnapshotRegistry(settings: settings)
        model.setActiveProvider(ProviderRef(providerID: "mock-offline", model: nil))
        await ShellSceneSupport.wait(seconds: 5) { model.activeAvailability != nil }
        let state = ShellDestination.state(of: model, environment: [:])
        #expect(state.text == "Local · Ollama is not running")
        #expect(state.tint == .orange)
        #expect(state.symbol == "exclamationmark.triangle.fill")
    }

    @Test func otherJobsAreNamedInTheMenu() {
        #expect(ShellDestinationMenu.otherJobLines(review: Sample.ollama, chat: Sample.claude, report: Sample.anthropic)
                == ["Chat questions go to Claude Code (subscription).", "The report is written by Anthropic API (api.anthropic.com)."])
        #expect(ShellDestinationMenu.otherJobLines(review: Sample.ollama, chat: Sample.ollama, report: nil).isEmpty)
    }
}
