import Foundation
import Testing
import RefereeCore
@testable import CitationKit

/// "No list" and "robustness" (plan.md §11.4, WP3).
@Suite struct CitationRobustnessTests {
    private typealias Docs = CitationTestDocuments

    // MARK: no list

    @Test func aDocumentWithoutAReferenceHeadingGivesAnEmptyIndex() {
        let lines: [SyntheticLine] = ["Herding was studied by Banerjee (1992).", "Banerjee, A. V. (1992). A simple model of herd behavior.",
                                      "Kogan, D. (2020). Learning from reviews.", "Lee, J. (2021). Observational learning."]
        for paper in [Docs.paper(lines), Docs.paper(lines, withBounds: false)] {
            let index = CitationIndexer().buildIndex(paper: paper, links: [])
            #expect(index == CitationIndex(style: .unknown))
        }
    }

    @Test func degenerateInputsGiveAnEmptyIndex() {
        let link = RawLink(pageIndex: 0, bounds: PageRect(pageIndex: 0, x: 100, y: 100, width: 10, height: 10), text: "1",
                           target: .internalDestination(pageIndex: 3, x: 72, y: 500))
        let papers: [PaperText] = [
            PaperText(pages: [], hasTextLayer: false, hasMarginLineNumbers: false),
            PaperText(pages: [PageText(index: 0, size: PageSize(width: 612, height: 792), string: "")], hasTextLayer: false, hasMarginLineNumbers: false),
            Docs.paper(["References"]),                                                          // a heading and nothing after it
            Docs.paper(["Text.", "References", "Banerjee, A. V. (1992). A simple model.", "Lee, J. (2021). Learning."]),   // two entries
            Docs.paper(["Text.", "References", "", "   "]),
        ]
        for paper in papers {
            #expect(CitationIndexer().buildIndex(paper: paper, links: [link]) == CitationIndex(style: .unknown))
        }
    }

    @Test func linesOfOtherKindsAreNotRead() {
        var paper = Docs.paper(["Text citing Kogan (2020).", "References", "Banerjee, A. V. (1992). A simple model of herd behavior.",
                                "Kogan, D. (2020). Learning from reviews.", "Lee, J. (2021). Observational learning."])
        #expect(CitationIndexer().buildIndex(paper: paper, links: []).entries.count == 3)
        paper.pages[0].lines[1].kind = .runningHeader
        #expect(CitationIndexer().buildIndex(paper: paper, links: []) == CitationIndex(style: .unknown))
    }

    // MARK: robustness

    /// A small deterministic generator (SplitMix64), so that a failure can be reproduced.
    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private static let vocabulary = [
        "the", "model", "of", "and", "Smith", "Lee", "et", "al.", "(1992)", "[12]", "[3–5]", "1998", "2021a", "References", "Appendix",
        "A", "Proofs", "Tables", "p.", "12", "–", "-", "Bikhchan-", "dani", "Sørensen", "ﬁnancial", "μ", "😀", "e\u{301}", "Ω", "β",
        "https://doi.org/10.1000/xyz", "arXiv:1810.04805", "doi:10.3115/v1/", "D14-1179", "“quoted”", "’s", "&", ";", ",", ".", "(", ")",
        "[", "]", "1.", "[1]", "Jr.", "van", "der", "Berg", "WORKING", "paper", "forthcoming", "n.d.", "\u{00AD}", "\u{200B}", "\t",
    ]

    private static func randomPaper(seed: UInt64, pages: Int, linesPerPage: Int) -> (PaperText, [RawLink]) {
        var generator = SeededGenerator(state: seed)
        var result: [[SyntheticLine]] = []
        for _ in 0..<pages {
            var lines: [SyntheticLine] = []
            for _ in 0..<linesPerPage {
                let count = Int.random(in: 0...14, using: &generator)
                let words = (0..<count).map { _ in vocabulary.randomElement(using: &generator)! }
                let x = [72.0, 72, 72, 84, 90, 320, 40].randomElement(using: &generator)!
                let height = [10.0, 10, 10, 12, 14, 0].randomElement(using: &generator)!
                lines.append(SyntheticLine(words.joined(separator: Bool.random(using: &generator) ? " " : ""), x: x, height: height))
            }
            result.append(lines)
        }
        var links: [RawLink] = []
        for _ in 0..<40 {
            let page = Int.random(in: -1...pages, using: &generator)
            let target: RawLinkTarget = Bool.random(using: &generator)
                ? .internalDestination(pageIndex: Int.random(in: -1...pages, using: &generator), x: Double.random(in: 0...612, using: &generator),
                                       y: Double.random(in: 0...792, using: &generator))
                : .url("https://doi.org/10.1000/\(Int.random(in: 0...999, using: &generator))")
            links.append(RawLink(pageIndex: page, bounds: PageRect(pageIndex: page, x: Double.random(in: 0...600, using: &generator),
                                                                    y: Double.random(in: 0...780, using: &generator), width: 20, height: 10),
                                 text: vocabulary.randomElement(using: &generator)!, target: target))
        }
        return (Docs.paper(pages: result), links)
    }

