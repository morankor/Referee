import Foundation
import Testing
import RefereeCore
@testable import AppCore
import TestSupport

// Helpers for the tests of the two models. Every dependency is a fake from TestSupport, except a few small stand-ins
// that TestSupport does not have: a clock the test moves by hand (the debounces), a provider that counts its
// `listModels()` calls (Gate 0: no fake does), a paper service that fails to load, a session store that fails to
// read, and (step 5c) an engine whose reviews differ from call to call and can be held open, with the gate that holds
// them. They live here, in the test target, and nowhere else.

/// A clock the test moves by hand. A wait ends when the clock reaches its deadline, or with `CancellationError`.
final class ManualModelClock: ModelClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var waiters: [UUID: (deadline: Date, continuation: CheckedContinuation<Void, Error>)] = [:]

    init(start: Date = Date()) { current = start }

    func now() -> Date { lock.withLock { current } }

    func sleep(until deadline: Date) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if current >= deadline {
                    lock.unlock()
                    continuation.resume()
                } else if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = (deadline, continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            let waiter = lock.withLock { waiters.removeValue(forKey: id) }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves the clock on and ends every wait whose deadline it reaches.
    func advance(by seconds: TimeInterval) {
        let due: [CheckedContinuation<Void, Error>] = lock.withLock {
            current = current.addingTimeInterval(seconds)
            let ready = waiters.filter { $0.value.deadline <= current }
            for key in ready.keys { waiters[key] = nil }
            return ready.values.map(\.continuation)
        }
        for continuation in due { continuation.resume() }
    }
}

/// A provider with a scripted status, model list and answer, which counts its `listModels()` calls.
final class CountingModelProvider: LLMProvider, @unchecked Sendable {
    let descriptor: ProviderDescriptor
    private let lock = NSLock()
    private var listCalls = 0
    private let models: [ModelInfo]
    private let listFailure: LLMError?
    private let status: ProviderAvailability
    private let answer: String
    private let streamFailure: LLMError?

    init(id: ProviderID, isLocal: Bool = true, authMode: AuthMode = .local, models: [ModelInfo] = [], listFailure: LLMError? = nil,
         status: ProviderAvailability = .ready(detail: "Ready"), answer: String = "OK", streamFailure: LLMError? = nil) {
        descriptor = ProviderDescriptor(id: id, displayName: id, vendor: "Test", authMode: authMode, isLocal: isLocal,
                                        destination: isLocal ? "this Mac" : "\(id).example.org", supportsNativePDF: false, streaming: .token,
                                        retentionNote: "A test provider.", isExperimental: false)
        self.models = models
        self.listFailure = listFailure
        self.status = status
        self.answer = answer
        self.streamFailure = streamFailure
    }

    var listModelsCalls: Int { lock.withLock { listCalls } }

    func availability() async -> ProviderAvailability { status }

    func listModels() async throws -> [ModelInfo] {
        lock.withLock { listCalls += 1 }
        if let listFailure { throw listFailure }
        return models
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        let answer = answer
        let failure = streamFailure
        return AsyncThrowingStream { continuation in
            if let failure {
                continuation.finish(throwing: failure)
                return
            }
            continuation.yield(.textDelta(answer))
            continuation.yield(.finished(.endOfTurn, Usage(inputTokens: 5, outputTokens: 1)))
            continuation.finish()
        }
    }
}

/// A paper service whose `load` always fails with the given error.
struct FailingModelPaperService: PaperService {
    let error: PaperError
    func load(url: URL) async throws -> LoadedPaper { throw error }
    func load(data: Data, fileName: String) async throws -> LoadedPaper { throw error }
    func rects(for spans: [TextSpan], in document: DocumentRef) async -> [PageRect] { [] }
    func unload(_ document: DocumentRef) async {}
}

/// A session store that cannot read the stored session and counts what it is asked to write.
final class UnreadableModelSessionStore: SessionStoring, @unchecked Sendable {
    private let error: StoreError
    private let lock = NSLock()
    private var saved = 0
    init(_ error: StoreError) { self.error = error }
    var saveCount: Int { lock.withLock { saved } }
    func loadSession(sha256: String) async throws -> ReviewSession? { throw error }
    func save(_ session: ReviewSession) async throws { lock.withLock { saved += 1 } }
    func listSessions() async -> [SessionSummary] { [] }
    func deleteSession(sha256: String) async throws {}
}

