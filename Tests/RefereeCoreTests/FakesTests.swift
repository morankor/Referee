import Foundation
import Testing
import RefereeCore
import TestSupport

/// The simple fakes of TestSupport (plan.md sections 10.3 and 11.3): each test pins the behaviour its doc comment promises.
@Suite struct FakesTests {
    private let moment = Date(timeIntervalSince1970: 1_800_000_000)

    /// A paper of two pages, small enough to read: three lines on page 1, one of them not body text; two on page 2.
    private func tinyPaper() -> PaperText {
        func line(_ page: Int, _ location: Int, _ text: String, kind: LineKind = .body, y: Double? = nil) -> TextLine {
            TextLine(pageIndex: page, range: TextRange(location: location, length: text.utf16.count),
                     contentRange: TextRange(location: location, length: text.utf16.count), text: text, kind: kind,
                     bounds: y.map { PageRect(pageIndex: page, x: 72, y: $0, width: 400, height: 11) })
        }
        let first = PageText(index: 0, label: "1", size: PageSize(width: 612, height: 792),
                             string: "Herding is common.\nCONFIDENTIAL\nSørensen showed it — twice.",
                             lines: [line(0, 0, "Herding is common.", y: 700), line(0, 19, "CONFIDENTIAL", kind: .watermark, y: 400),
                                     line(0, 32, "Sørensen showed it — twice.", y: 680)])
        let second = PageText(index: 1, label: "2", size: PageSize(width: 612, height: 792), string: "Herding is rare.\nThe end.",
                              lines: [line(1, 0, "Herding is rare."), line(1, 17, "The end.")])
        return PaperText(pages: [first, second], hasTextLayer: true, hasMarginLineNumbers: false)
    }

    private func session(_ sha256: String, updatedAt: Date, pending: Int = 0, approved: Int = 0, report: Bool = false) -> ReviewSession {
        func comment(_ status: CommentStatus) -> ReviewComment {
            ReviewComment(id: UUID(), origin: .user, status: status, kind: .minor, category: "other", title: "t", body: "b",
                          anchor: Anchor(quote: "", confidence: .none, locationLabel: ""), includeInReport: true, createdAt: moment, updatedAt: moment)
        }
        return ReviewSession(schemaVersion: 1, id: UUID(),
                             document: DocumentRef(sha256: sha256, fileName: "\(sha256.prefix(4)).pdf", lastKnownPath: "/tmp/x.pdf", byteCount: 10, pageCount: 2),
                             meta: ManuscriptMeta(title: "Title \(sha256.prefix(4))", reviewerNotes: ""),
                             comments: (0..<pending).map { _ in comment(.pending) } + (0..<approved).map { _ in comment(.approved) },
                             report: report ? ReportDraft(markdown: "## Summary assessment", userEdited: false) : nil,
                             createdAt: moment, updatedAt: updatedAt)
    }

    private func context(model: ModelInfo? = nil, digest: String? = nil) -> EngineContext {
        EngineContext(provider: ProviderRef(providerID: "mock", model: model?.id), providerSettings: ProviderSettings(enabled: true, inputMode: .auto),
                      model: model, prompts: DefaultSettings.make().prompts, meta: ManuscriptMeta(reviewerNotes: ""), paperDigest: digest)
    }

    // ---- stores ----

