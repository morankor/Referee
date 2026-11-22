import Foundation
import Testing
import RefereeCore
import TestSupport
@testable import CitationKit

/// The rows of WP3's acceptance table that are measured on the committed fixtures (plan.md §11.4, rows marked ●).
/// `PaperTextBuilder` is a placeholder in this worktree, so the paper is `identityPaperText` of the raw dump: every
/// line `.body`, which is clean for these four fixtures (page numbers stay in the text and end up in the entries that
/// end a page; nothing below depends on those).
@Suite struct CitationFixtureTests {
    private typealias Docs = CitationTestDocuments

    private static let roundTargets = [
        "p1 Banerjee", "p1 Bikhchandani", "p1 Avery", "p1 Smith", "p1 Acemoglu", "p1 Smith", "p1 Kogan", "p1 Lee",
        "p2 Banerjee", "p2 Avery", "p2 Lee", "p2 Smith", "p2 Osborne", "p2 Dekel", "p2 Bikhchandani",
    ]

    private static func targets(_ index: CitationIndex) -> [String] {
        index.mentions.map { "p\($0.pageIndex + 1) " + Docs.firstAuthors(of: $0, in: index) }
    }

    // MARK: reference list, author–year

    @Test func authorYearReferenceList() throws {
        let (paper, _) = try Docs.fixture("ay_round_nolinks")
        let index = CitationIndexer().buildIndex(paper: paper, links: [])
        #expect(index.style == .authorYear)
        try #require(index.entries.count == 9)
        #expect(index.entries.map { $0.parsed.authorSurnames.first ?? "" }
                == ["Acemoglu", "Avery", "Banerjee", "Bikhchandani", "Dekel", "Kogan", "Lee", "Osborne", "Smith"])
        #expect(index.entries.map(\.parsed.year) == [2011, 1998, 1992, 1992, 2000, 2020, 2021, 1994, 2000])
        #expect(index.entries.map(\.id) == Array(0..<9))
        #expect(index.entries[0].parsed.authorSurnames == ["Acemoglu", "Dahleh", "Lobel", "Ozdaglar"])

        let dekel = index.entries[4]
        let dekelFirstLine = try #require(dekel.spans.first.map { Docs.text(of: $0, in: paper) })
        #expect(!dekelFirstLine.contains(" "))                      // "DekelE,PiccioneM(2000)Sequentialvoting…"
        #expect(dekel.parsed.authorSurnames == ["Dekel", "Piccione"])
        #expect(dekel.rawText.hasSuffix("J Polit Econ 108(1):34–55"))
        #expect(index.entries[7].rawText.hasSuffix("A Course in Game Theory. MIT Press."))

