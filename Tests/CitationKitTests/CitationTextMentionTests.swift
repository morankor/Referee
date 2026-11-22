import Foundation
import Testing
import RefereeCore
@testable import CitationKit

/// In-text citations from text patterns (plan.md §8.4) on synthetic documents.
@Suite struct CitationTextMentionTests {
    private typealias Docs = CitationTestDocuments

    private static let references = [
        "Banerjee, A. V. (1992). A simple model of herd behavior. Quarterly Journal of Economics, 107(3):797–817.",
        "Lee, J. (2021). Observational learning with heterogeneous priors. Games and Economic Behavior, 125:1–20.",
        "Smith, L. (2019). Learning in markets. Journal of Economic Theory, 180:1–20.",
        "Smith, L. (2021). Learning in networks. Journal of Economic Theory, 190:21–40.",
    ]

    private static func index(_ body: [String], references: [String] = references) -> CitationIndex {
        CitationIndexer().buildIndex(paper: Docs.authorYear(body: body, references: references), links: [])
    }

    // MARK: not citations

    @Test func aYearAfterAWordThatEndsInTheSurnameIsNotACitation() {
        let index = Self.index(["We use the employee (2021) survey for the estimates."])
        #expect(index.entries.count == 4)
        #expect(index.mentions.isEmpty)
    }

    @Test func aPossessiveIsACitation() throws {
        let index = Self.index(["Banerjee's (1992) model is the benchmark.", "So is Banerjee’s (1992) second model."])
        try #require(index.mentions.count == 2)
        #expect(index.mentions.map(\.entryIDs) == [[0], [0]])
        #expect(index.mentions[0].text == "Banerjee's (1992")
    }

    @Test func twoYearsAfterOneAuthorAreTwoCitations() throws {
        let index = Self.index(["Smith (2019, 2021) studies both settings."])
        try #require(index.mentions.count == 2)
        #expect(index.mentions.map(\.entryIDs) == [[2], [3]])
        #expect(index.mentions.map(\.text) == ["Smith (2019", "Smith (2019, 2021"])
    }

    // MARK: numeric, synthetic

    private static let numericReferences = [
        "[1] A. Abel. First title. Journal, 2001.", "[2] B. Baker. Second title. Journal, 2002.", "[3] C. Clark. Third title. Journal, 2003.",
        "[4] D. Dunn. Fourth title. Journal, 2004.", "[5] E. Evans. Fifth title. Journal, 2005.",
    ]

    @Test func aRangeIsOneMentionAndANumberOutsideTheListIsIgnored() throws {
        let paper = Docs.paper(["A range [3–5] is one citation and [99] is none."].map { SyntheticLine($0) } + ["References"]
                               + Self.numericReferences.map { SyntheticLine($0) })
        let index = CitationIndexer().buildIndex(paper: paper, links: [])
        #expect(index.style == .numeric)
        try #require(index.mentions.count == 1)
        #expect(index.mentions[0].text == "3–5")
        #expect(index.mentions[0].entryIDs == [2, 3, 4])
        #expect(index.mentions[0].spans.map { Docs.text(of: $0, in: paper) } == ["3–5"])
    }

    @Test func eachNumberInABracketIsItsOwnMention() throws {
        let paper = Docs.paper(["Several results [1, 5, 3] and [2; 4] and [1–2, 5] apply, but not [0], [6] or [2, 9]."].map { SyntheticLine($0) }
                               + ["References"] + Self.numericReferences.map { SyntheticLine($0) })
        let index = CitationIndexer().buildIndex(paper: paper, links: [])
        #expect(index.mentions.map(\.text) == ["1", "5", "3", "2", "4", "1–2", "5"])
        #expect(index.mentions.map(\.entryIDs) == [[0], [4], [2], [1], [3], [0, 1], [4]])
        #expect(index.mentions.map(\.id) == Array(0..<7))
    }

    @Test func numericMentionsAcrossALineBreak() throws {
        let paper = Docs.paper(["The results of [1,", "4] agree."].map { SyntheticLine($0) } + ["References"] + Self.numericReferences.map { SyntheticLine($0) })
        let index = CitationIndexer().buildIndex(paper: paper, links: [])
        #expect(index.mentions.map(\.text) == ["1", "4"])
        #expect(index.mentions.map { $0.spans.map(\.range.location) } == [[16], [19]])      // "The results of [" is 16 units; line 2 starts at 19
    }

    // MARK: the rules of §8.4 one by one

