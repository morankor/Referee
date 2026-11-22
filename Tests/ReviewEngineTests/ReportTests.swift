import Foundation
import Testing
@testable import ReviewEngine
import RefereeCore
import TestSupport

/// The report (plan.md section 6.10): row "report" of WP6, and the voice revision.
@Suite struct ReportTests {
    private let paper = EngineTest.paper(pages: [
        ["Line one of page one.", "Line two of page one.", "Line three of page one."],
        ["Line one of page two.", "Line two of page two."],
    ])

    private func comment(_ title: String, _ kind: CommentKind, status: CommentStatus = .approved, include: Bool = true, page: Int?, line: Int? = nil,
                         label: String, created: TimeInterval) -> ReviewComment {
        var spans: [TextSpan] = []
        if let page, let line { spans = [TextSpan(pageIndex: page, range: paper.text.pages[page].lines[line].contentRange)] }
        let confidence: AnchorConfidence = page == nil ? .none : (spans.isEmpty ? .pageOnly : .exact)
        return ReviewComment(id: UUID(), origin: .ai(runID: UUID()), status: status, kind: kind, category: kind == .major ? "claims" : "data", title: title,
                             body: "Body of \(title).", suggestion: kind == .major ? "Fix \(title)." : nil,
                             anchor: Anchor(quote: "Quote of \(title)", spans: spans, pageIndex: page, confidence: confidence, locationLabel: label),
                             includeInReport: include, createdAt: Date(timeIntervalSince1970: created), updatedAt: Date(timeIntervalSince1970: created))
    }

    private func session(_ comments: [ReviewComment], meta: ManuscriptMeta = ManuscriptMeta(reviewerNotes: ""), report: ReportDraft? = nil) -> ReviewSession {
        ReviewSession(schemaVersion: 1, id: UUID(), document: paper.ref, meta: meta, comments: comments, report: report, createdAt: Date(), updatedAt: Date())
    }

