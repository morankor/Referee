import AppKit
import PDFKit
import Testing
import RefereeCore
import AppCore
import TestSupport
@testable import RefereeUI

/// The reader's controller with a real PDF view (plan.md sections 7.3–7.6 and 8.6), on the fakes of TestSupport: the
/// paper is `ay_round_nolinks` with identity text, the session and the citation index are the test's own. The PDF view
/// sits in a window that is never put on screen.
@Suite struct ReaderControllerTests {
    // Rectangles on page 1 of the fixture (612 × 792 points); the text block runs from x 110.9.
    private static let upper = PageRect(pageIndex: 0, x: 110.9, y: 560, width: 300, height: 10.6)
    private static let middle = PageRect(pageIndex: 0, x: 110.9, y: 500, width: 300, height: 10.6)
    private static let lower = PageRect(pageIndex: 0, x: 110.9, y: 440, width: 300, height: 10.6)

    @MainActor private func ours(on page: PDFPage) -> [PDFAnnotation] {
        page.annotations.filter { ReaderHighlightController.ownerID(of: $0) != nil }
    }

    @MainActor private func fill(of id: UUID, on page: PDFPage) -> PDFAnnotation? {
        ours(on: page).first { ReaderHighlightController.ownerID(of: $0) == id && $0.type == "Highlight" }
    }

    @Test @MainActor func highlightsFollowCommentsFilterSelectionAndSettings() async throws {
        let pending = ReaderTestSupport.comment(status: .pending, rects: [Self.upper])
        let approved = ReaderTestSupport.comment(status: .approved, rects: [Self.middle], confidence: .fuzzy(score: 0.9))
        let rejected = ReaderTestSupport.comment(status: .rejected, rects: [Self.lower])
        let model = try await ReaderTestSupport.openModel(comments: [pending, approved, rejected])
        let (reader, window) = try await ReaderTestSupport.attachedReader(model)
        defer { window.close() }
        let page = try #require(reader.pdfView.document?.page(at: 0))

        await ReaderTestSupport.wait { ours(on: page).count == 3 }
        #expect(Set(ours(on: page).compactMap(ReaderHighlightController.ownerID)) == [pending.id, approved.id])   // rejected: setting off
        #expect(ours(on: page).filter { $0.type == "Square" }.count == 1)                     // the fuzzy anchor's dashed frame
        let pendingFill = try #require(fill(of: pending.id, on: page))
        #expect(abs(pendingFill.color.alphaComponent - 0.35) < 0.01)
        #expect(abs(pendingFill.bounds.minX - Self.upper.x) < 0.01 && abs(pendingFill.bounds.width - Self.upper.width) < 0.01)
        #expect(pendingFill.userName == "referee:" + pending.id.uuidString)
        #expect(ours(on: page).first { $0.type == "Square" }?.border?.style == .dashed)

        model.selectedCommentID = pending.id
        await ReaderTestSupport.wait { (fill(of: pending.id, on: page)?.color.alphaComponent ?? 0) > 0.55 }
        #expect(abs((fill(of: pending.id, on: page)?.color.alphaComponent ?? 0) - 0.60) < 0.01)
        #expect(ours(on: page).filter { ReaderHighlightController.ownerID(of: $0) == pending.id }.count == 1)    // replaced, not added

        model.filter = .approved
        await ReaderTestSupport.wait { fill(of: pending.id, on: page) == nil }
        #expect(Set(ours(on: page).compactMap(ReaderHighlightController.ownerID)) == [approved.id])

        model.filter = .all
        var settings = model.settings
        settings.ui.showRejectedHighlights = true
        model.reloadSettings(settings)
        await ReaderTestSupport.wait { fill(of: rejected.id, on: page) != nil }
        #expect(abs((fill(of: rejected.id, on: page)?.color.alphaComponent ?? 0) - 0.15) < 0.01)
        #expect(reader.pdfView.document?.documentURL == nil)       // in memory only: nothing can write them to the file
    }

