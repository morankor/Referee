import Foundation
import Testing
import RefereeCore
@testable import AppCore
import TestSupport

/// Acceptance row "selection normalised" (plan.md section 11.4, WP8b; section 7.4), on a synthetic PaperText with margin
/// digits, a watermark line and a number-only line.
@Suite struct SelectionNormalizerTests {
    static let paper = SyntheticPaper.lineNumbered
    static let text = paper.text

    /// What PDFKit reports for a drag from " As shown by…" on line 1 to "…wheth" on line 2: one span per line, the
    /// first one running into the glued "11".
    static var twoLineRawSelection: SelectionInfo {
        let start = SyntheticPaper.offset(of: " As shown by", in: paper, page: 0)
        let first = TextSpan(pageIndex: 0, range: RefereeCore.TextRange(location: start, length: text.pages[0].lines[1].range.upperBound - start))
        let second = SyntheticPaper.rawSpan(paper, page: 0, line: 2, length: "network structure determines wheth".utf16.count)
        return SelectionInfo(text: " As shown by Acemoglu et al. [2011],11\nnetwork structure determines wheth", spans: [first, second],
                             rects: [PageRect(pageIndex: 0, x: -2.2, y: 700, width: 498.4, height: 12)])
    }

    @Test func aTwoLineSelectionLosesTheMarginDigitsAndGetsOneSpanPerLine() throws {
        let normalised = try #require(SelectionNormalizer.normalize(Self.twoLineRawSelection, in: Self.text))
        #expect(normalised.text == "As shown by Acemoglu et al. [2011], network structure determines wheth")
        #expect(normalised.spans.count == 2)
        #expect(normalised.rects.isEmpty)
        for (span, lineIndex) in zip(normalised.spans, [1, 2]) {
            let content = Self.text.pages[0].lines[lineIndex].contentRange
            #expect(span.pageIndex == 0)
            #expect(span.range.location >= content.location)
            #expect(span.range.upperBound <= content.upperBound)
        }
        let page = Self.text.pages[0].string as NSString
        #expect(page.substring(with: normalised.spans[0].range.nsRange) == "As shown by Acemoglu et al. [2011],")
        #expect(page.substring(with: normalised.spans[1].range.nsRange) == "network structure determines wheth")
    }

    @Test func aSelectionAcrossTheWatermarkAndTheNumberOnlyLineContainsNeither() throws {
        // One raw span per line, as PDFKit gives them: lines 2 to 5, the watermark and "13" included.
        let start = SyntheticPaper.offset(of: "see also", in: Self.paper, page: 0)
        let spans = [TextSpan(pageIndex: 0, range: RefereeCore.TextRange(location: start, length: Self.text.pages[0].lines[2].range.upperBound - start)),
                     SyntheticPaper.rawSpan(Self.paper, page: 0, line: 3), SyntheticPaper.rawSpan(Self.paper, page: 0, line: 4),
                     SyntheticPaper.rawSpan(Self.paper, page: 0, line: 5, length: "We define the office".utf16.count)]
        let normalised = try #require(SelectionNormalizer.normalize(SelectionInfo(text: "raw", spans: spans), in: Self.text))
        #expect(normalised.text == "see also Lee [2021]. We define the office")
        #expect(!normalised.text.contains("CONFIDENTIAL"))
        #expect(!normalised.text.contains("13"))
        #expect(!normalised.text.contains("12"))
        #expect(normalised.spans.count == 2)

        // The same drag reported as one span over the four lines gives the same result.
        let whole = TextSpan(pageIndex: 0, range: RefereeCore.TextRange(location: start, length: spans[3].range.upperBound - start))
        #expect(SelectionNormalizer.normalize(SelectionInfo(text: "raw", spans: [whole]), in: Self.text) == normalised)
    }

