import AppKit
import Observation
import PDFKit
import RefereeCore
import AppCore

// Wave 0 (plan.md section 11.4, WP0b): `attach()` really loads the display document, because the first window and
// the snapshot mode need a PDF on screen. Everything else is still a placeholder. WP9 writes the controller
// (section 7.4): selection, commands from the model, highlights, find and zoom.

public enum ZoomStep { case zoomIn, zoomOut, fitWidth }

/// The only object other UI code uses to reach the PDF view. One per review window.
@MainActor public final class ReaderController {
    private let model: ReviewSessionModel
    private var isAttached = false
    private var shownDocument: String?                    // sha256 of the paper whose document the view shows

    public init(model: ReviewSessionModel) {
        self.model = model
        self.pdfView = RefereePDFView()
    }

    public let pdfView: RefereePDFView                    // created in init, lives as long as the window

    /// Starts observing the model and loads the display document as soon as model.paper is set. Idempotent.
    /// Called by ReviewWindowController right after it creates the controller, and by the snapshot runner.
    public func attach() {
        guard !isAttached else { return }
        isAttached = true
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = Theme.pdfBackground
        showPaperAndKeepWatching()
    }

    public var isDocumentLoaded: Bool { pdfView.document != nil }    // pdfView.document != nil

    public func showFind() {}               // Edit ▸ Find…
    public func findNext() {}
    public func findPrevious() {}
    public func zoom(_ step: ZoomStep) {}   // View ▸ Zoom In / Zoom Out / Fit Width

    /// Shows the model's paper now and again whenever `model.paper` changes. The display document is made from the
    /// paper's bytes (section 7.1): it has no URL, so nothing can write it back to the file.
    private func showPaperAndKeepWatching() {
        let paper = withObservationTracking {
            model.paper
        } onChange: { [weak self] in
            Task { @MainActor in self?.showPaperAndKeepWatching() }
        }
        guard paper?.ref.sha256 != shownDocument else { return }
        shownDocument = paper?.ref.sha256
        pdfView.document = paper.flatMap { PDFDocument(data: $0.data) }
    }
}
