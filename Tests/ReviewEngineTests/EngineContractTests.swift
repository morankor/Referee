import Foundation
import Testing
import RefereeCore
import TestSupport
@testable import ReviewEngine

extension Array where Element == ReplyEvent {
    var notices: [String] { compactMap { if case .notice(let text) = $0 { return text } else { return nil } } }
}

extension Array where Element == ReportEvent {
    var notices: [String] { compactMap { if case .notice(let text) = $0 { return text } else { return nil } } }
}

/// What Gate 1 changed in the engine's contract (plan.md Appendix A.6, Appendix G.6): replies and reports say when the
/// provider refused the PDF and the text went instead, and a voice revision is given the draft it revises.
@Suite struct EngineContractTests {
    private let paper: LoadedPaper

    init() throws { paper = try makeSamplePaper() }

    private func approvedComment() -> ReviewComment {
        ReviewComment(id: UUID(), origin: .ai(runID: UUID()), status: .approved, kind: .major, category: "claims", title: "An approved comment",
                      body: "Its body.", anchor: Anchor(quote: "The coefficient in Table 2 is 0.91", pageIndex: 0, confidence: .pageOnly,
                                                        locationLabel: "p. 1"),
                      includeInReport: true, createdAt: Date(), updatedAt: Date())
    }

    private func refusingMock(_ purpose: RequestPurpose, answer: String) -> MockLLMProvider {
        let answers = [MockResponse(text: "", failAfterChunks: 0, failure: .contextTooLong("prompt is too long")), MockResponse(text: answer)]
        return MockLLMProvider(script: EngineTest.script(purpose, answers), supportsNativePDF: true)
    }

    private func isPDF(_ part: LLMPart) -> Bool {
        if case .pdf = part { return true }
        return false
    }

    @Test func aReplyWhosePDFIsRefusedGoesAgainAsTextWithANotice() async throws {
        let mock = refusingMock(.discussion, answer: "The interval does include one.")
        let context = EngineTest.context(model: try await mock.listModels().first)
        let comment = approvedComment()
        let events = try await EngineTest.collect(EngineTest.engine([mock], paper: paper)
            .discuss(paper: paper, comment: comment, message: "Is that right?", context: context))
        #expect(mock.recordedRequests.count == 2)
        #expect(mock.recordedRequests.first?.parts.contains(where: isPDF) == true)
        #expect(mock.recordedRequests.last?.parts.contains(where: isPDF) == false)
        #expect(events.notices == ["The provider did not accept the PDF file (\(LLMError.contextTooLong("prompt is too long").userMessage)), "
                                   + "so the answer is based on the text extracted from it."])
        #expect(events.finished?.run.status == .completed)
        #expect(events.finished?.reply.text == "The interval does include one.")
    }

    @Test func aReportWhosePDFIsRefusedGoesAgainAsTextWithANotice() async throws {
        let report = try Fixtures.text("llm/report_sample.txt")
        let mock = refusingMock(.report, answer: report)
        let context = EngineTest.context(model: try await mock.listModels().first)
        let session = ReviewSession(schemaVersion: 1, id: UUID(), document: paper.ref, meta: ManuscriptMeta(reviewerNotes: ""),
                                    comments: [approvedComment()], createdAt: Date(), updatedAt: Date())
        let events = try await EngineTest.collect(EngineTest.engine([mock], paper: paper).generateReport(paper: paper, session: session, context: context))
        #expect(mock.recordedRequests.count == 2)
        #expect(events.notices.count == 1)
        #expect(events.notices.first?.hasSuffix("so the report is written from the text extracted from it.") == true)
        #expect(events.finished?.run.status == .completed)
    }

    @Test func aVoiceRevisionKeepsTheRevisedDraftsCommentsVersionsAndRecommendation() async throws {
        let ids = [UUID(), UUID()]
        let version = ReportVersion(markdown: "## Summary assessment\n\nAn older text.", savedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                    note: "before regenerate")
        let draft = ReportDraft(markdown: "## Summary assessment\n\nThe text to revise.", recommendation: .accept, basedOnCommentIDs: ids,
                                userEdited: true, versions: [version])
        // An answer that names no recommendation: the draft's own stays.
        let mock = MockLLMProvider(script: EngineTest.script(.revise, [MockResponse(text: "## Summary assessment\n\nThe revised text.")]))
        let events = try await EngineTest.collect(EngineTest.engine([mock], paper: paper).reviseVoice(draft: draft, findings: [], context: EngineTest.context()))
        let finished = try #require(events.finished)
        #expect(finished.run.status == .completed)
        #expect(finished.draft.markdown == "## Summary assessment\n\nThe revised text.")
        #expect(finished.draft.recommendation == .accept)
        #expect(finished.draft.basedOnCommentIDs == ids)
        #expect(finished.draft.versions == [version])                     // the model pushes the old text, not the engine
        #expect(finished.draft.userEdited == false)

        // An answer that names one: it wins.
        let sample = try Fixtures.text("llm/report_sample.txt")
        let naming = MockLLMProvider(script: EngineTest.script(.revise, [MockResponse(text: sample)]))
        let renamed = try await EngineTest.collect(EngineTest.engine([naming], paper: paper).reviseVoice(draft: draft, findings: [], context: EngineTest.context()))
        #expect(renamed.finished?.draft.recommendation == .majorRevision)

        // A failure gives the draft back as it was.
        let failing = MockLLMProvider(script: EngineTest.script(.revise, [MockResponse(text: "", failAfterChunks: 0, failure: .overloaded(retryAfter: nil))]))
        let failed = try await EngineTest.collect(EngineTest.engine([failing], paper: paper).reviseVoice(draft: draft, findings: [], context: EngineTest.context()))
        #expect(failed.finished?.draft == draft)
        #expect(failed.finished?.run.status == .failed(LLMError.overloaded(retryAfter: nil).userMessage))
    }

    @Test func theDebugTranscriptFolderIsAnArgumentOfThePublicInitialiser() async throws {
        let folder = EngineTest.temporaryDirectory("contract-dump")
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = ReviewEngine(providers: ProviderRegistry([MockLLMProvider()]), paperService: FakePaperService(paper: paper),
                                  matcherFactory: { FakeQuoteMatcher(paper: $0) }, renderer: FakePaperRenderer(), debugDumpDirectory: folder)
        _ = try await EngineTest.collect(engine.ask(paper: paper, conversation: Conversation(id: UUID(), createdAt: Date()), question: "Why?",
                                                    context: EngineTest.context()))
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(files.count == 1)
        #expect(files.first?.hasSuffix("-question.txt") == true)
        // Without the argument nothing is written, whatever the process environment holds.
        let quiet = ReviewEngine(providers: ProviderRegistry([MockLLMProvider()]), paperService: FakePaperService(paper: paper),
                                 matcherFactory: { FakeQuoteMatcher(paper: $0) }, renderer: FakePaperRenderer())
        _ = try await EngineTest.collect(quiet.ask(paper: paper, conversation: Conversation(id: UUID(), createdAt: Date()), question: "Why?",
                                                   context: EngineTest.context()))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 1)
    }
}
