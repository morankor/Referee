import AppKit
import PDFKit
import Testing
import RefereeCore
import AppCore
import TestSupport
@testable import RefereeUI

/// When the selection bar shows (plan.md section 9.5) and when it steps aside once it has been used (design review
/// D14), with a real PDF view on the fakes of TestSupport. Copy writes to a pasteboard of the test's own, never to the
/// general one.
@Suite struct ReaderSelectionBarTests {
    private static let passage = "Herding has been studied"

    /// Selects `passage` on page 1 as a drag would and waits for the model's normalised selection with its rectangles.
    @MainActor private func select(_ passage: String, in reader: ReaderController, model: ReviewSessionModel) async throws -> SelectionInfo {
        let page = try #require(reader.pdfView.document?.page(at: 0))
        let range = ((page.string ?? "") as NSString).range(of: passage)
        try #require(range.location != NSNotFound)
        let selection = try #require(page.selection(for: range))
        reader.pdfView.setCurrentSelection(selection, animate: false)
        await ReaderTestSupport.wait { model.selection?.text == passage && model.selection?.rects.isEmpty == false }
        return try #require(model.selection)
    }

    /// The spans the model gives `passage` on page 1 (the fake paper service's text is the page's own).
    @MainActor private func spans(of passage: String, fixture: String = "ay_round_nolinks") throws -> [TextSpan] {
        let document = try #require(PDFDocument(url: Fixtures.url("pdf/\(fixture).pdf")))
        let range = ((document.page(at: 0)?.string ?? "") as NSString).range(of: passage)
        try #require(range.location != NSNotFound)
        return [TextSpan(pageIndex: 0, range: TextRange(range))]
    }

    @Test @MainActor func theBarComesOnceTheSelectionSettlesAndStepsAsideWhileACommentIsWrittenOnIt() async throws {
        let model = try await ReaderTestSupport.openModel()
        let (reader, window) = try await ReaderTestSupport.attachedReader(model)
        defer { window.close() }
        #expect(reader.selectionBarSelection == nil)

        let selection = try await select(Self.passage, in: reader, model: model)
        await ReaderTestSupport.wait { reader.selectionBarSelection != nil }
        #expect(reader.selectionBarSelection?.spans == selection.spans)

        model.beginComposingComment()                               // Comment in the bar, or N
        #expect(model.composing?.selection?.spans == selection.spans)
        #expect(reader.selectionBarSelection == nil)                 // its result is in the sidebar
        #expect(reader.pdfView.currentSelection != nil)              // the passage stays marked while the comment is written
        model.cancelComposing()
        #expect(reader.selectionBarSelection?.spans == selection.spans)
    }

    @Test @MainActor func aSelectionOfTwoCharactersHasNoBar() async throws {
        let model = try await ReaderTestSupport.openModel()
        let (reader, window) = try await ReaderTestSupport.attachedReader(model)
        defer { window.close() }
        _ = try await select("He", in: reader, model: model)
        await ReaderTestSupport.settle(milliseconds: 400)
        #expect(reader.selectionBar.settled == nil)
        #expect(reader.selectionBarSelection == nil)
    }

    @Test @MainActor func aPassageAskedAboutOrCommentedOnHasNoBar() async throws {
        let spans = try spans(of: Self.passage)
        let asked = Anchor(quote: Self.passage, spans: spans, pageIndex: 0, confidence: .exact, locationLabel: "p. 1")
        let conversation = Conversation(id: UUID(), anchor: asked, createdAt: ReaderTestSupport.date)
        let model = try await ReaderTestSupport.openModel(conversations: [conversation])
        let (reader, window) = try await ReaderTestSupport.attachedReader(model)
        defer { window.close() }
        _ = try await select(Self.passage, in: reader, model: model)
        await ReaderTestSupport.wait { reader.selectionBar.settled != nil }
        #expect(reader.selectionBar.settled?.spans == spans)
        #expect(reader.selectionBarSelection == nil)

        // Another passage still gets its bar.
        let other = try await select("Herding has been", in: reader, model: model)
        await ReaderTestSupport.wait { reader.selectionBarSelection != nil }
        #expect(reader.selectionBarSelection?.spans == other.spans)
    }

    @Test @MainActor func anOwnCommentMadeFromThePassageKeepsTheBarAwayButAnAICommentDoesNot() async throws {
        let spans = try spans(of: Self.passage)
        var own = ReaderTestSupport.comment(status: .approved, origin: .user, rects: [])
        own.anchor = Anchor(quote: Self.passage, spans: spans, pageIndex: 0, confidence: .exact, locationLabel: "p. 1")
        var ai = ReaderTestSupport.comment(status: .pending, rects: [])
        ai.anchor = own.anchor
        let document = DocumentRef(sha256: String(repeating: "ab", count: 32), fileName: "paper.pdf", byteCount: 1, pageCount: 4)
        let session = ReviewSession(schemaVersion: 1, id: UUID(), document: document, meta: ManuscriptMeta(reviewerNotes: ""),
                                    comments: [own], createdAt: ReaderTestSupport.date, updatedAt: ReaderTestSupport.date)
        let selection = SelectionInfo(text: Self.passage, spans: spans, rects: [PageRect(pageIndex: 0, x: 100, y: 600, width: 200, height: 10)])
        #expect(ReaderSelectionBarState.stepsAside(for: selection, composing: nil, session: session))
        var withAI = session
        withAI.comments = [ai]
        #expect(!ReaderSelectionBarState.stepsAside(for: selection, composing: nil, session: withAI))   // an AI comment's quote can be asked about
        #expect(!ReaderSelectionBarState.stepsAside(for: selection, composing: nil, session: nil))
        #expect(ReaderSelectionBarState.stepsAside(for: selection, composing: ComposingComment(selection: SelectionInfo(text: Self.passage, spans: spans)),
                                                   session: nil))                    // compared by spans: rectangles may not be in yet
        #expect(!ReaderSelectionBarState.stepsAside(for: SelectionInfo(text: "", spans: []), composing: ComposingComment(selection: nil),
                                                    session: withAI))
    }

    @Test @MainActor func copyReadsCopiedThenTheBarStepsAsideUntilTheSelectionChanges() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("local.referee.test.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let model = try await ReaderTestSupport.openModel()
        let (reader, window) = try await ReaderTestSupport.attachedReader(model)
        defer { window.close() }
        let selection = try await select(Self.passage, in: reader, model: model)
        await ReaderTestSupport.wait { reader.selectionBarSelection != nil }
        let shown = try #require(reader.selectionBarSelection)

        reader.copySelection(shown, to: pasteboard)
        #expect(pasteboard.string(forType: .string) == selection.text)
        #expect(reader.selectionBar.isShowingCopied(for: shown))
        #expect(reader.selectionBarSelection != nil)                 // "Copied" is shown on the bar
        await ReaderTestSupport.wait(seconds: 5) { reader.selectionBarSelection == nil }
        #expect(reader.selectionBarSelection == nil)                 // after Theme.feedbackDuration it steps aside
        #expect(!reader.selectionBar.isShowingCopied(for: shown))
        #expect(model.selection?.spans == selection.spans)           // the passage is still selected

        // Another selection brings the bar back, and so does the first passage once it is selected again.
        _ = try await select("Herding has been", in: reader, model: model)
        await ReaderTestSupport.wait { reader.selectionBarSelection != nil }
        #expect(reader.selectionBarSelection != nil)
        _ = try await select(Self.passage, in: reader, model: model)
        await ReaderTestSupport.wait { reader.selectionBarSelection?.spans == selection.spans }
        #expect(reader.selectionBarSelection?.spans == selection.spans)
    }
}
