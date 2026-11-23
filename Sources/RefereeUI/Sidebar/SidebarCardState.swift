import Foundation
import RefereeCore
import AppCore

// What a comment card shows (plan.md section 9.3), derived from the comment and the window's state. Pure, so that every
// row of the state table of section 9.3 is unit-tested without drawing anything.
//
// Where section 9.3 leaves a choice, this file decides (also listed in docs/contract-notes/wp10-sidebar.md):
// - A rejected comment stays one grey line, also while it is selected; selection or hover adds its Undo button. Its
//   thread can still be opened under that line, and editing replaces the line with the editor.
// - A similar comment is collapsed while it is pending, not selected and not clicked open, and only while the comment
//   it resembles still exists (the model clears `similarTo` when that one is deleted).
// - An own comment keeps its blue bar whatever its status, except when rejected (the grey line). Approved comments,
//   own ones included, show the check mark.
// - `.none` is "Passage not found" with "Attach to selection", except for an own comment written without a selection
//   (empty quote): it never had a passage, so nothing is shown (WP8b's note for the UI packages).

/// The window state a card depends on, besides its comment.
struct SidebarCardInputs: Equatable {
    var selectedCommentID: UUID?
    var editingCommentID: UUID?
    var openThreadCommentID: UUID?
    var streamingTargetID: UUID?             // the comment or conversation receiving a reply
    var replyFailure: ReplyFailure?
    var hasSelection: Bool                   // the PDF has a selection: "Attach to selection" can be used
    var rubric: [RubricCategory]
    var titles: [UUID: String]               // every comment's title, for "Similar to: <title>"

    init(selectedCommentID: UUID? = nil, editingCommentID: UUID? = nil, openThreadCommentID: UUID? = nil, streamingTargetID: UUID? = nil,
         replyFailure: ReplyFailure? = nil, hasSelection: Bool = false, rubric: [RubricCategory] = [], titles: [UUID: String] = [:]) {
        self.selectedCommentID = selectedCommentID
        self.editingCommentID = editingCommentID
        self.openThreadCommentID = openThreadCommentID
        self.streamingTargetID = streamingTargetID
        self.replyFailure = replyFailure
        self.hasSelection = hasSelection
        self.rubric = rubric
        self.titles = titles
    }

    /// The inputs as the model has them now.
    @MainActor init(model: ReviewSessionModel) {
        var titles: [UUID: String] = [:]
        for comment in model.session?.comments ?? [] where titles[comment.id] == nil { titles[comment.id] = comment.title }
        self.init(selectedCommentID: model.selectedCommentID, editingCommentID: model.editingCommentID,
                  openThreadCommentID: model.openThreadCommentID, streamingTargetID: model.streamingTargetID,
                  replyFailure: model.replyFailure, hasSelection: model.selection != nil, rubric: model.settings.rubric, titles: titles)
    }
}

/// Everything a comment card shows, decided from the comment and `SidebarCardInputs`.
struct SidebarCardState: Equatable {
    enum Layout: Equatable {
        case full                    // the card of the diagram in section 9.3
        case collapsedRejected       // one grey line: kind and title
        case collapsedSimilar        // two lines: kind and title, then "Similar to: <title>"
    }

    /// The colour of the left bar.
    enum Bar: Equatable { case pending, approved, rejected, own }

    enum Location: Equatable {
        case exact(String)           // "p. 4, lines 14–16"
        case fuzzy(String)           // "≈" beside the label, tooltip "Approximate match"
        case pageOnly(String)        // "p. 4" with a dotted underline, tooltip "Passage not located on the page"
        case notFound                // warning glyph, "Passage not found", button "Attach to selection"
        case noPassage               // an own comment written without a selection: nothing to show
    }

    enum Action: String, Equatable, CaseIterable, Identifiable {
        case approve, reject, undo, discuss, edit
        var id: String { rawValue }
    }

    var layout: Layout
    var bar: Bar
    var showsCheckmark: Bool                 // approved
    var kind: CommentKind
    var kindTitle: String                    // "MAJOR"
    var categoryTitle: String?               // nil when the "You" badge stands in its place
    var showsYouBadge: Bool                  // own comment in category "other"
    var showsVerifyTag: Bool                 // AI comment in category "literature"
    var location: Location
    var similarToID: UUID?                   // set only in the collapsed similar layout
    var similarToTitle: String?
    var quote: String?                       // nil when the anchor has no quote
    var isSelected: Bool
    var isEditing: Bool
    var isThreadOpen: Bool
    var actions: [Action]                    // the buttons, in order
    var canAttachToSelection: Bool
    var proposal: CommentRevision?
    var replyFailureMessage: String?         // the failed reply of this comment, shown in red with Retry
    var isReceivingReply: Bool
    var isExcludedFromReport: Bool

    /// Whether the card offers "Attach to selection" outside its ⋯ menu.
    var showsAttachButton: Bool { location == .notFound }