/// A gate the test opens by hand: `wait()` returns once `open()` has been called, at once when it already has.
final class ModelTestGate: @unchecked Sendable {
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

/// Reviews as a real engine plays them, built per call from what the call was given (step 5c): a run record of the
/// call's own provider and model (`.started`, status `.running`), the comments `script` makes for that run, then
/// `.finished` with the run completed and `reportedModel` set to what `reports` says for the call's context. A call with
/// a gate in `gates` (by its position, 0 for the first review) waits after its comments until the test opens the gate:
/// a review under way. Every other job, and the plan, goes to the scripted engine, which records them as usual.
final class StagedReviewEngine: ReviewEngineProtocol, @unchecked Sendable {
    typealias Script = @Sendable (_ call: Int, _ context: EngineContext, _ existing: [ReviewComment], _ run: RunRecord) -> [ReviewComment]

    let scripted: ScriptedReviewEngine
    private let script: Script
    private let reports: @Sendable (EngineContext) -> String?
    private let gates: [Int: ModelTestGate]
    private let lock = NSLock()
    private var reviews: [(context: EngineContext, existing: [ReviewComment])] = []

    init(scripted: ScriptedReviewEngine, gates: [Int: ModelTestGate] = [:], reports: @escaping @Sendable (EngineContext) -> String? = { _ in nil },
         script: @escaping Script) {
        self.scripted = scripted
        self.gates = gates
        self.reports = reports
        self.script = script
    }

    /// What each review call was given, in order.
    var reviewCalls: [(context: EngineContext, existing: [ReviewComment])] { lock.withLock { reviews } }

    func plan(paper: LoadedPaper, context: EngineContext) async -> SendPlan { await scripted.plan(paper: paper, context: context) }

