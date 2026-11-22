import Foundation
import Testing
import RefereeCore
@testable import AppCore
import TestSupport

/// A paper service that counts loads and unloads; with `slow`, each load takes 300 ms, so a test can close the window
/// while the paper is still loading (Gate 1: one `unload` per `load`, plan.md Appendix A.2).
final class CountingModelPaperService: PaperService, @unchecked Sendable {
    private let base: FakePaperService
    private let slow: Bool
    private let lock = NSLock()
    private var loadCount = 0
    private var unloadCount = 0

    init(paper: LoadedPaper, slow: Bool = false) {
        base = FakePaperService(paper: paper)
        self.slow = slow
    }

    var loads: Int { lock.withLock { loadCount } }
    var unloads: Int { lock.withLock { unloadCount } }

    func load(url: URL) async throws -> LoadedPaper {
        if slow { try? await Task.sleep(for: .milliseconds(300)) }
        let paper = try await base.load(url: url)
        lock.withLock { loadCount += 1 }
        return paper
    }
    func load(data: Data, fileName: String) async throws -> LoadedPaper {
        let paper = try await base.load(data: data, fileName: fileName)
        lock.withLock { loadCount += 1 }
        return paper
    }
    func rects(for spans: [TextSpan], in document: DocumentRef) async -> [PageRect] { await base.rects(for: spans, in: document) }
    func unload(_ document: DocumentRef) async { lock.withLock { unloadCount += 1 } }
}

/// The in-memory store, reporting a repair after every load as the file store does when it loaded the backup.
final class RecoveringModelSessionStore: SessionStoring, @unchecked Sendable {
    let base = InMemorySessionStore()
    let notice: String
    init(notice: String) { self.notice = notice }
    func loadSession(sha256: String) async throws -> ReviewSession? { try await base.loadSession(sha256: sha256) }
    func recoveryNotice(sha256: String) async -> String? { notice }
    func save(_ session: ReviewSession) async throws { try await base.save(session) }
    func listSessions() async -> [SessionSummary] { await base.listSessions() }
    func deleteSession(sha256: String) async throws { try await base.deleteSession(sha256: sha256) }
}

/// What Gate 1 added to the model's contract or checked in it (plan.md Appendix A.9, Appendix G.6).
@Suite struct ReviewSessionModelContractTests {
    static let entries = [
        BibEntry(id: 0, rawText: "Banerjee, A. V. (1992). A simple model of herd behavior.", parsed: ParsedReference(authorSurnames: ["Banerjee"], year: 1992)),
        BibEntry(id: 1, rawText: "Lee, J. (2021). Observational learning.", parsed: ParsedReference(authorSurnames: ["Lee"], year: 2021)),
    ]
    static let index = CitationIndex(style: .authorYear, entries: entries)

    static func draft(_ id: UUID, title: String) -> DraftComment {
        DraftComment(id: id, kind: .major, category: "claims", page: 1, quote: "a quote", title: title, body: "")
    }

    // ---- runs (Appendix A.6) ----

    @Test @MainActor func aDraftThatNoCommentReplacedIsGoneWhenTheRunCompletes() async throws {
        let kept = UUID()
        let dropped = UUID()
        let comment = ModelSample.comment("Kept", page: nil)
        let events: [ReviewEvent] = [.started(ModelSample.run(.review, .running)), .draft(Self.draft(kept, title: "Kept")),
                                     .comment(comment, replacesDraft: kept), .draft(Self.draft(dropped, title: "A repeat the engine dropped")),
                                     .finished(ModelSample.run(.review, .completed))]
        let harness = try await makeModelHarness(engine: ScriptedReviewEngine(plan: ModelSample.localPlan, review: events))
        await harness.open()
        harness.model.startReview()
        await harness.finishJobs()
        #expect(harness.model.drafts.isEmpty)
        #expect(harness.model.session?.comments.map(\.title) == ["Kept"])
        #expect(harness.model.session?.runs.last?.status == .completed)
        #expect(harness.model.banner == nil)
    }

    @Test @MainActor func aStreamThatEndsWithoutFinishedIsRecordedAsCancelled() async throws {
        let comment = ModelSample.comment("Arrived", page: nil)
        let events: [ReviewEvent] = [.started(ModelSample.run(.review, .running)), .comment(comment, replacesDraft: UUID())]
        let harness = try await makeModelHarness(engine: ScriptedReviewEngine(plan: ModelSample.localPlan, review: events))
        await harness.open()
        harness.model.startReview()
        await harness.finishJobs()
        #expect(harness.model.session?.comments.map(\.title) == ["Arrived"])
        #expect(harness.model.session?.runs.last?.status == .cancelled)
        #expect(harness.model.session?.runs.last?.finishedAt != nil)
        #expect(harness.model.banner == nil)                              // a cancelled run shows no banner
        #expect(harness.model.runState == .idle)
    }

