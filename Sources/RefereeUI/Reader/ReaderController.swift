import AppKit
import Observation
import PDFKit
import RefereeCore
import AppCore
import PDFBridge

// The reader's controller (plan.md sections 7.1, 7.3–7.6): the one object other UI code uses to reach the PDF view.
//
// - `attach()` keeps the Wave 0 behaviour: idempotent, and the display document is loaded as soon as `model.paper` is
//   set, made from the paper's bytes (no URL, so nothing can write the file). From then on the controller follows the
//   model: the paper, `readerCommand` (reveal, go to page, clear selection) and everything the highlights depend on.
// - The PDF view tells the model about selections (debounced 150 ms, raw: the model normalises them), clicks on
//   highlights and clicks on citations (`RefereePDFView` asks `handleMouseDown(at:)`).
// - Find and zoom do not pass through the model: the menu calls `showFind()`, `findNext()`, `findPrevious()` and
//   `zoom(_:)` here (section 2.4), and the window's Esc calls `dismissFind()` (section 9.4, Wave 3).
//
// Decisions (also in docs/contract-notes/wp9-reader.md):
// - A command issued before `attach()` is not replayed; one issued before the document is shown waits for it.
// - `.reveal` scrolls so that the top of the first rectangle sits one third of the way down the visible area (clamped
//   at the ends of the document) and keeps the horizontal position unless the rectangle is outside it. `.reveal` and
//   `.goToPage` close the citation card: the page changes under it.
// - The citation card follows its mention while the PDF scrolls and closes when the mention leaves the visible area;
//   it also closes on a click anywhere in the PDF, on Esc (the model's `dismissTransientUI`) and on its own close button.
//   A scroll notification cannot tell a referee's scroll from a layout pass (a window resized, the sidebar shown), so
//   "dismissed on scroll" (section 7.4) is read as "never left floating away from what it belongs to".

public enum ZoomStep { case zoomIn, zoomOut, fitWidth }

/// The only object other UI code uses to reach the PDF view. One per review window.
@MainActor public final class ReaderController {
    let model: ReviewSessionModel
    let finder: ReaderFinder
    let overlay = ReaderOverlayState()
    let navigator = ReaderNavigatorState()
    let highlights: ReaderHighlightController

    /// How long a selection must stay unchanged before the model hears of it (section 7.4).
    static let selectionDelay: Duration = .milliseconds(150)

    private var isAttached = false
    private var shownDocument: String?                    // sha256 of the paper whose document the view shows
    private var lastCommandSerial: Int?
    private var waitingCommand: ReaderCommand?            // arrived before the document was shown
    private var selectionTask: Task<Void, Never>?
    private let notifications = ReaderNotificationTokens()
    private weak var watchedClipView: NSClipView?

    public init(model: ReviewSessionModel) {
        self.model = model
        let view = RefereePDFView()
        self.pdfView = view
        self.finder = ReaderFinder(pdfView: view)
        self.highlights = ReaderHighlightController(pdfView: view)
        view.readerController = self
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
        lastCommandSerial = model.readerCommand?.serial
        watchTheView()
        showPaperAndKeepWatching()
        performCommandsAndKeepWatching()
        showHighlightsAndKeepWatching()
    }

    public var isDocumentLoaded: Bool { pdfView.document != nil }    // pdfView.document != nil

    public func showFind() { finder.show() }               // Edit ▸ Find…
    public func findNext() { finder.next() }
    public func findPrevious() { finder.previous() }

    /// Esc in the PDF (section 9.4): hides the find bar if it is shown, and says whether it was. The window's key monitor
    /// calls it when none of the model's transient UI is open (Wave 3).
    public func dismissFind() -> Bool {
        guard finder.isVisible else { return false }
        finder.close()
        return true
    }

    public func zoom(_ step: ZoomStep) {                   // View ▸ Zoom In / Zoom Out / Fit Width
        switch step {
        case .zoomIn: pdfView.zoomIn(nil)
        case .zoomOut: pdfView.zoomOut(nil)
        case .fitWidth: pdfView.autoScales = true
        }
    }

    // ---- for the reader's own views and scenes ----

    /// Shows the find bar with `query` and searches at once (the scene `reader-find`; a scene cannot type).
    func find(_ query: String) {
        finder.query = query
        finder.show()                                       // searches a query it has no results for
    }

