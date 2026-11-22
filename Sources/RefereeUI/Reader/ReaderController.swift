import AppKit
import PDFKit
import RefereeCore
import AppCore

// Wave 0 placeholder (plan.md section 11.4, WP0a). WP0b makes `attach()` load the display document; WP9 writes the
// controller (section 7.4).

public enum ZoomStep { case zoomIn, zoomOut, fitWidth }

/// The only object other UI code uses to reach the PDF view. One per review window.
@MainActor public final class ReaderController {
    private let model: ReviewSessionModel

    public init(model: ReviewSessionModel) {
        self.model = model
        self.pdfView = RefereePDFView()
    }

    public let pdfView: RefereePDFView                    // created in init, lives as long as the window

    /// Starts observing the model and loads the display document as soon as model.paper is set. Idempotent.
    /// Called by ReviewWindowController right after it creates the controller, and by the snapshot runner.
    /// Placeholder: does nothing.
    public func attach() {}

    public var isDocumentLoaded: Bool { pdfView.document != nil }    // pdfView.document != nil

    public func showFind() {}               // Edit ▸ Find…
    public func findNext() {}
    public func findPrevious() {}
    public func zoom(_ step: ZoomStep) {}   // View ▸ Zoom In / Zoom Out / Fit Width
}
