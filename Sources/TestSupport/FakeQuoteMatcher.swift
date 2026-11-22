import Foundation
import RefereeCore

/// Exact substring search inside single lines of the body text; label "p. N".
///
/// The quote must stand, character for character, inside the text of one `.body` line: nothing is folded, and a quote
/// that runs over a line break is not found. With a page hint that page is searched first, then the pages in order.
/// The match is one span with confidence `.exact`. The label names the page of the first span ("p. 3"), and is empty
/// for no spans.
public struct FakeQuoteMatcher: QuoteMatching {
    private let paper: PaperText

    public init(paper: PaperText) { self.paper = paper }

    public func locate(quote: String, pageHint: Int?) -> AnchorMatch? {
        guard !quote.isEmpty else { return nil }
        let hinted = paper.pages.filter { $0.index == pageHint }
        let others = paper.pages.filter { $0.index != pageHint }
        for page in hinted + others {
            for line in page.lines where line.kind == .body {
                guard let found = line.text.range(of: quote) else { continue }
                let offset = line.text.utf16.distance(from: line.text.utf16.startIndex, to: found.lowerBound)
                let span = TextSpan(pageIndex: page.index,
                                    range: TextRange(location: line.contentRange.location + offset, length: quote.utf16.count))
                return AnchorMatch(spans: [span], confidence: .exact)
            }
        }
        return nil
    }

    public func locationLabel(for spans: [TextSpan]) -> String {
        guard let first = spans.first else { return "" }
        return "p. \(first.pageIndex + 1)"
    }
}
