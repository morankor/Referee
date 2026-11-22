import Foundation
import RefereeCore

// Wave 0 placeholder (plan.md section 11.4, WP0a). WP1 replaces it with the matcher of section 6.7.

public struct QuoteMatcher: QuoteMatching {
    public init(paper: PaperText) {}

    /// Placeholder: no quote is ever located.
    public func locate(quote: String, pageHint: Int?) -> AnchorMatch? { nil }

    /// Placeholder: pages only ("p. 4", "pp. 4–5"), no line numbers; "" for no spans.
    public func locationLabel(for spans: [TextSpan]) -> String {
        guard let first = spans.first, let last = spans.last else { return "" }
        if first.pageIndex == last.pageIndex { return "p. \(first.pageIndex + 1)" }
        return "pp. \(first.pageIndex + 1)–\(last.pageIndex + 1)"
    }
}