    @Test @MainActor func aNewDocumentGetsItsHighlightsAgain() async throws {
        let pending = ReaderTestSupport.comment(status: .pending, rects: [Self.upper])
        let model = try await ReaderTestSupport.openModel(comments: [pending])
        let (reader, window) = try await ReaderTestSupport.attachedReader(model)
        defer { window.close() }
        let first = try #require(reader.pdfView.document)
        await ReaderTestSupport.wait { first.page(at: 0).map { fill(of: pending.id, on: $0) != nil } ?? false }

        await model.close()
        await ReaderTestSupport.wait { !reader.isDocumentLoaded }
        #expect(!reader.isDocumentLoaded)
        await model.open(url: Fixtures.url("pdf/ay_round_nolinks.pdf"))
        await ReaderTestSupport.wait { reader.pdfView.document.map { $0 !== first } ?? false }
        let second = try #require(reader.pdfView.document?.page(at: 0))
        await ReaderTestSupport.wait { fill(of: pending.id, on: second) != nil }
        #expect(fill(of: pending.id, on: second) != nil)
    }

    @Test @MainActor func aClickOnACitationOpensTheCardWithoutPDFKitSeeingIt() async throws {
        let mentionRect = PageRect(pageIndex: 0, x: 300, y: 450, width: 60, height: 12)
        let mention = CitationMention(id: 0, pageIndex: 0, text: "Banerjee (1992", rects: [mentionRect], entryIDs: [0], source: .textPattern)
        let index = CitationIndex(style: .authorYear, entries: [ReaderTestSupport.entry(0)], mentions: [mention])
        let model = try await ReaderTestSupport.openModel(index: index)
        let (reader, window) = try await ReaderTestSupport.attachedReader(model)
        defer { window.close() }
        let pageBefore = reader.pdfView.currentPage

        // The path of section 10.1's check-citation-click: the view hitTest finds at the mention, a mouse-down sent to it.
        let point = try ReaderTestSupport.windowPoint(of: mentionRect, in: reader)
        let hit = try #require(window.contentView?.hitTest(point))
        hit.mouseDown(with: try ReaderTestSupport.mouseEvent(.leftMouseDown, at: point, in: window))
        #expect(model.citationLookup != .idle)
        reader.pdfView.mouseUp(with: try ReaderTestSupport.mouseEvent(.leftMouseUp, at: point, in: window))
        await ReaderTestSupport.wait {
            if case .resolved = model.citationLookup { return true }
            return false
        }
        guard case .resolved(let target, let entries, let references) = model.citationLookup else {
            Issue.record("the lookup did not resolve: \(model.citationLookup)")
            return
        }
        #expect(target == .mention(0))
        #expect(entries.map(\.id) == [0])
        #expect(references.first?.status == .resolved)
        #expect(reader.pdfView.currentPage === pageBefore)
        #expect(reader.pdfView.currentSelection == nil)
        #expect(reader.cardMention?.id == 0)

        // The cursor over it is PDFKit's link cursor; beside it, it is not. PDFKit asks with the mouse event, and passes
        // the point on to `areaOfInterest(for:)` in view coordinates (measured: the view is not at the window's origin).
        let viewPoint = reader.pdfView.convert(point, from: nil)
        #expect(reader.pdfView.areaOfInterest(for: viewPoint).contains(.linkArea))
        #expect(reader.pdfView.areaOfInterest(forMouse: try ReaderTestSupport.mouseEvent(.mouseMoved, at: point, in: window)).contains(.linkArea))
        #expect(reader.isOverCitation(at: viewPoint))
        let besidePage = try #require(reader.pdfView.document?.page(at: 0))
        let beside = reader.pdfView.convert(CGPoint(x: 200, y: 300), from: besidePage)
        #expect(!reader.isOverCitation(at: beside))
        let besideInWindow = reader.pdfView.convert(beside, to: nil)
        #expect(!reader.pdfView.areaOfInterest(forMouse: try ReaderTestSupport.mouseEvent(.mouseMoved, at: besideInWindow, in: window)).contains(.linkArea))

        // A click anywhere else in the PDF closes the card.
        #expect(reader.handleMouseDown(at: beside) == .other)
        #expect(model.citationLookup == .idle)
    }

