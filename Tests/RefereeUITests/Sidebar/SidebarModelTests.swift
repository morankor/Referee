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
        #expect(harness.state(of: similar.id)?.layout == .full)
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
