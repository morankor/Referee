import Foundation
import Testing
@testable import ReviewEngine
import RefereeCore
import TestSupport

/// Discussions (section 6.8), questions (section 6.9) and the paper context they carry (section 6.3): rows
/// "discussion", "ask" and "paper context" of WP6.
@Suite struct ReplyTests {
    private func comment(page: Int? = 0, quote: String = "The coefficient in Table 2 is 0.91", label: String = "p. 1",
                         thread: [ThreadMessage] = []) -> ReviewComment {
        let anchor = page.map { Anchor(quote: quote, pageIndex: $0, confidence: .pageOnly, locationLabel: label) }
            ?? Anchor(quote: quote, confidence: .none, locationLabel: "")
        return ReviewComment(id: UUID(), origin: .ai(runID: UUID()), status: .pending, kind: .major, category: "claims",
                             title: "The interval includes one, yet the effect is called robust", body: "The data are consistent with no effect.",
                             suggestion: "Drop \"robust\".", anchor: anchor, thread: thread, includeInReport: true, createdAt: Date(), updatedAt: Date())
    }

    private func discuss(_ answer: String, chunkSize: Int = 7, comment: ReviewComment? = nil, message: String = "The interval is in the text.")
        async throws -> (events: [ReplyEvent], request: LLMRequest?) {
        let paper = try makeSamplePaper()
        let mock = MockLLMProvider(script: EngineTest.script(.discussion, [MockResponse(text: answer, chunkSize: chunkSize)]))
        let events = try await EngineTest.collect(EngineTest.engine([mock], paper: paper)
            .discuss(paper: paper, comment: comment ?? self.comment(), message: message, context: EngineTest.context()))
        return (events, mock.recordedRequests.first)
    }

    // ---- discussion ----

