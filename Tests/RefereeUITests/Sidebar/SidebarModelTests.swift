import Foundation
import Testing
import RefereeCore
import AppCore
import TestSupport
@testable import RefereeUI

/// The card states as a real `ReviewSessionModel` drives them (on the fakes of TestSupport): what the buttons and
/// keys of sections 9.3 and 9.4 change in the model shows on the right card.
@Suite struct SidebarModelTests {
    typealias Sample = SidebarTestData

    @Test @MainActor func selectionEditingAndTheThreadReachTheCards() async throws {
        let first = Sample.comment(title: "First")
        let second = Sample.comment(title: "Second", createdAt: Sample.created.addingTimeInterval(1))
        let harness = try await SidebarTestHarness.open(comments: [first, second])
        let model = harness.model
        model.selectedCommentID = first.id
        model.openThreadCommentID = first.id
        model.editingCommentID = second.id
        let one = try #require(harness.state(of: first.id))
        let two = try #require(harness.state(of: second.id))
        #expect(one.isSelected && one.isThreadOpen && !one.isEditing)
        #expect(!two.isSelected && !two.isThreadOpen && two.isEditing)
        model.dismissTransientUI()                       // Esc closes the editor first (section 9.4)
        #expect(harness.state(of: second.id)?.isEditing == false)
    }

    @Test @MainActor func approvingTurnsTheButtonsIntoUndoAndUndoBringsThemBack() async throws {
        let comment = Sample.comment()
        let harness = try await SidebarTestHarness.open(comments: [comment])
        harness.model.selectedCommentID = comment.id                         // the selected card is the one in full (D1)
        harness.model.setStatus(.approved, for: comment.id)
        #expect(harness.state(of: comment.id)?.actions == [.undo, .discuss, .edit])
        #expect(harness.state(of: comment.id)?.bar == .approved)
        harness.model.setStatus(.rejected, for: comment.id)
        #expect(harness.state(of: comment.id)?.layout == .collapsedRejected)
        harness.model.setStatus(.pending, for: comment.id)
        #expect(harness.state(of: comment.id)?.actions == [.approve, .reject, .discuss, .edit])
    }

    @Test @MainActor func aSimilarCommentExpandsWhenSelectedAndWhenTheOtherIsDeleted() async throws {
        let other = Sample.comment(title: "The estimate cannot be told apart from no effect")
        let similar = Sample.comment(title: "The interval includes one", similarTo: other.id, createdAt: Sample.created.addingTimeInterval(1))
        let harness = try await SidebarTestHarness.open(comments: [other, similar])
        #expect(harness.state(of: similar.id)?.layout == .collapsedSimilar)
        #expect(harness.state(of: similar.id)?.similarToTitle == other.title)
        harness.model.selectedCommentID = similar.id
        #expect(harness.state(of: similar.id)?.layout == .full)
        harness.model.selectedCommentID = nil
        harness.model.deleteComment(other.id)
        #expect(harness.state(of: similar.id)?.layout == .compact)              // no longer folded; compact, as unselected (D1)
    }

    /// J and K move the full card with the selection; the card left behind is compact again (D1).
    @Test @MainActor func theFullCardFollowsTheSelection() async throws {
        let first = Sample.comment(title: "First")
        let second = Sample.comment(title: "Second", createdAt: Sample.created.addingTimeInterval(1))
        let harness = try await SidebarTestHarness.open(comments: [first, second])
        let model = harness.model
        model.selectNextComment(pendingOnly: false)
        #expect(harness.state(of: first.id)?.layout == .full)
        #expect(harness.state(of: second.id)?.layout == .compact)
        model.selectNextComment(pendingOnly: false)
        #expect(harness.state(of: first.id)?.layout == .compact)
        #expect(harness.state(of: second.id)?.layout == .full)
        #expect(harness.state(of: second.id)?.actions == [.approve, .reject, .discuss, .edit])
    }

    // ---- D10: an answer turned into a comment opens in the editor ----

    @Test func theNewCommentIsTheOneIDThatWasNotThereBefore() {
        let old = [UUID(), UUID()]
        let new = UUID()
        #expect(SidebarChatActions.newCommentID(before: old, after: old + [new]) == new)
        #expect(SidebarChatActions.newCommentID(before: old, after: old) == nil)
        #expect(SidebarChatActions.newCommentID(before: [], after: []) == nil)
    }

    @Test @MainActor func addingAnAnswerAsACommentOpensItInTheEditorOnTheCommentsTab() async throws {
        let answer = ThreadMessage(id: UUID(), role: .assistant, text: "The interval in Table 2 crosses one, so the claim is too strong.",
                                   createdAt: Sample.created, provider: ProviderRef(providerID: "mock", model: "mock"))
        let conversation = Conversation(id: UUID(), anchor: Sample.exact, messages: [answer], createdAt: Sample.created)
        let existing = Sample.comment(title: "Existing")
        let harness = try await SidebarTestHarness.open(comments: [existing], conversations: [conversation])
        let model = harness.model
        model.sidebarTab = .chat

        SidebarChatActions.addAsComment(model: model, conversationID: conversation.id, messageID: answer.id, kind: .question)

        let made = try #require(model.session?.comments.first { $0.id != existing.id })
        #expect(made.kind == .question)
        #expect(made.origin == .user)
        #expect(model.selectedCommentID == made.id)
        #expect(model.editingCommentID == made.id)
        #expect(model.sidebarTab == .comments)
        #expect(harness.state(of: made.id)?.isEditing == true)
    }

