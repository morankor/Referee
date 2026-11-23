import AppKit
import PDFKit
import RefereeCore

// Highlights without touching the file (plan.md section 7.3): annotations on the pages of the display document, which
// has no URL and is never written, so they exist in memory only. Whenever the desired list changes, this controller
// removes the annotations that are no longer wanted and adds the missing ones; PDFKit draws, scrolls and zooms them.
//
// Decisions (also in docs/contract-notes/wp9-reader.md):
// - PDFKit ignores the border of markup annotations (PDFAnnotation.h: "Highlight, Strikethrough, Underline ignores the
//   border"), so a fuzzy anchor's dashed border is a second annotation: a square with the dashed border in the hue and
//   no fill, over the same rectangle. Both carry the userName "referee:<id>".
// - The selected comment's annotations are added after the others, so they lie on top where highlights overlap.
// - The flash of a reveal (section 7.4) is one underline annotation per rectangle in the accent colour, removed after
//   0.8 s or when the next reveal starts.

@MainActor
final class ReaderHighlightController {
    static let userNamePrefix = "referee:"
    static let flashUserName = "referee:flash"
    static let flashDuration: Duration = .milliseconds(800)

    /// What the pages show now, in the plan's order; hit-testing reads it.
    private(set) var shown: [ReaderHighlight] = []

    private weak var pdfView: PDFView?
    private var placed: [ReaderHighlight: [(page: PDFPage, annotation: PDFAnnotation)]] = [:]
    private weak var placedDocument: PDFDocument?
    private var flashAnnotations: [(page: PDFPage, annotation: PDFAnnotation)] = []
    private var flashTask: Task<Void, Never>?

    init(pdfView: PDFView) {
        self.pdfView = pdfView
    }

    /// Makes the display document's highlight annotations exactly `desired`.
    func show(_ desired: [ReaderHighlight]) {
        shown = desired
        guard let pdfView, let document = pdfView.document else {
            placed = [:]
            placedDocument = nil
            return
        }
        if placedDocument !== document {           // a new document: the old annotations went with the old one
            placed = [:]
            placedDocument = document
        }
        var touched: [PDFPage] = []
        func note(_ page: PDFPage) { if !touched.contains(where: { $0 === page }) { touched.append(page) } }

        let wanted = Set(desired)
        for (highlight, annotations) in placed where !wanted.contains(highlight) {
            for (page, annotation) in annotations {
                page.removeAnnotation(annotation)
                note(page)
            }
            placed[highlight] = nil
        }
        for highlight in desired.filter({ !$0.isSelected }) + desired.filter(\.isSelected) where placed[highlight] == nil {
            guard let page = document.page(at: highlight.rect.pageIndex) else { continue }
            let annotations = Self.annotations(for: highlight)
            for annotation in annotations { page.addAnnotation(annotation) }
            placed[highlight] = annotations.map { (page, $0) }
            note(page)
        }
        for page in touched { pdfView.annotationsChanged(on: page) }
    }

    /// Underlines `rects` for 0.8 s (section 7.4, `.reveal(rects, flash: true)`).
    func flash(_ rects: [PageRect]) {
        removeFlash()
        guard let pdfView, let document = pdfView.document else { return }
        for rect in rects {
            guard let page = document.page(at: rect.pageIndex), rect.width > 0, rect.height > 0 else { continue }
            let underline = PDFAnnotation(bounds: rect.cgRect, forType: .underline, withProperties: nil)
            underline.color = NSColor.controlAccentColor
            underline.userName = Self.flashUserName
            page.addAnnotation(underline)
            flashAnnotations.append((page, underline))
            pdfView.annotationsChanged(on: page)
        }
        guard !flashAnnotations.isEmpty else { return }
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: Self.flashDuration)
            guard !Task.isCancelled else { return }
            self?.removeFlash()
        }
    }

    /// The annotations that draw one highlight: the fill, and for a fuzzy anchor the dashed frame.
    static func annotations(for highlight: ReaderHighlight) -> [PDFAnnotation] {
        let bounds = highlight.rect.cgRect.standardized
        let name = userNamePrefix + highlight.ownerID.uuidString
        let fill = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
        fill.color = highlight.color
        fill.userName = name
        guard highlight.isFuzzy else { return [fill] }
        let frame = PDFAnnotation(bounds: bounds, forType: .square, withProperties: nil)
        frame.color = highlight.hue
        let border = PDFBorder()
        border.style = .dashed
        border.lineWidth = Theme.fuzzyBorderWidth
        border.dashPattern = Theme.fuzzyBorderDash.map { NSNumber(value: Double($0)) }
        frame.border = border
        frame.userName = name
        return [fill, frame]
    }

    /// The comment or conversation id in an annotation's userName, nil for any other annotation.
    static func ownerID(of annotation: PDFAnnotation) -> UUID? {
        guard let name = annotation.userName, name.hasPrefix(userNamePrefix) else { return nil }
        return UUID(uuidString: String(name.dropFirst(userNamePrefix.count)))
    }

    private func removeFlash() {
        flashTask?.cancel()
        flashTask = nil
        for (page, annotation) in flashAnnotations {
            page.removeAnnotation(annotation)
            pdfView?.annotationsChanged(on: page)
        }
        flashAnnotations = []
    }
}
