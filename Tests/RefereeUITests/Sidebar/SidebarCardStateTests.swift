import Foundation
import Testing
import RefereeCore
import AppCore
@testable import RefereeUI

/// The card view-state derivation (WP10): one test per row of the state table of plan.md section 9.3.
@Suite struct SidebarCardStateTests {
    typealias Sample = SidebarTestData

    @Test func aPendingCardHasTheFourButtonsAndTheYellowBar() {
        let comment = Sample.comment()
        let state = SidebarCardState.make(for: comment, inputs: Sample.inputs())
        #expect(state.layout == .full)
        #expect(state.bar == .pending)
        #expect(state.actions == [.approve, .reject, .discuss, .edit])
        #expect(!state.showsCheckmark)
        #expect(state.kindTitle == "MAJOR")
        #expect(state.categoryTitle == "Claims vs. evidence")
        #expect(state.quote == "The effect is statistically significant")
        #expect(state.location == .exact("p. 1, lines 13–14"))
    }

    @Test func anApprovedCardShowsTheCheckMarkAndUndoDiscussEdit() {
        let state = SidebarCardState.make(for: Sample.comment(status: .approved), inputs: Sample.inputs())
        #expect(state.layout == .full)
        #expect(state.bar == .approved)
        #expect(state.showsCheckmark)
        #expect(state.actions == [.undo, .discuss, .edit])
    }

    @Test func aRejectedCardIsOneGreyLineWithUndoOnlyOnHoverOrSelection() {
        let comment = Sample.comment(status: .rejected)
        let plain = SidebarCardState.make(for: comment, inputs: Sample.inputs())
        #expect(plain.layout == .collapsedRejected)
        #expect(plain.bar == .rejected)
        #expect(plain.actions.isEmpty)
        #expect(SidebarCardState.make(for: comment, inputs: Sample.inputs(), isHovered: true).actions == [.undo])
        let selected = SidebarCardState.make(for: comment, inputs: Sample.inputs(selected: comment.id))
        #expect(selected.layout == .collapsedRejected)
        #expect(selected.isSelected)
        #expect(selected.actions == [.undo])
    }

    @Test func aSimilarPendingCardIsCollapsedUntilSelectedOrClicked() {
        let other = Sample.comment(title: "The estimate cannot be told apart from no effect")
        let similar = Sample.comment(title: "The interval includes one", similarTo: other.id)
        let titles = [other.id: other.title, similar.id: similar.title]

        let collapsed = SidebarCardState.make(for: similar, inputs: Sample.inputs(titles: titles))
        #expect(collapsed.layout == .collapsedSimilar)
        #expect(collapsed.similarToID == other.id)
        #expect(collapsed.similarToTitle == "The estimate cannot be told apart from no effect")
        #expect(collapsed.actions.isEmpty)

        let selected = SidebarCardState.make(for: similar, inputs: Sample.inputs(selected: similar.id, titles: titles))
        #expect(selected.layout == .full)
        #expect(selected.actions == [.approve, .reject, .discuss, .edit])
        #expect(selected.similarToTitle == nil)

        let clicked = SidebarCardState.make(for: similar, inputs: Sample.inputs(titles: titles), isExpanded: true)
        #expect(clicked.layout == .full)
    }

    @Test func aSimilarCardIsNotCollapsedOnceDecidedOrWhenTheOtherCommentIsGone() {
        let other = Sample.comment()
        let titles = [other.id: other.title]
        let approved = Sample.comment(status: .approved, similarTo: other.id)
        #expect(SidebarCardState.make(for: approved, inputs: Sample.inputs(titles: titles)).layout == .full)
        let orphan = Sample.comment(similarTo: UUID())
        #expect(SidebarCardState.make(for: orphan, inputs: Sample.inputs(titles: titles)).layout == .full)
    }

