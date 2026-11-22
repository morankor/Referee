import Foundation
import Testing
import RefereeCore
import PaperText
import TestSupport

/// WP1 acceptance (plan.md section 11.4), the renderer rows: rendering and chunking.
@Suite struct PaperTextRendererTests {
    private static let rendered = ["ay_nolinks", "s1_ruler", "ay_round_nolinks"]

    private func lines(of text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    @Test(arguments: rendered)
    func rendering(name: String) throws {
        let paper = try PaperTextSample.paper(name)
        let text = PaperRenderer().render(paper, pages: nil)
        let lines = lines(of: text)

        #expect(lines.count == 37)
        #expect(text.hasSuffix("\n") && !text.hasSuffix("\n\n"))
        #expect(!lines.contains(""))
        #expect(text.hasPrefix("[[page 1]]\n"))
        #expect(lines.filter { $0.hasPrefix("[[page ") } == ["[[page 1]]", "[[page 2]]", "[[page 3]]", "[[page 4]]"])
        #expect(lines.contains("2 Model"))
        #expect(lines.contains("µi ="))
        for row in ["Specification Estimate 95% interval", "Baseline 0.91 [0.78, 1.06]", "Staggered rollout 0.87 [0.74, 1.02]",
                    "Office fixed effects 0.95 [0.80, 1.12]"] {
            #expect(lines.contains(row), "\(row)")
        }
        #expect(text.contains("difficult to reconcile with the claim of a robust effect"))
        #expect(text.contains("predecessors"))

        let page2 = try #require(lines.firstIndex(of: "[[page 2]]"))
        let payoff = try #require(lines.firstIndex { $0.contains("the payoff function.") })
        #expect(payoff < page2)
        #expect(lines[page2 + 1].hasPrefix("In Banerjee"))

        for absent in ["CONFIDENTIAL", "to14", "Journal of Synthetic", "mc.example.org", "For Peer Review"] {
            #expect(!text.contains(absent), "\(absent)")
        }
        #expect(!lines.contains { !$0.isEmpty && $0.allSatisfy(\.isNumber) })
    }

    @Test func theThreeSameTextFixturesRenderAlike() throws {
        let texts = try Self.rendered.map { PaperRenderer().render(try PaperTextSample.paper($0), pages: nil) }
        // ay_nolinks has square-bracket citations and glued words; the other two have the same lines, two of the
        // equation's in another order (PDFKit's).
        #expect(Set(lines(of: texts[1])) == Set(lines(of: texts[2])))
        #expect(zip(lines(of: texts[1]), lines(of: texts[2])).filter { $0 != $1 }.count == 2)
    }

    @Test func pageRangesAreCutToThePaper() throws {
        let paper = try PaperTextSample.paper("ay_nolinks")
        let renderer = PaperRenderer()
        #expect(renderer.render(paper, pages: 0..<0) == "")
        #expect(renderer.render(paper, pages: 7..<9) == "")
        #expect(renderer.render(paper, pages: 2..<9) == renderer.render(paper, pages: 2..<4))
        let page2 = renderer.render(paper, pages: 1..<2)
        #expect(page2.hasPrefix("[[page 2]]\nfunction.\nIn Banerjee"))
        #expect(renderer.render(PaperText(hasTextLayer: false, hasMarginLineNumbers: false), pages: nil) == "")
    }

    // MARK: - Rules on small pages

    /// Six long lines make a page whose full length is known.
    private static let filler = (1...6).map { "Filler line number \($0) of this page, written out to full length." }

    @Test func aRunCrossingAPageIsCutAtTheFirstSentenceEnd() {
        let page1 = Self.filler + ["The last full line of the first page continues on the next page with the end"]
        let page2 = ["of the sentence. Then another sentence starts on the second page and goes on.", "Short line."]
        let text = PaperRenderer().render(PaperTextSample.plainPaper([page1, page2]), pages: nil)
        #expect(text.contains("continues on the next page with the end of the sentence.\n[[page 2]]\nThen another sentence starts"))
    }

    @Test func aRunWithoutASentenceEndHasTheMarkerAfterIt() {
        let page1 = Self.filler + ["The last full line of the first page continues on the next page with the end"]
        let page2 = ["of the sentence and no full stop for a long while", "Next paragraph."]
        let text = PaperRenderer().render(PaperTextSample.plainPaper([page1, page2]), pages: nil)
        #expect(text.contains("with the end of the sentence and no full stop for a long while\n[[page 2]]\nNext paragraph.\n"))
    }

    @Test func aSentenceEndingAtThePageBreakPutsTheMarkerThere() {
        let page1 = Self.filler + ["The last full line of the first page ends exactly with its own full sentence."]
        let page2 = ["The second page begins a new sentence that is long enough to be a full line here.", "End."]
        let text = PaperRenderer().render(PaperTextSample.plainPaper([page1, page2]), pages: nil)
        #expect(text.contains("ends exactly with its own full sentence.\n[[page 2]]\nThe second page begins"))
    }

    @Test func hyphensAreDroppedUnlessTheWordIsWrittenWithOne() {
        let page = Self.filler + [
            "Here the long line ends with a word that the typesetter broke across lines: predeces-",
            "sors are agents. Then a second long line ends with a compound word like office-",
            "specific as written. A third long line mentions an office-specific rule again, and so-",
            "Called words with a capital letter keep their hyphen and get a space.",
        ]
        let text = PaperRenderer().render(PaperTextSample.plainPaper([page]), pages: nil)
        #expect(text.contains("predecessors are agents"))
        #expect(text.contains("like office-specific as written"))
        #expect(text.contains("and so- Called words"))
    }

    @Test func shortLinesAndFarLinesEndARun() {
        // A heading, then a paragraph, then a line after a gap of almost four line pitches.
        let texts = ["1 Introduction"] + Self.filler + ["A line far below the paragraph, after a large vertical gap here."]
        var page = PaperTextSample.rawPage(index: 0, lines: texts)
        if var last = page.lines.last, let bounds = last.bounds {
            last.bounds = PageRect(pageIndex: 0, x: bounds.x, y: bounds.y - 40, width: bounds.width, height: bounds.height)
            page.lines[page.lines.count - 1] = last
        }
        let text = PaperRenderer().render(identityPaperText(from: RawDocument(pages: [page])), pages: nil)
        let lines = lines(of: text)
        #expect(lines.count == 4)
        #expect(lines[1] == "1 Introduction")
        #expect(lines[2].hasPrefix("Filler line number 1") && lines[2].hasSuffix("number 6 of this page, written out to full length."))
        #expect(lines[3].hasPrefix("A line far below"))
    }

    @Test func withoutBoundsOnlyFullnessDecides() {
        let page = Self.filler + ["Last line."]
        let text = PaperRenderer().render(PaperTextSample.plainPaper([page], pitch: nil), pages: nil)
        #expect(lines(of: text).count == 2)
    }

    // MARK: - Chunking

    private func expectGoodChunks(_ paper: PaperText, limit: Int, sourceLocation: SourceLocation = #_sourceLocation) {
        let renderer = PaperRenderer()
        let ranges = renderer.chunkPageRanges(paper, maxCharacters: limit)
        guard !paper.pages.isEmpty else {
            #expect(ranges.isEmpty, sourceLocation: sourceLocation)
            return
        }
        #expect(ranges.first?.lowerBound == 0, sourceLocation: sourceLocation)
        #expect(ranges.last?.upperBound == paper.pages.count, sourceLocation: sourceLocation)
        #expect(ranges.allSatisfy { !$0.isEmpty }, sourceLocation: sourceLocation)
        #expect(zip(ranges, ranges.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound }, "not contiguous",
                sourceLocation: sourceLocation)
        for range in ranges where range.count > 1 {
            #expect(renderer.render(paper, pages: range).count <= limit, "\(range) over \(limit)", sourceLocation: sourceLocation)
        }
        // Greedy: a range that could take the next page would have.
        for (range, next) in zip(ranges, ranges.dropFirst()) {
            #expect(renderer.render(paper, pages: range.lowerBound..<(next.lowerBound + 1)).count > limit, sourceLocation: sourceLocation)
        }
    }

