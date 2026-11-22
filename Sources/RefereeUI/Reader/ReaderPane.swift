import SwiftUI
import PDFKit
import RefereeCore
import AppCore

// Wave 0 placeholder (plan.md section 11.4, WP0b): the controller's PDF view and nothing else, so that a review
// window shows the manuscript. WP9 writes the pane (find bar, selection bar, citation card; section 7.4).
//
// The pane sets no minimum width, on purpose. With the composition of section 9.2, SwiftUI on macOS 26 adds the
// inspector's width to whatever minimum the detail column declares: `.frame(minWidth: 480)` here makes the smallest
// possible window 1448 points wide, and a review window can then be neither 1280 nor 1000 points wide. Without a
// declared minimum the smallest window is 968 points wide (docs/contract-notes/wp0b-testsupport.md, contract problems).

public struct ReaderPane: View {          // PDF, find bar, selection bar, citation card
    private let controller: ReaderController

    public init(controller: ReaderController) { self.controller = controller }

    public var body: some View {
        PlaceholderPDFViewHost(controller: controller)
    }
}

/// Puts the controller's own PDF view into the SwiftUI hierarchy. The view belongs to the controller and outlives
/// this wrapper.
private struct PlaceholderPDFViewHost: NSViewRepresentable {
    let controller: ReaderController

    func makeNSView(context: Context) -> PDFView { controller.pdfView }

    func updateNSView(_ nsView: PDFView, context: Context) {}
}
