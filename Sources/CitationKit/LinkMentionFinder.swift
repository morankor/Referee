import Foundation
import RefereeCore

/// In-text citations from internal link annotations (plan.md section 8.5). Mentions come back with rectangles and no
/// spans, source `.linkAnnotation`, one target entry each, in the order of the links, with provisional ids.
enum LinkMentionFinder {
    /// What the link path needs to know of an entry.
    struct Target {
        var id: Int
        var firstLine: PageRect
    }

    /// The vertical extent of the reference list's lines on one page.
    struct ListExtent {
        var bottom: Double          // the bottom of the lowest line
        var top: Double             // the top of the highest line
    }

    struct Result {
        var mentions: [CitationMention]
        var pieces: Int             // internal links taken as citation pieces
        var ignored: Int            // other internal links (equations, tables, sections, …)
    }

    static func find(links: [RawLink], style: CitationStyle, targets: [Target], extents: [Int: ListExtent]) -> Result {
        var pieces: [(link: RawLink, entry: Int)] = []
        var ignored = 0
        for link in links.enumerated().sorted(by: { ($0.element.pageIndex, $0.offset) < ($1.element.pageIndex, $1.offset) }).map(\.element) {
            guard case .internalDestination(let page, let x, let y) = link.target else { continue }
            guard let extent = extents[page], y >= extent.bottom, y <= extent.top + 30,
                  let entry = targetEntry(page: page, x: x, y: y, targets: targets) else {
                ignored += 1
                continue
            }
            pieces.append((link, entry))
        }

        var mentions: [CitationMention] = []
        var closed = true
        for piece in pieces {
            let text = piece.link.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if style == .authorYear, !closed, let last = mentions.last, last.entryIDs == [piece.entry], last.pageIndex == piece.link.pageIndex,
               let previous = last.rects.last, continues(previous, with: piece.link.bounds) {
                mentions[mentions.count - 1].rects.append(piece.link.bounds)
                mentions[mentions.count - 1].text = joinPieces(last.text, text)
                closed = isYear(text)
                continue
            }
            mentions.append(CitationMention(id: mentions.count, pageIndex: piece.link.pageIndex, text: text, rects: [piece.link.bounds],
                                            entryIDs: [piece.entry], source: .linkAnnotation))
            closed = isYear(text)
        }
        return Result(mentions: mentions, pieces: pieces.count, ignored: ignored)
    }

    /// Among the entries whose first line is on the destination page, those within 60 pt of the destination's x (all of
    /// them if none is); of those, the one whose first-line top is the highest still at or below y + 4, else the nearest.
    static func targetEntry(page: Int, x: Double, y: Double, targets: [Target]) -> Int? {
        let onPage = targets.filter { $0.firstLine.pageIndex == page }
        guard !onPage.isEmpty else { return nil }
        let near = onPage.filter { abs($0.firstLine.x - x) <= 60 }
        let pool = near.isEmpty ? onPage : near
        func top(_ target: Target) -> Double { target.firstLine.y + target.firstLine.height }
        let below = pool.filter { top($0) <= y + 4 }
        if let best = below.max(by: { top($0) < top($1) }) { return best.id }
        return pool.min(by: { abs(top($0) - y) < abs(top($1) - y) })?.id
    }

    /// A new piece continues the last one: on the same line with a gap under 12 pt, or on the next line down, starting
    /// further left.
    static func continues(_ previous: PageRect, with next: PageRect) -> Bool {
        let previousMid = previous.y + previous.height / 2
        let nextMid = next.y + next.height / 2
        let height = max(previous.height, next.height, 1)
        let gap = next.x - (previous.x + previous.width)
        if abs(previousMid - nextMid) < max(3, 0.3 * height) { return gap > -2 && gap < 12 }
        let drop = previousMid - nextMid
        return drop > 0.5 * height && drop < max(40, 2.5 * height) && next.x < previous.x
    }

    /// A piece whose text is just a year ("1998", "2019a") closes the mention.
    static func isYear(_ text: String) -> Bool {
        let core = String(text.unicodeScalars.filter(Folding.isLetterOrDigit).map(Character.init))
        guard core.unicodeScalars.count == 4 || core.unicodeScalars.count == 5 else { return false }
        return Patterns.year.first(in: core as NSString).map { $0.range.location == 0 && $0.range.length == (core as NSString).length } ?? false
    }

    /// "Avery and Zem-" + "sky" -> "Avery and Zemsky"; otherwise a space between pieces.
    static func joinPieces(_ text: String, _ piece: String) -> String {
        guard !piece.isEmpty else { return text }
        guard !text.isEmpty else { return piece }
        if EntryText.endsInWordHyphen(text), piece.first?.isLowercase == true { return String(text.dropLast()) + piece }
        return text + " " + piece
    }
}
