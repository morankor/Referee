import Foundation
import RefereeCore

/// Returns `index` whatever the input; nil = an index with style .unknown, no entries and no mentions.
public struct FakeCitationIndexer: CitationIndexing {
    private let index: CitationIndex

    public init(index: CitationIndex? = nil) { self.index = index ?? CitationIndex(style: .unknown) }

    public func buildIndex(paper: PaperText, links: [RawLink]) -> CitationIndex { index }
}