    @Test @MainActor func noticesOfARepliesAndAReportAreInfoBanners() async throws {
        let comment = ModelSample.comment("Approved", page: nil, status: .approved)
        let reply = ThreadMessage(id: UUID(), role: .assistant, text: "An answer.", createdAt: ModelSample.start)
        let draft = ReportDraft(markdown: "## Summary assessment\n\nFine.", userEdited: false)
        let engine = ScriptedReviewEngine(plan: ModelSample.localPlan,
                                          reply: [.started(ModelSample.run(.discussion, .running)), .notice("Reply notice."),
                                                  .finished(reply: reply, proposal: nil, run: ModelSample.run(.discussion, .completed))],
                                          report: [.started(ModelSample.run(.report, .running)), .notice("Report notice."),
                                                   .finished(draft, run: ModelSample.run(.report, .completed))])
        let paper = try makeSamplePaper()
        let harness = try await makeModelHarness(paper: paper, engine: engine, seed: ModelSample.session(for: paper, comments: [comment]))
        await harness.open()
        harness.model.sendDiscussionMessage("Why?", commentID: comment.id)
        await harness.finishJobs()
        #expect(harness.model.banner?.style == .info)
        #expect(harness.model.banner?.message == "Reply notice.")
        harness.model.generateReport()
        await harness.finishJobs()
        #expect(harness.model.banner?.message == "Report notice.")
        #expect(harness.model.session?.report?.markdown == draft.markdown)
    }

    @Test @MainActor func aVoiceRevisionKeepsTheDraftsCommentsAndPushesTheOldText() async throws {
        let comment = ModelSample.comment("Approved", page: nil, status: .approved)
        let old = ReportDraft(markdown: "## Summary assessment\n\nOld text.", recommendation: .reject, basedOnCommentIDs: [comment.id],
                              userEdited: true)
        let revised = ReportDraft(markdown: "## Summary assessment\n\nNew text.", userEdited: false)
        let engine = ScriptedReviewEngine(plan: ModelSample.localPlan,
                                          report: [.started(ModelSample.run(.revise, .running)), .finished(revised, run: ModelSample.run(.revise, .completed))])
        let paper = try makeSamplePaper()
        let harness = try await makeModelHarness(paper: paper, engine: engine,
                                                 seed: ModelSample.session(for: paper, comments: [comment], report: old))
        await harness.open()
        harness.model.reviseReportVoice()
        await harness.finishJobs()
        let report = try #require(harness.model.session?.report)
        #expect(harness.engine.calls.contains("revise"))
        #expect(report.markdown == revised.markdown)
        #expect(report.basedOnCommentIDs == [comment.id])
        #expect(report.recommendation == .reject)                         // the new text names none: the old one stays
        #expect(report.userEdited == false)
        #expect(report.versions.map(\.note) == ["before voice revision"])
        #expect(report.versions.first?.markdown == old.markdown)
    }

    // ---- consent (section 9.7) ----

    @Test @MainActor func askAgainSendsThisTimeAndAsksAgainNextTime() async throws {
        let harness = try await ReviewSessionModelConsentTests.remoteHarness()
        harness.model.startReview()
        #expect(harness.model.consentRequest != nil)
        harness.model.answerConsent(granted: true, askAgain: true)
        await harness.finishJobs()
        #expect(harness.calls(of: "review") == 1)
        #expect(harness.model.session?.consents.isEmpty == true)          // nothing recorded
        harness.model.startReview()
        #expect(harness.model.consentRequest != nil)                      // so the card comes again
        harness.model.answerConsent(granted: false)
        await harness.finishJobs()
        #expect(harness.calls(of: "review") == 1)
    }

    // ---- reply failures (sections 9.3, 9.9) ----

    @Test @MainActor func aFailedChatAnswerIsShownInlineAndGoesWithItsConversation() async throws {
        let reply = ThreadMessage(id: UUID(), role: .assistant, text: "", createdAt: ModelSample.start)
        let engine = ScriptedReviewEngine(plan: ModelSample.localPlan,
                                          reply: [.started(ModelSample.run(.question, .running)),
                                                  .finished(reply: reply, proposal: nil, run: ModelSample.run(.question, .failed("The provider is overloaded.")))])
        let harness = try await makeModelHarness(engine: engine)
        await harness.open()
        harness.model.ask("Is the claim supported?", about: nil, in: nil)
        await harness.finishJobs()
        let conversation = try #require(harness.model.session?.conversations.first)
        #expect(harness.model.replyFailure == ReplyFailure(targetID: conversation.id, message: "The provider is overloaded."))
        #expect(harness.model.banner == nil)
        harness.model.deleteConversation(conversation.id)
        #expect(harness.model.replyFailure == nil)
        harness.model.retryFailedReply()                                  // nothing left to retry
        await harness.finishJobs()
        #expect(harness.calls(of: "ask") == 1)
    }