    /// `isExpanded`: the referee clicked a collapsed similar card open. `isHovered`: the pointer is over the card.
    static func make(for comment: ReviewComment, inputs: SidebarCardInputs, isExpanded: Bool = false, isHovered: Bool = false) -> SidebarCardState {
        let isSelected = inputs.selectedCommentID == comment.id
        let isOwn = comment.origin == .user
        let similarTitle = comment.similarTo.flatMap { inputs.titles[$0] }

        let layout: Layout
        if comment.status == .rejected {
            layout = .collapsedRejected
        } else if comment.status == .pending, similarTitle != nil, !isSelected, !isExpanded {
            layout = .collapsedSimilar
        } else {
            layout = .full
        }

        let bar: Bar
        switch comment.status {
        case .rejected: bar = .rejected
        case .approved: bar = isOwn ? .own : .approved
        case .pending: bar = isOwn ? .own : .pending
        }

        let actions: [Action]
        switch layout {
        case .full: actions = comment.status == .pending ? [.approve, .reject, .discuss, .edit] : [.undo, .discuss, .edit]
        case .collapsedRejected: actions = isSelected || isHovered ? [.undo] : []
        case .collapsedSimilar: actions = []
        }

        let quote = comment.anchor.quote.trimmingCharacters(in: .whitespacesAndNewlines)
        let showsYouBadge = isOwn && comment.category == "other"
        return SidebarCardState(
            layout: layout,
            bar: bar,
            showsCheckmark: comment.status == .approved,
            kind: comment.kind,
            kindTitle: kindTitle(comment.kind),
            categoryTitle: showsYouBadge ? nil : categoryName(comment.category, rubric: inputs.rubric),
            showsYouBadge: showsYouBadge,
            showsVerifyTag: !isOwn && comment.category == "literature",
            location: location(of: comment.anchor, isOwn: isOwn),
            similarToID: layout == .collapsedSimilar ? comment.similarTo : nil,
            similarToTitle: layout == .collapsedSimilar ? similarTitle : nil,
            quote: quote.isEmpty ? nil : quote,
            isSelected: isSelected,
            isEditing: inputs.editingCommentID == comment.id,
            isThreadOpen: inputs.openThreadCommentID == comment.id,
            actions: actions,
            canAttachToSelection: inputs.hasSelection,
            proposal: comment.proposedRevision,
            replyFailureMessage: inputs.replyFailure?.targetID == comment.id ? inputs.replyFailure?.message : nil,
            isReceivingReply: inputs.streamingTargetID == comment.id,
            isExcludedFromReport: !comment.includeInReport)
    }

    /// "MAJOR", "MINOR", "QUESTION", "STRENGTH".
    static func kindTitle(_ kind: CommentKind) -> String { kind.rawValue.uppercased() }

    /// "Major", "Minor", "Question", "Strength" (pickers and menus).
    static func kindName(_ kind: CommentKind) -> String {
        switch kind {
        case .major: return "Major"
        case .minor: return "Minor"
        case .question: return "Question"
        case .strength: return "Strength"
        }
    }

    /// The rubric's name for a category id; an id the rubric does not know displays as "Other" (Appendix A.4).
    static func categoryName(_ id: String, rubric: [RubricCategory]) -> String {
        rubric.first { $0.id == id }?.name ?? "Other"
    }

    static func location(of anchor: Anchor, isOwn: Bool) -> Location {
        let page = anchor.spans.first?.pageIndex ?? anchor.pageIndex
        let label = anchor.locationLabel.isEmpty ? page.map { "p. \($0 + 1)" } ?? "" : anchor.locationLabel
        switch anchor.confidence {
        case .exact: return .exact(label)
        case .fuzzy: return .fuzzy(label)
        case .pageOnly: return .pageOnly(label)
        case .none:
            let hasQuote = !anchor.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return isOwn && !hasQuote ? .noPassage : .notFound
        }
    }
}

/// What the card of a comment still being written shows (section 9.3, "draft (streaming)").
struct SidebarDraftState: Equatable {
    var kind: CommentKind?                   // the badge shows once the kind is known
    var kindTitle: String?
    var categoryTitle: String?               // only a category the rubric knows
    var pageLabel: String?                   // "p. 3", from the page the model wrote
    var title: String?
    var quote: String?
    var body: String?
    var suggestion: String?

    /// Neither title nor body has arrived yet.
    var isWaitingForText: Bool { title == nil && body == nil }

    static func make(for draft: DraftComment, rubric: [RubricCategory]) -> SidebarDraftState {
        SidebarDraftState(
            kind: draft.kind,
            kindTitle: draft.kind.map(SidebarCardState.kindTitle),
            categoryTitle: draft.category.flatMap { id in rubric.first { $0.id == id.lowercased() }?.name },
            pageLabel: draft.page.flatMap { $0 > 0 ? "p. \($0)" : nil },
            title: nonBlank(draft.title),
            quote: nonBlank(draft.quote),
            body: nonBlank(draft.body),
            suggestion: nonBlank(draft.suggestion))
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
