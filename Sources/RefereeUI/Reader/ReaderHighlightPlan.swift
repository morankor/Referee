import AppKit
import RefereeCore
import AppCore

// Which highlights the PDF shows (plan.md section 7.3): comments, the sidebar's filter and the selected comment in, a
// list of rectangles with their colour out. Pure, so that the rules are unit-tested without a PDF view; the highlight
// controller turns the list into annotations on the display document.
//
// Where section 7.3 leaves a choice, this file decides (also in docs/contract-notes/wp9-reader.md):
// - A comment is highlighted when it passes the sidebar's filter (`model.filter`, the rule of `visibleComments`) and its
//   anchor has rectangles. Conversations' passages are always shown: they are not comments and no filter applies.
// - The reviewer's own comment is blue whatever its status (Theme.Highlight.own). An AI comment that was rejected has no
//   highlight unless "Show highlights of rejected comments" is on; then it is grey, and stronger when selected.
// - Two highlights with exactly the same rectangle (the "similar" pair of the sample session, two comments on one
//   passage) are drawn once: two translucent layers would add up to the strength of a selected highlight. The one kept
//   is the selected comment's, else the first of own, pending, approved, question, rejected, else the earlier one.

/// One rectangle the PDF shows for a comment or a conversation (section 7.3).
struct ReaderHighlight: Hashable {
    var ownerID: UUID                    // the comment or conversation; the annotation's userName is "referee:" + this id
    var rect: PageRect
    var style: Theme.Highlight
    var isSelected: Bool
    var isFuzzy: Bool                    // a fuzzy anchor also gets a dashed border in its hue

    var alpha: CGFloat { Theme.highlightAlpha(style, selected: isSelected) }
    var color: NSColor { Theme.highlightColor(style, selected: isSelected) }
    var hue: NSColor { Theme.highlightHue(style) }
}

enum ReaderHighlightPlan {
    /// The highlights for these comments and conversations, at most one per rectangle, ordered by page, then from the
    /// top of the page down, then from left to right.
    static func highlights(comments: [ReviewComment], conversations: [Conversation], filter: CommentFilter,
                           selectedCommentID: UUID?, showRejected: Bool) -> [ReaderHighlight] {
        var candidates: [ReaderHighlight] = []
        for comment in comments where matches(comment, filter) {
            guard let style = style(of: comment, showRejected: showRejected) else { continue }
            let fuzzy = isFuzzy(comment.anchor.confidence)
            for rect in comment.anchor.rects where isDrawable(rect) {
                candidates.append(ReaderHighlight(ownerID: comment.id, rect: rect, style: style, isSelected: comment.id == selectedCommentID,
                                                  isFuzzy: fuzzy))
            }
        }
        for conversation in conversations {
            guard let anchor = conversation.anchor else { continue }
            let fuzzy = isFuzzy(anchor.confidence)
            for rect in anchor.rects where isDrawable(rect) {
                candidates.append(ReaderHighlight(ownerID: conversation.id, rect: rect, style: .question, isSelected: false, isFuzzy: fuzzy))
            }
        }

        // One highlight per rectangle: the strongest claim wins, ties keep the earlier candidate.
        var kept: [PageRect: (rank: Int, highlight: ReaderHighlight)] = [:]
        for highlight in candidates {
            let rank = self.rank(of: highlight)
            if let known = kept[highlight.rect], known.rank <= rank { continue }
            kept[highlight.rect] = (rank, highlight)
        }
        return kept.values.map(\.highlight).sorted { left, right in
            if left.rect.pageIndex != right.rect.pageIndex { return left.rect.pageIndex < right.rect.pageIndex }
            if left.rect.y + left.rect.height != right.rect.y + right.rect.height {
                return left.rect.y + left.rect.height > right.rect.y + right.rect.height     // page space: larger y is higher up
            }
            if left.rect.x != right.rect.x { return left.rect.x < right.rect.x }
            return left.ownerID.uuidString < right.ownerID.uuidString
        }
    }

    /// The colour a comment's highlight has, or nil when it has none (a rejected AI comment with the setting off).
    static func style(of comment: ReviewComment, showRejected: Bool) -> Theme.Highlight? {
        if case .user = comment.origin { return .own }
        switch comment.status {
        case .pending: return .pending
        case .approved: return .approved
        case .rejected: return showRejected ? .rejected : nil
        }
    }

    /// The sidebar's filter, as `ReviewSessionModel.visibleComments` applies it (Appendix A.9).
    static func matches(_ comment: ReviewComment, _ filter: CommentFilter) -> Bool {
        switch filter {
        case .all: return true
        case .pending: return comment.status == .pending
        case .approved: return comment.status == .approved
        case .rejected: return comment.status == .rejected
        case .kind(let kind): return comment.kind == kind
        }
    }

    private static func isFuzzy(_ confidence: AnchorConfidence) -> Bool {
        if case .fuzzy = confidence { return true }
        return false
    }

    /// A rectangle PDFKit can draw: finite, not empty, on a page.
    private static func isDrawable(_ rect: PageRect) -> Bool {
        rect.pageIndex >= 0 && rect.width > 0 && rect.height > 0
            && [rect.x, rect.y, rect.width, rect.height].allSatisfy { $0.isFinite }
    }

    /// Lower wins: the selected comment, then own, pending, approved, question, rejected.
    private static func rank(of highlight: ReaderHighlight) -> Int {
        if highlight.isSelected { return 0 }
        switch highlight.style {
        case .own: return 1
        case .pending: return 2
        case .approved: return 3
        case .question: return 4
        case .rejected: return 5
        }
    }
}
