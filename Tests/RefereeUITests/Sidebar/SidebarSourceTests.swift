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

    /// A run is recorded when it starts (step 5c): a comment of the review under way names that run's provider and
    /// model; the drafts name the run under way; an AI comment whose run the session does not have says so.
    @Test func aRunningReviewAndARunTheSessionDoesNotHave() {
        let start = Sample.created
        var underWay = Sample.run("claude-cli", model: "opus", startedAt: start)
        underWay.status = .running
        underWay.finishedAt = nil
        let running = SidebarSourceNames.Running(since: start, ref: underWay.provider)
        let names = SidebarSourceNames(descriptors: [Self.claude], cachedModels: ["claude-cli": Self.claudeModels], runs: [underWay],
                                       running: running)
        let fresh = Sample.comment(origin: .ai(runID: underWay.id), createdAt: start.addingTimeInterval(5))
        #expect(names.source(of: fresh)?.text == "Claude Code · Opus")
        #expect(names.runningSource?.text == "Claude Code · Opus")
        let unknown = Sample.comment(origin: .ai(runID: UUID()), createdAt: start.addingTimeInterval(5))
        #expect(names.source(of: unknown) == .unrecorded)
        #expect(SidebarSource.unrecorded.text == "Model not recorded")
        #expect(SidebarSourceNames().source(of: fresh) == .unrecorded)
        #expect(SidebarSourceNames().runningSource == nil)
    }

    /// Through the model: while a review runs, its comments and drafts name the provider and model the review was started
    /// with, also after the document has been moved to another provider (step 5c, the Sidebar's contract problem 2).
    @Test @MainActor func theCommentsOfAReviewUnderWayKeepItsProviderWhenTheDocumentChangesProvider() async throws {
        let gate = SidebarSourceGate()
        let harness = try await SidebarTestHarness.open(comments: [], engine: ScriptedReviewEngine(plan: Sample.plan),
                                                        providers: [MockLLMProvider(id: "mock"), MockLLMProvider(id: "mock-remote", isLocal: false)],
                                                        wrap: { SidebarHeldReviewEngine(scripted: $0, gate: gate) })
        let model = harness.model
        model.setActiveProvider(ProviderRef(providerID: "mock", model: "model-x"))
        model.startReview()
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while model.session?.comments.isEmpty != false, clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let comment = try #require(model.session?.comments.first)
        #expect(SidebarSourceNames(model: model).source(of: comment)?.text == "Mock · model-x")
        #expect(SidebarSourceNames(model: model).runningSource?.text == "Mock · model-x")

        // The referee moves the document to another provider while the review runs: the labels stay the run's.
        model.setActiveProvider(ProviderRef(providerID: "mock-remote", model: "model-y"))
        #expect(model.activeProvider?.id == "mock-remote")
        #expect(SidebarSourceNames(model: model).source(of: comment)?.text == "Mock · model-x")
        #expect(SidebarSourceNames(model: model).runningSource?.text == "Mock · model-x")

        gate.open()
        while model.runState != .idle, clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.runState == .idle)
        #expect(SidebarSourceNames(model: model).source(of: comment)?.text == "Mock · model-x")
        #expect(SidebarSourceNames(model: model).runningSource == nil)
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

/// A gate the test opens by hand.
private final class SidebarSourceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        for waiter in waiting { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

/// A review as the real engine plays it, held open: the run of the call's own provider and model (`.started`), one
/// comment of that run, then nothing until the gate opens, then `.finished`. Everything else goes to the scripted engine.
private final class SidebarHeldReviewEngine: ReviewEngineProtocol, @unchecked Sendable {
    let scripted: ScriptedReviewEngine
    let gate: SidebarSourceGate

    init(scripted: ScriptedReviewEngine, gate: SidebarSourceGate) {
        self.scripted = scripted
        self.gate = gate
    }

    func plan(paper: LoadedPaper, context: EngineContext) async -> SendPlan { await scripted.plan(paper: paper, context: context) }

    func review(paper: LoadedPaper, existing: [ReviewComment], context: EngineContext) -> AsyncThrowingStream<ReviewEvent, Error> {
        let run = RunRecord(id: UUID(), kind: .review, provider: context.provider, destination: "this Mac", sentPDF: false, requestCount: 0,
                            startedAt: SidebarTestData.created, status: .running)
        var finished = run
        finished.status = .completed
        finished.finishedAt = run.startedAt.addingTimeInterval(60)
        let comment = SidebarTestData.comment(origin: .ai(runID: run.id), title: "Delivered while the review runs")
        let gate = gate
        return AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.started(run))
                continuation.yield(.comment(comment, replacesDraft: UUID()))
                await gate.wait()
                continuation.yield(.finished(finished))
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                gate.open()
            }
        }
    }

    func discuss(paper: LoadedPaper, comment: ReviewComment, message: String, context: EngineContext) -> AsyncThrowingStream<ReplyEvent, Error> {
        scripted.discuss(paper: paper, comment: comment, message: message, context: context)
    }

    func ask(paper: LoadedPaper, conversation: Conversation, question: String, context: EngineContext) -> AsyncThrowingStream<ReplyEvent, Error> {
        scripted.ask(paper: paper, conversation: conversation, question: question, context: context)
    }

    func generateReport(paper: LoadedPaper, session: ReviewSession, context: EngineContext) -> AsyncThrowingStream<ReportEvent, Error> {
        scripted.generateReport(paper: paper, session: session, context: context)
    }

    func reviseVoice(draft: ReportDraft, findings: [LintFinding], context: EngineContext) -> AsyncThrowingStream<ReportEvent, Error> {
        scripted.reviseVoice(draft: draft, findings: findings, context: context)
    }

    func lint(reportMarkdown: String) -> [LintFinding] { scripted.lint(reportMarkdown: reportMarkdown) }
}
