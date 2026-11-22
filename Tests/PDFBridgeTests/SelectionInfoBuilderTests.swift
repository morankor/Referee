import Foundation
import PDFKit
import Testing
import RefereeCore
import PDFBridge
import TestSupport

/// WP2 row "selection info" (plan.md sections 7.4 and 11.4): the raw selection, one span and one rectangle per line.
@Suite struct SelectionInfoBuilderTests {
    @Test @MainActor func aSelectionMadeFromARangeGivesThatSpan() throws {
        let document = try fixtureDocument("ay_nolinks")
        let page = try #require(document.page(at: 0))
        let string = try #require(page.string) as NSString
        // Part of a line, and the whole line with its glued "14" (PDFKit then reports the range with its line break).
        for range in [NSRange(location: 697, length: 59), NSRange(location: 697, length: 84)] {
            let selection = try #require(page.selection(for: range))
            let info = try #require(SelectionInfoBuilder.make(from: selection, in: document))
            #expect(info.spans == [TextSpan(pageIndex: 0, range: TextRange(range))])
            #expect(info.rects.count == 1)
            #expect(info.rects.allSatisfy { $0.pageIndex == 0 && $0.width > 0 && $0.height > 0 })
            #expect(info.text.hasPrefix(string.substring(with: range)))
        }
    }

    @Test @MainActor func aSelectionOverTwoLinesGivesTwoSpansAsPDFKitReportsThem() throws {
        let document = try fixtureDocument("ay_nolinks")
        let page = try #require(document.page(at: 0))
        let string = try #require(page.string) as NSString
        let start = string.range(of: " As shown by Acemoglu").location
        let end = NSMaxRange(string.range(of: "network structure determines wheth"))
        let selection = try #require(page.selection(for: NSRange(location: start, length: end - start)))
        let info = try #require(SelectionInfoBuilder.make(from: selection, in: document))

        // Section 7.4: the text of a drag from the middle of one line to the middle of the next, margin digits and all.
        #expect(info.text == " As shown by Acemoglu et al. [2011],11\nnetwork structure determines wheth")
        #expect(info.spans.count == 2)
        #expect(info.spans.map { string.substring(with: $0.range.nsRange) } == [" As shown by Acemoglu et al. [2011],11", "network structure determines wheth"])
        #expect(info.spans.allSatisfy { $0.pageIndex == 0 })
        #expect(info.rects.count == 2)
        // Not normalised: the first rectangle includes the glued "11" and is as wide as the page (x = −2.2, width 498.4).
        #expect(info.rects.first.map { $0.x < 0 && $0.width > 490 } == true, "\(info.rects)")
    }

    @Test @MainActor func aSelectionAcrossAPageBreakHasSpansOnBothPages() throws {
        let document = try fixtureDocument("ay_nolinks")
        let first = try #require(document.page(at: 0))
        let second = try #require(document.page(at: 1))
        let selection = try #require(document.selection(from: first, atCharacterIndex: 900, to: second, atCharacterIndex: 30))
        let info = try #require(SelectionInfoBuilder.make(from: selection, in: document))
        // The end of the last text line of page 1, its page number "1", then "17", "function." and "In Banerjee [1992]".
        #expect(info.spans.map(\.pageIndex) == [0, 0, 1, 1, 1])
        #expect(info.rects.map(\.pageIndex) == [0, 0, 1, 1, 1])
        let strings = [try #require(first.string) as NSString, try #require(second.string) as NSString]
        #expect(info.spans.map { strings[$0.pageIndex].substring(with: $0.range.nsRange) }
                == [" verify the differentiability of the payoff16", "1", "17", "function.", "In Banerjee [1992]"])
        for span in info.spans {
            #expect(!strings[span.pageIndex].substring(with: span.range.nsRange).contains("\n"))
        }
    }

    @Test @MainActor func nothingSelectedGivesNil() throws {
        let document = try fixtureDocument("ay_nolinks")
        #expect(SelectionInfoBuilder.make(from: PDFSelection(document: document), in: document) == nil)

        // A selection on a page of another document names no page of this one.
        let other = try fixtureDocument("num_links")
        let foreign = try #require(other.page(at: 0)?.selection(for: NSRange(location: 0, length: 20)))
        #expect(SelectionInfoBuilder.make(from: foreign, in: document) == nil)
    }
}
