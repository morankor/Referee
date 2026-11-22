import Foundation
import PDFKit
import RefereeCore

// Written in Wave 0 (plan.md section 11.4, WP0b) in its simplest working form, because the committed raw dumps under
// Fixtures/raw are made with it. WP2 owns, tests and completes it (section 7.2, "Raw extraction").
//
// Only the PDFKit calls that section 7.2 lists as index-consistent with `PDFPage.string` are used.

public enum RawExtractor {
    /// Pages with their lines, every link annotation, and the outline, exactly as PDFKit reports them.
    public static func extract(from document: PDFDocument) -> RawDocument {
        var pages: [RawPage] = []
        var links: [RawLink] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let string = page.string ?? ""
            let size = page.bounds(for: .mediaBox).size
            pages.append(RawPage(index: index, label: page.label, size: PageSize(width: Double(size.width), height: Double(size.height)),
                                 string: string, lines: lines(of: page, index: index, string: string)))
            links += self.links(of: page, index: index, in: document)
        }
        return RawDocument(pages: pages, links: links, outline: outline(of: document))
    }

    /// One line per line selection of the whole page: its range without trailing line breaks, the text at that range,
    /// and the selection's bounds. The number of lines is unrelated to the number of line breaks in `string`.
    private static func lines(of page: PDFPage, index: Int, string: String) -> [RawLine] {
        let text = string as NSString
        guard text.length > 0, let whole = page.selection(for: NSRange(location: 0, length: text.length)) else { return [] }
        var lines: [RawLine] = []
        for selection in whole.selectionsByLine() where selection.numberOfTextRanges(on: page) > 0 {
            var range = selection.range(at: 0, on: page)
            guard range.location != NSNotFound, range.location >= 0, NSMaxRange(range) <= text.length else { continue }
            while range.length > 0, isLineBreak(text.character(at: NSMaxRange(range) - 1)) { range.length -= 1 }
            lines.append(RawLine(range: TextRange(range), text: text.substring(with: range),
                                 bounds: pageRect(selection.bounds(for: page), index)))
        }
        return lines
    }

    private static func isLineBreak(_ unit: unichar) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029
    }

    /// Every annotation of type Link: its target from the action, else from the annotation's own destination or URL,
    /// and the text PDFKit finds under its rectangle.
    private static func links(of page: PDFPage, index: Int, in document: PDFDocument) -> [RawLink] {
        page.annotations.filter { $0.type == "Link" }.map { annotation in
            RawLink(pageIndex: index, bounds: pageRect(annotation.bounds, index),
                    text: page.selection(for: annotation.bounds)?.string ?? "", target: target(of: annotation, in: document))
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
        guard let page = destination.page else { return nil }
        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound else { return nil }
        return .internalDestination(pageIndex: pageIndex, x: Double(destination.point.x), y: Double(destination.point.y))
    }

    /// The outline in preorder; top-level items have depth 0.
    private static func outline(of document: PDFDocument) -> [OutlineItem] {
        var items: [OutlineItem] = []
        func walk(_ node: PDFOutline, depth: Int) {
            for position in 0..<node.numberOfChildren {
                guard let child = node.child(at: position) else { continue }
                let pageIndex = child.destination?.page.map { document.index(for: $0) }
                items.append(OutlineItem(id: items.count, title: child.label ?? "", pageIndex: pageIndex == NSNotFound ? nil : pageIndex,
                                         depth: depth))
                walk(child, depth: depth + 1)
            }
        }
        if let root = document.outlineRoot { walk(root, depth: 0) }
        return items
    }

    private static func pageRect(_ rect: CGRect, _ index: Int) -> PageRect {
        PageRect(pageIndex: index, x: Double(rect.origin.x), y: Double(rect.origin.y), width: Double(rect.size.width), height: Double(rect.size.height))
    }
}