    // ---- opening, closing (Appendix A.2, section 4.5) ----

    @Test @MainActor func everyLoadIsMatchedByOneUnload() async throws {
        let paper = try makeSamplePaper()
        let service = CountingModelPaperService(paper: paper)
        let harness = try await makeModelHarness(paper: paper, paperService: service)
        await harness.open()
        await harness.open()                                              // opening again closes first
        #expect(service.loads == 2)
        #expect(service.unloads == 1)
        await harness.model.close()
        #expect(service.unloads == 2)
        await harness.model.close()                                       // a second close unloads nothing
        #expect(service.unloads == 2)
        await harness.open()
        await harness.model.deleteReviewData()
        #expect(service.loads == 3)
        #expect(service.unloads == 3)
    }

    @Test @MainActor func aPaperClosedWhileItLoadsIsUnloadedWhenTheLoadEnds() async throws {
        let paper = try makeSamplePaper()
        let service = CountingModelPaperService(paper: paper, slow: true)
        let harness = try await makeModelHarness(paper: paper, paperService: service)
        let opening = Task { await harness.model.open(url: harness.url) }
        #expect(await waitForModel { harness.model.phase == .loading(fileName: harness.url.lastPathComponent) })
        await harness.model.close()
        await opening.value
        #expect(service.loads == 1)
        #expect(service.unloads == 1)
        #expect(harness.model.paper == nil)
        #expect(harness.model.phase == .empty)
    }

    @Test @MainActor func aRepairedSessionRaisesTheBackupBanner() async throws {
        let notice = "The saved review was damaged, so its previous version was loaded from the backup."
        let paper = try makeSamplePaper()
        let store = RecoveringModelSessionStore(notice: notice)
        try await store.save(ModelSample.session(for: paper))
        let harness = try await makeModelHarness(paper: paper, sessions: store)
        await harness.open()
        #expect(harness.model.phase == .ready)
        #expect(harness.model.banner == Banner(id: try #require(harness.model.banner?.id), style: .warning, message: notice))
    }

    // ---- references (sections 7.6, 8.6, 8.7) ----

    @Test @MainActor func lookupsAreKeptPerEntryAndTheSearchURLComesFromTheResolver() async throws {
        let harness = try await makeModelHarness(index: Self.index)
        await harness.open()
        #expect(harness.model.references.isEmpty)                          // background lookups are off by default
        harness.model.lookUpEntry(entryID: 1)
        await harness.model.waitForBackgroundWork()
        #expect(harness.model.references.keys.sorted() == [1])
        #expect(harness.model.references[1]?.status == .resolved)
        harness.model.dismissTransientUI()                                // the card closes; what was learnt stays
        #expect(harness.model.references.keys.sorted() == [1])
        #expect(harness.model.searchURL(for: Self.entries[0]) == FakeResolver().searchURL(for: Self.entries[0]))
        await harness.model.close()
        #expect(harness.model.references.isEmpty)
    }

    @Test @MainActor func backgroundLookupsRunOnlyWhenTheSettingIsOn() async throws {
        let settings = ModelSample.settings { $0.privacy.resolveReferencesInBackground = true }
        let harness = try await makeModelHarness(settings: settings, index: Self.index)
        await harness.open()
        await harness.model.waitForBackgroundWork()
        #expect(harness.model.references.keys.sorted() == [0, 1])
        #expect(harness.model.citationLookup == .idle)                    // no card opens by itself
    }

    // ---- export (section 6.10) ----

    @Test @MainActor func anExportThatCannotBeWrittenThrowsAnExportError() async throws {
        let harness = try await makeModelHarness()
        await harness.open()
        harness.model.updateReportMarkdown("## Summary assessment\n\nText.")
        let nowhere = FileManager.default.temporaryDirectory.appendingPathComponent("referee-missing-\(UUID().uuidString)/report.md")
        do {
            try harness.model.exportReport(format: .markdown, to: nowhere)
            Issue.record("the export should have failed")
        } catch let error as ExportError {
            guard case .couldNotWrite = error else {
                Issue.record("expected .couldNotWrite, got \(error)")
                return
            }
            #expect(error.userMessage.hasPrefix("The exported report could not be saved"))
        }
    }
}