    /// The Outline list's click: the top of that page.
    func goToPage(_ index: Int) {
        guard let page = pdfView.document?.page(at: index) else { return }
        dismissCitationCard()
        pdfView.go(to: page)
    }

    /// "Show in References": the navigator switches to References and marks the entry.
    func showInReferences(entryID: Int) {
        navigator.tab = .references
        navigator.shownEntryID = entryID
        navigator.scrollRequest &+= 1
    }

    /// Closes the citation card, if one is open, and nothing else (`dismissCitationLookup`, Appendix A.9).
    func dismissCitationCard() {
        model.dismissCitationLookup()
    }

    /// A rectangle of the display document in the PDF view's own coordinates (origin at the bottom left); nil when the
    /// page does not exist.
    func viewRect(for rect: PageRect) -> CGRect? {
        guard let page = pdfView.document?.page(at: rect.pageIndex) else { return nil }
        return pdfView.convert(rect.cgRect, from: page)
    }

    /// The mention a citation card belongs to, when the card was opened from the PDF.
    var cardMention: CitationMention? {
        let target: CitationLookup.Target
        switch model.citationLookup {
        case .idle: return nil
        case .resolving(let current): target = current
        case .resolved(let current, _, _): target = current
        }
        guard case .mention(let id) = target else { return nil }
        return model.citations?.mentions.first { $0.id == id }
    }

    // ---- clicks (called by RefereePDFView) ----

    enum Click: Equatable { case citation, highlight, other }

    /// Section 7.4: a highlight → `readerClickedComment` and PDFKit carries on (the selection still works); a citation →
    /// `readerClickedCitation` and PDFKit must not see the click (no jump to the bibliography). The smallest rectangle
    /// wins (ReaderHitTesting). Any click in the PDF closes an open citation card first.
    func handleMouseDown(at viewPoint: CGPoint) -> Click {
        dismissCitationCard()
        guard let spot = pageSpot(at: viewPoint) else { return .other }
        switch ReaderHitTesting.target(at: spot.point, pageIndex: spot.index, highlights: highlights.shown,
                                       mentions: model.citations?.mentions ?? []) {
        case .comment(let id)?:
            model.readerClickedComment(id)
            return .highlight
        case .mention(let id)?:
            model.readerClickedCitation(mentionID: id)
            return .citation
        case nil:
            return .other
        }
    }

    /// Whether the cursor is over a citation (the pointing hand of `areaOfInterest`).
    func isOverCitation(at viewPoint: CGPoint) -> Bool {
        guard let spot = pageSpot(at: viewPoint) else { return false }
        return ReaderHitTesting.mention(at: spot.point, pageIndex: spot.index, mentions: model.citations?.mentions ?? []) != nil
    }

    private func pageSpot(at viewPoint: CGPoint) -> (index: Int, point: CGPoint)? {
        guard let document = pdfView.document, let page = pdfView.page(for: viewPoint, nearest: true) else { return nil }
        let index = document.index(for: page)
        guard index != NSNotFound else { return nil }
        return (index, pdfView.convert(viewPoint, to: page))
    }

