import Foundation
import PDFKit
import RefereeCore

// The raw selection of plan.md section 7.4. The view calls it on the main actor with the display document's selection;
// ReviewSessionModel then normalises the result against PaperText (SelectionNormalizer) and asks the paper service for
// clean rectangles, so nothing here removes margin numbers, watermarks or page furniture.

@MainActor public enum SelectionInfoBuilder {
    /// The selection exactly as PDFKit reports it: one span and one rectangle per line. Not normalised (section 7.4).
    ///
    /// Per line selection (`selectionsByLine()`) and per page it lies on: a span for each text range (`range(at:on:)`; on
    /// every page examined a line has exactly one) without its leading and trailing line breaks, and the line's bounds.
    /// A selection ranged by hand includes the line break that ends it (PDFKit reports {697, 85} for a selection made
    /// from {697, 84}), which is why the breaks are trimmed. `text` is the selection's own string, line breaks, margin
    /// digits and all. Pages of another document are skipped. nil when no text is selected.
    public static func make(from selection: PDFSelection, in document: PDFDocument) -> SelectionInfo? {
        var spans: [TextSpan] = []
        var rects: [PageRect] = []
        var strings: [Int: NSString] = [:]
        let lines = selection.selectionsByLine()
        for line in lines.isEmpty ? [selection] : lines {
            for page in line.pages {
                let pageIndex = document.index(for: page)
                guard pageIndex != NSNotFound else { continue }
                let string = strings[pageIndex] ?? ((page.string ?? "") as NSString)
                strings[pageIndex] = string
                var touched = false
                for position in 0..<line.numberOfTextRanges(on: page) {
                    guard let range = trimmed(line.range(at: position, on: page), in: string) else { continue }
                    spans.append(TextSpan(pageIndex: pageIndex, range: TextRange(range)))
                    touched = true
                }
                if touched, let rect = PageGeometry.pageRect(line.bounds(for: page), pageIndex: pageIndex) { rects.append(rect) }
            }
        }
        guard !spans.isEmpty else { return nil }
        return SelectionInfo(text: selection.string ?? "", spans: spans, rects: rects)
    }

    /// `range` inside the page string, without line breaks at either end; nil when nothing else is left.
    private static func trimmed(_ range: NSRange, in string: NSString) -> NSRange? {
        guard var range = PageGeometry.clamped(range, toLength: string.length) else { return nil }
        while range.length > 0, PageGeometry.isLineBreak(string.character(at: range.location)) { range.location += 1; range.length -= 1 }
        while range.length > 0, PageGeometry.isLineBreak(string.character(at: NSMaxRange(range) - 1)) { range.length -= 1 }
        return range.length > 0 ? range : nil
    }
}