    @Test @MainActor func anEmptyAnswerMakesNoCommentAndOpensNothing() async throws {
        let empty = ThreadMessage(id: UUID(), role: .assistant, text: "  ", createdAt: Sample.created)
        let conversation = Conversation(id: UUID(), messages: [empty], createdAt: Sample.created)
        let harness = try await SidebarTestHarness.open(comments: [], conversations: [conversation])
        let model = harness.model
        model.sidebarTab = .chat
        SidebarChatActions.addAsComment(model: model, conversationID: conversation.id, messageID: empty.id, kind: .major)
        #expect(model.session?.comments.isEmpty == true)
        #expect(model.editingCommentID == nil)
        #expect(model.sidebarTab == .chat)
    }

    // ---- step 5b: who wrote each comment ----

    /// The cards name their run's provider and model; a provider switched off since is still named; the referee's own
    /// comments name none.
    @Test @MainActor func theCardsNameTheProviderAndModelOfTheirRun() async throws {
        let mockRun = Sample.run("mock", model: "mock")
        let claudeRun = Sample.run("claude-cli", model: "sonnet")
        let byMock = Sample.comment(origin: .ai(runID: mockRun.id), title: "By the mock")
        let byClaude = Sample.comment(origin: .ai(runID: claudeRun.id), title: "By Claude Code", createdAt: Sample.created.addingTimeInterval(1))
        let own = Sample.comment(origin: .user, title: "Mine", createdAt: Sample.created.addingTimeInterval(2))
        let harness = try await SidebarTestHarness.open(comments: [byMock, byClaude, own], runs: [mockRun, claudeRun])
        #expect(harness.state(of: byMock.id)?.source?.text == "Mock · mock")
        #expect(harness.state(of: byClaude.id)?.source?.text == "Claude Code · sonnet")       // no cached list here: the id
        #expect(harness.state(of: byClaude.id)?.source?.help == "Written by claude-cli, model sonnet")
        #expect(harness.state(of: own.id)?.source == nil)
        // The window's names: the enabled mock has its descriptor, nothing runs.
        let names = SidebarSourceNames(model: harness.model)
        #expect(names.descriptors.contains { $0.id == "mock" })
        #expect(names.running == nil)
    }

    @Test @MainActor func aFailedReplyShowsUnderItsCommentOnlyAndRetryClearsIt() async throws {
        let run = RunRecord(id: UUID(), kind: .discussion, provider: ProviderRef(providerID: "mock", model: "mock"), destination: "this Mac",
                            sentPDF: false, requestCount: 1, startedAt: Sample.created, status: .running)
        var failed = run
        failed.status = .failed("The provider is overloaded.")
        failed.finishedAt = Sample.created
        let engine = ScriptedReviewEngine(plan: SidebarTestData.plan, reply: [
            .started(run),
            .finished(reply: ThreadMessage(id: UUID(), role: .assistant, text: "", createdAt: Sample.created), proposal: nil, run: failed),
        ])
        let discussed = Sample.comment(title: "Discussed")
        let quiet = Sample.comment(title: "Quiet", createdAt: Sample.created.addingTimeInterval(1))
        let harness = try await SidebarTestHarness.open(comments: [discussed, quiet], engine: engine)
        let model = harness.model

        model.sendDiscussionMessage("Is the comment still fair?", commentID: discussed.id)
        await harness.wait { model.replyFailure != nil && model.streamingTargetID == nil }
        #expect(harness.state(of: discussed.id)?.replyFailureMessage == "The provider is overloaded.")
        #expect(harness.state(of: quiet.id)?.replyFailureMessage == nil)
        #expect(model.banner == nil)                                         // a failed reply raises no banner
        #expect(model.session?.comments.first { $0.id == discussed.id }?.thread.map(\.text) == ["Is the comment still fair?"])

        model.retryFailedReply()                                             // the inline Retry: the message is not added again
        await harness.wait { model.streamingTargetID == nil && model.replyFailure != nil }
        #expect(model.session?.comments.first { $0.id == discussed.id }?.thread.count == 1)
    }

    @Test @MainActor func attachToSelectionIsEnabledOnceThePDFHasASelection() async throws {
        let unanchored = Sample.comment(anchor: Sample.unanchored)
        let harness = try await SidebarTestHarness.open(comments: [unanchored])
        #expect(harness.state(of: unanchored.id)?.canAttachToSelection == false)
        let line = try #require(harness.paper.text.pages.first?.lines.first { $0.kind == .body && $0.contentRange.length > 20 })
        harness.model.readerSelectionChanged(SelectionInfo(text: line.text, spans: [TextSpan(pageIndex: line.pageIndex, range: line.contentRange)]))
        #expect(harness.model.selection != nil)
        let state = try #require(harness.state(of: unanchored.id))
        #expect(state.showsAttachButton && state.canAttachToSelection)

        let selection = try #require(harness.model.selection)
        harness.model.reanchorComment(unanchored.id, to: selection)          // what the button calls
        #expect(harness.state(of: unanchored.id)?.location == .exact("p. 1"))
    }

    @Test @MainActor func theSceneSupportFindsAPassageOnItsPage() async throws {
        let harness = try await SidebarTestHarness.open(comments: [])
        let passage = "The effect is statistically significant but economically small."
        let selection = try #require(SidebarSceneSupport.selection(of: passage, onPage: 0, in: harness.model))
        #expect(selection.spans.count == 1)
        let page = try #require(harness.paper.text.pages.first)
        let span = try #require(selection.spans.first)
        #expect((page.string as NSString).substring(with: span.range.nsRange) == passage)
        #expect(SidebarSceneSupport.selection(of: passage, onPage: 3, in: harness.model) == nil)
        #expect(SidebarSceneSupport.selection(of: "Nowhere in this paper.", onPage: 0, in: harness.model) == nil)
    }
}