    // ---- the model's paper, commands and highlights ----

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
        finder.documentDidChange()
        // Left to itself PDFKit opens a document a little below the top of its first page, by an amount that
        // depends on the size of the view. Going to the top left corner of that page gives the same start everywhere.
        if let first = pdfView.document?.page(at: 0) {
            pdfView.layoutDocumentView()
            let box = first.bounds(for: pdfView.displayBox)
            pdfView.go(to: PDFDestination(page: first, at: NSPoint(x: box.minX, y: box.maxY)))
        }
        watchTheClipView()
        highlights.show(desiredHighlights())
        if pdfView.document != nil, let command = waitingCommand {
            waitingCommand = nil
            perform(command)
        }
        geometryDidChange()
    }

    private func performCommandsAndKeepWatching() {
        let current = withObservationTracking {
            model.readerCommand
        } onChange: { [weak self] in
            Task { @MainActor in self?.performCommandsAndKeepWatching() }
        }
        guard let current, current.serial != lastCommandSerial else { return }
        lastCommandSerial = current.serial
        if pdfView.document == nil {
            waitingCommand = current.command
        } else {
            perform(current.command)
        }
    }

    private func showHighlightsAndKeepWatching() {
        let desired = withObservationTracking {
            desiredHighlights()
        } onChange: { [weak self] in
            Task { @MainActor in self?.showHighlightsAndKeepWatching() }
        }
        highlights.show(desired)
    }

    private func desiredHighlights() -> [ReaderHighlight] {
        guard let session = model.session else { return [] }
        return ReaderHighlightPlan.highlights(comments: session.comments, conversations: session.conversations, filter: model.filter,
                                              selectedCommentID: model.selectedCommentID,
                                              showRejected: model.settings.ui.showRejectedHighlights)
    }

    func perform(_ command: ReaderCommand) {
        switch command {
        case .reveal(let rects, let flash):
            dismissCitationCard()
            reveal(rects)
            if flash { highlights.flash(rects) }
        case .goToPage(let index):
            goToPage(index)
        case .clearSelection:
            pdfView.clearSelection()
        }
    }

    /// Scrolls so that the first rectangle's top edge is one third of the way down the visible area.
    private func reveal(_ rects: [PageRect]) {
        guard let first = rects.first, let page = pdfView.document?.page(at: first.pageIndex) else { return }
        ReaderScrolling.reveal(first.cgRect.standardized, on: page, in: pdfView)
    }

    // ---- what the view reports ----

    private func watchTheView() {
        let center = NotificationCenter.default
        notifications.add(center.addObserver(forName: .PDFViewSelectionChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.selectionDidChange() }
        })
        for name in [Notification.Name.PDFViewScaleChanged, .PDFViewPageChanged, .PDFViewDisplayModeChanged] {
            notifications.add(center.addObserver(forName: name, object: pdfView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.geometryDidChange() }
            })
        }
        pdfView.postsFrameChangedNotifications = true
        notifications.add(center.addObserver(forName: NSView.frameDidChangeNotification, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.geometryDidChange() }
        })
        watchTheClipView()
    }

    /// Scrolling moves the clip view inside the PDF view; overlays are placed again each time.
    private func watchTheClipView() {
        guard let clipView = pdfView.documentView?.enclosingScrollView?.contentView, clipView !== watchedClipView else { return }
        watchedClipView = clipView
        clipView.postsBoundsChangedNotifications = true
        notifications.add(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clipView,
                                                                 queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.geometryDidChange() }
        })
    }

    /// The raw selection, 150 ms after it last changed. The current find match is no passage of the referee's.
    private func selectionDidChange() {
        selectionTask?.cancel()
        selectionTask = Task { [weak self] in
            try? await Task.sleep(for: Self.selectionDelay)
            guard !Task.isCancelled, let self else { return }
            self.model.readerSelectionChanged(self.rawSelection())
        }
    }

    /// What PDFKit has selected, as SelectionInfoBuilder reports it (not normalised; the model does that).
    func rawSelection() -> SelectionInfo? {
        guard let document = pdfView.document, let selection = pdfView.currentSelection, !finder.owns(selection) else { return nil }
        return SelectionInfoBuilder.make(from: selection, in: document)
    }

    private func geometryDidChange() {
        overlay.geometryTick &+= 1
        if let mention = cardMention, !mentionIsVisible(mention) { dismissCitationCard() }
    }

    private func mentionIsVisible(_ mention: CitationMention) -> Bool {
        let size = pdfView.bounds.size
        guard size.width > 0, size.height > 0 else { return true }          // not laid out yet: nothing to judge
        return mention.rects.contains { rect in viewRect(for: rect).map { ReaderOverlayPlacement.isVisible($0, in: size) } ?? false }
    }
}

/// What the overlays over the PDF need to be placed again: a counter bumped whenever the PDF moves under them (scroll,
/// zoom, resize, a new page or document). Views that place an overlay read it, so they are evaluated again.
@MainActor @Observable
final class ReaderOverlayState {
    var geometryTick = 0
}

/// The navigator's tab and the entry "Show in References" pointed at (section 8.6).
enum ReaderNavigatorTab: String, CaseIterable, Identifiable {
    case pages, outline, references
    var id: Self { self }
    var title: String {
        switch self {
        case .pages: return "Pages"
        case .outline: return "Outline"
        case .references: return "References"
        }
    }
}

@MainActor @Observable
final class ReaderNavigatorState {
    var tab: ReaderNavigatorTab = .pages
    var shownEntryID: Int?               // marked in the References list
    var scrollRequest = 0                // bumped to scroll the list to `shownEntryID`
}

/// Notification observers, removed when their owner goes away.
final class ReaderNotificationTokens {
    private var tokens: [NSObjectProtocol] = []
    func add(_ token: NSObjectProtocol) { tokens.append(token) }
    deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }
}