    @Test @MainActor func aClickOnAHighlightSelectsItsComment() async throws {
        let comment = ReaderTestSupport.comment(status: .approved, rects: [Self.middle])
        let model = try await ReaderTestSupport.openModel(comments: [comment])
        let (reader, window) = try await ReaderTestSupport.attachedReader(model)
        defer { window.close() }
        await ReaderTestSupport.wait { !reader.highlights.shown.isEmpty }
        let page = try #require(reader.pdfView.document?.page(at: 0))
        let inView = reader.pdfView.convert(Self.middle.cgRect, from: page)
        #expect(reader.handleMouseDown(at: CGPoint(x: inView.midX, y: inView.midY)) == .highlight)
        #expect(model.selectedCommentID == comment.id)
        #expect(model.sidebarTab == .comments)
    }

    @Test @MainActor func revealPutsThePassageOneThirdDownAndFlashesIt() async throws {
        let target = PageRect(pageIndex: 2, x: 110.9, y: 400, width: 300, height: 10.6)
        let comment = ReaderTestSupport.comment(rects: [target])
        let model = try await ReaderTestSupport.openModel(comments: [comment])
        let (reader, window) = try await ReaderTestSupport.attachedReader(model)
        defer { window.close() }
        let page = try #require(reader.pdfView.document?.page(at: 2))
        func distanceFromTop() -> CGFloat {
            reader.pdfView.bounds.height - reader.pdfView.convert(target.cgRect, from: page).maxY
        }
        func flashes() -> [PDFAnnotation] { page.annotations.filter { $0.userName == ReaderHighlightController.flashUserName } }

        model.selectedCommentID = comment.id
        model.revealSelectedCommentInPDF()
        await ReaderTestSupport.wait { abs(distanceFromTop() - reader.pdfView.bounds.height / 3) < 4 }
        #expect(abs(distanceFromTop() - reader.pdfView.bounds.height / 3) < 4)
        #expect(flashes().count == 1)
        #expect(flashes().first?.type == "Underline")
        await ReaderTestSupport.wait(seconds: 3) { flashes().isEmpty }
        #expect(flashes().isEmpty)                                  // gone after 0.8 s
    }

    @Test @MainActor func aPageOnlyAnchorGoesToItsPageAndARevealClosesTheCard() async throws {
        var pageOnly = ReaderTestSupport.comment(rects: [])
        pageOnly.anchor = Anchor(quote: "not in the paper", pageIndex: 3, confidence: .pageOnly, locationLabel: "p. 4")
        let index = CitationIndex(style: .authorYear, entries: [ReaderTestSupport.entry(0)], mentions: [])
        let model = try await ReaderTestSupport.openModel(comments: [pageOnly], index: index)
        let (reader, window) = try await ReaderTestSupport.attachedReader(model)
        defer { window.close() }
        model.lookUpEntry(entryID: 0)
        #expect(model.citationLookup != .idle)

        model.selectedCommentID = pageOnly.id
        model.revealSelectedCommentInPDF()
        await ReaderTestSupport.wait { reader.pdfView.currentPage.map { reader.pdfView.document?.index(for: $0) } == 3 }
        #expect(reader.pdfView.currentPage.map { reader.pdfView.document?.index(for: $0) } == 3)
        #expect(model.citationLookup == .idle)                       // the page changed under the card
    }

    @Test @MainActor func theCardClosesWhenItsMentionLeavesTheView() async throws {
        let mentionRect = PageRect(pageIndex: 0, x: 300, y: 450, width: 60, height: 12)
        let mention = CitationMention(id: 0, pageIndex: 0, text: "Banerjee (1992", rects: [mentionRect], entryIDs: [0], source: .textPattern)
        let model = try await ReaderTestSupport.openModel(index: CitationIndex(style: .authorYear, entries: [ReaderTestSupport.entry(0)],
                                                                               mentions: [mention]))
        let (reader, window) = try await ReaderTestSupport.attachedReader(model)
        defer { window.close() }
        model.readerClickedCitation(mentionID: 0)
        await ReaderTestSupport.wait {
            if case .resolved = model.citationLookup { return true }
            return false
        }
        // Scrolling a little keeps it; scrolling the mention out of sight closes it.
        let documentView = try #require(reader.pdfView.documentView)
        let visible = documentView.visibleRect
        documentView.scroll(NSPoint(x: visible.minX, y: visible.minY + (documentView.isFlipped ? 20 : -20)))
        await ReaderTestSupport.settle()
        #expect(model.citationLookup != .idle)
        let lastPage = try #require(reader.pdfView.document?.page(at: 3))
        reader.pdfView.go(to: lastPage)
        await ReaderTestSupport.wait { model.citationLookup == .idle }
        #expect(model.citationLookup == .idle)
    }

