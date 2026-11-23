import Foundation
import Testing
import RefereeCore
import AppCore
@testable import RefereeUI

/// The card view-state derivation (WP10): one test per row of the state table of plan.md section 9.3, and the changes
/// of step 5 (docs/design-review.md D1, D17, D18, D22, D31; the source label of step 5b).
@Suite struct SidebarCardStateTests {
    typealias Sample = SidebarTestData

    @Test func aPendingCardHasTheFourButtonsAndTheYellowBar() {
        let comment = Sample.comment()
        let state = SidebarCardState.make(for: comment, inputs: Sample.inputs(selected: comment.id))
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
        let comment = Sample.comment(status: .approved)
        let state = SidebarCardState.make(for: comment, inputs: Sample.inputs(selected: comment.id))
        #expect(state.layout == .full)
        #expect(state.bar == .approved)
        #expect(state.showsCheckmark)
        #expect(state.actions == [.undo, .discuss, .edit])
    }

    // ---- D1: compact cards ----

    /// A card that nobody works on is compact: header and title, no buttons; its bar, badge and location stay.
    @Test func aCardThatIsNotWorkedOnIsCompact() {
        let state = SidebarCardState.make(for: Sample.comment(status: .approved), inputs: Sample.inputs())
        #expect(state.layout == .compact)
        #expect(state.actions.isEmpty)
        #expect(state.bar == .approved)
        #expect(state.showsCheckmark)
        #expect(state.kindTitle == "MAJOR")
        #expect(state.location == .exact("p. 1, lines 13–14"))
    }

    /// Selected, edited, discussed, receiving a reply, a failed reply, or "Show Full Text of Every Comment": in full.
    @Test func theCardBeingWorkedOnIsInFull() {
        let comment = Sample.comment()
        let failure = ReplyFailure(targetID: comment.id, message: "The provider is overloaded.")
        let cases: [(String, SidebarCardInputs)] = [
            ("selected", Sample.inputs(selected: comment.id)),
            ("edited", Sample.inputs(editing: comment.id)),
            ("discussed", Sample.inputs(thread: comment.id)),
            ("receiving a reply", Sample.inputs(streaming: comment.id)),
            ("a failed reply", Sample.inputs(failure: failure)),
            ("every card in full", Sample.inputs(expandsAllCards: true)),
        ]
        for (name, inputs) in cases {
            #expect(SidebarCardState.make(for: comment, inputs: inputs).layout == .full, "\(name)")
        }
        let elsewhere = UUID()
        let other = Sample.inputs(selected: elsewhere, editing: elsewhere, thread: elsewhere, streaming: elsewhere)
        #expect(SidebarCardState.make(for: comment, inputs: other).layout == .compact)
    }

    /// The collapsed forms keep their place before the rule: rejected and similar stay collapsed even with every card
    /// in full.
    @Test func rejectedAndSimilarCardsStayCollapsedWithEveryCardInFull() {
        let other = Sample.comment()
        let similar = Sample.comment(similarTo: other.id)
        let inputs = Sample.inputs(titles: [other.id: other.title], expandsAllCards: true)
        #expect(SidebarCardState.make(for: Sample.comment(status: .rejected), inputs: inputs).layout == .collapsedRejected)
        #expect(SidebarCardState.make(for: similar, inputs: inputs).layout == .collapsedSimilar)
    }

    @Test func theCompactCardCountsTheMessagesAndCarriesTheProposal() {
        let message = ThreadMessage(id: UUID(), role: .user, text: "Is this fair?", createdAt: Sample.created)
        let answer = ThreadMessage(id: UUID(), role: .assistant, text: "Partly.", createdAt: Sample.created)
        let proposal = CommentRevision(kind: .minor, title: "Shorter", body: "Less.", withdraw: false)
        let state = SidebarCardState.make(for: Sample.comment(thread: [message, answer], proposal: proposal), inputs: Sample.inputs())
        #expect(state.layout == .compact)
        #expect(state.threadCount == 2)
        #expect(state.proposal == proposal)
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

        // Clicked open and no longer selected: an ordinary card again, compact like the others (D1).
        let clicked = SidebarCardState.make(for: similar, inputs: Sample.inputs(titles: titles), isExpanded: true)
        #expect(clicked.layout == .compact)
    }

