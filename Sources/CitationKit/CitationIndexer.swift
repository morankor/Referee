import Foundation
import RefereeCore

/// Builds the citation index of a paper (plan.md section 8): finds and splits the reference list, parses each entry,
/// finds the in-text citations by text pattern and by link annotation, and merges the two paths.
///
/// Pure: the same paper and links always give the same index. It reads only `.body` lines, so it expects the finished
/// `PaperText` (margin numbers stripped, clean line bounds). Text-pattern mentions come back with `rects == []`; the
/// caller fills them with `PaperService.rects(for:in:)`.
public struct CitationIndexer: CitationIndexing {
    public init() {}

    public func buildIndex(paper: PaperText, links: [RawLink]) -> CitationIndex {
        CitationAnalysis(paper: paper, links: links).index
    }
}
