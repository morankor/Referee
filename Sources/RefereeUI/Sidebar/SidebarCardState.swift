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
//
// Step 5 (docs/design-review.md, D1): a card is shown in full only while it is the one being worked on (selected,
// edited, discussed, receiving or having failed a reply) or while the referee asked for every card in full; every other
// card is compact, its header and title, so that a list of 25 comments can be read one comment at a time.

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
    var expandsAllCards: Bool                // "Show Full Text of Every Comment" in the Comments tab's ⋯ menu (D1)
    var sources: [UUID: SidebarSource]       // which provider and model wrote each AI comment (step 5b)

    init(selectedCommentID: UUID? = nil, editingCommentID: UUID? = nil, openThreadCommentID: UUID? = nil, streamingTargetID: UUID? = nil,
         replyFailure: ReplyFailure? = nil, hasSelection: Bool = false, rubric: [RubricCategory] = [], titles: [UUID: String] = [:],
         expandsAllCards: Bool = false, sources: [UUID: SidebarSource] = [:]) {
        self.selectedCommentID = selectedCommentID
        self.editingCommentID = editingCommentID
        self.openThreadCommentID = openThreadCommentID
        self.streamingTargetID = streamingTargetID
        self.replyFailure = replyFailure
        self.hasSelection = hasSelection
        self.rubric = rubric
        self.titles = titles
        self.expandsAllCards = expandsAllCards
        self.sources = sources
    }

    /// The inputs as the model has them now.
    @MainActor init(model: ReviewSessionModel, expandsAllCards: Bool = false) {
        let comments = model.session?.comments ?? []
        var titles: [UUID: String] = [:]
        for comment in comments where titles[comment.id] == nil { titles[comment.id] = comment.title }
        self.init(selectedCommentID: model.selectedCommentID, editingCommentID: model.editingCommentID,
                  openThreadCommentID: model.openThreadCommentID, streamingTargetID: model.streamingTargetID,
                  replyFailure: model.replyFailure, hasSelection: model.selection != nil, rubric: model.settings.rubric, titles: titles,
                  expandsAllCards: expandsAllCards, sources: SidebarSourceNames(model: model).sources(of: comments))
    }
}

/// Everything a comment card shows, decided from the comment and `SidebarCardInputs`.
struct SidebarCardState: Equatable {
    enum Layout: Equatable {
        case full                    // the card of the diagram in section 9.3
        case compact                 // the header and the title (two lines at most); no quote, body, suggestion or buttons (D1)
        case collapsedRejected       // one grey line: kind and title
        case collapsedSimilar        // two lines: kind and title, then "Similar to: <title>"
    }

    /// The colour of the left bar.
    enum Bar: Equatable { case pending, approved, rejected, own }

    enum Location: Equatable {
        case exact(String)           // "p. 4, lines 14–16"
        case fuzzy(String)           // "≈ p. 4, lines 14–16", tooltip "Approximate match: …" (D17)
        case pageOnly(String)        // "p. 4 · page only", with a tooltip that says what to do (D17)
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
    var threadCount: Int                     // messages in the discussion; a compact card shows the number (D1)
    var source: SidebarSource?               // the provider and model that wrote it; nil for an own comment (step 5b)
    var similarToSource: SidebarSource?      // set only in the collapsed similar layout: who wrote the other comment

    /// Whether the card offers "Attach to selection" outside its ⋯ menu.
    var showsAttachButton: Bool { location == .notFound }

