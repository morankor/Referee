import Foundation
import Testing
import RefereeCore

// Gate 0, step 1 (plan.md section 11.4): every protocol of Appendix A has a consumer.
//
// Each type below is written from its protocol alone, as the kind of type the real implementations are: an actor for
// PaperService, ReferenceResolving, SessionStoring and SettingsStoring; a class for SecretStoring, LLMProvider and
// ReviewEngineProtocol; a struct for the rest. `callEveryRequirement` then calls every requirement through the
// existentials that AppDependencies holds, as AppCore will. If a protocol changes in a way that its implementers or
// its callers cannot follow, this file stops compiling.

// ---- A.1 ----

private struct ConsumerError: RefereeError {
    var userMessage: String { "Something went wrong." }
    var recoverySuggestion: String? { "Try again." }
    var isRetryable: Bool { true }
}

// ---- A.2 ----

private struct ConsumerTextBuilder: PaperTextBuilding {
    func build(from raw: RawDocument) -> PaperText {
        let pages = raw.pages.map { page in
            PageText(index: page.index, label: page.label, size: page.size, string: page.string,
                     lines: page.lines.map { TextLine(pageIndex: page.index, range: $0.range, contentRange: $0.range, text: $0.text, kind: .body, bounds: $0.bounds) })
        }
        return PaperText(pages: pages, hasTextLayer: true, hasMarginLineNumbers: false)
    }
}

private struct ConsumerQuoteMatcher: QuoteMatching {
    let paper: PaperText
    func locate(quote: String, pageHint: Int?) -> AnchorMatch? {
        for page in paper.pages.sorted(by: { ($0.index == pageHint ? 0 : 1, $0.index) < ($1.index == pageHint ? 0 : 1, $1.index) }) {
            let found = (page.string as NSString).range(of: quote)
            if found.location != NSNotFound { return AnchorMatch(spans: [TextSpan(pageIndex: page.index, range: TextRange(found))], confidence: .exact) }
        }
        return nil
    }
    func locationLabel(for spans: [TextSpan]) -> String { spans.first.map { "p. \($0.pageIndex + 1)" } ?? "" }
}

private struct ConsumerRenderer: PaperRendering {
    func render(_ paper: PaperText, pages: Range<Int>?) -> String {
        paper.pages[(pages ?? paper.pages.indices).clamped(to: paper.pages.indices)].map { "[[page \($0.index + 1)]]\n\($0.string)\n" }.joined()
    }
    func chunkPageRanges(_ paper: PaperText, maxCharacters: Int) -> [Range<Int>] {
        paper.pages.indices.map { $0..<($0 + 1) }
    }
}

private actor ConsumerPaperService: PaperService {
    private var open: [String: LoadedPaper] = [:]
    func load(url: URL) async throws -> LoadedPaper {
        guard let data = try? Data(contentsOf: url) else { throw PaperError.unreadable("it does not exist") }
        return try await load(data: data, fileName: url.lastPathComponent)
    }
    func load(data: Data, fileName: String) async throws -> LoadedPaper {
        guard data.starts(with: Data("%PDF-".utf8)) else { throw PaperError.notAPDF }
        let raw = RawDocument(pages: [RawPage(index: 0, size: PageSize(width: 612, height: 792), string: "A sentence on the only page.",
                                              lines: [RawLine(range: TextRange(location: 0, length: 28), text: "A sentence on the only page.")])])
        let paper = LoadedPaper(ref: DocumentRef(sha256: String(repeating: "c", count: 64), fileName: fileName, byteCount: data.count, pageCount: 1),
                                data: data, isEncrypted: false, text: ConsumerTextBuilder().build(from: raw))
        open[paper.ref.sha256] = paper
        return paper
    }
    func rects(for spans: [TextSpan], in document: DocumentRef) async -> [PageRect] {
        guard open[document.sha256] != nil else { return [] }
        return spans.map { PageRect(pageIndex: $0.pageIndex, x: 72, y: 700, width: Double($0.range.length) * 5, height: 12) }
    }
    func unload(_ document: DocumentRef) async { open[document.sha256] = nil }
}

// ---- A.3 ----