    @Test func selectionEditingAndTheOpenThreadFollowTheirIDs() {
        let comment = Sample.comment()
        let elsewhere = UUID()
        let mine = SidebarCardState.make(for: comment, inputs: Sample.inputs(selected: comment.id, editing: comment.id, thread: comment.id))
        #expect(mine.isSelected && mine.isEditing && mine.isThreadOpen)
        let theirs = SidebarCardState.make(for: comment, inputs: Sample.inputs(selected: elsewhere, editing: elsewhere, thread: elsewhere))
        #expect(!theirs.isSelected && !theirs.isEditing && !theirs.isThreadOpen)
    }

    @Test func theAnchorDecidesTheLocation() {
        func location(_ anchor: Anchor, origin: CommentOrigin = .ai(runID: UUID())) -> SidebarCardState.Location {
            SidebarCardState.make(for: Sample.comment(origin: origin, anchor: anchor), inputs: Sample.inputs()).location
        }
        #expect(location(Sample.exact) == .exact("p. 1, lines 13–14"))
        #expect(location(Sample.fuzzy) == .fuzzy("p. 1, lines 5–7"))           // "≈" and "Approximate match"
        #expect(location(Sample.pageOnly) == .pageOnly("p. 3"))                // dotted underline, "Passage not located on the page"
        #expect(location(Sample.unanchored) == .notFound)                      // "Passage not found", "Attach to selection"
        #expect(location(Sample.noPassage) == .notFound)                       // an AI comment without a quote: still not found
        #expect(location(Sample.noPassage, origin: .user) == .noPassage)       // an own comment written without a selection
        #expect(location(Sample.unanchored, origin: .user) == .notFound)       // an own comment whose passage was lost
        let unlabelled = Anchor(quote: "x", pageIndex: 3, confidence: .pageOnly, locationLabel: "")
        #expect(location(unlabelled) == .pageOnly("p. 4"))
    }

    @Test func attachToSelectionShowsOnUnanchoredCardsAndNeedsASelection() {
        let comment = Sample.comment(anchor: Sample.unanchored)
        let without = SidebarCardState.make(for: comment, inputs: Sample.inputs())
        #expect(without.showsAttachButton)
        #expect(!without.canAttachToSelection)
        #expect(SidebarCardState.make(for: comment, inputs: Sample.inputs(hasSelection: true)).canAttachToSelection)
        #expect(!SidebarCardState.make(for: Sample.comment(), inputs: Sample.inputs(hasSelection: true)).showsAttachButton)
    }

    @Test func anOwnCommentHasTheBlueBarAndTheYouBadgeInCategoryOther() {
        let own = SidebarCardState.make(for: Sample.comment(origin: .user, status: .approved, category: "other"), inputs: Sample.inputs())
        #expect(own.bar == .own)
        #expect(own.showsCheckmark)
        #expect(own.showsYouBadge)
        #expect(own.categoryTitle == nil)
        let ownPending = SidebarCardState.make(for: Sample.comment(origin: .user, category: "other"), inputs: Sample.inputs())
        #expect(ownPending.bar == .own)
        let ownClaims = SidebarCardState.make(for: Sample.comment(origin: .user, category: "claims"), inputs: Sample.inputs())
        #expect(!ownClaims.showsYouBadge)
        #expect(ownClaims.categoryTitle == "Claims vs. evidence")
        let ownRejected = SidebarCardState.make(for: Sample.comment(origin: .user, status: .rejected), inputs: Sample.inputs())
        #expect(ownRejected.bar == .rejected)
        let aiOther = SidebarCardState.make(for: Sample.comment(category: "other"), inputs: Sample.inputs())
        #expect(!aiOther.showsYouBadge)
        #expect(aiOther.categoryTitle == "Other")
    }