    @Test(arguments: PaperTextSample.journalStamped + PaperTextSample.unnumbered)
    func chunking(name: String) throws {
        let paper = try PaperTextSample.paper(name)
        let whole = PaperRenderer().render(paper, pages: nil).count
        #expect(PaperRenderer().chunkPageRanges(paper, maxCharacters: whole) == [0..<paper.pages.count])
        #expect(PaperRenderer().chunkPageRanges(paper, maxCharacters: 1) == paper.pages.indices.map { $0..<($0 + 1) })
        for limit in [1, 500, 1_200, 2_000, 2_500, 3_000, whole - 1, whole, 1_000_000] {
            expectGoodChunks(paper, limit: limit)
        }
    }

    @Test func chunkingALongSyntheticPaper() {
        var generator = SeededGenerator(seed: 7)
        let pages = (0..<40).map { page in
            (0..<Int.random(in: 0...30, using: &generator)).map { line in
                "Page \(page) line \(line) " + String(repeating: "word ", count: Int.random(in: 1...14, using: &generator)) + "end."
            }
        }
        let paper = PaperTextSample.plainPaper(pages)
        for limit in [0, 100, 900, 2_500, 10_000, 100_000] {
            expectGoodChunks(paper, limit: limit)
        }
        expectGoodChunks(PaperText(hasTextLayer: false, hasMarginLineNumbers: false), limit: 100)
    }
}