    @Test func aSimilarCardIsNotCollapsedOnceDecidedOrWhenTheOtherCommentIsGone() {
        let other = Sample.comment()
        let titles = [other.id: other.title]
        let approved = Sample.comment(status: .approved, similarTo: other.id)
        #expect(SidebarCardState.make(for: approved, inputs: Sample.inputs(titles: titles)).layout == .compact)
        let orphan = Sample.comment(similarTo: UUID())
        #expect(SidebarCardState.make(for: orphan, inputs: Sample.inputs(titles: titles)).layout == .compact)
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
        #expect(location(Sample.fuzzy) == .fuzzy("p. 1, lines 5–7"))           // "≈ p. 1, lines 5–7" (D17)
        #expect(location(Sample.pageOnly) == .pageOnly("p. 3"))                // "p. 3 · page only" (D17)
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

    // ---- D17: what a location says ----

    @Test func locationsSayWhatTheyMean() {
        #expect(SidebarCardState.locationText(.exact("p. 4, lines 14–16")) == "p. 4, lines 14–16")
        #expect(SidebarCardState.locationText(.fuzzy("p. 1, lines 5–7")) == "≈ p. 1, lines 5–7")
        #expect(SidebarCardState.locationText(.pageOnly("p. 3")) == "p. 3 · page only")
        #expect(SidebarCardState.locationText(.notFound) == "Passage not found")
        #expect(SidebarCardState.locationText(.noPassage) == nil)
        #expect(SidebarCardState.locationText(.exact("")) == nil)

        #expect(SidebarCardState.locationHelp(.exact("p. 4")) == "Show the passage in the PDF")
        #expect(SidebarCardState.locationHelp(.fuzzy("p. 4")) == "Approximate match: the quote differs slightly from the paper's text")
        #expect(SidebarCardState.locationHelp(.pageOnly("p. 4"))
                == "The model named this page, but its quote was not found on it. Select the passage and choose Attach to Selection in the ⋯ menu.")
    }

    @Test func voiceOverHearsTheLocationInWords() {
        #expect(SidebarCardState.spokenLocation(.exact("p. 4, lines 14–16")) == "page 4, lines 14 to 16")
        #expect(SidebarCardState.spokenLocation(.exact("p. 4, line 9")) == "page 4, line 9")
        #expect(SidebarCardState.spokenLocation(.fuzzy("p. 1, lines 5–7")) == "page 1, lines 5 to 7, approximate")
        #expect(SidebarCardState.spokenLocation(.pageOnly("p. 3")) == "page 3, page only")
        #expect(SidebarCardState.spokenLocation(.notFound) == "passage not found")
        #expect(SidebarCardState.spokenLocation(.noPassage) == nil)
        #expect(SidebarCardState.spoken("pp. 4–5 (p. 4 line 58 to p. 5 line 3)") == "pages 4 to 5 (page 4 line 58 to page 5 line 3)")
    }

    // ---- D22: VoiceOver ----

