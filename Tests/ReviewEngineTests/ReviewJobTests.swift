import Foundation
import Testing
@testable import ReviewEngine
import RefereeCore
import TestSupport

/// The review job (plan.md section 6.6) with the mock provider and the fakes of TestSupport.
@Suite struct ReviewJobTests {
    private func block(kind: String = "minor", category: String = "claims", page: Int = 1, quote: String, title: String,
                       body: String = "A body.") -> String {
        "@@COMMENT\nkind: \(kind)\ncategory: \(category)\npage: \(page)\nquote: \(quote)\ntitle: \(title)\nbody:\n\(body)\n@@END\n"
    }

    // ---- review, one pass ----

    @Test func aOnePassReviewEmitsTheEventsOfSection66() async throws {
        let mock = MockLLMProvider()
        let paper = try makeSamplePaper()
        let engine = EngineTest.engine([mock], paper: paper)
        let events = try await EngineTest.collect(engine.review(paper: paper, existing: [], context: EngineTest.context()))

        guard let started = events.startedRun, let run = events.finishedRun else {
            Issue.record("a review starts with .started and ends with .finished; got \(events)")
            return
        }
        #expect(started.status == .running)
        #expect(started.kind == .review)
        #expect(events[1] == .phase(.preparing))
        #expect(events.phases == [.preparing, .reading(part: 1, of: 1)])
        // Nothing but drafts, comments and notices between the phases and the end.
        for event in events.dropFirst(3).dropLast() {
            switch event {
            case .draft, .comment, .notice: break
            default: Issue.record("unexpected event in the middle of a review: \(event)")
            }
        }
        #expect(events.digests.isEmpty)

        let comments = events.comments
        #expect(comments.count == 6)
        #expect(comments.allSatisfy { $0.status == .pending && $0.includeInReport && $0.origin == .ai(runID: run.id) && $0.similarTo == nil })
        // FakeQuoteMatcher finds the third and the sixth quote on the sample paper; the others anchor to their page.
        #expect(comments.map(\.anchor.confidence) == [.pageOnly, .pageOnly, .exact, .pageOnly, .pageOnly, .exact])
        #expect(comments.map(\.anchor.locationLabel) == ["p. 1", "p. 1", "p. 1", "p. 2", "p. 2", "p. 1"])
        #expect(comments.map(\.anchor.pageIndex) == [0, 0, 0, 1, 1, 0])
        #expect(comments[2].anchor.spans.count == 1)
        #expect(comments[2].anchor.rects.map(\.x) == [100])           // FakePaperService fills the rectangles
        #expect(comments[0].anchor.spans.isEmpty && comments[0].anchor.rects.isEmpty)
        #expect(comments[2].anchor.quote == "The effect is statistically significant but economically small.")

        // Each comment replaces a draft announced before it, with the same id.
        var drafts: Set<UUID> = []
        for event in events {
            if case .draft(let draft) = event { drafts.insert(draft.id) }
            if case .comment(let comment, let replaced) = event {
                #expect(drafts.contains(replaced))
                #expect(comment.id == replaced)
            }
        }

        #expect(run.id == started.id)
        #expect(run.status == .completed)
        #expect(run.requestCount == 1)
        #expect(run.usage?.inputTokens != nil && run.usage?.outputTokens != nil)
        #expect(run.sentPDF == false)
        #expect(run.destination == "this Mac")
        #expect(run.finishedAt != nil)
        #expect(mock.recordedRequests.count == 1)
        #expect(mock.recordedRequests.first?.purpose == .review)
        #expect(mock.recordedRequests.first?.model == "mock")
    }

    @Test func aStreamThatIsNeverIteratedSendsNothing() async throws {
        let mock = MockLLMProvider()
        let paper = try makeSamplePaper()
        let engine = EngineTest.engine([mock], paper: paper)
        let stream = engine.review(paper: paper, existing: [], context: EngineTest.context())
        try await Task.sleep(for: .milliseconds(50))
        #expect(mock.recordedRequests.isEmpty)
        _ = stream
    }

    // ---- review, in parts ----

