import Foundation
import PDFKit
import RefereeCore

// Raw extraction, plan.md section 7.2. Written in Wave 0 in its simplest working form, because the committed dumps under
// Fixtures/raw are made with it (`referee-cli dump-raw`), and completed in WP2. Its output for the committed PDFs must stay
// byte-identical to those dumps: PaperText and CitationKit are tested against them, and PDFBridgeSmokeTests compares.
//
// Only the PDFKit calls that section 7.2 lists as consistent with `PDFPage.string` are used for text and geometry:
// `page.string`, `page.selection(for: NSRange)`, `selectionsByLine()`, `numberOfTextRanges(on:)`, `range(at:on:)`,
// `bounds(for:)`, `string`, `page.selection(for: CGRect)`, and the annotations' actions, destinations and URLs.
// Never `characterBounds(at:)` or `characterIndex(at:)`.

public enum RawExtractor {
    /// Pages with their lines, every link annotation, and the outline, exactly as PDFKit reports them.
    ///
    /// Each line is one line selection of the whole page: the first text range of that selection with its trailing line
    /// breaks removed, the text at that range, and the selection's bounds. On every page examined PDFKit gives these in
    /// string order and without overlap; where it does not, the lines are put in string order and a line that overlaps
    /// the one before keeps only its part after it, so that `RawPage.lines` always has increasing, non-overlapping ranges.
    /// The number of lines is unrelated to the number of line breaks in the page's string.
    public static func extract(from document: PDFDocument) -> RawDocument {
        var pages: [RawPage] = []
        var links: [RawLink] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let string = page.string ?? ""
            let size = page.bounds(for: .mediaBox).size
            pages.append(RawPage(index: index, label: page.label, size: PageSize(width: finite(size.width), height: finite(size.height)),
                                 string: string, lines: lines(of: page, index: index, string: string)))
            links += self.links(of: page, index: index, in: document)
        }
        return RawDocument(pages: pages, links: links, outline: outline(of: document))
    }

    // MARK: - Lines

    private static func lines(of page: PDFPage, index: Int, string: String) -> [RawLine] {
        let text = string as NSString
        guard text.length > 0, let whole = page.selection(for: NSRange(location: 0, length: text.length)) else { return [] }

        var found: [(range: NSRange, selection: PDFSelection)] = []
        for selection in whole.selectionsByLine() where selection.numberOfTextRanges(on: page) > 0 {
            var range = selection.range(at: 0, on: page)
            guard range.location != NSNotFound, range.location >= 0, range.length >= 0, NSMaxRange(range) <= text.length else { continue }
            while range.length > 0, PageGeometry.isLineBreak(text.character(at: NSMaxRange(range) - 1)) { range.length -= 1 }
            found.append((range, selection))
        }
        if !found.indices.dropFirst().allSatisfy({ found[$0 - 1].range.location <= found[$0].range.location }) {
            found.sort { $0.range.location < $1.range.location }        // stable: lines that start together keep PDFKit's order
        }

        var lines: [RawLine] = []
        var end = 0
        for (range, selection) in found {
            if range.location >= end {
                lines.append(RawLine(range: TextRange(range), text: text.substring(with: range),
                                     bounds: PageGeometry.pageRect(selection.bounds(for: page), pageIndex: index)))
                end = NSMaxRange(range)
            } else if NSMaxRange(range) > end {
                let rest = NSRange(location: end, length: NSMaxRange(range) - end)
                lines.append(RawLine(range: TextRange(rest), text: text.substring(with: rest),
                                     bounds: PageGeometry.pageRect(page.selection(for: rest)?.bounds(for: page), pageIndex: index)))
                end = NSMaxRange(rest)
            }
        }
        return lines
    }

    // MARK: - Links

    /// Every annotation of type Link: its target from the action, else from the annotation's own destination or URL,
    /// and the text PDFKit finds under its rectangle.
    private static func links(of page: PDFPage, index: Int, in document: PDFDocument) -> [RawLink] {
        page.annotations.filter { $0.type == "Link" }.map { annotation in
            let bounds = PageGeometry.pageRect(annotation.bounds, pageIndex: index) ?? PageRect(pageIndex: index, x: 0, y: 0, width: 0, height: 0)
            return RawLink(pageIndex: index, bounds: bounds, text: page.selection(for: annotation.bounds)?.string ?? "",
                           target: target(of: annotation, in: document))
        }
    }

    private static func target(of annotation: PDFAnnotation, in document: PDFDocument) -> RawLinkTarget {
        if let action = annotation.action as? PDFActionGoTo, let target = internalTarget(action.destination, in: document) { return target }
        if let action = annotation.action as? PDFActionURL, let url = action.url { return .url(url.absoluteString) }
        if let destination = annotation.destination, let target = internalTarget(destination, in: document) { return target }
        if let url = annotation.url { return .url(url.absoluteString) }
        return .other
    }

    private static func internalTarget(_ destination: PDFDestination, in document: PDFDocument) -> RawLinkTarget? {
        guard let pageIndex = index(of: destination.page, in: document) else { return nil }
        return .internalDestination(pageIndex: pageIndex, x: finite(destination.point.x), y: finite(destination.point.y))
    }

    // MARK: - Outline

    /// The outline in preorder; top-level items have depth 0. An item's page comes from its destination, else from the
    /// destination of its go-to action.
    private static func outline(of document: PDFDocument) -> [OutlineItem] {
        var items: [OutlineItem] = []
        func walk(_ node: PDFOutline, depth: Int) {
            for position in 0..<node.numberOfChildren {
                guard let child = node.child(at: position) else { continue }
                let destination = child.destination ?? (child.action as? PDFActionGoTo)?.destination
                items.append(OutlineItem(id: items.count, title: child.label ?? "", pageIndex: index(of: destination?.page, in: document),
                                         depth: depth))
                walk(child, depth: depth + 1)
            }
        }
        if let root = document.outlineRoot { walk(root, depth: 0) }
        return items
    }

    // MARK: - Helpers

    private static func index(of page: PDFPage?, in document: PDFDocument) -> Int? {
        guard let page else { return nil }
        let index = document.index(for: page)
        return index == NSNotFound ? nil : index
    }

    /// A coordinate as a Double, with 0 for a value that is not finite (JSON cannot hold one).
    private static func finite(_ value: CGFloat) -> Double {
        value.isFinite ? Double(value) : 0
    }
}