private struct ConsumerIndexer: CitationIndexing {
    func buildIndex(paper: PaperText, links: [RawLink]) -> CitationIndex {
        CitationIndex(style: links.isEmpty ? .unknown : .numeric)
    }
}

private actor ConsumerResolver: ReferenceResolving {
    private var cache: [String: [Int: ResolvedReference]] = [:]
    func resolve(_ entry: BibEntry, documentSHA256: String) async -> ResolvedReference {
        if let cached = cache[documentSHA256]?[entry.id] { return cached }
        let result = ResolvedReference(entryID: entry.id, status: .notFound, confidence: 0, resolvedAt: Date(timeIntervalSince1970: 0))
        cache[documentSHA256, default: [:]][entry.id] = result
        return result
    }
    func forget(documentSHA256: String) async { cache[documentSHA256] = nil }
    func fetchPDF(for reference: ResolvedReference) async throws -> URL { throw ResolverError.noOpenAccessPDF }
    /// Synchronous in the protocol, so an actor answers it without isolation.
    nonisolated func searchURL(for entry: BibEntry) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "scholar.example.org"
        components.queryItems = [URLQueryItem(name: "q", value: entry.rawText)]
        return components.url ?? URL(fileURLWithPath: "/")
    }
}

// ---- A.5 ----

private final class ConsumerProvider: LLMProvider {
    let descriptor = ProviderDescriptor(id: "consumer", displayName: "Consumer", vendor: "Test", authMode: .none, isLocal: true, destination: "this Mac",
                                        supportsNativePDF: false, streaming: .token, retentionNote: "Nothing leaves this Mac.", isExperimental: false)
    func availability() async -> ProviderAvailability { .ready(detail: "Always") }
    func listModels() async throws -> [ModelInfo] { [ModelInfo(id: "echo", displayName: "Echo", contextWindow: 1_000)] }
    /// Echoes the text parts back, then finishes.
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        let echo = request.parts.compactMap { part -> String? in if case .text(let text) = part { return text } else { return nil } }.joined()
        return AsyncThrowingStream { continuation in
            continuation.yield(.status("Echoing"))
            continuation.yield(.textDelta(echo))
            continuation.yield(.finished(.endOfTurn, Usage(inputTokens: 1, outputTokens: 1)))
            continuation.finish()
        }
    }
}

private struct ConsumerRegistry: ProviderResolving {
    let all: [any LLMProvider]
    func provider(id: ProviderID) -> (any LLMProvider)? { all.first { $0.descriptor.id == id } }
}

private final class ConsumerSecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func secret(for key: String) throws -> String? { lock.withLock { values[key] } }
    func setSecret(_ value: String?, for key: String) throws { lock.withLock { values[key] = value } }
}

// ---- A.6 ----

private final class ConsumerEngine: ReviewEngineProtocol {
    private static let moment = Date(timeIntervalSince1970: 1_800_000_000)

    func plan(paper: LoadedPaper, context: EngineContext) async -> SendPlan {
        SendPlan(sendsPDF: false, requestCount: 1, estimatedInputTokens: paper.data.count / 4, destination: "this Mac", isLocal: true)
    }
    func review(paper: LoadedPaper, existing: [ReviewComment], context: EngineContext) -> AsyncThrowingStream<ReviewEvent, Error> {
        let run = Self.run(.review, context)
        return Self.play([.started(run), .phase(.preparing), .notice("Nothing to say."), .finished(Self.completed(run))])
    }
    func discuss(paper: LoadedPaper, comment: ReviewComment, message: String, context: EngineContext) -> AsyncThrowingStream<ReplyEvent, Error> {
        reply(.discussion, context)
    }
    func ask(paper: LoadedPaper, conversation: Conversation, question: String, context: EngineContext) -> AsyncThrowingStream<ReplyEvent, Error> {
        reply(.question, context)
    }
    func generateReport(paper: LoadedPaper, session: ReviewSession, context: EngineContext) -> AsyncThrowingStream<ReportEvent, Error> {
        let run = Self.run(.report, context)
        return Self.play([.started(run), .textDelta("## Summary assessment"),
                          .finished(ReportDraft(markdown: "## Summary assessment", userEdited: false), run: Self.completed(run))])
    }
    func reviseVoice(draft: ReportDraft, findings: [LintFinding], context: EngineContext) -> AsyncThrowingStream<ReportEvent, Error> {
        let run = Self.run(.revise, context)
        return Self.play([.started(run), .finished(draft, run: Self.completed(run))])
    }
    func lint(reportMarkdown: String) -> [LintFinding] {
        let found = (reportMarkdown as NSString).range(of: "robust")
        return found.location == NSNotFound ? [] : [LintFinding(id: 0, range: TextRange(found), rule: "banned-word", message: "\"robust\"")]
    }