    @Test @MainActor func theRawSelectionReachesTheModelButAFindMatchDoesNot() async throws {
        let model = try await ReaderTestSupport.openModel()
        let (reader, window) = try await ReaderTestSupport.attachedReader(model)
        defer { window.close() }
        let page = try #require(reader.pdfView.document?.page(at: 0))
        let range = ((page.string ?? "") as NSString).range(of: "Herding has been studied")
        try #require(range.location != NSNotFound)
        guard let herding = page.selection(for: range) else {
            Issue.record("PDFKit made no selection of the range")
            return
        }
        reader.pdfView.setCurrentSelection(herding, animate: false)
        await ReaderTestSupport.wait { model.selection?.rects.isEmpty == false }
        #expect(model.selection?.text == "Herding has been studied")
        #expect(model.selection?.spans == [TextSpan(pageIndex: 0, range: TextRange(range))])

        reader.find("effect")                                       // the current match becomes the PDF's selection
        await ReaderTestSupport.wait { model.selection == nil }
        #expect(model.selection == nil)
        #expect(reader.finder.countText == "1 of 3")

        // Esc in the window: the model clears its selection and tells the PDF view to clear its own.
        reader.finder.close()
        reader.pdfView.setCurrentSelection(herding, animate: false)
        await ReaderTestSupport.wait { model.selection != nil }
        model.dismissTransientUI()
        await ReaderTestSupport.wait { reader.pdfView.currentSelection == nil }
        #expect(reader.pdfView.currentSelection == nil)
        #expect(model.selection == nil)
    }

    @Test @MainActor func zoomStepsAndFitWidth() async throws {
        let model = try await ReaderTestSupport.openModel()
        let (reader, window) = try await ReaderTestSupport.attachedReader(model)
        defer { window.close() }
        #expect(reader.pdfView.autoScales)
        let fitted = reader.pdfView.scaleFactor
        reader.zoom(.zoomIn)
        #expect(!reader.pdfView.autoScales)
        #expect(reader.pdfView.scaleFactor > fitted * 1.1)
        reader.zoom(.zoomOut)
        reader.zoom(.zoomOut)
        #expect(reader.pdfView.scaleFactor < fitted)
        reader.zoom(.fitWidth)
        #expect(reader.pdfView.autoScales)
        await ReaderTestSupport.settle()
        #expect(abs(reader.pdfView.scaleFactor - fitted) < 0.01)
    }

    @Test @MainActor func theMenuItemsReachTheFindBar() async throws {
        let model = try await ReaderTestSupport.openModel()
        let (reader, window) = try await ReaderTestSupport.attachedReader(model)
        defer { window.close() }
        reader.showFind()
        #expect(reader.finder.isVisible)
        reader.finder.query = "effect"
        reader.findNext()
        #expect(reader.finder.countText == "1 of 3")
        reader.findNext()
        #expect(reader.finder.countText == "2 of 3")
        reader.findPrevious()
        #expect(reader.finder.countText == "1 of 3")
        #expect(reader.pdfView.highlightedSelections?.count == 3)

        // Each current match is in sight, below the find bar: the one on page 3 was scrolled to.
        func currentIsInSight() -> Bool {
            guard let match = reader.pdfView.currentSelection, let page = match.pages.first else { return false }
            return ReaderScrolling.isInSight(match.bounds(for: page), on: page, in: reader.pdfView, topInset: ReaderFinder.barClearance)
        }
        #expect(currentIsInSight())
        reader.findPrevious()
        #expect(reader.finder.countText == "3 of 3")
        #expect(reader.pdfView.currentSelection?.pages.first.map { reader.pdfView.document?.index(for: $0) } == 2)
        #expect(currentIsInSight())
    }
}