    /// What every index must satisfy, whatever the input.
    private static func checkInvariants(_ index: CitationIndex, paper: PaperText) {
        #expect(index.entries.map(\.id) == Array(index.entries.indices))
        #expect(index.mentions.map(\.id) == Array(index.mentions.indices))
        if index.style == .unknown { #expect(index.entries.isEmpty && index.mentions.isEmpty) }
        for mention in index.mentions {
            #expect(mention.entryIDs.allSatisfy { index.entries.indices.contains($0) })
            #expect(!mention.spans.isEmpty || !mention.rects.isEmpty)
            for span in mention.spans {
                let length = (paper.pages[span.pageIndex].string as NSString).length
                #expect(span.range.location >= 0 && span.range.length > 0 && span.range.upperBound <= length)
            }
        }
        let positions = index.mentions.map { $0.pageIndex }
        #expect(positions == positions.sorted())
    }

    @Test(arguments: [UInt64(1), 2, 3, 4, 5, 6, 7, 8])
    func randomTextCompletesQuickly(seed: UInt64) {
        let (paper, links) = Self.randomPaper(seed: seed, pages: 8, linesPerPage: 60)
        var index = CitationIndex(style: .unknown)
        let elapsed = ContinuousClock().measure { index = CitationIndexer().buildIndex(paper: paper, links: links) }
        #expect(elapsed < .seconds(2))
        Self.checkInvariants(index, paper: paper)
    }

    @Test func randomTextAfterAHeadingCompletesQuickly() {
        // The heading and four entries are planted (at the leftmost x the noise uses, so that they start entries whatever
        // the left edge turns out to be), so the list walk, the parser and both mention paths run on noise.
        for seed in UInt64(11)...UInt64(16) {
            var (paper, links) = Self.randomPaper(seed: seed, pages: 6, linesPerPage: 60)
            let entry = "Smith, L. (1992). Noise and herding. Journal, 1:1–2."
            paper = Docs.paper(pages: paper.pages.enumerated().map { pageIndex, page in
                page.lines.enumerated().map { i, line in
                    if pageIndex == 3 && i == 10 { return SyntheticLine("References", x: 40) }
                    if pageIndex == 3 && (11...14).contains(i) { return SyntheticLine(entry, x: 40) }
                    let text = Patterns.heading.matches(line.text) ? "noise" : line.text      // no other heading
                    return SyntheticLine(text, x: line.bounds?.x ?? 72, height: line.bounds?.height ?? 10)
                }
            })
            var index = CitationIndex(style: .unknown)
            let elapsed = ContinuousClock().measure { index = CitationIndexer().buildIndex(paper: paper, links: links) }
            #expect(elapsed < .seconds(2))
            #expect(index.entries.count >= 3)
            Self.checkInvariants(index, paper: paper)
        }
    }

    @Test func aFiveThousandLineDocumentCompletesQuickly() throws {
        // 4,000 lines of text, each citing one of 1,000 entries, then the list: 5,001 lines on 101 pages.
        func surname(_ i: Int) -> String {
            let letters = Array("bcdfghjklmnprstvz")
            let a = letters[i % letters.count], b = letters[(i / letters.count) % letters.count], c = letters[(i / 289) % letters.count]
            return String(a).uppercased() + "a" + String(b) + "o" + String(c) + "en"
        }
        func year(_ i: Int) -> Int { 1900 + i % 120 }
        var lines: [SyntheticLine] = []
        for k in 0..<4000 {
            let i = (k * 7) % 1000
            lines.append(SyntheticLine("As shown by \(surname(i)) (\(year(i))), the effect of the policy is robust in every specification."))
        }
        lines.append("References")
        for i in 0..<1000 {
            lines.append(SyntheticLine("\(surname(i)), A. (\(year(i))). A study of case \(i). Journal of Studies, \(i % 90 + 1)(2):1–20."))
        }
        let pages = stride(from: 0, to: lines.count, by: 50).map { Array(lines[$0..<min($0 + 50, lines.count)]) }
        let paper = Docs.paper(pages: pages)
        #expect(paper.pages.reduce(0) { $0 + $1.lines.count } == 5001)

        var index = CitationIndex(style: .unknown)
        let elapsed = ContinuousClock().measure { index = CitationIndexer().buildIndex(paper: paper, links: []) }
        #expect(elapsed < .seconds(2))
        #expect(index.style == .authorYear)
        try #require(index.entries.count == 1000)
        #expect(index.mentions.count == 4000)
        #expect(index.mentions.enumerated().allSatisfy { k, mention in mention.entryIDs == [(k * 7) % 1000] })
        Self.checkInvariants(index, paper: paper)
    }

    @Test func theIndexIsAPureFunctionOfItsInput() throws {
        let (paper, links) = try Docs.fixture("ay_links")
        let first = CitationIndexer().buildIndex(paper: paper, links: links)
        let second = CitationIndexer().buildIndex(paper: paper, links: links)
        #expect(first == second)
        let data = try JSONEncoder().encode(first)
        #expect(try JSONDecoder().decode(CitationIndex.self, from: data) == first)
    }
}
