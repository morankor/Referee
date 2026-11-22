import Foundation
import RefereeCore

/// The one display order of comments (plan.md Appendix A.9, `ReviewSessionModel.visibleComments`): by page, then by
/// the position of the first span's line in that page's `PageText.lines`, then by creation time. A comment with a page
/// but no span (`.pageOnly`) comes first on its page; a comment with no page (`.none`) comes last. Pure.
///
/// Details the plan leaves open: a comment's page is that of its first span, else `anchor.pageIndex`; a span that
/// starts between two lines counts as being on the line before; without the paper's text (or for a page the text does
/// not have) the span's offset stands in for the line position; comments equal in all three keys keep their stored order.
enum CommentOrdering {
    static func sorted(_ comments: [ReviewComment], in text: PaperText?) -> [ReviewComment] {
        var pages: [Int: PageText] = [:]
        for page in text?.pages ?? [] where pages[page.index] == nil { pages[page.index] = page }
        let keyed = comments.enumerated().map { position, comment in (key: key(for: comment, position: position, pages: pages), comment: comment) }
        return keyed.sorted { $0.key < $1.key }.map(\.comment)
    }

    static func matches(_ comment: ReviewComment, _ filter: CommentFilter) -> Bool {
        switch filter {
        case .all: return true
        case .pending: return comment.status == .pending
        case .approved: return comment.status == .approved
        case .rejected: return comment.status == .rejected
        case .kind(let kind): return comment.kind == kind
        }
    }

    private struct Key: Comparable {
        var unplaced: Int       // 0: the comment has a page; 1: it has none and goes last
        var page: Int
        var line: Int           // -1: no span, first on its page
        var createdAt: Date
        var position: Int       // stored order, the last tie-break

        static func < (left: Key, right: Key) -> Bool {
            if left.unplaced != right.unplaced { return left.unplaced < right.unplaced }
            if left.page != right.page { return left.page < right.page }
            if left.line != right.line { return left.line < right.line }
            if left.createdAt != right.createdAt { return left.createdAt < right.createdAt }
            return left.position < right.position
        }
    }

    private static func key(for comment: ReviewComment, position: Int, pages: [Int: PageText]) -> Key {
        let anchor = comment.anchor
        guard let page = anchor.spans.first?.pageIndex ?? anchor.pageIndex else {
            return Key(unplaced: 1, page: 0, line: 0, createdAt: comment.createdAt, position: position)
        }
        guard let span = anchor.spans.first else {
            return Key(unplaced: 0, page: page, line: -1, createdAt: comment.createdAt, position: position)
        }
        return Key(unplaced: 0, page: page, line: linePosition(of: span, in: pages[span.pageIndex]), createdAt: comment.createdAt,
                   position: position)
    }

    /// The position in `PageText.lines` of the last line that starts at or before the span.
    private static func linePosition(of span: TextSpan, in page: PageText?) -> Int {
        guard let page, !page.lines.isEmpty else { return span.range.location }
        var found = 0
        for (index, line) in page.lines.enumerated() {
            if line.range.location <= span.range.location { found = index } else { break }
        }
        return found
    }
}