    @Test func aSelectionOnlyOnPageFurnitureIsNothing() {
        let watermark = SelectionInfo(text: "CONFIDENTIAL", spans: [SyntheticPaper.rawSpan(Self.paper, page: 0, line: 3)])
        #expect(SelectionNormalizer.normalize(watermark, in: Self.text) == nil)
        let numberOnly = SelectionInfo(text: "13", spans: [SyntheticPaper.rawSpan(Self.paper, page: 0, line: 4)])
        #expect(SelectionNormalizer.normalize(numberOnly, in: Self.text) == nil)
        let pageNumber = SelectionInfo(text: "1", spans: [SyntheticPaper.rawSpan(Self.paper, page: 0, line: 7)])
        #expect(SelectionNormalizer.normalize(pageNumber, in: Self.text) == nil)
        let header = SelectionInfo(text: "Journal", spans: [SyntheticPaper.rawSpan(Self.paper, page: 1, line: 0)])
        #expect(SelectionNormalizer.normalize(header, in: Self.text) == nil)
        let digitsOnly = SelectionInfo(text: "11", spans: [SyntheticPaper.rawSpan(Self.paper, page: 0, line: 1,
                                                                                    from: Self.text.pages[0].lines[1].text.utf16.count)])
        #expect(SelectionNormalizer.normalize(digitsOnly, in: Self.text) == nil)
        #expect(SelectionNormalizer.normalize(SelectionInfo(text: "nothing"), in: Self.text) == nil)
        let elsewhere = SelectionInfo(text: "x", spans: [TextSpan(pageIndex: 9, range: RefereeCore.TextRange(location: 0, length: 5))])
        #expect(SelectionNormalizer.normalize(elsewhere, in: Self.text) == nil)
    }

    @Test func aWordHyphenatedAcrossLinesIsJoinedWithoutTheHyphen() throws {
        let selection = SelectionInfo(text: "raw", spans: [SyntheticPaper.rawSpan(Self.paper, page: 0, line: 5),
                                                         SyntheticPaper.rawSpan(Self.paper, page: 0, line: 6)])
        let normalised = try #require(SelectionNormalizer.normalize(selection, in: Self.text))
        #expect(normalised.text == "We define the office-specific identification threshold and verify the differentiability of the payoff.")
        #expect(normalised.spans.count == 2)
    }

    @Test func theHyphenStaysWhenTheDocumentPrintsTheWordWithIt() throws {
        // "office-specific" stands unbroken on page 2's second line, and "officespecific" nowhere (section 6.2, rule 4).
        let selection = SelectionInfo(text: "raw", spans: [SyntheticPaper.rawSpan(Self.paper, page: 1, line: 2),
                                                         SyntheticPaper.rawSpan(Self.paper, page: 1, line: 3)])
        let normalised = try #require(SelectionNormalizer.normalize(selection, in: Self.text))
        #expect(normalised.text == "The cost of the office-specific rule is the same in every period.")
    }

    @Test func aSelectionAcrossAPageBreakKeepsTextOrder() throws {
        let selection = SelectionInfo(text: "raw", spans: [SyntheticPaper.rawSpan(Self.paper, page: 1, line: 1),
                                                         SyntheticPaper.rawSpan(Self.paper, page: 0, line: 6)])
        let normalised = try #require(SelectionNormalizer.normalize(selection, in: Self.text))
        #expect(normalised.spans.map(\.pageIndex) == [0, 1])
        #expect(normalised.text == "tification threshold and verify the differentiability of the payoff. The office-specific threshold is defined in Section 2.")
    }

    @Test func normalisingTwiceChangesNothing() throws {
        let once = try #require(SelectionNormalizer.normalize(Self.twoLineRawSelection, in: Self.text))
        #expect(SelectionNormalizer.normalize(once, in: Self.text) == once)
    }

    // ---- through the model ----

    @Test @MainActor func theModelPublishesTheNormalisedSelectionAtOnceThenItsRectangles() async throws {
        let harness = try await makeHarness(paper: Self.paper)
        await harness.open()
        harness.model.readerSelectionChanged(Self.twoLineRawSelection)
        let published = try #require(harness.model.selection)
        #expect(published.text == "As shown by Acemoglu et al. [2011], network structure determines wheth")
        #expect(published.rects.isEmpty)                                 // at once, before the paper service answers
        await harness.model.waitForBackgroundWork()
        let filled = try #require(harness.model.selection)
        #expect(filled.spans == published.spans)
        #expect(filled.rects.count == 2)                                 // one per span, from PaperService.rects
        #expect(filled.rects.allSatisfy { $0.x >= 100 })

        harness.model.readerSelectionChanged(SelectionInfo(text: "CONFIDENTIAL", spans: [SyntheticPaper.rawSpan(Self.paper, page: 0, line: 3)]))
        #expect(harness.model.selection == nil)
        harness.model.readerSelectionChanged(Self.twoLineRawSelection)
        harness.model.readerSelectionChanged(nil)
        await harness.model.waitForBackgroundWork()
        #expect(harness.model.selection == nil)                          // late rectangles of an old selection are not applied
    }
}
