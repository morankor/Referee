import AppKit
import PDFKit
import Testing
import TestSupport
@testable import RefereeUI

/// Find in a PDF view (plan.md section 7.6), on a real fixture: `findString` with `.caseInsensitive`, all matches
/// marked, the current one the view's selection, "3 of 17".
@Suite struct ReaderFinderTests {
    /// The fixture as a display document is made: from its bytes.
    @MainActor static func document(_ fixture: String) throws -> PDFDocument {
        let document: PDFDocument? = PDFDocument(data: try Data(contentsOf: Fixtures.url("pdf/\(fixture).pdf")))
        return try #require(document)
    }

    @MainActor private func viewWithDocument(_ fixture: String = "ay_round_nolinks") throws -> PDFView {
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        view.document = try Self.document(fixture)
        return view
    }

    @Test @MainActor func matchesAreCountedMarkedAndSteppedThroughWithWrapping() throws {
        let view = try viewWithDocument()
        let finder = ReaderFinder(pdfView: view)
        finder.query = "EFFECT"                                  // case does not matter
        finder.show()
        #expect(finder.isVisible)
        #expect(finder.resultCount == 3)                         // two on page 1, one on page 3
        #expect(finder.countText == "1 of 3")
        #expect(view.highlightedSelections?.count == 3)
        let first = try #require(view.currentSelection)
        #expect(finder.owns(first))
        #expect(first.string?.lowercased() == "effect")

        finder.next()
        #expect(finder.countText == "2 of 3")
        finder.next()
        #expect(finder.countText == "3 of 3")
        #expect(view.currentSelection?.pages.first.map { view.document?.index(for: $0) } == 2)
        finder.next()
        #expect(finder.countText == "1 of 3")                    // wraps round
        finder.previous()
        #expect(finder.countText == "3 of 3")

        finder.close()
        #expect(!finder.isVisible)
        #expect(view.highlightedSelections == nil)
        #expect(view.currentSelection == nil)                    // the current match was the selection; it goes too
        #expect(finder.query == "EFFECT")                        // kept for next time
        #expect(finder.countText == "")
    }

    @Test @MainActor func aSelectionOfTheReferees() throws {
        let view = try viewWithDocument()
        let finder = ReaderFinder(pdfView: view)
        let page = try #require(view.document?.page(at: 0))
        guard let own = page.selection(for: NSRange(location: 0, length: 20)) else {
            Issue.record("PDFKit made no selection of the range")
            return
        }
        view.setCurrentSelection(own, animate: false)
        #expect(!finder.owns(own))                               // nothing found yet
        finder.query = "effect"
        finder.search()
        #expect(finder.owns(try #require(view.currentSelection)))
        #expect(!finder.owns(own))
        // Closing leaves a selection alone that the finder did not make.
        view.setCurrentSelection(own, animate: false)
        finder.close()
        #expect(view.currentSelection === own || view.currentSelection?.string == own.string)
    }

    @Test @MainActor func noMatchesAndNoQuery() throws {
        let view = try viewWithDocument()
        let finder = ReaderFinder(pdfView: view)
        finder.show()
        #expect(finder.countText == "")
        finder.query = "zebra crossing"
        finder.search()
        #expect(finder.resultCount == 0)
        #expect(finder.countText == "No matches")
        #expect(view.highlightedSelections == nil)
        finder.query = "   "
        finder.search()
        #expect(finder.countText == "No matches")
    }

    @Test @MainActor func nextWithoutAQueryOnlyPutsTheCursorIntoTheField() throws {
        let view = try viewWithDocument()
        let finder = ReaderFinder(pdfView: view)
        let request = finder.focusRequest
        finder.next()
        #expect(finder.isVisible)
        #expect(finder.focusRequest == request + 1)
        #expect(finder.resultCount == 0)
        // With a query that was never searched, Next searches and shows the first match.
        finder.query = "herding"
        finder.next()
        #expect(finder.countText == "1 of 1")
    }

    @Test @MainActor func aNewDocumentForgetsTheResults() throws {
        let view = try viewWithDocument()
        let finder = ReaderFinder(pdfView: view)
        finder.query = "effect"
        finder.show()
        #expect(finder.resultCount == 3)
        view.document = try Self.document("num_links")
        finder.documentDidChange()                               // the bar is open: the new document is searched
        #expect(finder.resultCount == (view.document?.findString("effect", withOptions: [.caseInsensitive]).count ?? -1))
        finder.close()
        view.document = try Self.document("ay_round_nolinks")
        finder.documentDidChange()
        #expect(finder.resultCount == 0)
        #expect(finder.countText == "")
    }

    @Test func theCountReads() {
        #expect(ReaderFinder.countText(current: 2, count: 17, capped: false, searched: true) == "3 of 17")
        #expect(ReaderFinder.countText(current: 0, count: 5_000, capped: true, searched: true) == "1 of 5000+")
        #expect(ReaderFinder.countText(current: nil, count: 0, capped: false, searched: true) == "No matches")
        #expect(ReaderFinder.countText(current: nil, count: 0, capped: false, searched: false) == "")
    }
}
