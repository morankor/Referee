import Foundation
import Testing
@testable import ReviewEngine
import RefereeCore
import TestSupport

/// Prompt assembly (plan.md section 6.3, Appendix B.2 and the doc comment of `FormatSpec`): row "prompts" of WP6.
@Suite struct PromptTests {
    private func reviewRequest(meta: ManuscriptMeta = ManuscriptMeta(reviewerNotes: ""), existing: [ReviewComment] = [], pdf: Bool = false,
                               rubric: [RubricCategory]? = nil) async throws -> (LLMRequest, LoadedPaper) {
        let paper = try makeSamplePaper()
        let mock = MockLLMProvider(supportsNativePDF: pdf)
        var context = EngineTest.context(model: try await mock.listModels().first, meta: meta)
        if let rubric { context.rubric = rubric }
        _ = try await EngineTest.collect(EngineTest.engine([mock], paper: paper).review(paper: paper, existing: existing, context: context))
        return (try #require(mock.recordedRequests.first), paper)
    }

    private func existing(_ title: String, status: CommentStatus) -> ReviewComment {
        ReviewComment(id: UUID(), origin: .user, status: status, kind: .minor, category: "other", title: title, body: "b",
                      anchor: Anchor(quote: "", confidence: .none, locationLabel: ""), includeInReport: true, createdAt: Date(), updatedAt: Date())
    }

    @Test func theReviewSystemPromptHasTheRubricAndTheFormat() async throws {
        let (request, _) = try await reviewRequest()
        let defaults = DefaultSettings.make()
        #expect(request.system.hasPrefix(defaults.prompts.reviewSystem))
        #expect(request.system.hasSuffix(FormatSpec.review))
        #expect(request.system.contains(#"Categories (use the id in the "category" field):"#))
        for category in defaults.rubric where category.enabled {
            #expect(request.system.contains("- \(category.id): \(category.name). \(category.guidance)"))
        }
        // The rubric block stands between the system prompt and the format.
        let rubric = try #require(request.system.range(of: "Categories (use the id"))
        let format = try #require(request.system.range(of: "OUTPUT FORMAT."))
        #expect(rubric.lowerBound < format.lowerBound)
    }

    @Test func onlyEnabledCategoriesAreListed() async throws {
        var rubric = DefaultSettings.make().rubric
        rubric[0].enabled = false
        let (request, _) = try await reviewRequest(rubric: rubric)
        #expect(!request.system.contains("- claims:"))
        #expect(request.system.contains("- assumptions:"))
        #expect(PromptBuilder.rubricBlock([]).hasSuffix("- other: Other."))
    }

    @Test func pdfModePutsThePDFFirstAndACacheBoundaryAfterIt() async throws {
        let (request, paper) = try await reviewRequest(pdf: true)
        #expect(request.parts.count == 3)
        #expect(request.parts.first == .pdf(data: paper.data, fileName: "manuscript.pdf"))
        #expect(request.parts[1] == .cacheBoundary)
        #expect(request.parts.last == .text("""
            The manuscript is the attached PDF. Use PDF page numbers: the first page of the file is page 1.
            Write your referee comments on this manuscript in the required format.
            """))
    }

    @Test func textModeCarriesTheRenderedPaperThenTheTask() async throws {
        let (request, paper) = try await reviewRequest()
        #expect(request.parts.count == 3)
        guard case .text(let paperText) = request.parts[0], case .cacheBoundary = request.parts[1], case .text(let task) = request.parts[2] else {
            Issue.record("expected text, cache boundary, text; got \(request.parts)")
            return
        }
        #expect(paperText.hasPrefix("The manuscript follows as text extracted from a PDF. Lines of the form [[page N]] mark where PDF page N begins"))
        #expect(paperText.contains("Extraction leaves artefacts: words run together without spaces, odd hyphenation, and equations and tables broken "
                                   + "into fragments. These are not errors in the manuscript; do not comment on them."))
        let rendered = FakePaperRenderer().render(paper.text, pages: nil)
        #expect(paperText.hasSuffix(rendered.trimmingCharacters(in: .newlines)))
        #expect(task == "Write your referee comments on this manuscript in the required format.")
    }

    @Test func reviewerNotesVenueAndExistingTitlesAppearInTheTask() async throws {
        let meta = ManuscriptMeta(targetVenue: "Journal of Examples", reviewerNotes: "Focus on identification.\nIgnore the typos.")
        let (request, _) = try await reviewRequest(meta: meta, existing: [existing("First earlier comment", status: .approved),
                                                                           existing("Rejected one", status: .rejected),
                                                                           existing("Second earlier comment", status: .pending)])
        #expect(request.parts.last == .text("""
            Write your referee comments on this manuscript in the required format.
            Reviewer's notes: Focus on identification.
            Ignore the typos.
            Target journal: Journal of Examples
            Comments already made, do not repeat them: First earlier comment; Second earlier comment
            """))
        let (pdfRequest, _) = try await reviewRequest(meta: meta, pdf: true)
        guard case .text(let pdfTask)? = pdfRequest.parts.last else { return }
        #expect(pdfTask.hasSuffix("Reviewer's notes: Focus on identification.\nIgnore the typos.\nTarget journal: Journal of Examples"))
    }

    @Test func noPromptContainsTheDocumentsFileName() async throws {
        let paper = EngineTest.paper(pageCount: 3, charactersPerPage: 600)
        #expect(paper.ref.fileName == EngineTest.secretFileName)
        let text = MockLLMProvider()
        let pdf = MockLLMProvider(id: "mock-pdf", supportsNativePDF: true)
        let engine = EngineTest.engine([text, pdf], paper: paper)
        let comment = ReviewComment(id: UUID(), origin: .user, status: .approved, kind: .major, category: "claims", title: "T", body: "B",
                                    anchor: Anchor(quote: "Page 1 marker", pageIndex: 0, confidence: .pageOnly, locationLabel: "p. 1"),
                                    includeInReport: true, createdAt: Date(), updatedAt: Date())
        let session = ReviewSession(schemaVersion: 1, id: UUID(), document: paper.ref, meta: ManuscriptMeta(reviewerNotes: ""), comments: [comment],
                                    createdAt: Date(), updatedAt: Date())
        for (provider, mock) in [("mock", text), ("mock-pdf", pdf)] {
            let context = EngineTest.context(provider: provider, model: try await mock.listModels().first)
            _ = try await EngineTest.collect(engine.review(paper: paper, existing: [], context: context))
            _ = try await EngineTest.collect(engine.discuss(paper: paper, comment: comment, message: "Why?", context: context))
            _ = try await EngineTest.collect(engine.ask(paper: paper, conversation: Conversation(id: UUID(), createdAt: Date()), question: "Why?",
                                                        context: context))
            _ = try await EngineTest.collect(engine.generateReport(paper: paper, session: session, context: context))
            _ = try await EngineTest.collect(engine.reviseVoice(draft: ReportDraft(markdown: "## Summary assessment\n\nFine.", userEdited: false),
                                                                findings: [], context: context))
        }
        let requests = text.recordedRequests + pdf.recordedRequests
        #expect(requests.count == 10)
        #expect(pdf.recordedRequests.contains { $0.parts.contains { if case .pdf = $0 { return true } else { return false } } })
        for request in requests {
            #expect(!EngineTest.text(of: request).contains("Rossi"))
            #expect(!EngineTest.text(of: request).contains("JPE-2026"))
            for case .pdf(_, let fileName) in request.parts { #expect(fileName == "manuscript.pdf") }
        }
    }

    // ---- FormatSpec placeholders ----

    @Test func partTasksFollowTheRuleForTheirMarker() {
        let first = PromptBuilder.partTask(part: 1, of: 3, firstPage: 1, lastPage: 4, notes: "", text: "[[page 1]]\nText.\n")
        #expect(first.hasPrefix("The manuscript is long, so you are reading it in parts, as text extracted from a PDF. This is part 1 of 3: PDF pages 1 to 4."))
        #expect(!first.contains("{"))
        #expect(!first.contains("Your notes on the earlier parts"))
        #expect(first.contains("do not comment on them.\n\n[[page 1]]\nText.\n\nFirst write comments on this part"))

        let second = PromptBuilder.partTask(part: 2, of: 3, firstPage: 5, lastPage: 8, notes: "Earlier {titles} notes.", text: "[[page 5]]\nMore.")
        #expect(second.contains("This is part 2 of 3: PDF pages 5 to 8."))
        #expect(second.contains("do not comment on them.\n\nYour notes on the earlier parts:\nEarlier {titles} notes.\n\n[[page 5]]\nMore.\n\nFirst write"))
        #expect(!second.contains("{if i > 1:}"))
        #expect(second.hasSuffix("End with a line containing only @@DONE"))

        let noNotes = PromptBuilder.partTask(part: 2, of: 2, firstPage: 3, lastPage: 3, notes: "", text: "x")
        #expect(noNotes.contains("Your notes on the earlier parts:\n(none)\n"))
    }

    @Test func wholeAndContinueTasksAreFilledIn() {
        let whole = PromptBuilder.wholeTask(notes: "N.", titles: ["A", "B"])
        #expect(whole.hasPrefix("You have now read the whole manuscript in parts. Your notes:\nN.\n\nComments you already made: A; B\n\n"))
        #expect(PromptBuilder.wholeTask(notes: "", titles: []).contains("Your notes:\n(none)\n\nComments you already made: none\n"))
        #expect(PromptBuilder.continueTask(titles: ["A", "B"]) == """
            Your previous answer was cut off. Comments already written (do not repeat them): A; B
            Continue with the remaining comments in the same format and end with a line containing only @@DONE
            """)
        #expect(PromptBuilder.fill("{a}{b}{a}", ["a": "{b}", "b": "2"]) == "{b}2{b}")
        #expect(PromptBuilder.fill("open { and {unknown}", ["x": "y"]) == "open { and {unknown}")
    }
}
