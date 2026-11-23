import SwiftUI
import AppKit
import PDFKit
import RefereeCore
import AppCore

// The reference viewer (plan.md section 7.7): a cited paper in a window of its own, with thumbnails, find and zoom; no
// sidebar, no AI, no session. The Shell makes the window and titles it with the reference's title.
//
// Decisions (also in docs/contract-notes/wp9-reader.md and step5-reader.md):
// - The file is read once, off the main actor, and shown from its bytes (`PDFDocument(data:)`): the document has no
//   URL, so the viewer can never write to the file, as for the manuscript (section 4.6).
// - The controls are in the window's toolbar (design review D27): zoom out and in, Fit Width, the page count, Find and
//   Open in Preview. The Edit and View menus reach the review window's ReaderController only, so the viewer keeps the
//   menu's keys itself (⌘−, ⌘+, ⌘0, ⌘F, ⌘G, ⇧⌘G), on buttons in its content that are not seen: a key there reaches the
//   window the way it always has, which the `reference-viewer` scene checks.
// - Open in Preview opens the file in Preview, where the referee may annotate it; the viewer itself never writes it.

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
        .background { ReaderViewerKeys(viewer: viewer) }
        .toolbar { ReaderViewerToolbar(viewer: viewer) }
        .task { await viewer.load() }
    }
}

/// The viewer's state: its own PDF view and finder, and whether the file could be shown.
@MainActor @Observable
final class ReaderViewerModel {
    enum State: Equatable { case loading, ready, failed(String) }

    /// Preview, which "Open in Preview" opens the file with (D27).
    static let previewBundleIdentifier = "com.apple.Preview"

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

    /// "2 pages", "1 page"; nil until the file is shown.
    var pageCountText: String? {
        switch pageCount {
        case 0: return nil
        case 1: return "1 page"
        default: return "\(pageCount) pages"
        }
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

    /// "Open in Preview" (D27): the file in Preview, or in the default PDF application when Preview cannot be found.
    func openInPreview() {
        let workspace = NSWorkspace.shared
        guard let preview = workspace.urlForApplication(withBundleIdentifier: Self.previewBundleIdentifier) else {
            workspace.open(fileURL)
            return
        }
        workspace.open([fileURL], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    @concurrent nonisolated private static func read(_ url: URL) async -> Data? {
        try? Data(contentsOf: url, options: .mappedIfSafe)
    }
}

/// The viewer's toolbar (D27), left to right at its trailing end: zoom out and in, Fit Width, the page count, Find,
/// Open in Preview. Its buttons name their keys in their tooltips; the keys themselves are `ReaderViewerKeys`'.
private struct ReaderViewerToolbar: ToolbarContent {
    let viewer: ReaderViewerModel

    var body: some ToolbarContent {
        let isReady = viewer.state == .ready
        ToolbarItemGroup(placement: .primaryAction) {
            ControlGroup {
                Button { viewer.zoom(.zoomOut) } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
                    .help("Zoom Out (⌘−)")
                Button { viewer.zoom(.zoomIn) } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
                    .help("Zoom In (⌘+)")
            }
            .disabled(!isReady)
            Button("Fit Width") { viewer.zoom(.fitWidth) }
                .help("Fit Width (⌘0)")
                .disabled(!isReady)
        }
        if let pages = viewer.pageCountText {
            ToolbarItem(placement: .primaryAction) {
                Text(pages)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .padding(.horizontal, 4)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { viewer.finder.show() } label: {
                Label("Find", systemImage: "magnifyingglass")
                    .labelStyle(.titleAndIcon)
            }
            .help("Find in this PDF (⌘F)")
            .disabled(!isReady)
            Button { viewer.openInPreview() } label: {
                Label("Open in Preview", systemImage: "arrow.up.forward.app")
                    .labelStyle(.titleAndIcon)
            }
            .help("Open this PDF in Preview")
            .disabled(!isReady)
        }
    }
}

/// The menu's keys of the viewer, on buttons in its content that are not seen (find next and previous have no button
/// of their own; the others' buttons are in the toolbar).
private struct ReaderViewerKeys: View {
    let viewer: ReaderViewerModel

    var body: some View {
        ZStack {
            Button("Zoom Out") { viewer.zoom(.zoomOut) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Zoom In") { viewer.zoom(.zoomIn) }
                .keyboardShortcut("+", modifiers: .command)
            Button("Fit Width") { viewer.zoom(.fitWidth) }
                .keyboardShortcut("0", modifiers: .command)
            Button("Find") { viewer.finder.show() }
                .keyboardShortcut("f", modifiers: .command)
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