    /// `isExpanded`: the referee clicked a collapsed similar card open. `isHovered`: the pointer is over the card.
    static func make(for comment: ReviewComment, inputs: SidebarCardInputs, isExpanded: Bool = false, isHovered: Bool = false) -> SidebarCardState {
        let isSelected = inputs.selectedCommentID == comment.id
        let isEditing = inputs.editingCommentID == comment.id
        let isThreadOpen = inputs.openThreadCommentID == comment.id
        let isReceivingReply = inputs.streamingTargetID == comment.id
        let replyFailureMessage = inputs.replyFailure?.targetID == comment.id ? inputs.replyFailure?.message : nil
        let isOwn = comment.origin == .user
        let similarTitle = comment.similarTo.flatMap { inputs.titles[$0] }

        let layout: Layout
        if comment.status == .rejected {
            layout = .collapsedRejected
        } else if comment.status == .pending, similarTitle != nil, !isSelected, !isExpanded {
            layout = .collapsedSimilar
        } else if isSelected || isEditing || isThreadOpen || isReceivingReply || replyFailureMessage != nil || inputs.expandsAllCards {
            layout = .full
        } else {
            layout = .compact
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
        case .compact, .collapsedSimilar: actions = []
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
            isEditing: isEditing,
            isThreadOpen: isThreadOpen,
            actions: actions,
            canAttachToSelection: inputs.hasSelection,
            proposal: comment.proposedRevision,
            replyFailureMessage: replyFailureMessage,
            isReceivingReply: isReceivingReply,
            isExcludedFromReport: !comment.includeInReport,
            threadCount: comment.thread.count,
            source: inputs.sources[comment.id],
            similarToSource: layout == .collapsedSimilar ? comment.similarTo.flatMap { inputs.sources[$0] } : nil)
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

    // ---- what the location says (D17) ----

    /// The location as the card prints it: "p. 4, lines 14–16", "≈ p. 1, lines 5–7", "p. 3 · page only", "Passage not
    /// found"; nil when there is nothing to print (an own comment without a passage, or an anchor without a label).
    static func locationText(_ location: Location) -> String? {
        switch location {
        case .exact(let label): return label.isEmpty ? nil : label
        case .fuzzy(let label): return "≈ " + label
        case .pageOnly(let label): return label + " · page only"
        case .notFound: return "Passage not found"
        case .noPassage: return nil
        }
    }

    /// The location's tooltip, which says what the label means.
    static func locationHelp(_ location: Location) -> String? {
        switch location {
        case .exact: return "Show the passage in the PDF"
        case .fuzzy: return "Approximate match: the quote differs slightly from the paper's text"
        case .pageOnly:
            return "The model named this page, but its quote was not found on it. Select the passage and choose Attach to Selection in the ⋯ menu."
        case .notFound, .noPassage: return nil
        }
    }

    /// The location for VoiceOver: "page 4, lines 14 to 16", "page 1, lines 5 to 7, approximate", "page 3, page only",
    /// "passage not found"; nil when there is none.
    static func spokenLocation(_ location: Location) -> String? {
        switch location {
        case .exact(let label): return label.isEmpty ? nil : spoken(label)
        case .fuzzy(let label): return spoken(label) + ", approximate"
        case .pageOnly(let label): return spoken(label) + ", page only"
        case .notFound: return "passage not found"
        case .noPassage: return nil
        }
    }

    /// "p. 4, lines 14–16" → "page 4, lines 14 to 16"; "pp. 4–5" → "pages 4 to 5".
    static func spoken(_ label: String) -> String {
        label.replacingOccurrences(of: "pp. ", with: "pages ")
            .replacingOccurrences(of: "p. ", with: "page ")
            .replacingOccurrences(of: "–", with: " to ")
    }

    // ---- VoiceOver (D22) ----

    /// "pending", "approved", "rejected", or "your own" for the referee's own comment ("your own, pending" while one
    /// made from a chat answer still waits for a decision).
    static func spokenStatus(of comment: ReviewComment) -> String {
        switch (comment.status, comment.origin == .user) {
        case (.rejected, _): return "rejected"
        case (.pending, true): return "your own, pending"
        case (.approved, true): return "your own"
        case (.pending, false): return "pending"
        case (.approved, false): return "approved"
        }
    }

    /// "Major comment, pending, page 4, lines 14 to 16: Abstract claims more than Table 2 supports".
    static func accessibilityLabel(of comment: ReviewComment, location: Location) -> String {
        var parts = [kindName(comment.kind) + " comment", spokenStatus(of: comment)]
        if let place = spokenLocation(location) { parts.append(place) }
        return parts.joined(separator: ", ") + ": " + comment.title
    }

    // ---- earlier versions (D31) ----

    /// A version's title in the "Earlier Versions" menu: on one line, at most 40 characters ("…" when cut).
    static func versionTitle(_ title: String) -> String {
        let line = title.split(whereSeparator: { $0.isNewline }).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if line.isEmpty { return "Untitled" }
        return line.count > 40 ? String(line.prefix(39)) + "…" : line
    }
}

/// What a proposed revision changes (D18). Pure.
enum SidebarProposalFacts {
    /// "Changes: kind Major → Minor · title · comment · suggestion", listing only what differs from the comment; nil
    /// for a proposed withdrawal or a proposal that changes nothing. A blank suggestion counts as none.
    static func changes(from comment: ReviewComment, to proposal: CommentRevision) -> String? {
        guard !proposal.withdraw else { return nil }
        var parts: [String] = []
        if proposal.kind != comment.kind {
            parts.append("kind \(SidebarCardState.kindName(comment.kind)) → \(SidebarCardState.kindName(proposal.kind))")
        }
        if proposal.title != comment.title { parts.append("title") }
        if proposal.body != comment.body { parts.append("comment") }
        if blankAsNone(proposal.suggestion) != blankAsNone(comment.suggestion) { parts.append("suggestion") }
        return parts.isEmpty ? nil : "Changes: " + parts.joined(separator: " · ")
    }

    private static func blankAsNone(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
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