    @Test func anAICommentInCategoryLiteratureCarriesTheVerifyTag() {
        #expect(SidebarCardState.make(for: Sample.comment(category: "literature"), inputs: Sample.inputs()).showsVerifyTag)
        #expect(!SidebarCardState.make(for: Sample.comment(origin: .user, category: "literature"), inputs: Sample.inputs()).showsVerifyTag)
        #expect(!SidebarCardState.make(for: Sample.comment(category: "claims"), inputs: Sample.inputs()).showsVerifyTag)
    }

    @Test func anUnknownCategoryDisplaysAsOther() {
        let state = SidebarCardState.make(for: Sample.comment(category: "no-such-category"), inputs: Sample.inputs())
        #expect(state.categoryTitle == "Other")
        #expect(SidebarCardState.categoryName("math", rubric: Sample.rubric) == "Proofs and derivations")
    }

    @Test func aFailedReplyShowsOnlyUnderItsOwnComment() {
        let comment = Sample.comment()
        let failure = ReplyFailure(targetID: comment.id, message: "The provider is overloaded.")
        #expect(SidebarCardState.make(for: comment, inputs: Sample.inputs(failure: failure)).replyFailureMessage == "The provider is overloaded.")
        let other = ReplyFailure(targetID: UUID(), message: "The provider is overloaded.")
        #expect(SidebarCardState.make(for: comment, inputs: Sample.inputs(failure: other)).replyFailureMessage == nil)
    }

    @Test func aStreamingReplyIsMarkedOnItsComment() {
        let comment = Sample.comment()
        #expect(SidebarCardState.make(for: comment, inputs: Sample.inputs(streaming: comment.id)).isReceivingReply)
        #expect(!SidebarCardState.make(for: comment, inputs: Sample.inputs(streaming: UUID())).isReceivingReply)
    }

    @Test func theProposalTheEmptyQuoteAndTheReportFlagAreCarried() {
        let proposal = CommentRevision(kind: .minor, title: "Shorter", body: "Less.", withdraw: false)
        let state = SidebarCardState.make(for: Sample.comment(anchor: Sample.noPassage, proposal: proposal, includeInReport: false), inputs: Sample.inputs())
        #expect(state.proposal == proposal)
        #expect(state.quote == nil)
        #expect(state.isExcludedFromReport)
    }

    @Test func kindTitlesAndNames() {
        #expect(CommentKind.allCases.map(SidebarCardState.kindTitle) == ["MAJOR", "MINOR", "QUESTION", "STRENGTH"])
        #expect(CommentKind.allCases.map(SidebarCardState.kindName) == ["Major", "Minor", "Question", "Strength"])
    }

    // ---- drafts ----

    @Test func aDraftShowsItsBadgeOnlyOnceTheKindIsKnown() {
        let early = SidebarDraftState.make(for: DraftComment(id: UUID(), body: ""), rubric: Sample.rubric)
        #expect(early.kind == nil)
        #expect(early.kindTitle == nil)
        #expect(early.isWaitingForText)

        let later = SidebarDraftState.make(for: DraftComment(id: UUID(), kind: .question, category: "data", page: 3, quote: " A quote ",
                                                             title: "A title", body: "Growing body"), rubric: Sample.rubric)
        #expect(later.kindTitle == "QUESTION")
        #expect(later.categoryTitle == "Numbers, tables and figures")
        #expect(later.pageLabel == "p. 3")
        #expect(later.quote == "A quote")
        #expect(later.title == "A title")
        #expect(later.body == "Growing body")
        #expect(!later.isWaitingForText)
    }

    @Test func aDraftShowsNoCategoryTheRubricDoesNotKnowAndNoPageZero() {
        let state = SidebarDraftState.make(for: DraftComment(id: UUID(), category: "half-writ", page: 0, body: "  "), rubric: Sample.rubric)
        #expect(state.categoryTitle == nil)
        #expect(state.pageLabel == nil)
        #expect(state.body == nil)
        #expect(SidebarDraftState.make(for: DraftComment(id: UUID(), category: "Claims", body: ""), rubric: Sample.rubric).categoryTitle
                == "Claims vs. evidence")
    }
}