    @Test func aReviewInThreePartsSendsFourRequestsAndEmitsTheDigestOnce() async throws {
        // Three pages of about 10,000 characters; an input budget of 4,000 tokens (14,000 characters, 11,600 for a part):
        // one page per part.
        let paper = EngineTest.paper(pageCount: 3, charactersPerPage: 10_000)
        let model = ModelInfo(id: "mock", displayName: "mock", contextWindow: 4_000 + 16_000 + 3_000 + 1_024)
        let answers = [
            block(page: 1, quote: "Page 1 marker", title: "On part one") + "@@NOTES\nNOTES-ONE: the question and the design.\np.1: Page 1 marker\n@@DONE\n",
            block(page: 2, quote: "Page 2 marker", title: "On part two") + "@@NOTES\nNOTES-TWO: what part two adds.\n@@DONE\n",
            "@@NOTES\nNOTES-THREE: the final notes on all three parts.\n@@DONE\n",
            block(kind: "major", page: 3, quote: "Page 3 marker", title: "On the whole paper") + "@@DONE\n",
        ].map { MockResponse(text: $0, chunkSize: 11) }
        let mock = MockLLMProvider(script: EngineTest.script(.review, answers))
        let engine = EngineTest.engine([mock], paper: paper)
        let context = EngineTest.context(model: model)
        let plan = await engine.plan(paper: paper, context: context)
        #expect(plan.requestCount == 4)
        #expect(plan.warnings.contains { $0.hasPrefix("Paper will be read in 3 parts") })

        let events = try await EngineTest.collect(engine.review(paper: paper, existing: [], context: context))
        let requests = mock.recordedRequests
        #expect(requests.count == 4)
        guard requests.count == 4 else { return }
        #expect(events.phases == [.preparing, .reading(part: 1, of: 3), .reading(part: 2, of: 3), .reading(part: 3, of: 3), .wholePaperPass])

        let first = EngineTest.userText(of: requests[0])
        #expect(first.contains("This is part 1 of 3: PDF pages 1 to 1."))
        #expect(!first.contains("Your notes on the earlier parts"))
        #expect(first.contains(EngineTest.pageWord(1)) && !first.contains(EngineTest.pageWord(2)))
        let second = EngineTest.userText(of: requests[1])
        #expect(second.contains("This is part 2 of 3: PDF pages 2 to 2."))
        #expect(second.contains("Your notes on the earlier parts:\nNOTES-ONE: the question and the design."))
        #expect(second.contains(EngineTest.pageWord(2)) && !second.contains(EngineTest.pageWord(1)))
        #expect(EngineTest.userText(of: requests[2]).contains("NOTES-TWO"))
        let whole = EngineTest.userText(of: requests[3])
        #expect(whole.contains("You have now read the whole manuscript in parts. Your notes:\nNOTES-THREE"))
        #expect(whole.contains("Comments you already made: On part one; On part two"))
        #expect(requests.allSatisfy { $0.parts.count == 1 })        // one text each, the part inside the task

        #expect(events.digests == ["NOTES-THREE: the final notes on all three parts."])
        let digestPosition = events.firstIndex { if case .digest = $0 { return true } else { return false } }
        #expect(digestPosition == events.count - 2)                 // just before .finished
        #expect(events.comments.map(\.title) == ["On part one", "On part two", "On the whole paper"])
        #expect(events.finishedRun?.requestCount == 4)
        #expect(events.finishedRun?.status == .completed)
    }

    // ---- continuation ----