        // The heading, the spans and the first-line bounds of an entry.
        let heading = try #require(index.bibliographyHeading)
        #expect(Docs.text(of: heading, in: paper) == "References")
        #expect(dekel.spans.map { Docs.text(of: $0, in: paper) }
                == ["DekelE,PiccioneM(2000)Sequentialvotingproceduresinsymmetricbinary", "elections.", "J Polit Econ 108(1):34–55"])
        #expect(dekel.firstLineBounds?.pageIndex == 2)
        #expect(index.entries.allSatisfy { $0.label == nil && $0.firstLineBounds != nil })
    }

    // MARK: mentions, round brackets

    @Test func roundBracketMentions() throws {
        let (paper, _) = try Docs.fixture("ay_round_nolinks")
        let index = CitationIndexer().buildIndex(paper: paper, links: [])
        try #require(index.mentions.count == 15)
        #expect(Self.targets(index) == Self.roundTargets)
        #expect(index.mentions.map(\.id) == Array(0..<15))
        #expect(index.mentions.allSatisfy { $0.source == .textPattern && $0.rects.isEmpty && $0.entryIDs.count == 1 && !$0.spans.isEmpty })

        let m = index.mentions
        #expect(m[1].text.hasPrefix("Bikhchan-") && m[1].spans.count == 2)      // broken by a hyphen across lines
        #expect(m[4].text.hasPrefix("Acemoglu et al.") && m[4].spans.count == 2) // across a line break
        #expect(Docs.surroundings(of: m[5], in: paper).after.hasPrefix(", p. 12)"))
        #expect(Docs.surroundings(of: m[8], in: paper).before.hasSuffix("In "))
        #expect(Docs.surroundings(of: m[9], in: paper).before.hasSuffix("The ") && Docs.surroundings(of: m[9], in: paper).after.hasPrefix(") model"))
        #expect(Docs.surroundings(of: m[10], in: paper).before.hasSuffix("See "))
        #expect(Docs.surroundings(of: m[11], in: paper).before.hasSuffix("Following "))
        #expect(m[14].text == "Bikhchandanietal.(1992")                         // on the line that has no spaces

        // No mention inside the list; none for "Table 2", "Proposition 1" or "(1)".
        let listSpans = index.entries.flatMap(\.spans)
        for mention in m {
            for span in mention.spans {
                #expect(!listSpans.contains { $0.pageIndex == span.pageIndex && NSIntersectionRange($0.range.nsRange, span.range.nsRange).length > 0 })
            }
            #expect(!mention.text.contains("Table") && !mention.text.contains("Proposition") && !mention.text.contains("(1)"))
        }
    }

    // MARK: mentions, square brackets

    @Test func squareBracketMentionsHaveTheSameTargets() throws {
        let (round, _) = try Docs.fixture("ay_round_nolinks")
        let (square, _) = try Docs.fixture("ay_links")
        let roundIndex = CitationIndexer().buildIndex(paper: round, links: [])
        let squareIndex = CitationIndexer().buildIndex(paper: square, links: [])
        #expect(squareIndex.style == .authorYear && squareIndex.entries.count == 9)
        #expect(Self.targets(squareIndex) == Self.roundTargets)
        #expect(squareIndex.mentions.map(\.entryIDs) == roundIndex.mentions.map(\.entryIDs))
        #expect(squareIndex.mentions.allSatisfy { $0.source == .textPattern && $0.rects.isEmpty })
    }

    // MARK: link path

    @Test func linkPath() throws {
        let (paper, links) = try Docs.fixture("ay_links")
        #expect(links.count == 36)
        let analysis = CitationAnalysis(paper: paper, links: links)
        let found = analysis.links
        #expect(found.pieces == 34)
        #expect(found.ignored == 2)
        try #require(found.mentions.count == 15)
        #expect(found.mentions.allSatisfy { $0.source == .linkAnnotation && $0.spans.isEmpty && $0.entryIDs.count == 1 })
        #expect(found.mentions.map { "p\($0.pageIndex + 1) " + Docs.firstAuthors(of: $0, in: analysis.index) } == Self.roundTargets)

        // "Avery and Zem-", "sky", "1998": one mention with three rectangles.
        let averyPieces = links.filter { ["Avery and Zem-", "sky", "1998"].contains($0.text) && $0.pageIndex == 0 }.map(\.bounds)
        #expect(averyPieces.count == 3)
        #expect(found.mentions[2].rects == averyPieces)
        #expect(found.mentions[2].text == "Avery and Zemsky 1998")

        // "Kogan [2020], Lee [2021]": two mentions.
        #expect(Docs.firstAuthors(of: found.mentions[6], in: analysis.index) == "Kogan" && found.mentions[6].rects.count == 2)
        #expect(Docs.firstAuthors(of: found.mentions[7], in: analysis.index) == "Lee" && found.mentions[7].rects.count == 2)
        #expect(found.mentions[6].text == "Kogan 2020" && found.mentions[7].text == "Lee 2021")

        // The links to the table ("2") and to the equation ("1") give none.
        let others = links.filter { $0.text == "2" || $0.text == "1" }.map(\.bounds)
        #expect(others.count == 2)
        #expect(!found.mentions.contains { mention in mention.rects.contains { others.contains($0) } })

        // After the merge: 15 mentions, each with text spans and link rectangles.
        let index = analysis.index
        try #require(index.mentions.count == 15)
        #expect(Self.targets(index) == Self.roundTargets)
        #expect(index.mentions.allSatisfy { !$0.spans.isEmpty && !$0.rects.isEmpty && $0.source == .linkAnnotation })
        #expect(index.mentions.map(\.rects) == found.mentions.map(\.rects))
        #expect(index.mentions.map(\.spans) == analysis.textMentions.map(\.spans))
        #expect(index.mentions.map(\.id) == Array(0..<15))
    }

    // MARK: numeric

    @Test func numericFixture() throws {
        let (paper, _) = try Docs.fixture("num_links")
        let index = CitationIndexer().buildIndex(paper: paper, links: [])
        #expect(index.style == .numeric)
        try #require(index.entries.count == 5)
        #expect(index.entries.map(\.label) == ["1", "2", "3", "4", "5"])
        #expect(index.mentions.map { $0.entryIDs.map { index.entries[$0].label ?? "?" }.joined(separator: ",") }
                == ["4", "2", "1", "1", "5", "3", "4", "2", "1", "5"])
        #expect(index.mentions.allSatisfy { $0.source == .textPattern && $0.spans.count == 1 && $0.rects.isEmpty })

        let second = index.entries[1]
        #expect(second.parsed.doi == "10.3115/v1/d14-1179")
        #expect(second.spans.map { Docs.text(of: $0, in: paper) }.last == "D14-1179")     // the DOI is broken across a line break
        #expect(second.rawText.hasSuffix("https://doi.org/10.3115/v1/D14-1179"))
        let third = index.entries[2]
        #expect(third.parsed.arxivID == "1810.04805")
        #expect(third.parsed.year == 2019)
        #expect(index.entries.map(\.parsed.year) == [2015, 2014, 2019, 1997, 2017])
        #expect(index.entries.map { $0.parsed.authorSurnames.first ?? "" } == ["Bahdanau", "Cho", "Devlin", "Hochreiter", "Vaswani"])
    }

    // MARK: numeric links

    @Test func numericLinks() throws {
        let (paper, links) = try Docs.fixture("num_links")
        let analysis = CitationAnalysis(paper: paper, links: links)
        let labels = ["4", "2", "1", "1", "5", "3", "4", "2", "1", "5"]
        func labelsOf(_ mentions: [CitationMention]) -> [String] {
            mentions.map { $0.entryIDs.map { analysis.index.entries[$0].label ?? "?" }.joined(separator: ",") }
        }
        try #require(analysis.links.mentions.count == 10)
        #expect(labelsOf(analysis.links.mentions) == labels)
        #expect(analysis.links.mentions.allSatisfy { $0.rects.count == 1 })
        #expect(analysis.links.ignored == 0)

        // The "1" that ends one line and the "1" that starts the next stay two mentions.
        let endOfLine = analysis.links.mentions[2]
        let startOfLine = analysis.links.mentions[3]
        #expect(endOfLine.text == "1" && startOfLine.text == "1")
        #expect(endOfLine.rects[0].y > startOfLine.rects[0].y + 5)
        #expect(startOfLine.rects[0].x < endOfLine.rects[0].x)

        // Merged one-to-one with the ten text mentions.
        let index = analysis.index
        try #require(index.mentions.count == 10)
        #expect(labelsOf(index.mentions) == labels)
        #expect(index.mentions.map(\.rects) == analysis.links.mentions.map(\.rects))
        #expect(index.mentions.map(\.spans) == analysis.textMentions.map(\.spans))
        #expect(index.mentions.allSatisfy { $0.rects.count == 1 && $0.spans.count == 1 && $0.source == .linkAnnotation })
        #expect(index.mentions[2].spans[0] != index.mentions[3].spans[0])
    }

    // MARK: two columns, smoke

    @Test func twoColumnsSmoke() throws {
        let (paper, links) = try Docs.fixture("num_twocol_links")
        let analysis = CitationAnalysis(paper: paper, links: links)
        let list = try #require(analysis.list)
        #expect(analysis.index.style == .numeric)
        #expect(analysis.index.entries.count == 5)
        // The list ends where PDFKit's text returns to the left column.
        let firstAfter = analysis.body.lines[list.end]
        #expect(firstAfter.trimmed == "3 Results")
        #expect((firstAfter.bounds?.x ?? 999) < 100)
        #expect(analysis.index.entries[4].rawText.hasSuffix("In NeurIPS, 2017."))
        #expect(analysis.textMentions.count == 10)
        #expect(analysis.links.mentions.count == 10)
        #expect(analysis.index.mentions.count == 10)
        #expect(CitationIndexer().buildIndex(paper: paper, links: []).mentions.count == 10)
    }

    // MARK: the other fixtures do not crash

    @Test(arguments: ["ay_nolinks", "s1_ruler", "scanned"])
    func otherFixturesComplete(name: String) throws {
        let (paper, links) = try Docs.fixture(name)
        let index = CitationIndexer().buildIndex(paper: paper, links: links)
        #expect(index.mentions.allSatisfy { $0.entryIDs.allSatisfy { index.entries.indices.contains($0) } })
        if name == "scanned" { #expect(index == CitationIndex(style: .unknown)) }
    }
}
