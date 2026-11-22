import Foundation
import Testing
import RefereeCore
@testable import AppCore
import TestSupport

// Helpers for the tests of the two models. Every dependency is a fake from TestSupport, except four small stand-ins
// that TestSupport does not have: a clock the test moves by hand (the debounces), a provider that counts its
// `listModels()` calls (Gate 0: no fake does), a paper service that fails to load, and a session store that fails to
// read. They live here, in the test target, and nowhere else.

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
