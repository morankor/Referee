import Foundation
import PDFKit
import Testing
import RefereeCore
import PDFBridge
import TestSupport

/// WP2 rows "raw consistency" and "links" (plan.md section 11.4), and the outline. The extraction of each committed PDF
/// equals its committed dump (PDFBridgeSmokeTests); these tests state what both must satisfy.
@Suite struct RawExtractorTests {
    /// Each line's text is the substring of the page string at its range; ranges increase and never overlap.
    private func expectConsistent(_ raw: RawDocument, _ name: String) {
        for page in raw.pages {
            let string = page.string as NSString
            var end = 0
            for line in page.lines {
                #expect(line.range.location >= end, "\(name) page \(page.index): \(line.range) starts before \(end)")
                #expect(line.range.length >= 0)
                guard line.range.location >= 0, line.range.length >= 0, line.range.upperBound <= string.length else {
                    Issue.record("\(name) page \(page.index): \(line.range) is outside a string of \(string.length) units")
                    continue
                }
                #expect(line.text == string.substring(with: line.range.nsRange), "\(name) page \(page.index): \(line.range)")
                end = line.range.upperBound
            }
        }
    }

    @Test(arguments: allFixtures)
    func everyExtractedLineIsTheSubstringAtItsRangeAndTheRangesIncrease(name: String) throws {
        let raw = RawExtractor.extract(from: try fixtureDocument(name))
        #expect(!raw.pages.isEmpty)
        expectConsistent(raw, name)
    }

    @Test(arguments: allFixtures)
    func everyCommittedDumpIsConsistentToo(name: String) throws {
        expectConsistent(try Fixtures.rawDocument(name), name)
    }

    /// The number of line selections is not the number of newline-separated pieces (section 7.2): the displayed fraction
    /// of ay_round_nolinks puts two line selections on one piece, and on every page of s1_ruler the header and its
    /// "Page N of 4" share one.
    @Test func lineSelectionsAreNotNewlineSeparatedPieces() throws {
        let page2 = RawExtractor.extract(from: try fixtureDocument("ay_round_nolinks")).pages[1]
        #expect(page2.lines.count == 22)
        #expect(page2.string.components(separatedBy: "\n").count == 21)

        for page in RawExtractor.extract(from: try fixtureDocument("s1_ruler")).pages {
            #expect(page.lines.count != page.string.components(separatedBy: "\n").count, "s1_ruler page \(page.index)")
        }
    }

    @Test func aPageWithoutTextHasNoLines() throws {
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        let raw = RawExtractor.extract(from: document)
        #expect(raw.pages.count == 1)
        #expect(raw.pages[0].string == "")
        #expect(raw.pages[0].lines.isEmpty)
        #expect(raw.links.isEmpty && raw.outline.isEmpty)

        let scanned = RawExtractor.extract(from: try fixtureDocument("scanned"))
        #expect(scanned.pages.count == 1 && scanned.pages[0].string.isEmpty && scanned.pages[0].lines.isEmpty)
    }

    // MARK: - Links

    private func internalPages(_ links: [RawLink]) -> [Int] {
        links.compactMap { link in
            if case .internalDestination(let pageIndex, _, _) = link.target { return pageIndex }
            return nil
        }
    }

    private func urls(_ links: [RawLink]) -> [String] {
        links.compactMap { link in
            if case .url(let url) = link.target { return url }
            return nil
        }
    }

    @Test func numLinksHasTenCitationLinksAndTwoPiecesOfOneDOI() throws {
        let links = RawExtractor.extract(from: try fixtureDocument("num_links")).links
        #expect(links.count == 12)
        #expect(internalPages(links).count == 10)
        #expect(Set(internalPages(links)) == [2, 3])
        #expect(urls(links).count == 2)
        #expect(urls(links).allSatisfy { $0.contains("doi.org/10.3115/v1/D14-1179") })
        #expect(links.allSatisfy { !$0.text.isEmpty })
    }

    @Test(arguments: [("num_twocol_links", 12), ("ay_links", 36), ("ay_nolinks", 0), ("ay_round_nolinks", 0), ("s1_ruler", 0), ("scanned", 0)])
    func linkCount(name: String, count: Int) throws {
        let raw = RawExtractor.extract(from: try fixtureDocument(name))
        #expect(raw.links.count == count)
        for link in raw.links {
            #expect(link.pageIndex >= 0 && link.pageIndex < raw.pages.count)
            #expect(link.bounds.pageIndex == link.pageIndex)
        }
    }

    @Test func everyLinkOfAyLinksIsInternal() throws {
        let links = RawExtractor.extract(from: try fixtureDocument("ay_links")).links
        #expect(internalPages(links).count == 36)
        #expect(internalPages(links).allSatisfy { $0 >= 0 && $0 < 4 })
        // natbib links the author and the year separately: the first citation of the introduction is two links.
        #expect(links.prefix(2).map(\.text) == ["Banerjee", "1992"])
    }

    // MARK: - Outline

    @Test(arguments: [("num_links", ["Introduction", "Method", "Results"], [0, 1, 2]),
                      ("num_twocol_links", ["Introduction", "Method", "Results"], [0, 0, 1]),
                      ("ay_links", ["Introduction", "Model", "Results"], [0, 1, 1]),
                      ("ay_nolinks", [], []), ("s1_ruler", [], []), ("scanned", [], [])])
    func outlineInPreorder(name: String, titles: [String], pages: [Int]) throws {
        let outline = RawExtractor.extract(from: try fixtureDocument(name)).outline
        #expect(outline.map(\.title) == titles)
        #expect(outline.map(\.pageIndex) == pages.map { Optional($0) })
        #expect(outline.map(\.id) == Array(outline.indices))
        #expect(outline.allSatisfy { $0.depth == 0 })
    }
}