    @Test func authorKeys() {
        func keys(_ names: [String], truncated: Bool = false) -> [String] {
            AuthorKeys.keys(surnames: names, truncated: truncated).map { String(String.UnicodeScalarView($0.compactMap(Unicode.Scalar.init))) }
        }
        #expect(keys(["Banerjee"]) == ["banerjee"])
        #expect(keys(["Avery", "Zemsky"]) == ["averyandzemsky", "averyzemsky"])
        #expect(keys(["Bikhchandani", "Hirshleifer", "Welch"]) == ["bikhchandanihirshleiferandwelch", "bikhchandanihirshleiferwelch", "bikhchandanietal"])
        #expect(keys(["Smith", "Sørensen"]) == ["smithandsørensen", "smithsørensen"])
        #expect(Set(keys(["van der Berg", "Smith"])) == ["vanderbergandsmith", "vanderbergsmith", "bergandsmith", "bergsmith"])
        #expect(keys(["De Groot"]) == ["degroot"])                       // an upper-case particle stays
        #expect(Set(keys(["Acemoglu"], truncated: true)) == ["acemoglu", "acemogluetal"])
        #expect(keys([]) == [])
    }

    @Test func citationStylesThatNeedNoSpecialRule() throws {
        let references = [
            "Avery, C. and Zemsky, P. (1998). Multidimensional uncertainty and herd behavior. American Economic Review, 88(4):724–748.",
            "Bikhchandani, S., Hirshleifer, D., and Welch, I. (1992). A theory of fads. Journal of Political Economy, 100(5):992–1026.",
            "Smith, L. and Sørensen, P. (2000). Pathological outcomes of observational learning. Econometrica, 68(2):371–398.",
            "van der Berg, J. (2005). Coalitions. Games and Economic Behavior, 50:1–20.",
        ]
        let body = [
            "(Bikhchandani et al., 1992; Smith and Sørensen, 2000) and [Avery and Zemsky, 1998, Smith and Sørensen, 2000];",
            "also Avery & Zemsky (1998), BIKHCHANDANI, HIRSHLEIFER AND WELCH (1992), van der Berg (2005) and Berg (2005);",
            "but not Banerjee (1992), not the year 2000 alone, and not Zemsky (1998) alone.",
        ]
        let index = Self.index(body, references: references)
        #expect(index.mentions.map { Docs.firstAuthors(of: $0, in: index) }
                == ["Bikhchandani", "Smith", "Avery", "Smith", "Avery", "Bikhchandani", "van der Berg", "van der Berg"])
        #expect(index.mentions.map(\.text)[0...1] == ["Bikhchandani et al., 1992", "Smith and Sørensen, 2000"])
    }

    @Test func theLongestKeyWinsAndTiesAreAllCandidates() throws {
        let references = [
            "Smith, L. (2000). One author. Journal A, 1:1–2.",
            "Smith, L. and Sørensen, P. (2000). Two authors. Journal B, 2:3–4.",
            "Jones, A. (2010). First. Journal C, 3:5–6.",
            "Jones, B. (2010). Second. Journal D, 4:7–8.",
        ]
        let index = Self.index(["As Smith and Sørensen (2000) show, and as Sørensen and Smith (2000) do not, see Jones (2010)."], references: references)
        try #require(index.mentions.count == 3)
        #expect(index.mentions[0].entryIDs == [1])              // "smithandsørensen" beats "smith"
        #expect(index.mentions[1].entryIDs == [0])              // "…and Smith (2000)" ends in the one-author key
        #expect(index.mentions[1].text == "Smith (2000")
        #expect(index.mentions[2].entryIDs == [2, 3])           // two entries with the same key and year
    }

    @Test func yearSuffixesMustAgree() throws {
        let references = [
            "Kogan, D. (2020a). Learning from reviews. Working paper.",
            "Kogan, D. (2020b). Learning from ratings. Working paper.",
            "Lee, J. (2021). Observational learning. Games and Economic Behavior, 125:1–20.",
        ]
        let index = Self.index(["Kogan (2020b) extends Kogan (2020a); Kogan (2020) is ambiguous; Kogan (2020c) is not listed."], references: references)
        #expect(index.mentions.map(\.entryIDs) == [[1], [0], [0, 1]])
    }

    @Test func aCitationAcrossAPageBreakHasASpanOnEachPage() throws {
        let references: [SyntheticLine] = [
            "Avery, C. and Zemsky, P. (1998). Multidimensional uncertainty and herd behavior.",
            "Banerjee, A. V. (1992). A simple model of herd behavior.",
            "Kogan, D. (2020). Learning from reviews with strategic sellers. Working paper.",
        ]
        let paper = Docs.paper(pages: [["The framework was extended by Avery and"], ["Zemsky (1998) to markets."] + ["References"] + references])
        let index = CitationIndexer().buildIndex(paper: paper, links: [])
        try #require(index.mentions.count == 1)
        #expect(index.mentions[0].pageIndex == 0)
        #expect(index.mentions[0].spans.map(\.pageIndex) == [0, 1])
        #expect(index.mentions[0].spans.map { Docs.text(of: $0, in: paper) } == ["Avery and", "Zemsky (1998"])
        #expect(index.mentions[0].text == "Avery and Zemsky (1998")
    }
}
