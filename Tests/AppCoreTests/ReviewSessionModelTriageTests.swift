import Foundation
import Testing
import RefereeCore
@testable import AppCore
import TestSupport

/// Acceptance rows "triage", "ordering", "editing and revisions" and "own comments" (plan.md section 11.4, WP8b;
/// Appendix A.9; sections 6.8, 9.3, 9.4).
@Suite struct ReviewSessionModelTriageTests {
    static let paper = SyntheticPaper.twoPages

    /// A comment on line `line` of page `page` of the two-page paper.
    static func on(_ title: String, page: Int, line: Int, offset: Int = 0, created: TimeInterval, kind: CommentKind = .minor,
                   status: CommentStatus = .pending) -> ReviewComment {
        ModelSample.comment(title, page: page, range: SyntheticPaper.span(paper, page: page, line: line, offset: offset), kind: kind,
                            status: status, created: created)
    }

    @MainActor static func harness(_ comments: [ReviewComment], settings: AppSettings = ModelSample.settings(),
                                   engine: ScriptedReviewEngine = ScriptedReviewEngine(plan: ModelSample.localPlan)) async throws -> ModelHarness {
        let harness = try await makeModelHarness(paper: paper, settings: settings, engine: engine, seed: ModelSample.session(for: paper, comments: comments))
        await harness.open()
        return harness
    }

    // ---- ordering ----

