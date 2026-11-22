import SwiftUI
import PDFKit
import RefereeCore
import AppCore

// The reference viewer (plan.md section 7.7): a cited paper in a window of its own, with thumbnails, find and zoom; no
// sidebar, no AI, no session. The Shell makes the window and titles it with the reference's title.
//
// Decisions (also in docs/contract-notes/wp9-reader.md):
// - The file is read once, off the main actor, and shown from its bytes (`PDFDocument(data:)`): the document has no
//   URL, so the viewer can never write to the file, as for the manuscript (section 4.6).
// - The viewer's own bar holds zoom out, zoom in, fit width and find, with the menu's keys (⌘−, ⌘+, ⌘0, ⌘F, ⌘G, ⇧⌘G):
//   the Edit and View menus reach the review window's ReaderController only.

public struct ReferenceViewerView: View {  // read-only viewer for a cited paper
    @State private var viewer: ReaderViewerModel

    public init(fileURL: URL, title: String) {
        _viewer = State(initialValue: ReaderViewerModel(fileURL: fileURL, title: title))
    }

    public var body: some View {
        HStack(spacing: 0) {
            ReaderThumbnailsRepresentable(pdfView: viewer.pdfView)
                .frame(width: 150)
            Divider()
            VStack(spacing: 0) {
                ReaderViewerBar(viewer: viewer)
                Divider()
                ZStack(alignment: .top) {
                    ReaderPDFViewRepresentable(pdfView: viewer.pdfView)
                    switch viewer.state {
                    case .loading:
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .failed(let message):
                        Text(message)
                            .font(Theme.bodyFont)
                            .foregroundStyle(.secondary)
                            .padding()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(nsColor: Theme.pdfBackground))
                    case .ready:
                        EmptyView()
                    }
                    if viewer.finder.isVisible {
                        ReaderFindBar(finder: viewer.finder)
                            .padding(.horizontal, ReaderOverlayPlacement.margin)
                            .padding(.top, ReaderOverlayPlacement.margin)
                    }
                }
            }
        }
        .task { await viewer.load() }
    }
}

/// The viewer's state: its own PDF view and finder, and whether the file could be shown.
@MainActor @Observable
final class ReaderViewerModel {
    enum State: Equatable { case loading, ready, failed(String) }

    let fileURL: URL
    let title: String
    @ObservationIgnored let pdfView: PDFView
    @ObservationIgnored let finder: ReaderFinder
    private(set) var state: State = .loading
    private(set) var pageCount = 0

    init(fileURL: URL, title: String) {
        self.fileURL = fileURL
        self.title = title
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = Theme.pdfBackground
        self.pdfView = view
        self.finder = ReaderFinder(pdfView: view)
    }

    /// Reads the file and shows it, once.
    func load() async {
        guard state == .loading, pdfView.document == nil else { return }
        let data = await Self.read(fileURL)
        guard state == .loading else { return }
        guard let data, let document = PDFDocument(data: data), document.pageCount > 0 else {
            state = .failed("This file could not be opened.")
            return
        }
        guard !document.isLocked else {
            state = .failed("This PDF is password-protected.")
            return
        }
        pdfView.document = document
        pageCount = document.pageCount
        if let first = document.page(at: 0) {
            pdfView.layoutDocumentView()
            let box = first.bounds(for: pdfView.displayBox)
            pdfView.go(to: PDFDestination(page: first, at: NSPoint(x: box.minX, y: box.maxY)))
        }
        finder.documentDidChange()
        state = .ready
    }

    func zoom(_ step: ZoomStep) {
        switch step {
        case .zoomIn: pdfView.zoomIn(nil)
        case .zoomOut: pdfView.zoomOut(nil)
        case .fitWidth: pdfView.autoScales = true
        }
    }

    @concurrent nonisolated private static func read(_ url: URL) async -> Data? {
        try? Data(contentsOf: url, options: .mappedIfSafe)
    }
}

/// Zoom and find, above the viewer's PDF.
private struct ReaderViewerBar: View {
    let viewer: ReaderViewerModel

    var body: some View {
        HStack(spacing: 8) {
            ControlGroup {
                Button { viewer.zoom(.zoomOut) } label: { Image(systemName: "minus.magnifyingglass") }
                    .keyboardShortcut("-", modifiers: .command)
                    .help("Zoom Out (⌘−)")
                Button { viewer.zoom(.zoomIn) } label: { Image(systemName: "plus.magnifyingglass") }
                    .keyboardShortcut("+", modifiers: .command)
                    .help("Zoom In (⌘+)")
            }
            .fixedSize()
            Button("Fit Width") { viewer.zoom(.fitWidth) }
                .keyboardShortcut("0", modifiers: .command)
            Spacer(minLength: 8)
            if viewer.pageCount > 0 {
                Text(viewer.pageCount == 1 ? "1 page" : "\(viewer.pageCount) pages")
                    .font(Theme.metadataFont)
                    .foregroundStyle(.secondary)
            }
            Button { viewer.finder.show() } label: { Label("Find", systemImage: "magnifyingglass") }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut("f", modifiers: .command)
        }
        .controlSize(.small)
        .disabled(viewer.state != .ready)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            // Find Next and Find Previous have keys but no button of their own.
            ZStack {
                Button("Find Next") { viewer.finder.next() }
                    .keyboardShortcut("g", modifiers: .command)
                Button("Find Previous") { viewer.finder.previous() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
            }
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .disabled(viewer.state != .ready)
        }
    }
}
