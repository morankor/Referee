import SwiftUI
import PDFKit

// A PDF view in the SwiftUI hierarchy (plan.md section 7.4). The view belongs to its controller (the manuscript's
// ReaderController, or the reference viewer's) and outlives this wrapper: SwiftUI only places it.
//
// No size is declared, on purpose. With the composition of section 9.2, SwiftUI on macOS 26 adds the inspector's width
// to whatever minimum the detail column declares: a minimum here makes the smallest possible window wider than 1280
// points, and every review scene fails (docs/contract-notes/wp0b-testsupport.md, contract problem 1).

struct ReaderPDFViewRepresentable: NSViewRepresentable {
    let pdfView: PDFView

    func makeNSView(context: Context) -> PDFView { pdfView }

    func updateNSView(_ nsView: PDFView, context: Context) {}
}

// A page-thumbnail column bound to a PDF view (section 7.6, the navigator's Pages tab, and the reference viewer).
struct ReaderThumbnailsRepresentable: NSViewRepresentable {
    let pdfView: PDFView

    func makeNSView(context: Context) -> ReaderThumbnailView {
        let thumbnails = ReaderThumbnailView()
        thumbnails.pdfView = pdfView
        thumbnails.maximumNumberOfColumns = 1
        thumbnails.allowsDragging = false
        thumbnails.allowsMultipleSelection = false
        thumbnails.backgroundColor = .clear
        thumbnails.labelFont = .systemFont(ofSize: NSFont.smallSystemFontSize)
        thumbnails.thumbnailSize = ReaderThumbnailView.thumbnailSize(forWidth: 200)
        return thumbnails
    }

    func updateNSView(_ thumbnails: ReaderThumbnailView, context: Context) {
        if thumbnails.pdfView !== pdfView { thumbnails.pdfView = pdfView }
    }

    /// Takes the room it is offered and asks for no minimum, so the column decides the width. Nothing about the view
    /// changes here: a hosted view whose metrics change during sizing makes SwiftUI lay the window out again, for ever.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView thumbnails: ReaderThumbnailView, context: Context) -> CGSize? {
        func finite(_ value: CGFloat?, otherwise fallback: CGFloat) -> CGFloat {
            guard let value, value.isFinite, value >= 0 else { return fallback }
            return value
        }
        return CGSize(width: finite(proposal.width, otherwise: 160), height: finite(proposal.height, otherwise: 300))
    }
}

/// A thumbnail column whose thumbnails follow its width: US-letter-shaped, 36 points narrower than the view, so that
/// the label and the selection frame fit.
final class ReaderThumbnailView: PDFThumbnailView {
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let wanted = Self.thumbnailSize(forWidth: newSize.width)
        if abs(wanted.width - thumbnailSize.width) > 1 { thumbnailSize = wanted }
    }

    static func thumbnailSize(forWidth width: CGFloat) -> CGSize {
        let thumbnailWidth = max(60, width - 36)
        return CGSize(width: thumbnailWidth, height: (thumbnailWidth * 11 / 8.5).rounded())
    }
}