    @Test func theSessionStoreKeepsListsAndDeletes() async throws {
        let store = InMemorySessionStore()
        #expect(try await store.loadSession(sha256: "aaaa") == nil)
        #expect(await store.listSessions().isEmpty)

        let older = session("aaaa", updatedAt: moment, pending: 2, approved: 1)
        let newer = session("bbbb", updatedAt: moment.addingTimeInterval(60), report: true)
        try await store.save(older)
        try await store.save(newer)
        #expect(try await store.loadSession(sha256: "aaaa") == older)
        #expect(try await store.loadSession(sha256: "bbbb") == newer)

        let summaries = await store.listSessions()
        #expect(summaries.map(\.id) == ["bbbb", "aaaa"])                 // newest first
        #expect(summaries.last == SessionSummary(id: "aaaa", fileName: "aaaa.pdf", title: "Title aaaa", lastKnownPath: "/tmp/x.pdf",
                                                 updatedAt: moment, commentCount: 3, pendingCount: 2, hasReport: false))
        #expect(summaries.first?.hasReport == true)

        // Saving again replaces: one session per document.
        var changed = older
        changed.updatedAt = moment.addingTimeInterval(120)
        changed.comments = []
        try await store.save(changed)
        #expect(try await store.loadSession(sha256: "aaaa") == changed)
        #expect(await store.listSessions().map(\.id) == ["aaaa", "bbbb"])

        try await store.deleteSession(sha256: "aaaa")
        try await store.deleteSession(sha256: "never-saved")
        #expect(try await store.loadSession(sha256: "aaaa") == nil)
        #expect(await store.listSessions().map(\.id) == ["bbbb"])
    }

    /// What WP8b's autosave test reads: every call of `save(_:)` counts, also one that saves an unchanged session;
    /// nothing else does.
    @Test func theSessionStoreCountsEverySave() async throws {
        let store = InMemorySessionStore()
        #expect(store.saveCount == 0)
        let first = session("aaaa", updatedAt: moment)
        try await store.save(first)
        try await store.save(first)
        try await store.save(session("bbbb", updatedAt: moment))
        #expect(store.saveCount == 3)
        _ = try await store.loadSession(sha256: "aaaa")
        _ = await store.listSessions()
        try await store.deleteSession(sha256: "aaaa")
        #expect(store.saveCount == 3)
        #expect(InMemorySessionStore().saveCount == 0)                     // one count per store
    }

    @Test func theSettingsStoreReturnsWhatWasSavedLast() async throws {
        #expect(await InMemorySettingsStore().load() == DefaultSettings.make())

        var settings = SnapshotSupport.settings()
        let store = InMemorySettingsStore(settings)
        #expect(await store.load() == settings)
        settings.privacy.localOnly = true
        settings.ui.sidebarWidth = 420
        try await store.save(settings)
        #expect(await store.load() == settings)
    }

    @Test func theSecretStoreSetsReplacesAndDeletes() throws {
        let store = InMemorySecretStore(["anthropic-api": "first"])
        #expect(!store.failReads)
        #expect(try store.secret(for: "anthropic-api") == "first")
        #expect(try store.secret(for: "openai-api") == nil)
        try store.setSecret("second", for: "anthropic-api")
        try store.setSecret("other", for: "openai-api")
        #expect(try store.secret(for: "anthropic-api") == "second")
        try store.setSecret(nil, for: "anthropic-api")
        #expect(try store.secret(for: "anthropic-api") == nil)
        #expect(try store.secret(for: "openai-api") == "other")
        #expect(try InMemorySecretStore().secret(for: "anything") == nil)
    }

    @Test func aSecretStoreThatFailsReadsThrowsAndChangesNothing() throws {
        let store = InMemorySecretStore(["anthropic-api": "kept"])
        store.failReads = true
        #expect(store.failReads)
        #expect(throws: SecretError.unreadable(status: -25293)) { try store.secret(for: "anthropic-api") }
        #expect(throws: SecretError.unreadable(status: -25293)) { try store.setSecret("lost", for: "anthropic-api") }
        #expect(throws: SecretError.unreadable(status: -25293)) { try store.setSecret(nil, for: "anthropic-api") }
        store.failReads = false
        #expect(try store.secret(for: "anthropic-api") == "kept")           // the failed writes wrote nothing
    }

    // ---- paper service, matcher, indexer, renderer ----

    @Test func thePaperServiceReturnsItsPaperAndOneRectanglePerSpan() async throws {
        let paper = LoadedPaper(ref: DocumentRef(sha256: "cccc", fileName: "tiny.pdf", byteCount: 3, pageCount: 2), data: Data([1, 2, 3]),
                                isEncrypted: false, text: tinyPaper())
        let service = FakePaperService(paper: paper)
        #expect(try await service.load(url: URL(fileURLWithPath: "/nonexistent/other.pdf")) == paper)
        #expect(try await service.load(data: Data(), fileName: "whatever.txt") == paper)
        await service.unload(paper.ref)
        #expect(try await service.load(data: Data(), fileName: "again.pdf") == paper)

        let spans = [TextSpan(pageIndex: 0, range: TextRange(location: 41, length: 6)),      // inside the third line of page 1
                     TextSpan(pageIndex: 1, range: TextRange(location: 0, length: 7)),       // a line without bounds
                     TextSpan(pageIndex: 7, range: TextRange(location: 0, length: 1))]       // a page the paper does not have
        let rects = await service.rects(for: spans, in: paper.ref)
        #expect(rects == [PageRect(pageIndex: 0, x: 100, y: 680, width: 200, height: 11),
                          PageRect(pageIndex: 1, x: 100, y: 100, width: 200, height: 12),
                          PageRect(pageIndex: 7, x: 100, y: 100, width: 200, height: 12)])
        #expect(await service.rects(for: [], in: paper.ref).isEmpty)
    }

    @Test func theQuoteMatcherFindsExactSubstringsOfSingleBodyLines() {
        let matcher = FakeQuoteMatcher(paper: tinyPaper())
        // UTF-16 offsets into the page string: "showed" starts 9 units into the line at 32.
        #expect(matcher.locate(quote: "showed it — twice", pageHint: nil)
                    == AnchorMatch(spans: [TextSpan(pageIndex: 0, range: TextRange(location: 41, length: 17))], confidence: .exact))
        // The first page in order wins without a hint; the hinted page wins with one.
        #expect(matcher.locate(quote: "Herding is", pageHint: nil)?.spans == [TextSpan(pageIndex: 0, range: TextRange(location: 0, length: 10))])
        #expect(matcher.locate(quote: "Herding is", pageHint: 1)?.spans == [TextSpan(pageIndex: 1, range: TextRange(location: 0, length: 10))])
        #expect(matcher.locate(quote: "The end.", pageHint: 0)?.spans.first?.pageIndex == 1)      // not on the hinted page: found elsewhere

        #expect(matcher.locate(quote: "herding is", pageHint: nil) == nil)                  // exact means exact: case matters
        #expect(matcher.locate(quote: "Herding  is", pageHint: nil) == nil)
        #expect(matcher.locate(quote: "common.\nSørensen", pageHint: nil) == nil)           // never across lines
        #expect(matcher.locate(quote: "CONFIDENTIAL", pageHint: nil) == nil)                // not body text
        #expect(matcher.locate(quote: "", pageHint: nil) == nil)
        #expect(matcher.locate(quote: "not in the paper", pageHint: 0) == nil)

        #expect(matcher.locationLabel(for: [TextSpan(pageIndex: 3, range: TextRange(location: 0, length: 1)),
                                            TextSpan(pageIndex: 4, range: TextRange(location: 0, length: 1))]) == "p. 4")
        #expect(matcher.locationLabel(for: []) == "")
    }

    /// What tests of the engine and the model can count on when they pair the fake matcher with the default sample
    /// paper and the mock's review answer: two of its six quotes stand within one line and are found; the other four
    /// run over a line break, or stand on a line whose spaces PDFKit lost, and are not.
    @Test func theQuoteMatcherFindsTwoOfTheSixReviewQuotesInTheSamplePaper() throws {
        let matcher = FakeQuoteMatcher(paper: try makeSamplePaper().text)
        let quotes = try Fixtures.text("llm/review_clean.txt").split(separator: "\n").filter { $0.hasPrefix("quote: ") }.map { String($0.dropFirst(7)) }
        #expect(quotes.count == 6)
        let found = quotes.map { matcher.locate(quote: $0, pageHint: nil) }
        #expect(found.map { $0 != nil } == [false, false, true, false, false, true])
        #expect(found[2]?.spans.map(\.pageIndex) == [0])
        #expect(found[5]?.spans.map(\.pageIndex) == [0])
        #expect(found[2].map { matcher.locationLabel(for: $0.spans) } == "p. 1")
    }

    @Test func theCitationIndexerReturnsItsIndexWhateverTheInput() {
        let paper = tinyPaper()
        #expect(FakeCitationIndexer().buildIndex(paper: paper, links: []) == CitationIndex(style: .unknown))
        let entry = BibEntry(id: 0, rawText: "Lee, J. (2021). Observational learning.", parsed: ParsedReference(authorSurnames: ["Lee"], year: 2021))
        let index = CitationIndex(style: .authorYear, entries: [entry],
                                  mentions: [CitationMention(id: 0, pageIndex: 0, text: "Lee (2021)", entryIDs: [0], source: .textPattern)])
        let indexer = FakeCitationIndexer(index: index)
        #expect(indexer.buildIndex(paper: paper, links: []) == index)
        #expect(indexer.buildIndex(paper: PaperText(hasTextLayer: false, hasMarginLineNumbers: false), links: []) == index)
    }

    /// "Stable for ever": ReviewEngine's tests are written against this exact text.
    @Test func theRendererGivesMarkerLinesAndBodyLines() {
        let paper = tinyPaper()
        let renderer = FakePaperRenderer()
        #expect(renderer.render(paper, pages: nil)
                    == "[[page 1]]\nHerding is common.\nSørensen showed it — twice.\n[[page 2]]\nHerding is rare.\nThe end.\n")
        #expect(renderer.render(paper, pages: 1..<2) == "[[page 2]]\nHerding is rare.\nThe end.\n")
        #expect(renderer.render(paper, pages: 0..<1) == "[[page 1]]\nHerding is common.\nSørensen showed it — twice.\n")
        #expect(renderer.render(paper, pages: 1..<9) == renderer.render(paper, pages: 1..<2))       // cut to the paper
        #expect(renderer.render(paper, pages: 0..<0) == "")
        #expect(renderer.render(paper, pages: 5..<7) == "")
        #expect(renderer.render(PaperText(hasTextLayer: false, hasMarginLineNumbers: false), pages: nil) == "")
    }

    @Test func theRendererChunksByWholePages() throws {
        let paper = tinyPaper()
        let renderer = FakePaperRenderer()
        let first = renderer.render(paper, pages: 0..<1).count              // 58
        let second = renderer.render(paper, pages: 1..<2).count             // 37
        #expect(first == 58)
        #expect(second == 37)
        #expect(renderer.chunkPageRanges(paper, maxCharacters: first + second) == [0..<2])
        #expect(renderer.chunkPageRanges(paper, maxCharacters: first + second - 1) == [0..<1, 1..<2])
        #expect(renderer.chunkPageRanges(paper, maxCharacters: 1) == [0..<1, 1..<2])       // a single page may exceed the limit
        #expect(renderer.chunkPageRanges(PaperText(hasTextLayer: false, hasMarginLineNumbers: false), maxCharacters: 100).isEmpty)

        // On a real paper: the ranges are contiguous, cover every page, and stay within the limit unless a range is one page.
        let real = try makeSamplePaper().text
        for limit in [500, 2_000, 3_500, 100_000] {
            let ranges = renderer.chunkPageRanges(real, maxCharacters: limit)
            #expect(ranges.first?.lowerBound == 0)
            #expect(ranges.last?.upperBound == real.pages.count)
            #expect(zip(ranges, ranges.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
            #expect(ranges.allSatisfy { $0.count == 1 || renderer.render(real, pages: $0).count <= limit })
            #expect(ranges.map { renderer.render(real, pages: $0) }.joined() == renderer.render(real, pages: nil))
        }
        #expect(renderer.chunkPageRanges(real, maxCharacters: 100_000) == [0..<4])
    }

    // ---- resolver ----

    @Test func theResolverResolvesEveryEntryAtOnce() async throws {
        let resolver = FakeResolver()
        let entry = BibEntry(id: 3, rawText: "Banerjee, A. V. (1992). A simple model of herd behavior. Quarterly Journal of Economics, 107(3):797–817.",
                             parsed: ParsedReference(authorSurnames: ["Banerjee"], year: 1992, doi: "10.1000/example"))
        let reference = await resolver.resolve(entry, documentSHA256: "aaaa")
        #expect(reference.entryID == 3)
        #expect(reference.status == .resolved)
        #expect(reference.title == "Resolved: Banerjee, A. V. (1992). A simp")              // "Resolved: " + the first 30 characters
        #expect(reference.authors == ["Banerjee"])
        #expect(reference.year == 1992)
        #expect(reference.doi == "10.1000/example")
        #expect(reference.landingURL == "https://example.org/reference/3")
        #expect(reference.openAccessPDFURL == "https://example.org/reference/3.pdf")
        #expect(reference.confidence == 1.0)
        #expect(await resolver.resolve(entry, documentSHA256: "bbbb") == reference)         // the same answer every time

        let short = await resolver.resolve(BibEntry(id: 0, rawText: "Lee (2021).", parsed: ParsedReference()), documentSHA256: "aaaa")
        #expect(short.title == "Resolved: Lee (2021).")
        #expect(short.authors.isEmpty)
    }

    @Test func theResolverRemembersWhichDocumentsItWasToldToForget() async {
        let resolver = FakeResolver()
        #expect(resolver.forgottenDocuments.isEmpty)
        await resolver.forget(documentSHA256: "aaaa")
        await resolver.forget(documentSHA256: "bbbb")
        await resolver.forget(documentSHA256: "aaaa")
        #expect(resolver.forgottenDocuments == ["aaaa", "bbbb", "aaaa"])
    }

    @Test func theResolverHandsOutAFixtureAsThePDFAndAScholarQuery() async throws {
        let resolver = FakeResolver()
        let entry = BibEntry(id: 1, rawText: "Smith & Sørensen (2000) \"Pathological outcomes\"", parsed: ParsedReference())
        let reference = await resolver.resolve(entry, documentSHA256: "aaaa")
        let file = try await resolver.fetchPDF(for: reference)
        #expect(file.isFileURL)
        #expect(file == Fixtures.url("pdf/num_twocol_links.pdf"))
        #expect(try Data(contentsOf: file).prefix(5) == Data("%PDF-".utf8))

        var closed = reference
        closed.openAccessPDFURL = nil
        await #expect(throws: ResolverError.noOpenAccessPDF) { _ = try await resolver.fetchPDF(for: closed) }

        let search = resolver.searchURL(for: entry)
        #expect(search.scheme == "https")
        #expect(search.host == "scholar.google.com")
        #expect(URLComponents(url: search, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "q", value: entry.rawText)])
    }

    // ---- engine ----

    @Test func theScriptedEnginePlaysItsEventsAndRecordsEveryCall() async throws {
        let plan = SendPlan(sendsPDF: false, requestCount: 1, estimatedInputTokens: 1_000, destination: "this Mac", isLocal: true)
        let run = RunRecord(id: UUID(), kind: .review, provider: ProviderRef(providerID: "mock", model: nil), destination: "this Mac", sentPDF: false,
                            requestCount: 1, startedAt: moment, status: .running)
        var finished = run
        finished.status = .completed
        let reply = ThreadMessage(id: UUID(), role: .assistant, text: "Yes.", createdAt: moment)
        let draft = ReportDraft(markdown: "## Summary assessment", userEdited: false)
        let finding = LintFinding(id: 0, range: TextRange(location: 3, length: 7), rule: "banned-word", message: "robust")
        let review: [ReviewEvent] = [.started(run), .phase(.preparing), .notice("n"), .digest("notes"), .finished(finished)]
        let replies: [ReplyEvent] = [.started(run), .textDelta("Yes"), .textDelta("."), .finished(reply: reply, proposal: nil, run: finished)]
        let reports: [ReportEvent] = [.started(run), .textDelta("## Summary"), .finished(draft, run: finished)]
        let engine = ScriptedReviewEngine(plan: plan, review: review, reply: replies, report: reports, lint: [finding])

        let paper = try makeSamplePaper()
        let comment = ReviewComment(id: UUID(), origin: .user, status: .pending, kind: .minor, category: "other", title: "t", body: "b",
                                    anchor: Anchor(quote: "", confidence: .none, locationLabel: ""), includeInReport: true, createdAt: moment, updatedAt: moment)
        let model = ModelInfo(id: "mock", displayName: "mock", contextWindow: 1_000_000)
        let plain = context()
        let rich = context(model: model, digest: "notes")
        #expect(engine.calls.isEmpty)

        #expect(await engine.plan(paper: paper, context: plain) == plan)
        var reviewed: [ReviewEvent] = []
        for try await event in engine.review(paper: paper, existing: [], context: rich) { reviewed.append(event) }
        #expect(reviewed == review)
        var discussed: [ReplyEvent] = []
        for try await event in engine.discuss(paper: paper, comment: comment, message: "Is it?", context: rich) { discussed.append(event) }
        #expect(discussed == replies)
        var asked: [ReplyEvent] = []
        for try await event in engine.ask(paper: paper, conversation: Conversation(id: UUID(), createdAt: moment), question: "Why?", context: plain) {
            asked.append(event)
        }
        #expect(asked == replies)
        var reported: [ReportEvent] = []
        let session = self.session(paper.ref.sha256, updatedAt: moment)
        for try await event in engine.generateReport(paper: paper, session: session, context: plain) { reported.append(event) }
        #expect(reported == reports)
        var revised: [ReportEvent] = []
        for try await event in engine.reviseVoice(draft: ReportDraft(markdown: "x", userEdited: false), findings: [finding], context: rich) {
            revised.append(event)
        }
        #expect(revised == reports)
        #expect(engine.lint(reportMarkdown: "anything") == [finding])

        #expect(engine.calls == ["plan", "review", "discuss", "ask", "report", "revise"])             // lint is not a job
        #expect(engine.contexts == [plain, rich, rich, plain, plain, rich])
        #expect(engine.contexts[1].model == model)
        #expect(engine.contexts[1].paperDigest == "notes")
    }

    @Test func aScriptedEngineWithoutEventsEndsAtOnceAndDelaysCanBeCancelled() async throws {
        let plan = SendPlan(sendsPDF: true, requestCount: 2, estimatedInputTokens: 5, destination: "mock.example.org", isLocal: false,
                            warnings: ["w"], blockingReason: "blocked")
        let empty = ScriptedReviewEngine(plan: plan)
        let paper = try makeSamplePaper()
        var count = 0
        for try await _ in empty.review(paper: paper, existing: [], context: context()) { count += 1 }
        #expect(count == 0)
        #expect(await empty.plan(paper: paper, context: context()).blockingReason == "blocked")
        #expect(empty.lint(reportMarkdown: "x").isEmpty)
        #expect(empty.calls == ["review", "plan"])

        // A call is recorded when it is made; the events come only when the stream is read, a delay before each.
        let slow = ScriptedReviewEngine(plan: plan, review: [.notice("one"), .notice("two"), .notice("three")], delayPerEvent: .seconds(1))
        let stream = slow.review(paper: paper, existing: [], context: context())
        #expect(slow.calls == ["review"])

        /// The events seen so far, readable while the consumer is still waiting for the next one.
        final class Seen: @unchecked Sendable {
            private let lock = NSLock()
            private var events: [ReviewEvent] = []
            func add(_ event: ReviewEvent) { lock.withLock { events.append(event) } }
            var all: [ReviewEvent] { lock.withLock { events } }
        }
        let seen = Seen()
        let clock = ContinuousClock()
        let started = clock.now
        let consumer = Task {
            do {
                for try await event in stream { seen.add(event) }
            } catch {
                Issue.record("a scripted stream never throws")
            }
        }
        while seen.all.isEmpty, clock.now - started < .seconds(8) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(clock.now - started >= .milliseconds(990))     // the first event waited for its delay
        consumer.cancel()                                       // the second one is a second away
        await consumer.value                                    // the cancelled stream ends, without the second event
        #expect(seen.all == [.notice("one")])
    }
}
