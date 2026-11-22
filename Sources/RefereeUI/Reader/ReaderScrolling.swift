import AppKit
import PDFKit

// Scrolling a PDF view to a passage, for `.reveal` (plan.md section 7.4) and for find matches (section 7.6).
//
// `PDFView.go(to:)` puts a selection or rectangle at the top edge of the view, where the find bar lies over it, and on
// the fixtures it scrolled or did not depending on the timing of layout. So both scroll the view's own scroll view:
// the top of the passage one third of the way down the visible area, clamped at the ends of the document, and the
// horizontal position kept unless the passage lies outside it.

@MainActor enum ReaderScrolling {
    /// Scrolls so that `rect` (page space, on `page`) has its top edge one third of the way down the visible area.
    static func reveal(_ rect: CGRect, on page: PDFPage, in pdfView: PDFView) {
        guard let documentView = pdfView.documentView, let clipView = documentView.enclosingScrollView?.contentView else {
            pdfView.go(to: rect, on: page)
            return
        }
        let target = documentView.convert(pdfView.convert(rect, from: page), from: pdfView)
        var visible = clipView.documentVisibleRect
        if documentView.isFlipped {
            visible.origin.y = target.minY - visible.height / 3
        } else {
            visible.origin.y = target.maxY + visible.height / 3 - visible.height
        }
        if target.minX < visible.minX || target.maxX > visible.maxX {
            visible.origin.x = target.minX - ReaderOverlayPlacement.margin * 3
        }
        let bounds = documentView.bounds
        visible.origin.y = min(max(visible.origin.y, bounds.minY), max(bounds.minY, bounds.maxY - visible.height))
        visible.origin.x = min(max(visible.origin.x, bounds.minX), max(bounds.minX, bounds.maxX - visible.width))
        documentView.scroll(visible.origin)
    }

    /// Whether `rect` (page space, on `page`) lies wholly inside the view and at least `topInset` points below its top.
    static func isInSight(_ rect: CGRect, on page: PDFPage, in pdfView: PDFView, topInset: CGFloat = 0) -> Bool {
        let inView = pdfView.convert(rect, from: page)
        let bounds = pdfView.bounds
        let top = pdfView.isFlipped ? inView.minY : bounds.height - inView.maxY
        let bottom = pdfView.isFlipped ? inView.maxY : bounds.height - inView.minY
        return inView.minX >= bounds.minX && inView.maxX <= bounds.maxX && top >= topInset && bottom <= bounds.height
    }
}