    func review(paper: LoadedPaper, existing: [ReviewComment], context: EngineContext) -> AsyncThrowingStream<ReviewEvent, Error> {
        let call = lock.withLock { () -> Int in
            reviews.append((context, existing))
            return reviews.count - 1
        }
        let started = RunRecord(id: UUID(), kind: .review, provider: context.provider, destination: "this Mac", sentPDF: false, requestCount: 0,
                                startedAt: ModelSample.start.addingTimeInterval(Double(call) * 600), status: .running)
        let comments = script(call, context, existing, started)
        var finished = started
        finished.status = .completed
        finished.requestCount = 1
        finished.finishedAt = started.startedAt.addingTimeInterval(60)
        finished.reportedModel = reports(context)
        let events: [ReviewEvent] = [.started(started)] + comments.map { .comment($0, replacesDraft: UUID()) }
        let gate = gates[call]
        return AsyncThrowingStream { continuation in
            let task = Task {
                for event in events { continuation.yield(event) }
                if let gate { await gate.wait() }
                continuation.yield(.finished(finished))
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                gate?.open()
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

/// Everything one review-model test works with.
@MainActor struct ModelHarness {
    let model: ReviewSessionModel
    let engine: ScriptedReviewEngine
    let store: InMemorySessionStore
    let resolver: FakeResolver
    let clock: ManualModelClock
    let paper: LoadedPaper
    let url: URL

    /// Opens the paper and waits until the plan and the model lists have arrived.
    func open() async {
        await model.open(url: url)
        await model.waitForBackgroundWork()
    }

    /// Waits until both lanes are idle.
    func finishJobs() async {
        while model.reviewLaneTask != nil || model.replyLaneTask != nil {
            await model.reviewLaneTask?.value
            await model.replyLaneTask?.value
        }
        await model.waitForBackgroundWork()
    }

    /// The context of the last engine call of that kind ("plan", "review", "discuss", "ask", "report", "revise").
    func lastContext(of call: String) -> EngineContext? {
        Array(zip(engine.calls, engine.contexts)).last { $0.0 == call }?.1
    }

    func calls(of call: String) -> Int {
        engine.calls.filter { $0 == call }.count
    }
}

enum ModelSample {
    static let localPlan = SendPlan(sendsPDF: false, requestCount: 1, estimatedInputTokens: 12_000, destination: "this Mac", isLocal: true)
    static let remotePlan = SendPlan(sendsPDF: false, requestCount: 1, estimatedInputTokens: 12_000, destination: "mock.example.org",
                                     isLocal: false)
    static let start = Date(timeIntervalSince1970: 1_795_000_000)

    /// The snapshot settings: the four mocks enabled with the model "mock", and "mock" the review default.
    static func settings(_ change: (inout AppSettings) -> Void = { _ in }) -> AppSettings {
        var settings = SnapshotSupport.settings()
        change(&settings)
        return settings
    }

    static func providers() -> [any LLMProvider] {
        [MockLLMProvider(id: "mock"), MockLLMProvider(id: "mock-remote", isLocal: false)]
    }

    static func run(_ kind: RunKind, _ status: RunStatus, provider: ProviderID = "mock", id: UUID = UUID()) -> RunRecord {
        RunRecord(id: id, kind: kind, provider: ProviderRef(providerID: provider, model: "mock"), destination: "this Mac", sentPDF: false,
                  requestCount: 1, startedAt: start, finishedAt: status == .running ? nil : start.addingTimeInterval(5), status: status,
                  usage: Usage(inputTokens: 100, outputTokens: 20))
    }

    /// A comment whose anchor covers `range` on `page` (0-based), or a page-only anchor (`range` nil), or none
    /// (`page` nil).
    static func comment(_ title: String, page: Int? = 0, range: RefereeCore.TextRange? = nil, quote: String = "", kind: CommentKind = .minor,
                        status: CommentStatus = .pending, origin: CommentOrigin = .ai(runID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!),
                        created: TimeInterval = 0, includeInReport: Bool = true) -> ReviewComment {
        let anchor: Anchor
        if let page, let range {
            anchor = Anchor(quote: quote, spans: [TextSpan(pageIndex: page, range: range)], pageIndex: page, confidence: .exact,
                            locationLabel: "p. \(page + 1)")
        } else if let page {
            anchor = Anchor(quote: quote, pageIndex: page, confidence: .pageOnly, locationLabel: "p. \(page + 1)")
        } else {
            anchor = Anchor(quote: quote, confidence: .none, locationLabel: "")
        }
        return ReviewComment(id: UUID(), origin: origin, status: status, kind: kind, category: "claims", title: title, body: "Body of " + title,
                             anchor: anchor, includeInReport: includeInReport, createdAt: start.addingTimeInterval(created),
                             updatedAt: start.addingTimeInterval(created))
    }

    /// A stored session for `paper` with these comments.
    static func session(for paper: LoadedPaper, comments: [ReviewComment] = [], conversations: [Conversation] = [],
                        report: ReportDraft? = nil) -> ReviewSession {
        ReviewSession(schemaVersion: 1, id: UUID(), document: paper.ref, meta: ManuscriptMeta(title: "A stored review", reviewerNotes: ""),
                      comments: comments, conversations: conversations, report: report, createdAt: start, updatedAt: start)
    }
}

/// A model on fakes. `seed` is put in the session store before the model exists, as a session saved earlier.
/// `wrap` puts something in front of the scripted engine (the report tests make lint depend on the text).
@MainActor func makeModelHarness(paper: LoadedPaper? = nil, settings: AppSettings = ModelSample.settings(),
                                 providers: [any LLMProvider] = ModelSample.providers(),
                                 engine: ScriptedReviewEngine = ScriptedReviewEngine(plan: ModelSample.localPlan),
                                 wrap: ((ScriptedReviewEngine) -> any ReviewEngineProtocol)? = nil, index: CitationIndex? = nil,
                                 seed: ReviewSession? = nil, sessions: (any SessionStoring)? = nil, paperService: (any PaperService)? = nil,
                                 clock: ManualModelClock = ManualModelClock()) async throws -> ModelHarness {
    let paper = try paper ?? makeSamplePaper()
    let store = InMemorySessionStore()
    if let seed { try await store.save(seed) }
    let resolver = FakeResolver()
    let dependencies = AppDependencies(paperService: paperService ?? FakePaperService(paper: paper), matcherFactory: { FakeQuoteMatcher(paper: $0) },
                                       citationIndexer: FakeCitationIndexer(index: index), engine: wrap?(engine) ?? engine, resolver: resolver,
                                       sessions: sessions ?? store, settings: InMemorySettingsStore(settings), providers: ProviderRegistry(providers),
                                       secrets: InMemorySecretStore())
    let model = ReviewSessionModel(dependencies: dependencies, settings: settings, clock: clock)
    // The fake paper service never reads the file; the URL only names where the model believes the PDF is.
    return ModelHarness(model: model, engine: engine, store: store, resolver: resolver, clock: clock, paper: paper,
                        url: FileManager.default.temporaryDirectory.appendingPathComponent(paper.ref.fileName))
}

/// Lets the main actor run until the condition holds, for ten seconds at most. Returns whether it held.
@MainActor @discardableResult
func waitForModel(_ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(10)
    while !condition() {
        if clock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}
