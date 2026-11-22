import SwiftUI
import PDFKit
import RefereeCore
import AppCore

// The PDF pane of the review window (plan.md sections 7.4, 9.2 and 9.5): the controller's PDF view with the three
// overlays tied to positions in it, as SwiftUI views layered over the PDF: the find bar at the top, the selection bar
// above the selection, the citation card below its mention (or at the top for an entry chosen in the References list).
// Overlays rather than popovers, because a popover is a window of its own and the snapshot mode captures only the
// main window. The banner and the consent card are not here: they belong to the Shell.
//
// The pane sets no minimum width, on purpose. With the composition of section 9.2, SwiftUI on macOS 26 adds the
// inspector's width to whatever minimum the detail column declares: `.frame(minWidth: 480)` here makes the smallest
// possible window 1448 points wide, and a review window can then be neither 1280 nor 1000 points wide
// (docs/contract-notes/wp0b-testsupport.md, contract problems). The overlays never change the pane's size.

public struct ReaderPane: View {          // PDF, find bar, selection bar, citation card
    private let controller: ReaderController

    public init(controller: ReaderController) { self.controller = controller }

    public var body: some View {
        ReaderPDFViewRepresentable(pdfView: controller.pdfView)
            .overlay(alignment: .topLeading) { ReaderOverlayLayer(controller: controller) }
    }
}

/// The overlays, placed from page rectangles: `pdfView.convert(_:from: page)` gives AppKit coordinates (origin at the
/// bottom left), which ReaderOverlayPlacement turns into SwiftUI's. The layer has no background, so where no overlay
/// is, clicks reach the PDF view below.
private struct ReaderOverlayLayer: View {
    let controller: ReaderController
    @State private var settledSelection: SelectionInfo?        // the selection, 200 ms after it last changed
    @State private var barSize = CGSize(width: 300, height: 30)
    @State private var cardSize = CGSize(width: ReaderCitationCard.width, height: 220)

    /// The selection bar appears this long after the selection settles (section 9.5).
    static let barDelay: Duration = .milliseconds(200)
    /// A selection shorter than this has no bar (section 9.5).
    static let barMinimumLength = 3

    var body: some View {
        let model = controller.model
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if let selection = settledSelection, let origin = barOrigin(for: selection, in: proxy.size) {
                    ReaderSelectionBar(model: model, selection: selection)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { barSize = $0 }
                        .offset(x: origin.x, y: origin.y)
                }
                if let content = ReaderCardContent.make(model.citationLookup, citations: model.citations),
                   let origin = cardOrigin(for: content.target, in: proxy.size) {
                    // Measured before the frame, which only caps the card: offered more, a frame with a maximum is as
                    // tall as its maximum, while the card itself is as tall as its content (or scrolls inside the cap).
                    ReaderCitationCard(controller: controller, content: content)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
                        .frame(maxHeight: max(120, proxy.size.height - 2 * ReaderOverlayPlacement.margin), alignment: .top)
                        .offset(x: origin.x, y: origin.y)
                }
                if controller.finder.isVisible {
                    ReaderFindBar(finder: controller.finder)
                        .padding(.horizontal, ReaderOverlayPlacement.margin)
                        .padding(.top, ReaderOverlayPlacement.margin)
                        .frame(width: proxy.size.width, alignment: .top)
                }
            }
        }
        .task(id: model.selection) {
            settledSelection = nil
            guard let selection = model.selection, selection.text.count >= Self.barMinimumLength, !selection.rects.isEmpty else { return }
            try? await Task.sleep(for: Self.barDelay)
            guard !Task.isCancelled else { return }
            settledSelection = model.selection
        }
    }

    /// 6 pt above the first rectangle of the selection, inside the view; nil while that rectangle is out of sight.
    private func barOrigin(for selection: SelectionInfo, in size: CGSize) -> CGPoint? {
        _ = controller.overlay.geometryTick
        guard let first = selection.rects.first, let rect = controller.viewRect(for: first),
              ReaderOverlayPlacement.isVisible(rect, in: size) else { return nil }
        return ReaderOverlayPlacement.origin(above: rect, size: barSize, in: size, isFlipped: controller.pdfView.isFlipped)
    }

    /// Below the mention (all its rectangles on the page of the first), or at the top of the pane for an entry chosen in
    /// the References list (below the find bar when that is shown).
    private func cardOrigin(for target: CitationLookup.Target, in size: CGSize) -> CGPoint? {
        switch target {
        case .entry:
            let top = controller.finder.isVisible ? ReaderOverlayPlacement.margin + 44 : ReaderOverlayPlacement.margin
            return ReaderOverlayPlacement.originAtTop(size: cardSize, in: size, top: top)
        case .mention:
            _ = controller.overlay.geometryTick
            guard let mention = controller.cardMention, let page = mention.rects.first?.pageIndex else { return nil }
            let rects = mention.rects.filter { $0.pageIndex == page }.compactMap { controller.viewRect(for: $0) }
            guard let first = rects.first else { return nil }
            let anchor = rects.dropFirst().reduce(first) { $0.union($1) }
            guard ReaderOverlayPlacement.isVisible(anchor, in: size) else { return nil }
            return ReaderOverlayPlacement.origin(below: anchor, size: cardSize, in: size, isFlipped: controller.pdfView.isFlipped)
        }
    }
}