    private func reply(_ kind: RunKind, _ context: EngineContext) -> AsyncThrowingStream<ReplyEvent, Error> {
        let run = Self.run(kind, context)
        let message = ThreadMessage(id: UUID(), role: .assistant, text: "Yes.", createdAt: Self.moment, provider: context.provider)
        return Self.play([.started(run), .textDelta("Yes."), .finished(reply: message, proposal: nil, run: Self.completed(run))])
    }
    private static func run(_ kind: RunKind, _ context: EngineContext) -> RunRecord {
        RunRecord(id: UUID(), kind: kind, provider: context.provider, destination: "this Mac", sentPDF: false, requestCount: 1, startedAt: moment,
                  status: .running)
    }
    private static func completed(_ run: RunRecord) -> RunRecord {
        var done = run
        done.finishedAt = moment
        done.status = .completed
        return done
    }
    private static func play<Event: Sendable>(_ events: [Event]) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

// ---- A.7 ----

private actor ConsumerSettingsStore: SettingsStoring {
    private var stored: AppSettings?
    func load() async -> AppSettings { stored ?? DefaultSettings.make() }
    func save(_ settings: AppSettings) async throws { stored = settings }
}

private actor ConsumerSessionStore: SessionStoring {
    private var sessions: [String: ReviewSession] = [:]
    func loadSession(sha256: String) async throws -> ReviewSession? { sessions[sha256] }
    func save(_ session: ReviewSession) async throws { sessions[session.document.sha256] = session }
    func listSessions() async -> [SessionSummary] {
        sessions.values.sorted { $0.updatedAt > $1.updatedAt }.map {
            SessionSummary(id: $0.document.sha256, fileName: $0.document.fileName, title: $0.meta.title, lastKnownPath: $0.document.lastKnownPath,
                           updatedAt: $0.updatedAt, commentCount: $0.comments.count, pendingCount: $0.comments.filter { $0.status == .pending }.count,
                           hasReport: $0.report != nil)
        }
    }
    func deleteSession(sha256: String) async throws { sessions[sha256] = nil }
}

// ---- every requirement, called through the existentials ----

/// Calls each requirement of each protocol of Appendix A once, through `any` types, and checks the little that the
/// consumers above promise. `builder` and `renderer` are not in AppDependencies: the paper service and the engine hold them.
private func callEveryRequirement(of dependencies: AppDependencies, builder: any PaperTextBuilding, renderer: any PaperRendering) async throws {
    let moment = Date(timeIntervalSince1970: 1_800_000_000)

    // A.1: the protocol, and the error types of Appendix A that conform to it.
    let errors: [any RefereeError] = [ConsumerError(), PaperError.notAPDF, ResolverError.offline, LLMError.cancelled, SecretError.unreadable(status: -25293),
                                      StoreError.io("disk full")]
    for error in errors {
        #expect(!error.userMessage.isEmpty)
        _ = error.recoverySuggestion
        _ = error.isRetryable
    }

    // A.2
    let raw = RawDocument(pages: [RawPage(index: 0, size: PageSize(width: 612, height: 792), string: "Herding is common.",
                                          lines: [RawLine(range: TextRange(location: 0, length: 18), text: "Herding is common.")])])
    let text = builder.build(from: raw)
    let matcher = dependencies.matcherFactory(text)
    let match = try #require(matcher.locate(quote: "is common", pageHint: 0))
    #expect(match.spans == [TextSpan(pageIndex: 0, range: TextRange(location: 8, length: 9))])
    #expect(matcher.locationLabel(for: match.spans) == "p. 1")
    #expect(renderer.render(text, pages: nil).hasPrefix("[[page 1]]"))
    #expect(renderer.chunkPageRanges(text, maxCharacters: 100) == [0..<1])
    let paper = try await dependencies.paperService.load(data: Data("%PDF-1.7\n".utf8), fileName: "manuscript.pdf")
    await #expect(throws: PaperError.notAPDF) { _ = try await dependencies.paperService.load(data: Data("plain".utf8), fileName: "note.txt") }
    await #expect(throws: PaperError.self) { _ = try await dependencies.paperService.load(url: URL(fileURLWithPath: "/nonexistent-folder/missing.pdf")) }
    #expect(await dependencies.paperService.rects(for: match.spans, in: paper.ref).count == 1)
    await dependencies.paperService.unload(paper.ref)
    #expect(await dependencies.paperService.rects(for: match.spans, in: paper.ref).isEmpty)

    // A.3
    #expect(dependencies.citationIndexer.buildIndex(paper: text, links: []).style == .unknown)
    let entry = BibEntry(id: 4, rawText: "Lee, J. (2021). Observational learning.", parsed: ParsedReference(authorSurnames: ["Lee"], year: 2021))
    let resolved = await dependencies.resolver.resolve(entry, documentSHA256: paper.ref.sha256)
    #expect(resolved.entryID == 4)
    await dependencies.resolver.forget(documentSHA256: paper.ref.sha256)
    await #expect(throws: ResolverError.noOpenAccessPDF) { _ = try await dependencies.resolver.fetchPDF(for: resolved) }
    #expect(dependencies.resolver.searchURL(for: entry).scheme == "https")
    #expect(await dependencies.resolver.cachedPDFBytes() == 0)            // Gate 1: the protocol's defaults
    await dependencies.resolver.clearPDFCache()

    // A.5
    #expect(dependencies.providers.all.map(\.descriptor.id) == ["consumer"])
    #expect(dependencies.providers.provider(id: "elsewhere") == nil)
    let provider = try #require(dependencies.providers.provider(id: "consumer"))
    #expect(provider.descriptor.isLocal)
    #expect(await provider.availability() == .ready(detail: "Always"))
    #expect(try await provider.listModels().map(\.id) == ["echo"])
    #expect(try await provider.listModels(includeHidden: true).map(\.id) == ["echo"])   // Gate 1: the default is listModels()
    var events: [LLMEvent] = []
    for try await event in provider.stream(LLMRequest(system: "Repeat.", parts: [.text("Hello")], purpose: .ping)) { events.append(event) }
    #expect(events == [.status("Echoing"), .textDelta("Hello"), .finished(.endOfTurn, Usage(inputTokens: 1, outputTokens: 1))])
    try dependencies.secrets.setSecret("first", for: "anthropic-api")
    #expect(try dependencies.secrets.secret(for: "anthropic-api") == "first")
    try dependencies.secrets.setSecret(nil, for: "anthropic-api")
    #expect(try dependencies.secrets.secret(for: "anthropic-api") == nil)

    // A.6
    let settings = DefaultSettings.make()
    let context = EngineContext(provider: ProviderRef(providerID: "consumer", model: "echo"), providerSettings: ProviderSettings(enabled: true, inputMode: .auto),
                                model: ModelInfo(id: "echo", displayName: "Echo", contextWindow: 1_000), prompts: settings.prompts, rubric: settings.rubric,
                                meta: ManuscriptMeta(reviewerNotes: ""), paperDigest: nil)
    #expect(await dependencies.engine.plan(paper: paper, context: context).requestCount == 1)
    var reviewEvents: [ReviewEvent] = []
    for try await event in dependencies.engine.review(paper: paper, existing: [], context: context) { reviewEvents.append(event) }
    guard case .finished(let run)? = reviewEvents.last else {
        Issue.record("a review ends with .finished")
        return
    }
    #expect(run.status == .completed)
    let comment = ReviewComment(id: UUID(), origin: .ai(runID: run.id), status: .pending, kind: .major, category: "claims", title: "t", body: "b",
                                anchor: Anchor(quote: "is common", confidence: .none, locationLabel: ""), includeInReport: true, createdAt: moment,
                                updatedAt: moment)
    var replies = 0
    for try await _ in dependencies.engine.discuss(paper: paper, comment: comment, message: "Why?", context: context) { replies += 1 }
    for try await _ in dependencies.engine.ask(paper: paper, conversation: Conversation(id: UUID(), createdAt: moment), question: "What?", context: context) {
        replies += 1
    }
    #expect(replies == 6)
    let session = ReviewSession(schemaVersion: 1, id: UUID(), document: paper.ref, meta: ManuscriptMeta(reviewerNotes: ""), comments: [comment],
                                createdAt: moment, updatedAt: moment)
    var reports: [ReportEvent] = []
    for try await event in dependencies.engine.generateReport(paper: paper, session: session, context: context) { reports.append(event) }
    for try await event in dependencies.engine.reviseVoice(draft: ReportDraft(markdown: "## Summary assessment", userEdited: false), findings: [],
                                                          context: context) {
        reports.append(event)
    }
    #expect(reports.count == 5)
    #expect(ReplyEvent.notice("The PDF was refused.") != ReplyEvent.textDelta("The PDF was refused."))   // Gate 1
    #expect(ReportEvent.notice("The PDF was refused.") != ReportEvent.textDelta("The PDF was refused."))
    #expect(dependencies.engine.lint(reportMarkdown: "A robust effect.").map(\.rule) == ["banned-word"])
    // Step 5, venues (G.9): a conformer that knows nothing of venues gets the default, its own journal check.
    #expect(dependencies.engine.lint(reportMarkdown: "A robust effect.", venue: DefaultSettings.venues[3]).map(\.rule) == ["banned-word"])
    #expect(context.venue == .unspecifiedJournal)

    // A.7
    var saved = await dependencies.settings.load()
    saved.privacy.localOnly = true
    try await dependencies.settings.save(saved)
    #expect(await dependencies.settings.load() == saved)
    try await dependencies.sessions.save(session)
    #expect(try await dependencies.sessions.loadSession(sha256: paper.ref.sha256) == session)
    #expect(await dependencies.sessions.listSessions().map(\.id) == [paper.ref.sha256])
    #expect(await dependencies.sessions.recoveryNotice(sha256: paper.ref.sha256) == nil)   // Gate 1: the default
    try await dependencies.sessions.deleteSession(sha256: paper.ref.sha256)
    #expect(try await dependencies.sessions.loadSession(sha256: paper.ref.sha256) == nil)
    try await dependencies.sessions.save(session)
    try await dependencies.sessions.deleteAllSessions()                    // Gate 1: the default deletes what the list shows
    #expect(await dependencies.sessions.listSessions().isEmpty)

    // A.8
    #expect(dependencies.dataDirectory == nil)
}

@Suite struct ContractConsumersTests {
    @Test func everyRequirementOfEveryProtocolOfAppendixACanBeImplementedAndCalled() async throws {
        let dependencies = AppDependencies(paperService: ConsumerPaperService(), matcherFactory: { ConsumerQuoteMatcher(paper: $0) },
                                           citationIndexer: ConsumerIndexer(), engine: ConsumerEngine(), resolver: ConsumerResolver(),
                                           sessions: ConsumerSessionStore(), settings: ConsumerSettingsStore(),
                                           providers: ConsumerRegistry(all: [ConsumerProvider()]), secrets: ConsumerSecretStore())
        try await callEveryRequirement(of: dependencies, builder: ConsumerTextBuilder(), renderer: ConsumerRenderer())
    }

    /// The concrete registry of Appendix A.8 is one more consumer of ProviderResolving.
    @Test func theRegistryOfAppendixA8ResolvesByID() {
        let registry: any ProviderResolving = ProviderRegistry([ConsumerProvider()])
        #expect(registry.all.count == 1)
        #expect(registry.provider(id: "consumer")?.descriptor.displayName == "Consumer")
        #expect(registry.provider(id: "mock") == nil)
    }
}