    @Test func aCardIsReadAsKindStatusPlaceAndTitle() {
        let pending = Sample.comment(title: "Abstract claims more than Table 2 supports",
                                     anchor: Anchor(quote: "x", pageIndex: 3, confidence: .exact, locationLabel: "p. 4, lines 14–16"))
        #expect(SidebarCardState.accessibilityLabel(of: pending, location: .exact("p. 4, lines 14–16"))
                == "Major comment, pending, page 4, lines 14 to 16: Abstract claims more than Table 2 supports")
        let rejected = Sample.comment(status: .rejected, kind: .minor, title: "A sign")
        #expect(SidebarCardState.accessibilityLabel(of: rejected, location: .notFound) == "Minor comment, rejected, passage not found: A sign")
        let own = Sample.comment(origin: .user, status: .approved, kind: .question, title: "Why forty?")
        #expect(SidebarCardState.accessibilityLabel(of: own, location: .noPassage) == "Question comment, your own: Why forty?")
        #expect(SidebarCardState.spokenStatus(of: Sample.comment(status: .approved)) == "approved")
        #expect(SidebarCardState.spokenStatus(of: Sample.comment(origin: .user)) == "your own, pending")
        #expect(SidebarCardState.spokenStatus(of: Sample.comment(origin: .user, status: .rejected)) == "rejected")
    }

    @Test func messagesSayWhoseTheyAre() {
        #expect(SidebarMessageBubble.accessibilityLabel(role: .user, text: "Is this fair?") == "You: Is this fair?")
        #expect(SidebarMessageBubble.accessibilityLabel(role: .assistant, text: "Partly.") == "Assistant: Partly.")
        #expect(SidebarMessageBubble.accessibilityLabel(role: .assistant, text: "", isStreaming: true) == "Assistant: writing")
    }

    // ---- D18: what a proposal changes ----

    @Test func aProposalListsOnlyWhatDiffers() {
        let comment = Sample.comment(kind: .major, title: "Old title", body: "Old body.", suggestion: "Old suggestion.")
        let everything = CommentRevision(kind: .minor, title: "New title", body: "New body.", suggestion: nil, withdraw: false)
        #expect(SidebarProposalFacts.changes(from: comment, to: everything) == "Changes: kind Major → Minor · title · comment · suggestion")
        let wording = CommentRevision(kind: .major, title: "Old title", body: "New body.", suggestion: "Old suggestion.", withdraw: false)
        #expect(SidebarProposalFacts.changes(from: comment, to: wording) == "Changes: comment")
        let same = CommentRevision(kind: .major, title: "Old title", body: "Old body.", suggestion: "Old suggestion.", withdraw: false)
        #expect(SidebarProposalFacts.changes(from: comment, to: same) == nil)
        let withdrawal = CommentRevision(kind: .major, title: "", body: "", withdraw: true)
        #expect(SidebarProposalFacts.changes(from: comment, to: withdrawal) == nil)
        // A blank suggestion is none.
        let blank = Sample.comment(suggestion: "  ")
        let none = CommentRevision(kind: blank.kind, title: blank.title, body: blank.body, suggestion: nil, withdraw: false)
        #expect(SidebarProposalFacts.changes(from: blank, to: none) == nil)
    }

    // ---- D31: earlier versions ----

    @Test func earlierVersionsAreListedByTitleOnOneLineOf40Characters() {
        #expect(SidebarCardState.versionTitle("A short title") == "A short title")
        let long = "The interval includes one and the text still calls the effect robust"
        let shown = SidebarCardState.versionTitle(long)
        #expect(shown.count == 40)
        #expect(shown.hasSuffix("…"))
        #expect(shown.hasPrefix("The interval includes one and the text"))
        #expect(SidebarCardState.versionTitle("Two\nlines") == "Two lines")
        #expect(SidebarCardState.versionTitle("  ") == "Untitled")
    }

    // ---- step 5b: who wrote it ----

    @Test func theCardCarriesItsSourceAndTheSimilarOnesSource() {
        let earlier = Sample.comment(title: "Staggered adoption is asserted")
        let later = Sample.comment(title: "The rollout dates are never reported", similarTo: earlier.id)
        let claude = SidebarSource(providerID: "claude-cli", providerName: "Claude Code", model: "sonnet", modelName: "Sonnet")
        let codex = SidebarSource(providerID: "codex-cli", providerName: "Codex", model: nil, modelName: nil)
        let inputs = Sample.inputs(titles: [earlier.id: earlier.title, later.id: later.title], sources: [earlier.id: claude, later.id: codex])
        let folded = SidebarCardState.make(for: later, inputs: inputs)
        #expect(folded.layout == .collapsedSimilar)
        #expect(folded.source?.text == "Codex · default model")
        #expect(folded.similarToSource?.text == "Claude Code · Sonnet")
        #expect(SidebarCardState.make(for: earlier, inputs: inputs).source == claude)
        // Open, the card no longer shows whose the other comment is: it shows no "Similar to" line.
        #expect(SidebarCardState.make(for: later, inputs: inputs, isExpanded: true).similarToSource == nil)
        #expect(SidebarCardState.make(for: Sample.comment(origin: .user), inputs: inputs).source == nil)
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