    @Test func theRequestListsTheApprovedIncludedCommentsInReportOrder() async throws {
        let comments = [
            comment("Major on page two", .major, page: 1, line: 0, label: "p. 2, line 1", created: 1),
            comment("Strength", .strength, page: 0, line: 0, label: "p. 1", created: 2),
            comment("Major on page one, line three", .major, page: 0, line: 2, label: "p. 1, line 3", created: 3),
            comment("Rejected major", .major, status: .rejected, page: 0, line: 0, label: "p. 1", created: 4),
            comment("Pending minor", .minor, status: .pending, page: 0, line: 0, label: "p. 1", created: 5),
            comment("Question left out of the report", .question, include: false, page: 0, line: 1, label: "p. 1", created: 6),
            comment("Minor, page only", .minor, page: 0, label: "p. 1", created: 7),
            comment("Major on page one, line one", .major, page: 0, line: 0, label: "p. 1, line 1", created: 8),
            comment("Question without a place", .question, page: nil, label: "", created: 9),
            comment("Minor on page one, line two", .minor, page: 0, line: 1, label: "p. 1, line 2", created: 10),
        ]
        let previous = ReportDraft(markdown: "Old.", userEdited: true, versions: [ReportVersion(markdown: "Older.", savedAt: Date(), note: "generated")])
        let meta = ManuscriptMeta(targetVenue: "Journal of Examples", reviewerNotes: "Keep it short.")
        let mock = MockLLMProvider()
        let context = EngineTest.context(meta: meta)
        let events = try await EngineTest.collect(EngineTest.engine([mock], paper: paper)
            .generateReport(paper: paper, session: session(comments, meta: meta, report: previous), context: context))

        let request = try #require(mock.recordedRequests.first)
        #expect(request.purpose == .report)
        #expect(request.system == DefaultSettings.make().prompts.reportSystem)
        let text = EngineTest.userText(of: request)
        let order = ["[M1] major | claims | p. 1, line 1", "[M2] major | claims | p. 1, line 3", "[M3] major | claims | p. 2, line 1",
                     "[m1] minor | data | p. 1\n", "[m2] minor | data | p. 1, line 2", "[Q1] question | data\n", "[S1] strength | data | p. 1"]
        var position = text.startIndex
        for header in order {
            guard let found = text.range(of: header, range: position..<text.endIndex) else {
                Issue.record("missing or out of order: \(header)")
                return
            }
            position = found.upperBound
        }
        #expect(text.contains("[M1] major | claims | p. 1, line 1\nquote: Quote of Major on page one, line one\ntitle: Major on page one, line one\n"
                              + "body: Body of Major on page one, line one.\nsuggestion: Fix Major on page one, line one."))
        #expect(!text.contains("Rejected major") && !text.contains("Pending minor") && !text.contains("Question left out"))
        #expect(text.hasPrefix(PromptBuilder.fullTextContext(FakePaperRenderer().render(paper.text, pages: nil))))
        #expect(text.contains("Target journal: Journal of Examples\nReviewer's notes: Keep it short.\n\nApproved comments:\n[M1]"))
        #expect(text.hasSuffix("Template:\n" + DefaultSettings.make().prompts.reportTemplate))

        let finished = try #require(events.finished)
        let sample = try Fixtures.text("llm/report_sample.txt").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(events.text == (try Fixtures.text("llm/report_sample.txt")))
        #expect(finished.draft.markdown == sample)
        #expect(finished.draft.recommendation == .majorRevision)
        #expect(finished.draft.userEdited == false)
        #expect(finished.draft.provider == context.provider)
        #expect(finished.draft.generatedAt != nil)
        #expect(finished.draft.versions == previous.versions)          // the model pushes the old draft, not the engine
        let expectedIDs = ["Major on page one, line one", "Major on page one, line three", "Major on page two", "Minor, page only",
                           "Minor on page one, line two", "Question without a place", "Strength"]
            .map { title in comments.first { $0.title == title }!.id }
        #expect(finished.draft.basedOnCommentIDs == expectedIDs)
        #expect(finished.run.kind == .report)
        #expect(finished.run.status == .completed)
    }

    @Test func emptyVenueAndNotesSaySo() async throws {
        let mock = MockLLMProvider()
        _ = try await EngineTest.collect(EngineTest.engine([mock], paper: paper)
            .generateReport(paper: paper, session: session([comment("One", .minor, page: 0, label: "p. 1", created: 1)]), context: EngineTest.context()))
        let text = EngineTest.userText(of: try #require(mock.recordedRequests.first))
        #expect(text.contains("Target journal: not specified\nReviewer's notes: none\n"))
    }

    @Test func withNoApprovedCommentTheJobFailsWithoutARequest() async throws {
        let mock = MockLLMProvider()
        let pending = [comment("Pending", .major, status: .pending, page: 0, label: "p. 1", created: 1),
                       comment("Approved but left out", .minor, include: false, page: 0, label: "p. 1", created: 2)]
        let previous = ReportDraft(markdown: "The report so far.", userEdited: true)
        let events = try await EngineTest.collect(EngineTest.engine([mock], paper: paper)
            .generateReport(paper: paper, session: session(pending, report: previous), context: EngineTest.context()))
        #expect(mock.recordedRequests.isEmpty)
        #expect(events.count == 2)
        let finished = try #require(events.finished)
        #expect(finished.run.status == .failed("Approve at least one comment first."))
        #expect(finished.run.requestCount == 0)
        #expect(finished.draft == previous)                            // nothing is lost
    }

    @Test(arguments: [
        ("## Summary assessment\n\nThe paper is sound.\n\n## Recommendation\n\nAccept. The concerns are cosmetic.\n\n## Major concerns\n\nNone.", Recommendation.accept),
        ("## Recommendation\n\nMinor revision: the main result stands, but two derivations need to be written out.\n", .minorRevision),
        ("## Recommendation\nMajor revision. The concerns below go to the main result.\n## Publication probability\n\nI would not reject it.", .majorRevision),
        ("## Recommendation\n\n**Reject.** The identification does not hold, and a major revision would not repair it.\n", .reject),
        ("## Recommendation\n\nAccept with minor revisions.\n", .minorRevision),
        ("**Recommendation**\n\nReject.\n", .reject),
        ("## Recommendation: major revision\n", .majorRevision),
        ("## Summary assessment\n\nI would reject this.\n", nil),
        ("## Recommendation\n\nIt depends on the editor.\n", nil),
    ] as [(String, Recommendation?)])
    func theRecommendationIsParsedFromItsSection(_ markdown: String, _ expected: Recommendation?) {
        #expect(ReportStructure.recommendation(in: markdown) == expected)
    }

    @Test func aFencedAnswerLosesItsFence() {
        #expect(ReportJob.cleaned("```markdown\n## Summary assessment\n\nFine.\n```\n") == "## Summary assessment\n\nFine.")
        #expect(ReportJob.cleaned("  ## Recommendation\n\nAccept.  \n") == "## Recommendation\n\nAccept.")
    }

    @Test func aFailedReportKeepsThePreviousDraft() async throws {
        let failing = MockResponse(text: "## Summary assessment\n\nHalf", chunkSize: 5, failAfterChunks: 2, failure: .quotaExhausted("weekly limit"))
        let mock = MockLLMProvider(script: EngineTest.script(.report, [failing]))
        let previous = ReportDraft(markdown: "Earlier report.", userEdited: false)
        let events = try await EngineTest.collect(EngineTest.engine([mock], paper: paper)
            .generateReport(paper: paper, session: session([comment("One", .major, page: 0, label: "p. 1", created: 1)], report: previous),
                            context: EngineTest.context()))
        let finished = try #require(events.finished)
        #expect(finished.run.status == .failed(LLMError.quotaExhausted("weekly limit").userMessage))
        #expect(finished.draft == previous)
        #expect(events.text == "## Summary")                            // two deltas of five characters
    }

    // ---- voice revision ----

    @Test func aVoiceRevisionSendsTheReportAndTheFindings() async throws {
        let mock = MockLLMProvider()
        let engine = EngineTest.engine([mock], paper: paper)
        let report = try Fixtures.text("llm/report_sample.txt")
        let findings = engine.lint(reportMarkdown: report)
        #expect(!findings.isEmpty)
        let events = try await EngineTest.collect(engine.reviseVoice(reportMarkdown: report, findings: findings, context: EngineTest.context()))
        let request = try #require(mock.recordedRequests.first)
        #expect(request.purpose == .revise)
        #expect(request.system == DefaultSettings.make().prompts.voiceRevisionSystem)
        #expect(request.parts.count == 1)                               // the report and the findings; no paper
        let text = EngineTest.userText(of: request)
        #expect(text.hasPrefix("The report:\n\n## Summary assessment"))
        #expect(text.contains("\n\nFlagged:\n- [em-dash] “—” Em dash: use a comma, parentheses or a new sentence."))
        #expect(text.contains("- [copula] “serves as” Write 'is'."))
        let finished = try #require(events.finished)
        #expect(finished.run.kind == .revise)
        #expect(finished.run.status == .completed)
        #expect(finished.run.sentPDF == false)
        #expect(finished.draft.markdown == report.trimmingCharacters(in: .whitespacesAndNewlines))   // the mock answers with the sample again
        #expect(finished.draft.recommendation == .majorRevision)
    }
}