    @Test func anAnswerCutOffByMaxTokensIsContinuedAtMostTwice() async throws {
        let cut = block(quote: "Our identification strategy exploits", title: "First comment")
            + block(quote: "network structure determines", title: "Second comment")
            + "@@COMMENT\nkind: minor\ncategory: math\npage: 2\nquote: Proposition 1 states\ntitle: Third comment, cut off\nbody:\nThe body stops in the mid"
        let answers = [MockResponse(text: cut, stop: .maxTokens),
                       MockResponse(text: block(quote: "Proposition 1", title: "Fourth comment") + "@@COMMENT\nkind: minor\ntitle: Fifth, cut", stop: .maxTokens),
                       MockResponse(text: block(quote: "staggered rollout", title: "Sixth comment"), stop: .maxTokens)]
        let mock = MockLLMProvider(script: EngineTest.script(.review, answers))
        let paper = try makeSamplePaper()
        let events = try await EngineTest.collect(EngineTest.engine([mock], paper: paper).review(paper: paper, existing: [], context: EngineTest.context()))

        let requests = mock.recordedRequests
        #expect(requests.count == 3)                                  // the request and two continuations, no more
        guard requests.count == 3 else { return }
        #expect(requests[0].parts.count == 3)
        // The same paper context, then TASK_CONTINUE with the titles so far.
        #expect(requests[1].parts.prefix(2) == requests[0].parts.prefix(2))
        guard case .text(let continuation)? = requests[1].parts.last else {
            Issue.record("the continuation should end with a text part")
            return
        }
        #expect(continuation.hasPrefix("Your previous answer was cut off. Comments already written (do not repeat them): "))
        #expect(continuation.contains("First comment; Second comment; Third comment, cut off"))
        guard case .text(let second)? = requests[2].parts.last else { return }
        #expect(second.contains("Fourth comment; Fifth, cut"))
        #expect(events.comments.map(\.title) == ["First comment", "Second comment", "Third comment, cut off", "Fourth comment", "Fifth, cut",
                                                 "Sixth comment"])
        #expect(events.comments[2].body == "The body stops in the mid")
        #expect(events.notices.contains { $0.contains("cut off") })
        #expect(events.finishedRun?.requestCount == 3)
        #expect(events.finishedRun?.status == .completed)
    }

    @Test func anOpenLastBlockWithoutDoneIsContinuedAndAClosedOneIsNot() async throws {
        let paper = try makeSamplePaper()
        // Ends normally, without @@DONE, inside a block: one continuation, which ends with @@DONE.
        let open = MockScript(responses: [.review: [
            MockResponse(text: block(quote: "q one", title: "One") + "@@COMMENT\nkind: minor\ntitle: Two\nbody:\nUnfinished"),
            MockResponse(text: block(quote: "q three", title: "Three") + "@@DONE\n"),
        ]])
        let first = MockLLMProvider(script: open)
        let events = try await EngineTest.collect(EngineTest.engine([first], paper: paper).review(paper: paper, existing: [], context: EngineTest.context()))
        #expect(first.recordedRequests.count == 2)
        #expect(events.comments.map(\.title) == ["One", "Two", "Three"])

        // Ends normally without @@DONE with its last block closed: complete.
        let closed = MockLLMProvider(script: MockScript(responses: [.review: [MockResponse(text: block(quote: "q one", title: "One"))]]))
        let more = try await EngineTest.collect(EngineTest.engine([closed], paper: paper).review(paper: paper, existing: [], context: EngineTest.context()))
        #expect(closed.recordedRequests.count == 1)
        #expect(more.comments.count == 1)
        #expect(more.finishedRun?.status == .completed)
    }

    @Test func aRefusalEndsTheRunWithANotice() async throws {
        let paper = try makeSamplePaper()
        let mock = MockLLMProvider(script: MockScript(responses: [.review: [MockResponse(text: block(quote: "q", title: "Only"), stop: .refusal)]]))
        let events = try await EngineTest.collect(EngineTest.engine([mock], paper: paper).review(paper: paper, existing: [], context: EngineTest.context()))
        #expect(events.notices.contains("The model declined to continue."))
        #expect(events.comments.count == 1)
        #expect(events.finishedRun?.status == .completed)
        #expect(mock.recordedRequests.count == 1)
    }

    // ---- repeats and similar ----

    /// A paper on which FakeQuoteMatcher finds every quote of review_dupes.txt, each on a line of its own.
    private func dupesPaper() -> LoadedPaper {
        EngineTest.paper(pages: [[
            "Intro text. The coefficient in Table 2 is 0.91 with a confidence interval that crosses one, the text goes on.",
            "Our identification strategy exploits the staggered rollout of a disclosure rule.",
            "The effect is statistically significant but economically small.",
            "As shown elsewhere, network structure determines whether learning is efficient in such models.",
        ], [
            "Proposition 1 states that an information cascade begins with positive probability.",
        ]])
    }

    @Test func repeatsAreDroppedAndCommentsOnTheSamePassageAreMarked() async throws {
        let paper = dupesPaper()
        let mock = MockLLMProvider(script: EngineTest.script(.review, [MockResponse(text: try EngineTest.fixture("review_dupes.txt"))]))
        let events = try await EngineTest.collect(EngineTest.engine([mock], paper: paper).review(paper: paper, existing: [], context: EngineTest.context()))
        let comments = events.comments
        #expect(comments.map(\.title) == [
            "The interval includes one, yet the effect is called robust",
            "Missing definition of the interval",
            "Is the interval in the text the one of Table 2, column 3?",
            "The rollout gives a credible source of variation",
            "Proposition 1 is stated precisely",
        ])
        guard comments.count == 5 else { return }
        #expect(comments.allSatisfy { $0.anchor.confidence == .exact })
        #expect(comments[0].similarTo == nil)
        #expect(comments[1].similarTo == comments[0].id)          // same kind, same quote, other title
        #expect(comments[2].similarTo == nil)                      // a question on the same quote
        #expect(comments[3].similarTo == nil && comments[4].similarTo == nil)
        // The two strength comments beyond the limit are named in one notice.
        let strengthNotices = events.notices.filter { $0.contains("strength") }
        #expect(strengthNotices.count == 1)
        #expect(strengthNotices.first?.contains("The abstract separates statistical from economic significance") == true)
        #expect(strengthNotices.first?.contains("The network literature is cited where it matters") == true)
    }

    @Test func withoutSpansTheSamePassageIsTheSameQuote() async throws {
        // On the sample paper FakeQuoteMatcher does not find the Table 2 quote: page-only anchors, compared by quote.
        let paper = try makeSamplePaper()
        let mock = MockLLMProvider(script: EngineTest.script(.review, [MockResponse(text: try EngineTest.fixture("review_dupes.txt"))]))
        let comments = try await EngineTest.collect(EngineTest.engine([mock], paper: paper).review(paper: paper, existing: [], context: EngineTest.context()))
            .comments
        #expect(comments.count == 5)
        guard comments.count == 5 else { return }
        #expect(comments[0].anchor.confidence == .pageOnly)
        #expect(comments[1].similarTo == comments[0].id)
        #expect(comments[2].similarTo == nil)
    }

    @Test func existingCommentsCountAsEarlierOnesUnlessRejected() async throws {
        let paper = dupesPaper()
        let quote = "The coefficient in Table 2 is 0.91 with a confidence interval that crosses one"
        let matcher = FakeQuoteMatcher(paper: paper.text)
        let spans = try #require(matcher.locate(quote: quote, pageHint: 0)).spans
        func existing(_ title: String, status: CommentStatus, kind: CommentKind = .major) -> ReviewComment {
            ReviewComment(id: UUID(), origin: .user, status: status, kind: kind, category: "claims", title: title, body: "Earlier.",
                          anchor: Anchor(quote: quote, spans: spans, pageIndex: 0, confidence: .exact, locationLabel: "p. 1"), includeInReport: true,
                          createdAt: Date(), updatedAt: Date())
        }
        let kept = existing("The interval includes one, yet the effect is called robust", status: .approved)
        let rejected = existing("Missing definition of the interval", status: .rejected)
        let mock = MockLLMProvider(script: EngineTest.script(.review, [MockResponse(text: try EngineTest.fixture("review_dupes.txt"))]))
        let events = try await EngineTest.collect(EngineTest.engine([mock], paper: paper)
            .review(paper: paper, existing: [kept, rejected], context: EngineTest.context()))
        let comments = events.comments
        // The first block repeats an existing comment: dropped. The third repeats a rejected one: kept, and similar to the
        // existing approved comment.
        #expect(comments.first?.title == "Missing definition of the interval")
        #expect(comments.first?.similarTo == kept.id)
        #expect(!comments.contains { $0.title == kept.title })
        // The titles of existing non-rejected comments went into the task.
        let task = EngineTest.userText(of: try #require(mock.recordedRequests.first))
        #expect(task.contains("Comments already made, do not repeat them: The interval includes one, yet the effect is called robust"))
        #expect(!task.contains("Missing definition of the interval"))
    }

    // ---- strength cap ----

    @Test func atMostTwoStrengthCommentsAreKept() async throws {
        let paper = try makeSamplePaper()
        let text = (1...4).map { block(kind: "strength", quote: "passage \($0)", title: "Strength \($0)") }.joined()
            + block(kind: "major", quote: "another passage", title: "A major one") + "@@DONE\n"
        let mock = MockLLMProvider(script: EngineTest.script(.review, [MockResponse(text: text)]))
        let events = try await EngineTest.collect(EngineTest.engine([mock], paper: paper).review(paper: paper, existing: [], context: EngineTest.context()))
        #expect(events.comments.map(\.title) == ["Strength 1", "Strength 2", "A major one"])
        let notices = events.notices
        #expect(notices.count == 1)
        #expect(notices.first?.contains("“Strength 3”; “Strength 4”") == true)
        #expect(notices.first?.hasPrefix("2 further strength comments were left out") == true)
        // The notice comes at the end, just before .finished.
        if case .notice? = events.dropLast().last {} else { Issue.record("the notice should come last before .finished") }
    }

    // ---- failure mid-stream ----

    @Test func aFailureMidStreamKeepsTheCommentsAndFailsTheRun() async throws {
        let clean = try Fixtures.text("llm/review_clean.txt")
        let paper = try makeSamplePaper()
        let response = MockResponse(text: clean, chunkSize: 400, failAfterChunks: 3, failure: .overloaded(retryAfter: nil))
        let mock = MockLLMProvider(script: EngineTest.script(.review, [response]))
        let events = try await EngineTest.collect(EngineTest.engine([mock], paper: paper).review(paper: paper, existing: [], context: EngineTest.context()))

        // 1,200 characters: the first two blocks and part of the third, whose open block is closed as it stands.
        let received = String(clean.prefix(1_200))
        var expected = CommentStreamParser(mode: .review, categories: CategoryTable(rubric: DefaultSettings.make().rubric))
        let closedSoFar = (expected.feed(received) + expected.finish()).filter { if case .blockClosed = $0 { return true } else { return false } }
        #expect(events.comments.count == closedSoFar.count)
        #expect(events.comments.count >= 2)
        #expect(events.comments.prefix(2).map(\.title) == ["The interval includes one, yet the effect is called robust",
                                                           "Nothing shows that rollout timing is unrelated to outcomes"])
        #expect(events.finishedRun?.status == .failed(LLMError.overloaded(retryAfter: nil).userMessage))
        #expect(events.finishedRun?.requestCount == 1)
    }

    @Test func aToolUseFailureGivesTheRunItsOwnMessage() async throws {
        let paper = try makeSamplePaper()
        let response = MockResponse(text: try Fixtures.text("llm/review_clean.txt"), chunkSize: 100, failAfterChunks: 7, failure: .toolUseBlocked("Bash"))
        let mock = MockLLMProvider(script: EngineTest.script(.review, [response]))
        let events = try await EngineTest.collect(EngineTest.engine([mock], paper: paper).review(paper: paper, existing: [], context: EngineTest.context()))
        #expect(events.finishedRun?.status == .failed(LLMError.toolUseBlocked("Bash").userMessage))
        #expect(!events.comments.isEmpty)
    }

    @Test func aProviderThatFailsAtOnceFailsTheRun() async throws {
        let paper = try makeSamplePaper()
        let mock = MockLLMProvider(script: MockScript(responses: [:]))             // .notConfigured for every request
        let events = try await EngineTest.collect(EngineTest.engine([mock], paper: paper).review(paper: paper, existing: [], context: EngineTest.context()))
        guard case .failed(let message)? = events.finishedRun?.status else {
            Issue.record("expected a failed run, got \(String(describing: events.finishedRun))")
            return
        }
        #expect(message.hasPrefix("Provider is not set up"))
        #expect(events.comments.isEmpty)
    }

    // ---- PDF fallback ----

    @Test(arguments: [LLMError.contextTooLong("prompt is too long"), .invalidRequest("The PDF could not be processed")])
    func aRefusedPDFIsRetriedOnceAsText(_ refusal: LLMError) async throws {
        let paper = try makeSamplePaper()
        let answers = [MockResponse(text: "", failAfterChunks: 0, failure: refusal), MockResponse(text: try Fixtures.text("llm/review_clean.txt"))]
        let mock = MockLLMProvider(script: EngineTest.script(.review, answers), supportsNativePDF: true)
        let model = try #require(try await mock.listModels().first)
        #expect(model.supportsPDFInput == true)
        let context = EngineTest.context(model: model)
        let engine = EngineTest.engine([mock], paper: paper)
        #expect(await engine.plan(paper: paper, context: context).sendsPDF)

        let events = try await EngineTest.collect(engine.review(paper: paper, existing: [], context: context))
        let requests = mock.recordedRequests
        #expect(requests.count == 2)
        guard requests.count == 2 else { return }
        #expect(requests[0].parts.first == .pdf(data: paper.data, fileName: "manuscript.pdf"))
        #expect(requests[0].parts[1] == .cacheBoundary)
        #expect(!requests[1].parts.contains { if case .pdf = $0 { return true } else { return false } })
        #expect(EngineTest.userText(of: requests[1]).contains("[[page 1]]"))
        #expect(events.notices.filter { $0.contains("did not accept the PDF") }.count == 1)
        #expect(events.comments.count == 6)
        #expect(events.finishedRun?.status == .completed)
        #expect(events.finishedRun?.sentPDF == true)                // the file did go out once
        #expect(events.finishedRun?.requestCount == 2)
    }

    @Test func anUnrelatedInvalidRequestIsNotRetried() async throws {
        let paper = try makeSamplePaper()
        let answers = [MockResponse(text: "", failAfterChunks: 0, failure: .invalidRequest("temperature must be at most 1")),
                       MockResponse(text: try Fixtures.text("llm/review_clean.txt"))]
        let mock = MockLLMProvider(script: EngineTest.script(.review, answers), supportsNativePDF: true)
        let context = EngineTest.context(model: try await mock.listModels().first)
        let events = try await EngineTest.collect(EngineTest.engine([mock], paper: paper).review(paper: paper, existing: [], context: context))
        #expect(mock.recordedRequests.count == 1)
        #expect(events.finishedRun?.status == .failed(LLMError.invalidRequest("temperature must be at most 1").userMessage))
    }

    // ---- cancellation ----

    @Test(.timeLimit(.minutes(1))) func cancellingDuringStreamingEndsWithACancelledRunPromptly() async throws {
        let paper = try makeSamplePaper()
        let mock = MockLLMProvider(script: .stallsAfterTwoComments)
        let stream = EngineTest.engine([mock], paper: paper).review(paper: paper, existing: [], context: EngineTest.context())
        let box = EventBox<ReviewEvent>()
        let consumer = Task {
            do {
                for try await event in stream { box.add(event) }
            } catch {
                Issue.record("the review stream should not throw: \(error)")
            }
            box.end()
        }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(20)
        while box.snapshot.events.comments.count < 2, clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(box.snapshot.events.comments.count == 2)
        try await Task.sleep(for: .milliseconds(300))                // the consumer is waiting for the stalled model
        #expect(!box.snapshot.ended)
        let cancelledAt = clock.now
        consumer.cancel()
        await consumer.value
        #expect(clock.now - cancelledAt < .seconds(5))
        let events = box.snapshot.events
        #expect(events.finishedRun?.status == .cancelled)
        #expect(events.finishedRun?.requestCount == 1)
        #expect(events.comments.count == 2)                         // the open third draft is discarded
        #expect(box.snapshot.ended)
    }

    // ---- parser, fallbacks (through the engine, for the notice) ----

    @Test func aJSONAnswerGivesCommentsThroughTheJSONPath() async throws {
        let paper = try makeSamplePaper()
        let mock = MockLLMProvider(script: EngineTest.script(.review, [MockResponse(text: try EngineTest.fixture("review_json.txt"))]))
        let events = try await EngineTest.collect(EngineTest.engine([mock], paper: paper).review(paper: paper, existing: [], context: EngineTest.context()))
        var clean = CommentStreamParser(mode: .review, categories: CategoryTable(rubric: DefaultSettings.make().rubric))
        let expected = (clean.feed(try Fixtures.text("llm/review_clean.txt")) + clean.finish())
            .compactMap { if case .blockClosed(let draft) = $0 { return draft } else { return nil } }
        let comments = events.comments
        #expect(comments.count == 6)
        #expect(comments.map(\.title) == expected.map { $0.title ?? "" })
        #expect(comments.map(\.kind) == expected.map { $0.kind ?? .minor })
        #expect(comments.map(\.category) == expected.map { $0.category ?? "" })
        #expect(comments.map(\.anchor.quote) == expected.map { $0.quote ?? "" })
        #expect(comments.map(\.suggestion) == expected.map(\.suggestion))
        #expect(comments.map(\.body) == expected.map(\.body))
        #expect(comments.map(\.anchor.confidence) == [.pageOnly, .pageOnly, .exact, .pageOnly, .pageOnly, .exact])
        #expect(events.notices.isEmpty)
    }

    @Test func proseGivesOneUnstructuredCommentAndANotice() async throws {
        let paper = try makeSamplePaper()
        let prose = try EngineTest.fixture("review_prose.txt")
        let mock = MockLLMProvider(script: EngineTest.script(.review, [MockResponse(text: prose)]))
        let events = try await EngineTest.collect(EngineTest.engine([mock], paper: paper).review(paper: paper, existing: [], context: EngineTest.context()))
        let comments = events.comments
        #expect(comments.count == 1)
        #expect(comments.first?.title == "Unstructured model output")
        #expect(comments.first?.kind == .minor)
        #expect(comments.first?.category == "other")
        #expect(comments.first?.body == prose.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(comments.first?.anchor.confidence == AnchorConfidence.none)
        #expect(events.notices == ["The model ignored the output format; its answer is shown as a single comment."])
        #expect(events.finishedRun?.status == .completed)
    }

    @Test func otherJSONShapesAreReadToo() {
        let categories = CategoryTable(rubric: DefaultSettings.make().rubric)
        let wrapped = #"{"comments": [{"Type": "Major", "Title": "Wrapped", "Comment": "In an object.", "Pages": [3, 4], "Fix": "N/A"}]}"#
        let single = "Some words first.\n```\n{\"severity\": \"critical\", \"title\": \"Alone\", \"body\": \"One object.\", \"category\": \"Math\"}\n```"
        let drafts = ParserFallbacks.jsonComments(in: wrapped, categories: categories)
        #expect(drafts.map(\.title) == ["Wrapped"])
        #expect(drafts.first?.kind == .major)
        #expect(drafts.first?.page == 3)
        #expect(drafts.first?.body == "In an object.")
        #expect(drafts.first?.suggestion == nil)
        let alone = ParserFallbacks.jsonComments(in: single, categories: categories)
        #expect(alone.map(\.title) == ["Alone"])
        #expect(alone.first?.kind == .major)
        #expect(alone.first?.category == "math")
        #expect(ParserFallbacks.jsonComments(in: "[1, 2, 3] and {\"no\": \"comment\"}", categories: categories).isEmpty)
        #expect(ParserFallbacks.jsonComments(in: "[{\"title\": \"broken\",]", categories: categories).isEmpty)
    }

    @Test func garbageThroughTheEngineEndsWithABoundedComment() async throws {
        let paper = try makeSamplePaper()
        var generator = SplitMix64(seed: 42)
        let bytes = (0..<300_000).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
        let garbage = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "@@", with: "")
        let mock = MockLLMProvider(script: EngineTest.script(.review, [MockResponse(text: garbage, chunkSize: 4_096)]))
        let events = try await EngineTest.collect(EngineTest.engine([mock], paper: paper).review(paper: paper, existing: [], context: EngineTest.context()))
        #expect(events.finishedRun?.status == .completed)
        #expect(events.comments.allSatisfy { $0.body.count <= ParserFallbacks.unstructuredBodyLength })
    }

    @Test func anEmptyAnswerSaysSoAndADoneOnlyAnswerDoesNot() async throws {
        let paper = try makeSamplePaper()
        let empty = MockLLMProvider(script: EngineTest.script(.review, [MockResponse(text: "  \n")]))
        let events = try await EngineTest.collect(EngineTest.engine([empty], paper: paper).review(paper: paper, existing: [], context: EngineTest.context()))
        #expect(events.notices == ["The model returned an empty answer."])
        #expect(events.comments.isEmpty)
        #expect(events.finishedRun?.status == .completed)

        // "If you have nothing to add, write only @@DONE": no comment, no notice, no fallback.
        let done = MockLLMProvider(script: EngineTest.script(.review, [MockResponse(text: "@@DONE\n")]))
        let quiet = try await EngineTest.collect(EngineTest.engine([done], paper: paper).review(paper: paper, existing: [], context: EngineTest.context()))
        #expect(quiet.notices.isEmpty)
        #expect(quiet.comments.isEmpty)
    }

    @Test func anUnknownProviderFailsTheRunWithoutARequest() async throws {
        let paper = try makeSamplePaper()
        let events = try await EngineTest.collect(EngineTest.engine([], paper: paper).review(paper: paper, existing: [], context: EngineTest.context(provider: "gone")))
        #expect(events.count == 2)
        #expect(events.finishedRun?.status == .failed(LLMError.notConfigured("no provider with the id gone is registered").userMessage))
        #expect(events.finishedRun?.destination == "")
    }
}
