import Foundation
import RefereeCore

// Wave 0 placeholder (plan.md section 11.4, WP0a). WP3 implements the indexer (section 8).

public struct CitationIndexer: CitationIndexing {
    public init() {}

    /// Placeholder: an empty index (no entries, no mentions, style unknown).
    public func buildIndex(paper: PaperText, links: [RawLink]) -> CitationIndex {
        CitationIndex(style: .unknown)
    }
}