    @Test(arguments: [1, 7, 4_096])
    func theReplyBeforeRevisedIsVisibleAndTheBlockIsTheRevision(chunkSize: Int) async throws {
        let answer = try Fixtures.text("llm/discussion_revise.txt")
        let (events, _) = try await discuss(answer, chunkSize: chunkSize)
        guard let finished = events.finished else {
            Issue.record("expected .finished, got \(events)")
            return
        }
        let visible = "You are right that the interval is in the text and not only in the table. The sentence says the interval \"crosses one\", "
            + "so the comment should not say the paper hides it. The problem that remains is the word \"robust\"."
        #expect(finished.reply.text == visible)
        #expect(finished.reply.role == .assistant)
        #expect(finished.reply.provider == ProviderRef(providerID: "mock", model: "mock"))
        #expect(events.text.trimmingCharacters(in: .whitespacesAndNewlines) == visible)
        #expect(!events.text.contains("@@"))
        #expect(finished.proposal == CommentRevision(kind: .minor, title: "\"Robust\" is not supported by the reported interval",
                                                     body: "The introduction itself says the interval crosses one. Calling the effect robust in the same "
                                                         + "sentence is unsupported. Please delete the word or point to the robustness check it refers to.",
                                                     suggestion: nil, withdraw: false))
        #expect(finished.run.kind == .discussion)
        #expect(finished.run.status == .completed)
        #expect(finished.run.requestCount == 1)
        if case .started(let run)? = events.first { #expect(run.id == finished.run.id) } else { Issue.record("expected .started first") }
    }

    @Test func withdrawProposesDroppingTheComment() async throws {
        let original = comment()
        let (events, _) = try await discuss("I agree; the comment does not hold once the interval is read correctly.\n@@WITHDRAW\n", comment: original)
        let finished = try #require(events.finished)
        #expect(finished.reply.text == "I agree; the comment does not hold once the interval is read correctly.")
        #expect(finished.proposal?.withdraw == true)
        #expect(finished.proposal?.title == original.title)
        #expect(!events.text.contains("WITHDRAW"))
    }

    @Test func noBlockMeansNoProposal() async throws {
        let (events, _) = try await discuss("The comment stands: Table 2 reports the same interval.\nNothing in it needs to change.")
        let finished = try #require(events.finished)
        #expect(finished.proposal == nil)
        #expect(finished.reply.text == "The comment stands: Table 2 reports the same interval.\nNothing in it needs to change.")
        #expect(events.text == "The comment stands: Table 2 reports the same interval.\nNothing in it needs to change.")
    }

    @Test func aRevisionKeepsWhatItLeavesOut() async throws {
        let original = comment()
        let (events, _) = try await discuss("Shorter.\n**@@REVISED**\nkind: question\ntitle: Which interval is meant?\n@@END\nIgnored afterwards.", comment: original)
        let proposal = try #require(events.finished?.proposal)
        #expect(proposal == CommentRevision(kind: .question, title: "Which interval is meant?", body: original.body, suggestion: nil, withdraw: false))
        #expect(events.finished?.reply.text == "Shorter.")
    }

    @Test func theDiscussionRequestCarriesTheCommentTheTranscriptAndTheMessage() async throws {
        let thread = [ThreadMessage(id: UUID(), role: .user, text: "Is the interval really in the text?", createdAt: Date()),
                      ThreadMessage(id: UUID(), role: .assistant, text: "Yes, in the introduction.", createdAt: Date()),
                      ThreadMessage(id: UUID(), role: .user, text: "Then soften the comment.", createdAt: Date())]
        let (_, request) = try await discuss("Fine.", comment: comment(label: "p. 1, lines 13–14", thread: thread), message: "Then soften the comment.")
        let sent = try #require(request)
        #expect(sent.purpose == .discussion)
        #expect(sent.system.hasSuffix(FormatSpec.revision))
        #expect(sent.system.hasPrefix(DefaultSettings.make().prompts.discussionSystem))
        let text = EngineTest.userText(of: sent)
        #expect(text.contains("""
            The comment under discussion (location: p. 1, lines 13–14):
            kind: major | category: claims
            quote: The coefficient in Table 2 is 0.91
            title: The interval includes one, yet the effect is called robust
            body: The data are consistent with no effect.
            suggestion: Drop "robust".

            Discussion so far:
            Referee: Is the interval really in the text?
            Assistant: Yes, in the introduction.

            Referee: Then soften the comment.
            """))
        // The new message, already in the thread, is not repeated in the transcript.
        #expect(text.components(separatedBy: "Then soften the comment.").count == 2)
        guard sent.parts.count == 3, case .cacheBoundary = sent.parts[1] else {
            Issue.record("expected paper context, cache boundary, task; got \(sent.parts.count) parts")
            return
        }
    }

    // ---- ask ----

    @Test func aQuestionAboutASelectionCarriesThePassageAndItsLabel() async throws {
        let paper = try makeSamplePaper()
        let mock = MockLLMProvider()
        let anchor = Anchor(quote: "The effect is statistically significant but economically small.", pageIndex: 0, confidence: .exact,
                            locationLabel: "p. 1, line 9")
        let conversation = Conversation(id: UUID(), anchor: anchor, createdAt: Date())
        let events = try await EngineTest.collect(EngineTest.engine([mock], paper: paper)
            .ask(paper: paper, conversation: conversation, question: "Is the claim in the abstract supported?", context: EngineTest.context()))
        let request = try #require(mock.recordedRequests.first)
        #expect(request.purpose == .question)
        #expect(request.system == DefaultSettings.make().prompts.questionSystem)
        let text = EngineTest.userText(of: request)
        #expect(text.contains("Selected passage (p. 1, line 9): «The effect is statistically significant but economically small.»"))
        #expect(text.hasSuffix("Referee: Is the claim in the abstract supported?"))
        let finished = try #require(events.finished)
        #expect(finished.reply.text == (try Fixtures.text("llm/question_answer.txt")).trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(finished.proposal == nil)
        #expect(finished.run.kind == .question)
        #expect(finished.run.status == .completed)
    }

    @Test func aGeneralQuestionHasNoPassageSection() async throws {
        let paper = try makeSamplePaper()
        let mock = MockLLMProvider()
        let history = [ThreadMessage(id: UUID(), role: .user, text: "What is the main claim?", createdAt: Date()),
                       ThreadMessage(id: UUID(), role: .assistant, text: "That disclosure slows herding.", createdAt: Date())]
        let conversation = Conversation(id: UUID(), messages: history, createdAt: Date())
        _ = try await EngineTest.collect(EngineTest.engine([mock], paper: paper)
            .ask(paper: paper, conversation: conversation, question: "Is it supported?", context: EngineTest.context()))
        let text = EngineTest.userText(of: try #require(mock.recordedRequests.first))
        #expect(!text.contains("Selected passage"))
        #expect(text.contains("Conversation so far:\nReferee: What is the main claim?\nAssistant: That disclosure slows herding.\n\nReferee: Is it supported?"))
    }

    // ---- paper context ----

    /// Six pages of about 4,000 characters (24,000 in all, about 6,900 tokens) and a context of 16,000 tokens: the reply
    /// budget is 7,976 tokens, 60% of it 4,785 tokens (16,700 characters), so the paper does not fit and an excerpt goes.
    private let largePaper = EngineTest.paper(pageCount: 6, charactersPerPage: 4_000)
    private let smallContext = ProviderSettings(enabled: true, contextWindowOverride: 16_000, inputMode: .auto)
    private let digest = "DIGEST: the paper asks whether disclosure slows herding; p.4: Page 4 marker"

    private func pagesIn(_ text: String) -> [Int] {
        (1...6).filter { text.contains(EngineTest.pageWord($0)) }
    }

    @Test func aDiscussionOfALargePaperCarriesTheDigestAndThePagesAroundTheAnchor() async throws {
        let mock = MockLLMProvider()
        let engine = EngineTest.engine([mock], paper: largePaper)
        let context = EngineTest.context(settings: smallContext, digest: digest)
        _ = try await EngineTest.collect(engine.discuss(paper: largePaper, comment: comment(page: 3, quote: "Page 4 marker", label: "p. 4"),
                                                        message: "Is this right?", context: context))
        let text = EngineTest.userText(of: try #require(mock.recordedRequests.first))
        #expect(text.contains(digest))
        #expect(text.contains("[[page 4]]"))
        #expect(pagesIn(text) == [3, 4, 5])
    }

    @Test func aQuestionAboutALargePaperCarriesTheDigestAndTheAnchorsPage() async throws {
        let mock = MockLLMProvider()
        let engine = EngineTest.engine([mock], paper: largePaper)
        let context = EngineTest.context(settings: smallContext, digest: digest)
        let anchored = Conversation(id: UUID(), anchor: Anchor(quote: "Page 6 marker", pageIndex: 5, confidence: .exact, locationLabel: "p. 6"),
                                    createdAt: Date())
        _ = try await EngineTest.collect(engine.ask(paper: largePaper, conversation: anchored, question: "Why?", context: context))
        let anchoredText = EngineTest.userText(of: try #require(mock.recordedRequests.first))
        #expect(anchoredText.contains(digest))
        #expect(pagesIn(anchoredText) == [5, 6])                 // the last page has one neighbour

        // Without a selection: the digest and page 1 with its neighbour.
        _ = try await EngineTest.collect(engine.ask(paper: largePaper, conversation: Conversation(id: UUID(), createdAt: Date()), question: "Why?",
                                                    context: context))
        let generalText = EngineTest.userText(of: mock.recordedRequests[1])
        #expect(generalText.contains(digest))
        #expect(generalText.contains("[[page 1]]"))
        #expect(pagesIn(generalText) == [1, 2])
    }

    @Test func theReportOfALargePaperCarriesTheDigestAndPageOne() async throws {
        let mock = MockLLMProvider()
        let engine = EngineTest.engine([mock], paper: largePaper)
        var approved = comment(page: 3, quote: "Page 4 marker", label: "p. 4")
        approved.status = .approved
        let session = ReviewSession(schemaVersion: 1, id: UUID(), document: largePaper.ref, meta: ManuscriptMeta(reviewerNotes: ""), comments: [approved],
                                    createdAt: Date(), updatedAt: Date())
        // The report reserves 8,000 output tokens: at 20,000 its budget is 7,976 tokens, the same as a reply's at 16,000.
        let reportSettings = ProviderSettings(enabled: true, contextWindowOverride: 20_000, inputMode: .auto)
        _ = try await EngineTest.collect(engine.generateReport(paper: largePaper, session: session,
                                                               context: EngineTest.context(settings: reportSettings, digest: digest)))
        let text = EngineTest.userText(of: try #require(mock.recordedRequests.first))
        #expect(text.contains(digest))
        #expect(pagesIn(text) == [1, 2])
    }

    @Test func withoutADigestTheExcerptIsThePagesAlone() async throws {
        let mock = MockLLMProvider()
        let engine = EngineTest.engine([mock], paper: largePaper)
        _ = try await EngineTest.collect(engine.discuss(paper: largePaper, comment: comment(page: 3, quote: "Page 4 marker", label: "p. 4"),
                                                        message: "Is this right?", context: EngineTest.context(settings: smallContext)))
        let text = EngineTest.userText(of: try #require(mock.recordedRequests.first))
        #expect(!text.contains("DIGEST"))
        #expect(!text.contains("notes on the whole manuscript"))
        #expect(pagesIn(text) == [3, 4, 5])
    }

    @Test func aPaperThatFitsGoesWhole() async throws {
        let mock = MockLLMProvider()
        let engine = EngineTest.engine([mock], paper: largePaper)
        _ = try await EngineTest.collect(engine.discuss(paper: largePaper, comment: comment(page: 3, quote: "Page 4 marker", label: "p. 4"),
                                                        message: "Is this right?", context: EngineTest.context(digest: digest)))
        let request = try #require(mock.recordedRequests.first)
        let text = EngineTest.userText(of: request)
        #expect(pagesIn(text) == [1, 2, 3, 4, 5, 6])
        #expect(!text.contains(digest))
        guard case .text(let first)? = request.parts.first else { return }
        #expect(first.hasPrefix(PromptBuilder.textIntroduction))
    }

    @Test func aPaperThatFitsAsPDFGoesAsPDF() async throws {
        let paper = try makeSamplePaper()
        let mock = MockLLMProvider(supportsNativePDF: true)
        let context = EngineTest.context(model: try await mock.listModels().first)
        _ = try await EngineTest.collect(EngineTest.engine([mock], paper: paper).discuss(paper: paper, comment: comment(), message: "Hm?", context: context))
        let request = try #require(mock.recordedRequests.first)
        #expect(request.parts.first == .pdf(data: paper.data, fileName: "manuscript.pdf"))
        #expect(request.parts[1] == .cacheBoundary)
        guard case .text(let task)? = request.parts.last else { return }
        #expect(task.hasPrefix("The manuscript is the attached PDF. Use PDF page numbers: the first page of the file is page 1."))
    }

    @Test func aReplyStoppedByAFailureKeepsWhatWasShown() async throws {
        let paper = try makeSamplePaper()
        let answer = MockResponse(text: "The first sentence arrives. The second never does.", chunkSize: 10, failAfterChunks: 3,
                                  failure: .network("connection reset"))
        let mock = MockLLMProvider(script: EngineTest.script(.discussion, [answer]))
        let events = try await EngineTest.collect(EngineTest.engine([mock], paper: paper)
            .discuss(paper: paper, comment: comment(), message: "Go on.", context: EngineTest.context()))
        let finished = try #require(events.finished)
        #expect(finished.run.status == .failed(LLMError.network("connection reset").userMessage))
        #expect(finished.reply.text == "The first sentence arrives. Th")         // three deltas of ten characters
        #expect(finished.proposal == nil)
    }
}
