import Foundation
import RefereeCore

// Wave 0a placeholder (see Placeholder.swift).

/// Exact substring search inside single lines of the body text; label "p. N".
/// Placeholder: nothing is found and the label is empty.
public struct FakeQuoteMatcher: QuoteMatching {
    public init(paper: PaperText) {}

    public func locate(quote: String, pageHint: Int?) -> AnchorMatch? { nil }

    public func locationLabel(for spans: [TextSpan]) -> String { "" }
}
