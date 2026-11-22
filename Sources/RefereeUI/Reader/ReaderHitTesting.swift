import Foundation
import CoreGraphics
import RefereeCore

// What a click in the PDF lands on (plan.md sections 7.4, 7.5 and 8.6). Pure: a point in page space and the rectangles
// of that page in, a comment (or conversation) id or a citation mention id out.
//
// Where the plan leaves a choice, this file decides (also in docs/contract-notes/wp9-reader.md): highlights and
// citations are one list, and the smallest rectangle containing the point wins, as section 7.5 says for overlapping
// highlights. A citation inside a highlighted passage is therefore the citation (its rectangle is smaller than the
// line's), and a click on it opens the card instead of selecting the comment and letting PDFKit jump to the
// bibliography. A mention's rectangles count 2 points larger on every side (section 8.6); highlights count as drawn.

enum ReaderHitTarget: Equatable {
    case comment(UUID)       // a comment's highlight, or a conversation's passage (the model tells them apart)
    case mention(Int)        // CitationMention.id
}

enum ReaderHitTesting {
    /// How much larger than drawn a mention's click rectangles are, on every side (section 8.6).
    static let mentionSlack: CGFloat = 2

    /// The target under `point` (page space) on page `pageIndex`: the smallest rectangle that contains it. On equal areas
    /// a mention wins over a highlight, and otherwise the one that comes first.
    static func target(at point: CGPoint, pageIndex: Int, highlights: [ReaderHighlight], mentions: [CitationMention]) -> ReaderHitTarget? {
        var best: (area: CGFloat, isMention: Bool, target: ReaderHitTarget)?
        func consider(_ rect: CGRect, isMention: Bool, target: ReaderHitTarget) {
            guard rect.contains(point) else { return }
            let area = rect.width * rect.height
            if let current = best {
                if area > current.area { return }
                if area == current.area && (current.isMention || !isMention) { return }
            }
            best = (area, isMention, target)
        }
        for mention in mentions {
            for rect in mention.rects where rect.pageIndex == pageIndex {
                consider(clickRect(of: rect), isMention: true, target: .mention(mention.id))
            }
        }
        for highlight in highlights where highlight.rect.pageIndex == pageIndex {
            consider(highlight.rect.cgRect.standardized, isMention: false, target: .comment(highlight.ownerID))
        }
        return best?.target
    }

    /// The mention under `point`, ignoring highlights: what the cursor shows (`areaOfInterest`).
    static func mention(at point: CGPoint, pageIndex: Int, mentions: [CitationMention]) -> Int? {
        if case .mention(let id)? = target(at: point, pageIndex: pageIndex, highlights: [], mentions: mentions) { return id }
        return nil
    }

    /// A mention rectangle as it is clicked: 2 points larger on every side.
    static func clickRect(of rect: PageRect) -> CGRect {
        rect.cgRect.standardized.insetBy(dx: -mentionSlack, dy: -mentionSlack)
    }
}
