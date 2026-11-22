import Foundation
import RefereeCore
import TestSupport
@testable import CitationKit

/// One line of a synthetic page: its text, left edge and height. Lines are laid out top to bottom at a fixed pitch.
struct SyntheticLine: ExpressibleByStringLiteral {
    var text: String
    var x: Double = 72
    var height: Double = 10

    init(_ text: String, x: Double = 72, height: Double = 10) {
        self.text = text
        self.x = x
        self.height = height
    }

    init(stringLiteral value: String) { self.init(value) }

    /// A continuation line of a hanging list.
    static func indented(_ text: String) -> SyntheticLine { SyntheticLine(text, x: 84) }
}

/// Synthetic documents and the fixtures, as the indexer sees them.
enum CitationTestDocuments {
    /// Pages of lines, each line a `.body` line whose range is its place in the page string (lines joined by "\n").
    /// Bounds: x as given, width 5.5 pt per character, height as given, baselines 14 pt apart from y = 740 down.
    static func paper(pages: [[SyntheticLine]], withBounds: Bool = true) -> PaperText {
        var result: [PageText] = []
        for (pageIndex, lines) in pages.enumerated() {
            var string = ""
            var textLines: [TextLine] = []
            for (i, line) in lines.enumerated() {
                if i > 0 { string += "\n" }
                let range = TextRange(location: string.utf16.count, length: line.text.utf16.count)
                string += line.text
                let bounds = PageRect(pageIndex: pageIndex, x: line.x, y: 740 - 14 * Double(i), width: 5.5 * Double(line.text.count),
                                      height: line.height)
                textLines.append(TextLine(pageIndex: pageIndex, range: range, contentRange: range, text: line.text, kind: .body,
                                          bounds: withBounds ? bounds : nil))
            }
            result.append(PageText(index: pageIndex, size: PageSize(width: 612, height: 792), string: string, lines: textLines))
        }
        return PaperText(pages: result, hasTextLayer: true, hasMarginLineNumbers: false)
    }

    /// One page.
    static func paper(_ lines: [SyntheticLine], withBounds: Bool = true) -> PaperText { paper(pages: [lines], withBounds: withBounds) }

    /// A fixture as the indexer sees it in this worktree: every raw line a `.body` line (`identityPaperText`), and the
    /// raw link annotations.
    static func fixture(_ name: String) throws -> (paper: PaperText, links: [RawLink]) {
        let raw = try Fixtures.rawDocument(name)
        return (identityPaperText(from: raw), raw.links)
    }

    /// A body paragraph followed by an author–year reference list of hanging entries.
    static func authorYear(body: [String], references: [String]) -> PaperText {
        paper(body.map { SyntheticLine($0) } + ["References"] + references.map { SyntheticLine($0) })
    }

    /// The first surname of each entry a mention points to, joined by "/" when there are several.
    static func firstAuthors(of mention: CitationMention, in index: CitationIndex) -> String {
        mention.entryIDs.map { index.entries[$0].parsed.authorSurnames.first ?? "?" }.joined(separator: "/")
    }

    /// The page-string text just before a mention's first span and just after its last one.
    static func surroundings(of mention: CitationMention, in paper: PaperText, width: Int = 12) -> (before: String, after: String) {
        guard let first = mention.spans.first, let last = mention.spans.last else { return ("", "") }
        let start = paper.pages[first.pageIndex].string as NSString
        let end = paper.pages[last.pageIndex].string as NSString
        let beforeStart = max(0, first.range.location - width)
        let before = start.substring(with: NSRange(location: beforeStart, length: first.range.location - beforeStart))
        let afterLength = min(width, end.length - last.range.upperBound)
        let after = end.substring(with: NSRange(location: last.range.upperBound, length: max(0, afterLength)))
        return (before, after)
    }

    /// The text of the page string under a span.
    static func text(of span: TextSpan, in paper: PaperText) -> String {
        (paper.pages[span.pageIndex].string as NSString).substring(with: span.range.nsRange)
    }
}
