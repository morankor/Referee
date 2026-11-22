import AppKit
import PDFKit
import Testing
import RefereeCore
import AppCore
import TestSupport
@testable import RefereeUI

/// What the Reader's tests share: a review model on the fakes of TestSupport, with a session and a citation index of
/// the test's own, and a window (never shown) to hold a PDF view, so that clicks and conversions work as in the app.
@MainActor enum ReaderTestSupport {
    nonisolated static let date = Date(timeIntervalSince1970: 1_800_000_000)

    /// A model on `fixture` (FakePaperService: identity text, rectangles x 100 / width 200 per span), opened, with
    /// `comments` and `conversations` already saved for that document and `index` as its citation index.
    static func openModel(fixture: String = "ay_round_nolinks", comments: [ReviewComment] = [], conversations: [Conversation] = [],
                          index: CitationIndex? = nil, settings: AppSettings = DefaultSettings.make()) async throws -> ReviewSessionModel {
        let paper = try makeSamplePaper(fixture: fixture)
        let store = InMemorySessionStore()
        if !comments.isEmpty || !conversations.isEmpty {
            let session = ReviewSession(schemaVersion: 1, id: UUID(), document: paper.ref, meta: ManuscriptMeta(reviewerNotes: ""),
                                        comments: comments, conversations: conversations, createdAt: date, updatedAt: date)
            try await store.save(session)
        }
        let plan = SendPlan(sendsPDF: false, requestCount: 1, estimatedInputTokens: 0, destination: "this Mac", isLocal: true)
        let dependencies = AppDependencies(paperService: FakePaperService(paper: paper), matcherFactory: { FakeQuoteMatcher(paper: $0) },
                                           citationIndexer: FakeCitationIndexer(index: index), engine: ScriptedReviewEngine(plan: plan),
                                           resolver: FakeResolver(), sessions: store, settings: InMemorySettingsStore(),
                                           providers: ProviderRegistry([]), secrets: InMemorySecretStore())
        let model = ReviewSessionModel(dependencies: dependencies, settings: settings)
        await model.open(url: Fixtures.url("pdf/\(fixture).pdf"))
        return model
    }

    /// A controller on `model`, attached, its PDF view of `size` points in a window that is never put on screen, the
    /// document loaded and laid out. The view does not start at the window's origin (as in the review window, where the
    /// navigator is on its left), so a point given in the wrong coordinates misses.
    static func attachedReader(_ model: ReviewSessionModel, size: NSSize = NSSize(width: 700, height: 800)) async throws -> (ReaderController, NSWindow) {
        _ = NSApplication.shared
        let reader = ReaderController(model: model)
        let inset = NSPoint(x: 120, y: 30)
        let windowSize = NSSize(width: size.width + inset.x + 40, height: size.height + inset.y + 20)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: windowSize), styleMask: [.titled, .resizable], backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(origin: .zero, size: windowSize))
        window.contentView = container
        reader.pdfView.frame = NSRect(origin: inset, size: size)
        container.addSubview(reader.pdfView)
        reader.attach()
        await wait { reader.isDocumentLoaded }
        try #require(reader.isDocumentLoaded)
        reader.pdfView.layoutDocumentView()
        await settle()
        return (reader, window)
    }

    /// Lets the main actor run until `condition` holds or `seconds` have passed.
    static func wait(seconds: Double = 5, until condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(seconds)
        while !condition(), clock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// Lets what the controller scheduled on the main actor (observation, notifications) run.
    static func settle(milliseconds: Int = 50) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    static func comment(_ id: UUID = UUID(), status: CommentStatus = .pending, origin: CommentOrigin = .ai(runID: UUID()),
                        kind: CommentKind = .major, rects: [PageRect], confidence: AnchorConfidence = .exact) -> ReviewComment {
        let spans = rects.map { TextSpan(pageIndex: $0.pageIndex, range: TextRange(location: 0, length: 4)) }
        let anchor = Anchor(quote: "a quoted passage", spans: spans, rects: rects, pageIndex: rects.first?.pageIndex, confidence: confidence,
                            locationLabel: "p. 1")
        return ReviewComment(id: id, origin: origin, status: status, kind: kind, category: "claims", title: "A comment", body: "Its body.",
                             anchor: anchor, includeInReport: true, createdAt: date, updatedAt: date)
    }

    static func conversation(_ id: UUID = UUID(), rects: [PageRect]) -> Conversation {
        let anchor = Anchor(quote: "a passage", spans: rects.map { TextSpan(pageIndex: $0.pageIndex, range: TextRange(location: 0, length: 4)) },
                            rects: rects, pageIndex: rects.first?.pageIndex, confidence: .exact, locationLabel: "p. 1")
        return Conversation(id: id, anchor: anchor, createdAt: date)
    }

    static func entry(_ id: Int, surnames: [String] = ["Banerjee"], year: Int? = 1992, label: String? = nil, doi: String? = nil,
                      url: String? = nil) -> BibEntry {
        BibEntry(id: id, label: label, rawText: "Banerjee, A. V. (1992). A simple model of herd behavior.",
                 parsed: ParsedReference(authorSurnames: surnames, year: year, title: "A simple model of herd behavior", doi: doi, url: url))
    }

    /// The centre of `rect` (page space) in the coordinates of the PDF view's window.
    static func windowPoint(of rect: PageRect, in reader: ReaderController) throws -> NSPoint {
        let page = try #require(reader.pdfView.document?.page(at: rect.pageIndex))
        let inView = reader.pdfView.convert(rect.cgRect, from: page)
        return reader.pdfView.convert(NSPoint(x: inView.midX, y: inView.midY), to: nil)
    }

    /// A left mouse event at `point` (window coordinates).
    static func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                        pressure: type == .leftMouseDown ? 1 : 0))
    }
}
