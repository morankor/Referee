import Foundation
import Testing
import RefereeCore
import PaperText

/// Wave 0a smoke tests. They hold for the placeholders and must keep holding for the real implementation (WP1).
@Suite struct PaperTextSmokeTests {
    private static let first = "Herding has been studied since Banerjee."
    private static let second = "We extend the framework to markets."

    /// One page with two short lines: no margin numbers, no page furniture, no bounds.
    private func tinyPaper() -> PaperText {
        let lines = [
            RawLine(range: TextRange(location: 0, length: Self.first.utf16.count), text: Self.first),
            RawLine(range: TextRange(location: Self.first.utf16.count + 1, length: Self.second.utf16.count), text: Self.second),
        ]
        let page = RawPage(index: 0, size: PageSize(width: 612, height: 792), string: Self.first + "\n" + Self.second, lines: lines)
        return PaperTextBuilder(stripMarginLineNumbers: { false }).build(from: RawDocument(pages: [page]))
    }

    @Test func builderKeepsPlainLinesAsBodyText() {
        let paper = tinyPaper()
        #expect(paper.pages.count == 1)
        #expect(paper.pages.first?.lines.map(\.text) == [Self.first, Self.second])
        #expect(paper.pages.first?.lines.allSatisfy { $0.kind == .body && $0.contentRange == $0.range } == true)
    }

    @Test func rendererMarksThePageAndKeepsTheText() {
        let paper = tinyPaper()
        let renderer = PaperRenderer()
        let text = renderer.render(paper, pages: nil)
        #expect(text.hasPrefix("[[page 1]]\n"))
        #expect(text.contains(Self.first))
        #expect(text.contains(Self.second))
        #expect(text.hasSuffix("\n"))
        #expect(renderer.chunkPageRanges(paper, maxCharacters: 100_000) == [0..<1])
    }

    @Test func matcherDoesNotFindAnAbsentSentence() {
        let matcher = QuoteMatcher(paper: tinyPaper())
        #expect(matcher.locate(quote: "this sentence is not in the paper at all whatsoever", pageHint: nil) == nil)
    }
}
