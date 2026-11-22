import Foundation
import Testing
import RefereeCore
@testable import CitationKit

/// "The list ends only on evidence" (plan.md §8.2 step 5): synthetic lists in the shape of the fixtures, hanging
/// entries at x = 72 with continuation lines at x = 84, lines 10 pt high.
@Suite struct CitationListEndTests {
    private typealias Docs = CitationTestDocuments

    private static let fourEntries: [SyntheticLine] = [
        "Abreu, D. and Gul, F. (2000). Bargaining and reputation.",
        .indented("Econometrica, 68(1):85–117."),
        "Banerjee, A. V. (1992). A simple model of herd behavior.",
        .indented("Quarterly Journal of Economics, 107(3):797–817."),
        "Dekel, E. and Piccione, M. (2000). Sequential voting procedures.",
        .indented("Journal of Political Economy, 108(1):34–55."),
        "Kogan, D. (2020). Learning from reviews with strategic sellers.",
        .indented("Working paper."),
    ]

    private static let body: [SyntheticLine] = ["Herding was studied by Banerjee (1992) and later by Kogan (2020)."]

    private static func list(_ lines: [SyntheticLine]) throws -> (analysis: CitationAnalysis, list: ReferenceList) {
        let analysis = CitationAnalysis(paper: Docs.paper(lines), links: [])
        return (analysis, try #require(analysis.list))
    }

    @Test func aTallerLetteredHeadingEndsTheList() throws {
        let appendix: [SyntheticLine] = [SyntheticLine("A Proofs", height: 14),
                                          "The proof of the proposition follows Kogan (2020) and is given here.",
                                          "It uses the notation of the model section."]
        let (analysis, list) = try Self.list(Self.body + ["References"] + Self.fourEntries + appendix)
        #expect(list.style == .authorYear && list.hanging)
        #expect(analysis.body.lines[list.end].trimmed == "A Proofs")
        #expect(analysis.index.entries.count == 4)
        #expect(analysis.index.entries[3].rawText == "Kogan, D. (2020). Learning from reviews with strategic sellers. Working paper.")
        // The text after the list is searched again: the appendix's citation is found.
        #expect(analysis.index.mentions.map { Docs.firstAuthors(of: $0, in: analysis.index) } == ["Banerjee", "Kogan", "Kogan"])
    }

    @Test func appendixAtTheLeftEdgeInTheListsOwnSizeEndsTheList() throws {
        let appendix: [SyntheticLine] = ["Appendix", "Here we collect the proofs of the results in the main text.", "More text."]
        let (analysis, list) = try Self.list(Self.body + ["References"] + Self.fourEntries + appendix)
        #expect(analysis.body.lines[list.end].trimmed == "Appendix")
        #expect(analysis.index.entries.count == 4)
        #expect(analysis.index.entries[3].rawText.hasSuffix("Working paper."))
    }

    @Test func continuationLinesThatLookLikeHeadingsDoNotEndTheList() throws {
        let entries: [SyntheticLine] = Self.fourEntries + [
            "Gradshteyn, I. S. and Ryzhik, I. M. (2007).",
            .indented("Tables of Integrals, Series, and Products. Academic Press."),
            "Osborne, M. J. and Rubinstein, A. (1994).",
            .indented("A Course in Game Theory. MIT Press."),
            "Zwick, R. and Lee, C. (1999). Bargaining and search.",
            .indented("Games and Economic Behavior, 26(2):210–240."),
        ]
        let lines = Self.body + ["References"] + entries
        let (analysis, list) = try Self.list(lines)
        #expect(list.hanging)
        #expect(list.end == analysis.body.lines.count)
        let index = analysis.index
        #expect(index.entries.map { $0.parsed.authorSurnames.first ?? "" } == ["Abreu", "Banerjee", "Dekel", "Kogan", "Gradshteyn", "Osborne", "Zwick"])
        #expect(index.entries[4].rawText.hasSuffix("Tables of Integrals, Series, and Products. Academic Press."))
        #expect(index.entries[5].rawText.hasSuffix("A Course in Game Theory. MIT Press."))

        // The same list set flush left (not hanging): those lines still end nothing, and the last entry is found.
        let flush = lines.map { SyntheticLine($0.text) }
        let (flushAnalysis, flushList) = try Self.list(flush)
        #expect(!flushList.hanging)
        #expect(flushList.end == flushAnalysis.body.lines.count)
        #expect(flushAnalysis.index.entries.last?.parsed.authorSurnames.first == "Zwick")
        #expect(flushAnalysis.index.entries.contains { $0.parsed.authorSurnames.first == "Gradshteyn" })
    }

    @Test func aHeadingWithATrailingNumberIsAccepted() throws {
        for heading in ["References 12", "References12", "7. References", "REFERENCES", "Bibliography", "Works Cited", "4 Reference list"] {
            let paper = Docs.paper(Self.body + [SyntheticLine(heading)] + Self.fourEntries)
            let analysis = CitationAnalysis(paper: paper, links: [])
            #expect(analysis.list != nil, "heading \(heading)")
            #expect(analysis.index.entries.count == 4, "heading \(heading)")
            #expect(analysis.index.bibliographyHeading.map { Docs.text(of: $0, in: paper) } == heading)
            #expect(analysis.index.mentions.count == 2, "heading \(heading)")
        }
        // Not headings: a sentence that mentions references, and a heading followed by more words.
        for line in ["See the references below.", "References and further reading"] {
            let analysis = CitationAnalysis(paper: Docs.paper(Self.body + [SyntheticLine(line)] + Self.fourEntries), links: [])
            #expect(analysis.list == nil, "line \(line)")
        }
    }

    @Test func theLastHeadingWins() throws {
        // A table of contents that names the references, then the real list.
        let lines: [SyntheticLine] = ["Contents", "References", "Appendix"] + Self.body + ["References"] + Self.fourEntries
        let (analysis, list) = try Self.list(lines)
        #expect(list.heading == 4)
        #expect(analysis.index.entries.count == 4)
    }

    @Test func ordinaryTextAtTheLeftEdgeEndsAHangingList() throws {
        // §8.2 step 5 (c): two lines at the left edge in a row that are not entries.
        let after: [SyntheticLine] = ["We now turn to the proofs of the main results of the paper.", "The argument is in three steps."]
        let (analysis, list) = try Self.list(Self.body + ["References"] + Self.fourEntries + after)
        #expect(analysis.body.lines[list.end].trimmed == after[0].text)
        #expect(analysis.index.entries.count == 4)
    }

    @Test func aNumericListEndsAtAKeywordLineAndAtAnEarlierColumn() throws {
        let entries: [SyntheticLine] = [
            "[1] A. Author. First title. Journal, 2001.", "[2] B. Author. Second title. Journal, 2002.",
            "[3] C. Author. Third title. Journal, 2003.", "[4] D. Author. Fourth title. Journal, 2004.",
        ]
        let keyword = try Self.list(["Text [1]."] + ["References"] + entries + ["Supplementary material", "[5] is not an entry here."])
        #expect(keyword.list.style == .numeric)
        #expect(keyword.analysis.body.lines[keyword.list.end].trimmed == "Supplementary material")
        #expect(keyword.analysis.index.entries.count == 4)

        let shifted = entries.map { SyntheticLine($0.text, x: 320) }
        let column = try Self.list(["Text [1]."] + ["References"] + shifted + ["3 Results", "Back in the left column of the page."])
        #expect(column.analysis.body.lines[column.list.end].trimmed == "3 Results")
        #expect(column.analysis.index.entries.count == 4)
    }

    @Test func labelsOnLinesOfTheirOwn() throws {
        let lines: [SyntheticLine] = ["Text cites [2] and [3]."] + ["References"] + [
            "[1]", SyntheticLine("A. Author. First title. Journal, 2001.", x: 92),
            "[2]", SyntheticLine("B. Author. Second title. Journal, 2002.", x: 92),
            "[3]", SyntheticLine("C. Author. Third title. Journal, 2003.", x: 92),
        ]
        let index = CitationIndexer().buildIndex(paper: Docs.paper(lines), links: [])
        #expect(index.style == .numeric)
        #expect(index.entries.map(\.label) == ["1", "2", "3"])
        #expect(index.entries.map(\.rawText) == ["[1] A. Author. First title. Journal, 2001.", "[2] B. Author. Second title. Journal, 2002.",
                                                  "[3] C. Author. Third title. Journal, 2003."])
        #expect(index.entries.map { $0.parsed.authorSurnames.first ?? "" } == ["Author", "Author", "Author"])
        #expect(index.mentions.map(\.entryIDs) == [[1], [2]])
    }
}