    @Test @MainActor func visibleCommentsFollowTheOneOrderingRule() async throws {
        let secondPage = Self.on("Page 2, line 2", page: 1, line: 1, created: 1)
        let lineSix = Self.on("Page 1, line 6", page: 0, line: 5, created: 2)
        let pageOnly = ModelSample.comment("Page 1, no passage", page: 0, quote: "A sentence that is not in the paper at all.", created: 3)
        let unanchored = ModelSample.comment("No page", page: nil, quote: "Nor is this one, anywhere.", created: 0)
        let lineThreeLater = Self.on("Page 1, line 3, written later", page: 0, line: 2, offset: 0, created: 5)
        let lineThreeEarlier = Self.on("Page 1, line 3, written earlier", page: 0, line: 2, offset: 30, created: 4)
        let unanchoredLater = ModelSample.comment("No page either", page: nil, created: 6)
        let harness = try await Self.harness([secondPage, lineSix, pageOnly, unanchored, lineThreeLater, lineThreeEarlier, unanchoredLater])
        #expect(harness.model.visibleComments.map(\.title) == [
            "Page 1, no passage",                // page only: first on its page
            "Page 1, line 3, written earlier",   // two on one line: by creation time, not by position in the line
            "Page 1, line 3, written later",
            "Page 1, line 6",
            "Page 2, line 2",
            "No page",                           // no page: last, by creation time
            "No page either",
        ])
        // Stored in creation order; only the display is ordered.
        #expect(harness.model.session?.comments.first?.title == "Page 2, line 2")
    }

    @Test @MainActor func theFilterComesBeforeTheOrder() async throws {
        let major = Self.on("Major", page: 0, line: 4, created: 1, kind: .major)
        let approved = Self.on("Approved", page: 0, line: 1, created: 2, status: .approved)
        let rejected = Self.on("Rejected", page: 1, line: 0, created: 3, kind: .question, status: .rejected)
        let pending = Self.on("Pending", page: 0, line: 0, created: 4)
        let harness = try await Self.harness([major, approved, rejected, pending])
        let model = harness.model
        #expect(model.visibleComments.map(\.title) == ["Pending", "Approved", "Major", "Rejected"])
        model.filter = .pending
        #expect(model.visibleComments.map(\.title) == ["Pending", "Major"])
        model.filter = .approved
        #expect(model.visibleComments.map(\.title) == ["Approved"])
        model.filter = .rejected
        #expect(model.visibleComments.map(\.title) == ["Rejected"])
        model.filter = .kind(.major)
        #expect(model.visibleComments.map(\.title) == ["Major"])
        model.filter = .kind(.strength)
        #expect(model.visibleComments.isEmpty)
    }

    // ---- triage ----

    @Test @MainActor func approveRejectAndResetChangeTheStatusAndTheCounts() async throws {
        let first = Self.on("First", page: 0, line: 0, created: 1)
        var second = Self.on("Second", page: 0, line: 1, created: 2)
        second.includeInReport = false
        let third = Self.on("Third", page: 0, line: 2, created: 3)
        let harness = try await Self.harness([first, second, third], settings: ModelSample.settings { $0.ui.autoAdvanceAfterTriage = false })
        let model = harness.model
        #expect(model.triage == (decided: 0, total: 3))
        model.setStatus(.approved, for: second.id)
        #expect(model.session?.comments[1].status == .approved)
        #expect(model.session?.comments[1].includeInReport == true)      // approving includes it in the report
        #expect(model.triage == (decided: 1, total: 3))
        model.setStatus(.rejected, for: first.id)
        #expect(model.session?.comments[0].status == .rejected)
        #expect(model.triage == (decided: 2, total: 3))
        model.setStatus(.pending, for: second.id)
        #expect(model.session?.comments[1].status == .pending)
        #expect(model.triage == (decided: 1, total: 3))
        #expect(model.selectedCommentID == nil)                          // "advance after decision" is off
        #expect(model.session?.comments[1].updatedAt == harness.clock.now())
    }

    @Test @MainActor func afterADecisionTheNextPendingCommentInVisibleOrderIsSelected() async throws {
        // Stored order differs from visible order: C (line 8), A (line 1), B (line 4), D (line 9, already approved), E (page 2).
        let c = Self.on("C", page: 0, line: 7, created: 1)
        let a = Self.on("A", page: 0, line: 0, created: 2)
        let b = Self.on("B", page: 0, line: 3, created: 3)
        let d = Self.on("D", page: 0, line: 8, created: 4, status: .approved)
        let e = Self.on("E", page: 1, line: 0, created: 5)
        let harness = try await Self.harness([c, a, b, d, e])
        let model = harness.model
        #expect(model.visibleComments.map(\.title) == ["A", "B", "C", "D", "E"])
        model.selectedCommentID = a.id
        model.setStatus(.approved, for: a.id)
        #expect(model.selectedCommentID == b.id)
        if case .reveal(let rects, let flash)? = model.readerCommand?.command {
            #expect(rects == model.session?.comments.first { $0.id == b.id }?.anchor.rects)
            #expect(flash)
        } else {
            Issue.record("the next comment was not revealed")
        }
        model.setStatus(.rejected, for: b.id)
        #expect(model.selectedCommentID == c.id)
        model.setStatus(.approved, for: c.id)
        #expect(model.selectedCommentID == e.id)                         // D is decided: skipped
        model.setStatus(.pending, for: a.id)                             // back to pending: no advance
        #expect(model.selectedCommentID == e.id)
        model.setStatus(.approved, for: e.id)
        #expect(model.selectedCommentID == a.id)                         // wraps round to the first pending one
        model.setStatus(.approved, for: a.id)
        #expect(model.selectedCommentID == a.id)                         // nothing pending is left: the selection stays
        #expect(model.triage == (decided: 5, total: 5))
    }

    @Test @MainActor func withTheFilterOnPendingTheNextPendingIsStillFound() async throws {
        let a = Self.on("A", page: 0, line: 0, created: 1)
        let b = Self.on("B", page: 0, line: 1, created: 2)
        let harness = try await Self.harness([a, b])
        harness.model.filter = .pending
        harness.model.selectedCommentID = a.id
        harness.model.setStatus(.approved, for: a.id)
        #expect(harness.model.visibleComments.map(\.title) == ["B"])
        #expect(harness.model.selectedCommentID == b.id)
    }

    @Test @MainActor func nextAndPreviousWalkTheVisibleList() async throws {
        let a = Self.on("A", page: 0, line: 0, created: 3)
        let b = Self.on("B", page: 0, line: 1, created: 2, status: .approved)
        let c = Self.on("C", page: 1, line: 0, created: 1)
        let harness = try await Self.harness([a, b, c])
        let model = harness.model
        model.selectNextComment(pendingOnly: false)
        #expect(model.selectedCommentID == a.id)                         // nothing selected: the first
        let serial = model.readerCommand?.serial ?? 0
        model.selectNextComment(pendingOnly: false)
        #expect(model.selectedCommentID == b.id)
        #expect((model.readerCommand?.serial ?? 0) > serial)            // J also scrolls the PDF
        model.selectNextComment(pendingOnly: false)
        #expect(model.selectedCommentID == c.id)
        model.selectNextComment(pendingOnly: false)
        #expect(model.selectedCommentID == c.id)                         // the end: stays
        model.selectPreviousComment()
        #expect(model.selectedCommentID == b.id)
        model.selectPreviousComment()
        model.selectPreviousComment()
        #expect(model.selectedCommentID == a.id)                         // the start: stays
        model.selectNextComment(pendingOnly: true)
        #expect(model.selectedCommentID == c.id)                         // B is approved: skipped
        model.selectNextComment(pendingOnly: true)
        #expect(model.selectedCommentID == a.id)                         // pending only wraps round
        model.selectedCommentID = nil
        model.selectPreviousComment()
        #expect(model.selectedCommentID == c.id)                         // nothing selected: the last
    }

    @Test @MainActor func revealingUsesTheRectanglesOrThePage() async throws {
        let anchored = Self.on("Anchored", page: 1, line: 2, created: 1)
        let pageOnly = ModelSample.comment("Page only", page: 1, quote: "Not a sentence of this paper.", created: 2)
        let unanchored = ModelSample.comment("Nowhere", page: nil, created: 3)
        let harness = try await Self.harness([anchored, pageOnly, unanchored])
        let model = harness.model
        model.selectedCommentID = anchored.id
        model.revealSelectedCommentInPDF()
        let rects = try #require(model.session?.comments.first?.anchor.rects)
        #expect(rects.count == 1)                                        // filled on open from the spans
        #expect(model.readerCommand?.command == .reveal(rects: rects, flash: true))
        let serial = model.readerCommand?.serial
        model.selectedCommentID = pageOnly.id
        model.revealSelectedCommentInPDF()
        #expect(model.readerCommand?.command == .goToPage(1))
        #expect(model.readerCommand?.serial != serial)
        model.selectedCommentID = unanchored.id
        let before = model.readerCommand?.serial
        model.revealSelectedCommentInPDF()
        #expect(model.readerCommand?.serial == before)                   // nothing to show
    }

    @Test @MainActor func clickingAHighlightSelectsItsCard() async throws {
        let comment = Self.on("Clicked", page: 0, line: 0, created: 1)
        let conversation = Conversation(id: UUID(), anchor: nil, createdAt: ModelSample.start)
        let paper = Self.paper
        var seed = ModelSample.session(for: paper, comments: [comment])
        seed.conversations = [conversation]
        let harness = try await makeModelHarness(paper: paper, seed: seed)
        await harness.open()
        harness.model.sidebarTab = .report
        harness.model.readerClickedComment(comment.id)
        #expect(harness.model.selectedCommentID == comment.id)
        #expect(harness.model.sidebarTab == .comments)
        harness.model.readerClickedComment(conversation.id)
        #expect(harness.model.sidebarTab == .chat)
    }

    @Test @MainActor func kindInclusionAndDeletion() async throws {
        let a = Self.on("A", page: 0, line: 0, created: 1)
        var b = Self.on("B", page: 0, line: 1, created: 2)
        b.similarTo = a.id
        let harness = try await Self.harness([a, b])
        let model = harness.model
        model.setKind(.question, for: a.id)
        #expect(model.session?.comments[0].kind == .question)
        #expect(model.session?.comments[0].previousVersions.isEmpty == true)
        model.setIncludeInReport(false, for: a.id)
        #expect(model.session?.comments[0].includeInReport == false)
        model.selectedCommentID = a.id
        model.editingCommentID = a.id
        model.openThreadCommentID = a.id
        model.deleteComment(a.id)
        #expect(model.session?.comments.map(\.title) == ["B"])
        #expect(model.session?.comments[0].similarTo == nil)
        #expect(model.selectedCommentID == nil)
        #expect(model.editingCommentID == nil)
        #expect(model.openThreadCommentID == nil)
    }

    // ---- editing and revisions ----

    @Test @MainActor func anEditPushesTheOldVersion() async throws {
        let comment = Self.on("Original title", page: 0, line: 0, created: 1, kind: .major)
        let harness = try await Self.harness([comment])
        let model = harness.model
        model.editingCommentID = comment.id
        model.editComment(comment.id, kind: .minor, category: "writing", title: "New title", body: "New body", suggestion: "Do this.")
        let edited = try #require(model.session?.comments.first)
        #expect(edited.kind == .minor)
        #expect(edited.category == "writing")
        #expect(edited.title == "New title")
        #expect(edited.body == "New body")
        #expect(edited.suggestion == "Do this.")
        #expect(edited.anchor.spans == comment.anchor.spans)
        #expect(edited.previousVersions == [CommentRevision(kind: .major, title: "Original title", body: comment.body, suggestion: nil, withdraw: false)])
        #expect(model.editingCommentID == nil)
        model.editComment(comment.id, kind: .minor, category: "writing", title: "New title", body: "New body", suggestion: "Do this.")
        #expect(model.session?.comments.first?.previousVersions.count == 1)   // nothing changed: nothing pushed

        // At most twenty versions are kept.
        for number in 1...25 {
            model.editComment(comment.id, kind: .minor, category: "writing", title: "Title \(number)", body: "New body", suggestion: nil)
        }
        let history = try #require(model.session?.comments.first?.previousVersions)
        #expect(history.count == 20)
        #expect(history.last?.title == "Title 24")
        #expect(model.session?.comments.first?.suggestion == nil)
    }

    @Test @MainActor func acceptingARevisionAppliesItAndClearsTheProposal() async throws {
        var comment = Self.on("Too strong", page: 0, line: 0, created: 1, kind: .major, status: .approved)
        comment.suggestion = "Old suggestion"
        comment.proposedRevision = CommentRevision(kind: .minor, title: "Milder", body: "A milder body.", suggestion: "New suggestion", withdraw: false)
        var withdrawn = Self.on("Wrong", page: 0, line: 1, created: 2)
        withdrawn.proposedRevision = CommentRevision(kind: .minor, title: "", body: "", withdraw: true)
        var discarded = Self.on("Kept as is", page: 0, line: 2, created: 3)
        discarded.proposedRevision = CommentRevision(kind: .question, title: "Other", body: "Other body.", withdraw: false)
        let harness = try await Self.harness([comment, withdrawn, discarded])
        let model = harness.model

        model.acceptProposedRevision(commentID: comment.id)
        let revised = try #require(model.session?.comments[0])
        #expect(revised.kind == .minor)
        #expect(revised.title == "Milder")
        #expect(revised.body == "A milder body.")
        #expect(revised.suggestion == "New suggestion")
        #expect(revised.status == .approved)                             // status kept
        #expect(revised.anchor.spans == comment.anchor.spans)            // anchor kept
        #expect(revised.proposedRevision == nil)
        #expect(revised.previousVersions == [CommentRevision(kind: .major, title: "Too strong", body: comment.body, suggestion: "Old suggestion",
                                                             withdraw: false)])

        model.acceptProposedRevision(commentID: withdrawn.id)
        #expect(model.session?.comments[1].status == .rejected)
        #expect(model.session?.comments[1].title == "Wrong")
        #expect(model.session?.comments[1].proposedRevision == nil)

        model.discardProposedRevision(commentID: discarded.id)
        #expect(model.session?.comments[2].proposedRevision == nil)
        #expect(model.session?.comments[2].title == "Kept as is")
        #expect(model.session?.comments[2].previousVersions.isEmpty == true)
    }

    @Test @MainActor func aDiscussionReplyCanProposeARevision() async throws {
        let comment = Self.on("Discussed", page: 0, line: 0, created: 1)
        let proposal = CommentRevision(kind: .minor, title: "Revised", body: "Revised body.", withdraw: false)
        let reply = ThreadMessage(id: UUID(), role: .assistant, text: "You are right.", createdAt: ModelSample.start)
        let engine = ScriptedReviewEngine(plan: ModelSample.localPlan, reply: [.started(ModelSample.run(.discussion, .running)), .textDelta("You are right."),
                                                                               .finished(reply: reply, proposal: proposal, run: ModelSample.run(.discussion, .completed))])
        let harness = try await Self.harness([comment], engine: engine)
        harness.model.sendDiscussionMessage("  Is this too strong?  ", commentID: comment.id)
        await harness.finishJobs()
        let discussed = try #require(harness.model.session?.comments.first)
        #expect(discussed.thread.map(\.role) == [.user, .assistant])
        #expect(discussed.thread.map(\.text) == ["Is this too strong?", "You are right."])
        #expect(discussed.thread.last?.provider == ProviderRef(providerID: "mock", model: "mock"))
        #expect(discussed.proposedRevision == proposal)
        #expect(discussed.title == "Discussed")                          // a proposal never changes the comment by itself
        #expect(harness.model.session?.runs.last?.kind == .discussion)
        harness.model.sendDiscussionMessage("   ", commentID: comment.id)   // nothing to send
        await harness.finishJobs()
        #expect(harness.calls(of: "discuss") == 1)
    }

    @Test @MainActor func aFailedReplyKeepsTheMessageAndRetrySendsItOnce() async throws {
        let comment = Self.on("Discussed", page: 0, line: 0, created: 1)
        let reply = ThreadMessage(id: UUID(), role: .assistant, text: "", createdAt: ModelSample.start)
        let engine = ScriptedReviewEngine(plan: ModelSample.localPlan, reply: [.started(ModelSample.run(.discussion, .running)),
                                                                               .finished(reply: reply, proposal: nil, run: ModelSample.run(.discussion, .failed("Rate limited: slow down")))])
        let harness = try await Self.harness([comment], engine: engine)
        harness.model.sendDiscussionMessage("Why?", commentID: comment.id)
        await harness.finishJobs()
        #expect(harness.model.banner?.message == "Reply stopped: Rate limited: slow down")
        #expect(harness.model.banner?.action == .retry)
        #expect(harness.model.session?.comments.first?.thread.map(\.text) == ["Why?"])
        harness.model.retryLastFailedJob()
        await harness.finishJobs()
        #expect(harness.calls(of: "discuss") == 2)
        #expect(harness.model.session?.comments.first?.thread.map(\.text) == ["Why?"])   // the message is not sent into the thread twice
        let sent = try #require(harness.lastContext(of: "discuss"))
        #expect(sent.provider.providerID == "mock")
    }

    // ---- own comments ----

    @Test @MainActor func anOwnCommentWithASelectionIsAnchoredToTheNormalisedText() async throws {
        let paper = SyntheticPaper.lineNumbered
        let harness = try await makeModelHarness(paper: paper)
        await harness.open()
        let model = harness.model
        model.readerSelectionChanged(SelectionNormalizerTests.twoLineRawSelection)
        await model.waitForBackgroundWork()
        let selection = try #require(model.selection)
        model.sidebarTab = .chat
        model.beginComposingComment()
        #expect(model.composing?.selection == selection)
        #expect(model.sidebarTab == .comments)
        model.addUserComment(kind: .minor, category: "other", title: "My point", body: "My body", anchoredTo: model.composing?.selection)
        #expect(model.composing == nil)
        let own = try #require(model.session?.comments.last)
        #expect(own.origin == .user)
        #expect(own.status == .approved)
        #expect(own.includeInReport)
        #expect(own.anchor.quote == "As shown by Acemoglu et al. [2011], network structure determines wheth")
        #expect(own.anchor.spans == selection.spans)
        #expect(own.anchor.rects == selection.rects)
        #expect(own.anchor.confidence == .exact)
        #expect(own.anchor.pageIndex == 0)
        #expect(own.anchor.locationLabel == "p. 1")

        // Given the raw selection instead, the anchor is the same, and its rectangles follow.
        model.addUserComment(kind: .major, category: "claims", title: "Raw", body: "Raw body", anchoredTo: SelectionNormalizerTests.twoLineRawSelection)
        await model.waitForBackgroundWork()
        let fromRaw = try #require(model.session?.comments.last)
        #expect(fromRaw.anchor.quote == own.anchor.quote)
        #expect(fromRaw.anchor.spans == own.anchor.spans)
        #expect(fromRaw.anchor.rects.count == 2)
    }

    @Test @MainActor func anOwnCommentWithoutASelectionHasNoPassage() async throws {
        let harness = try await makeModelHarness(paper: SyntheticPaper.lineNumbered)
        await harness.open()
        harness.model.beginComposingComment()
        #expect(harness.model.composing == ComposingComment(selection: nil))
        harness.model.cancelComposing()
        #expect(harness.model.composing == nil)
        harness.model.beginComposingComment()
        harness.model.addUserComment(kind: .question, category: "other", title: "General", body: "About the whole paper.", anchoredTo: nil)
        let own = try #require(harness.model.session?.comments.last)
        #expect(own.anchor.quote == "")
        #expect(own.anchor.spans.isEmpty)
        #expect(own.anchor.confidence == AnchorConfidence.none)
        #expect(own.anchor.pageIndex == nil)
        #expect(own.kind == .question)
        #expect(harness.model.composing == nil)
    }

    @Test @MainActor func reanchoringAttachesAnUnanchoredCommentToTheSelection() async throws {
        let paper = SyntheticPaper.lineNumbered
        let lost = ModelSample.comment("Passage not found", page: nil, quote: "Something the model invented.")
        let harness = try await makeModelHarness(paper: paper, seed: ModelSample.session(for: paper, comments: [lost]))
        await harness.open()
        #expect(harness.model.session?.comments.first?.anchor.confidence == AnchorConfidence.none)
        harness.model.reanchorComment(lost.id, to: SelectionNormalizerTests.twoLineRawSelection)
        await harness.model.waitForBackgroundWork()
        let anchor = try #require(harness.model.session?.comments.first?.anchor)
        #expect(anchor.quote == "As shown by Acemoglu et al. [2011], network structure determines wheth")
        #expect(anchor.confidence == .exact)
        #expect(anchor.spans.count == 2)
        #expect(anchor.rects.count == 2)
        #expect(anchor.locationLabel == "p. 1")
        #expect(harness.model.session?.comments.first?.title == "Passage not found")
        // A selection that normalises to nothing changes nothing.
        harness.model.reanchorComment(lost.id, to: SelectionInfo(text: "CONFIDENTIAL", spans: [SyntheticPaper.rawSpan(paper, page: 0, line: 3)]))
        #expect(harness.model.session?.comments.first?.anchor == anchor)
    }

    @Test @MainActor func escapeClosesOneThingAtATime() async throws {
        let paper = SyntheticPaper.lineNumbered
        let comment = ModelSample.comment("Card", page: nil)
        let index = CitationIndex(style: .authorYear, entries: [BibEntry(id: 0, rawText: "Lee (2021).", parsed: ParsedReference())],
                                  mentions: [CitationMention(id: 0, pageIndex: 0, text: "Lee [2021]", entryIDs: [0], source: .textPattern)])
        let harness = try await makeModelHarness(paper: paper, index: index, seed: ModelSample.session(for: paper, comments: [comment]))
        await harness.open()
        let model = harness.model
        model.readerSelectionChanged(SelectionNormalizerTests.twoLineRawSelection)
        model.openThreadCommentID = comment.id
        model.editingCommentID = comment.id
        model.beginComposingComment()
        model.lookUpCitation(mentionID: 0)
        model.dismissTransientUI()
        #expect(model.citationLookup == .idle)
        #expect(model.composing != nil)
        model.dismissTransientUI()
        #expect(model.composing == nil)
        #expect(model.editingCommentID == comment.id)
        model.dismissTransientUI()
        #expect(model.editingCommentID == nil)
        #expect(model.openThreadCommentID == comment.id)
        model.dismissTransientUI()
        #expect(model.openThreadCommentID == nil)
        #expect(model.selection != nil)
        model.dismissTransientUI()
        #expect(model.selection == nil)
        #expect(model.readerCommand?.command == .clearSelection)
        await model.waitForBackgroundWork()
        #expect(model.citationLookup == .idle)                            // a lookup that was dismissed does not come back
        #expect(model.selection == nil)
    }
}
