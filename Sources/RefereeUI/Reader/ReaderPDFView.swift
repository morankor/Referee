import AppKit
import PDFKit

// The manuscript's PDF view (plan.md sections 7.4 and 8.6). Two overrides:
//
// - `mouseDown(with:)`: the point goes to page space through ReaderController. A click on one of our highlights selects
//   its comment and then goes on to PDFKit (`super`), so a selection can still start there. A click on a citation opens
//   the citation card and does **not** reach PDFKit: on a hyperref link `super` would jump to the bibliography. The
//   drag and the mouse-up of such a click are kept from PDFKit too, so that nothing of it is seen as a link click.
// - `areaOfInterest(for:)` (a point in view coordinates) and `areaOfInterest(forMouse:)` (an event): PDFKit's own
//   answer, with `.linkArea` added over a citation, so that PDFKit shows the pointing hand over citations that have no
//   link annotation as well (a cursor set elsewhere would be overridden).
//
// Mouse events reach this view through PDFKit's internal page view, which forwards them, so calling `mouseDown(with:)`
// on the view that `window.contentView.hitTest` finds over a citation works without activating the app (section 10.1,
// `check-citation-click`; the scene `reader-citation` opens its card this way).

public final class RefereePDFView: PDFView {             // overrides mouseDown(with:) and areaOfInterest(for:) (section 7.4)
    /// Set by the controller that owns this view; without one the view behaves as a plain PDFView.
    weak var readerController: ReaderController?
    /// True from a mouse-down that hit a citation until its mouse-up.
    private var readerKeepsClickFromPDFKit = false

    public override func mouseDown(with event: NSEvent) {
        readerKeepsClickFromPDFKit = false
        guard let controller = readerController else {
            super.mouseDown(with: event)
            return
        }
        switch controller.handleMouseDown(at: convert(event.locationInWindow, from: nil)) {
        case .citation:
            readerKeepsClickFromPDFKit = true
        case .highlight, .other:
            super.mouseDown(with: event)
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        guard !readerKeepsClickFromPDFKit else { return }
        super.mouseDragged(with: event)
    }

    public override func mouseUp(with event: NSEvent) {
        guard !readerKeepsClickFromPDFKit else {
            readerKeepsClickFromPDFKit = false
            return
        }
        super.mouseUp(with: event)
    }

    public override func areaOfInterest(forMouse event: NSEvent) -> PDFAreaOfInterest {
        readerArea(super.areaOfInterest(forMouse: event), at: convert(event.locationInWindow, from: nil))
    }

    public override func areaOfInterest(for cursorLocation: NSPoint) -> PDFAreaOfInterest {
        readerArea(super.areaOfInterest(for: cursorLocation), at: cursorLocation)
    }

    private func readerArea(_ area: PDFAreaOfInterest, at viewPoint: NSPoint) -> PDFAreaOfInterest {
        guard let controller = readerController, controller.isOverCitation(at: viewPoint) else { return area }
        return area.union(.linkArea)
    }
}
