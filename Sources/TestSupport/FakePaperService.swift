import Foundation
import RefereeCore

/// load returns `paper`; rects(for:in:) returns one rectangle per span (x 100, width 200, on the span's page).
///
/// Both `load` functions return the paper whatever they are given, and nothing is read from disk. A rectangle's `y`
/// and `height` are those of the text line in which the span starts, when the paper knows that line's bounds (papers
/// from `makeSamplePaper` do); otherwise `y` is 100 and `height` 12.
public final class FakePaperService: PaperService, @unchecked Sendable {
    private let paper: LoadedPaper

    public init(paper: LoadedPaper) { self.paper = paper }

    public func load(url: URL) async throws -> LoadedPaper { paper }

    public func load(data: Data, fileName: String) async throws -> LoadedPaper { paper }

    public func rects(for spans: [TextSpan], in document: DocumentRef) async -> [PageRect] {
        spans.map { span in
            let line = paper.text.pages.first { $0.index == span.pageIndex }?.lines.first { line in
                line.range.location <= span.range.location && span.range.location < max(line.range.upperBound, line.range.location + 1)
            }
            return PageRect(pageIndex: span.pageIndex, x: 100, y: line?.bounds?.y ?? 100, width: 200, height: line?.bounds?.height ?? 12)
        }
    }

    public func unload(_ document: DocumentRef) async {}
}
