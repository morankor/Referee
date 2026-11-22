import Foundation
import Testing
import RefereeCore
import PaperText
import TestSupport

/// WP1 acceptance (plan.md section 11.4), the builder rows: margin line numbers, page furniture, the setting.
@Suite struct PaperTextBuilderTests {
    /// Numbers found by step 1 on a page: glued ones (content shorter than the line) and number-only lines.
    private func stepOneNumbers(_ page: PageText) -> [Int] {
        page.lines.filter { $0.kind == .marginNumberOnly || $0.contentRange != $0.range }.compactMap(\.marginNumber).sorted()
    }

    @Test func lineNumbersOnTextLines() throws {
        let paper = try PaperTextSample.paper("ay_nolinks")
        #expect(paper.hasMarginLineNumbers)
        try #require(paper.pages.count == 4)

        let expected = [Array(1...16), Array(17...33), Array(34...48), Array(49...54)]
        for (position, page) in paper.pages.enumerated() {
            #expect(stepOneNumbers(page) == expected[position], "page \(position + 1)")
        }
        #expect(paper.pages.map { $0.lines.filter { $0.kind == .marginNumberOnly }.count } == [4, 1, 3, 2])

        let table2 = try #require(PaperTextSample.line(paper, page: 0, startingWith: "Table 2 is 0.91"))
        #expect(table2.marginNumber == 14)
        #expect(table2.text.hasSuffix("difficult to"))
        #expect(table2.kind == .body)

        // Step 6: these two take the number PDFKit put on a line of its own.
        let function = try #require(PaperTextSample.line(paper, page: 1, startingWith: "function."))
        #expect(function.marginNumber == 17)
        #expect(function.contentRange == function.range)
        let course = try #require(PaperTextSample.line(paper, page: 3, startingWith: "A Course in Game Theory. MIT Press."))
        #expect(course.marginNumber == 52)
        #expect(course.contentRange == course.range)

        // The table and the displayed equation are far from every number; every other text line has one.
        let unnumbered: Set<String> = ["Table 2: Baseline estimates", "Specification Estimate 95% interval", "Baseline 0.91 [0.78, 1.06]",
                                       "Staggered rollout 0.87 [0.74, 1.02]", "Office fixed effects 0.95 [0.80, 1.12]",
                                       "µi =", "πf(si |H)", "πf(si |H) + (1−π)f(si |L).", "(1)"]
        let bodyWithoutNumber = paper.pages.flatMap(\.lines).filter { $0.kind == .body && $0.marginNumber == nil }
        #expect(Set(bodyWithoutNumber.map { PaperTextSample.trimmed($0.text) }) == unnumbered)
        #expect(bodyWithoutNumber.count == 9)
    }

    @Test func glueAndRemovalKeepTheTextAndItsRange() throws {
        let raw = try PaperTextSample.raw("ay_nolinks")
        let paper = PaperTextBuilder().build(from: raw)
        for (rawPage, page) in zip(raw.pages, paper.pages) {
            let string = page.string as NSString
            #expect(page.lines.count == rawPage.lines.count)
            for (rawLine, line) in zip(rawPage.lines, page.lines) {
                #expect(line.range == rawLine.range)
                #expect(line.bounds == rawLine.bounds)
                #expect(line.pageIndex == page.index)
                // contentRange lies inside the line, and the text is the page string there.
                #expect(line.contentRange.location >= line.range.location && line.contentRange.upperBound <= line.range.upperBound)
                #expect(string.substring(with: line.contentRange.nsRange) == line.text)
            }
        }
        // "J Polit Econ 108(1):34–5546": 46 is the line number, 34–55 the pages of the reference.
        let springer = try #require(PaperTextSample.line(paper, page: 2, startingWith: "J Polit Econ"))
        #expect(springer.text == "J Polit Econ 108(1):34–55")
        #expect(springer.marginNumber == 46)
    }

    @Test func ruler() throws {
        let paper = try PaperTextSample.paper("s1_ruler")
        #expect(paper.hasMarginLineNumbers)
        try #require(paper.pages.count == 4)
        for page in paper.pages {
            let ruler = page.lines.filter { $0.kind == .marginNumberOnly }
            #expect(ruler.count == 60, "page \(page.index + 1)")
            #expect(ruler.compactMap(\.marginNumber) == Array(1...60), "page \(page.index + 1)")
        }
        #expect(PaperTextSample.line(paper, page: 0, startingWith: "ficient in Table 2 is 0.91")?.marginNumber == 49)
        #expect(PaperTextSample.line(paper, page: 0, startingWith: "We study how sequential traders")?.marginNumber == 28)
        let digitsOnly = paper.pages.flatMap(\.lines).filter { line in
            line.kind == .body && !PaperTextSample.trimmed(line.text).isEmpty && PaperTextSample.trimmed(line.text).allSatisfy(\.isNumber)
        }
        #expect(digitsOnly.isEmpty)
    }

    @Test(arguments: PaperTextSample.unnumbered)
    func noFalsePositives(name: String) throws {
        let paper = try PaperTextSample.paper(name)
        #expect(!paper.hasMarginLineNumbers)
        let lines = paper.pages.flatMap(\.lines)
        #expect(lines.allSatisfy { $0.contentRange == $0.range && $0.marginNumber == nil && $0.kind != .marginNumberOnly })
    }

    @Test(arguments: PaperTextSample.journalStamped)
    func settingRespected(name: String) throws {
        let raw = try PaperTextSample.raw(name)
        let paper = PaperTextBuilder(stripMarginLineNumbers: { false }).build(from: raw)
        let lines = paper.pages.flatMap(\.lines)
        #expect(lines.allSatisfy { $0.contentRange == $0.range })
        #expect(lines.allSatisfy { $0.marginNumber == nil && $0.kind != .marginNumberOnly })
        #expect(zip(raw.pages.flatMap(\.lines), lines).allSatisfy { $0.text == $1.text })
        #expect(!paper.hasMarginLineNumbers)
    }

    /// The setting is read at every build, as the live app's closure reads the current settings.
    @Test func theSettingIsReadAtEachBuild() throws {
        let raw = try PaperTextSample.raw("ay_nolinks")
        let flag = Flag(true)
        let builder = PaperTextBuilder(stripMarginLineNumbers: { flag.value })
        #expect(builder.build(from: raw).hasMarginLineNumbers)
        flag.value = false
        #expect(!builder.build(from: raw).hasMarginLineNumbers)
        flag.value = true
        #expect(builder.build(from: raw).hasMarginLineNumbers)
    }

    @Test func pageFurnitureOfTheLinenoFixture() throws {
        let paper = try PaperTextSample.paper("ay_nolinks")
        let confidential = paper.pages.flatMap(\.lines).filter { PaperTextSample.trimmed($0.text) == "CONFIDENTIAL" }
        #expect(confidential.count == 4)
        #expect(confidential.allSatisfy { $0.kind == .watermark })
        for page in paper.pages {
            let last = try #require(page.lines.last)
            #expect(last.kind == .pageNumber, "page \(page.index + 1)")
            #expect(last.text == "\(page.index + 1)")
        }
        // Nothing else is furniture.
        #expect(paper.pages.flatMap(\.lines).filter { ![.body, .marginNumberOnly].contains($0.kind) }.count == 8)
    }

    @Test func pageFurnitureOfTheRulerFixture() throws {
        let paper = try PaperTextSample.paper("s1_ruler")
        for page in paper.pages {
            let n = page.index + 1
            #expect(PaperTextSample.line(paper, page: page.index, startingWith: "Journal of Synthetic Economics")?.kind == .runningHeader, "page \(n)")
            #expect(PaperTextSample.line(paper, page: page.index, startingWith: "Page \(n) of 4")?.kind == .pageNumber, "page \(n)")
            #expect(PaperTextSample.line(paper, page: page.index, startingWith: "https://mc.example.org/jse")?.kind == .runningFooter, "page \(n)")
            #expect(PaperTextSample.line(paper, page: page.index, startingWith: "For Peer Review")?.kind == .watermark, "page \(n)")
            #expect(page.lines.filter { ![.body, .marginNumberOnly].contains($0.kind) }.count == 4, "page \(n)")
        }
    }

    @Test(arguments: PaperTextSample.unnumbered)
    func unnumberedFixturesHaveOnlyPageNumbers(name: String) throws {
        let paper = try PaperTextSample.paper(name)
        for page in paper.pages {
            let furniture = page.lines.filter { $0.kind != .body }
            #expect(furniture.map(\.kind) == [.pageNumber], "page \(page.index + 1)")
            #expect(furniture.first?.text == "\(page.index + 1)")
        }
    }

    // MARK: - Numbered lists

    private static func referenceLines(_ count: Int, marker: (Int) -> String) -> [String] {
        (1...count).map { "\(marker($0)) Author\($0), A. (20\(10 + $0 % 10)). A title of the cited work. Journal of Studies, \($0):1–9." }
    }

    @Test func numberedListsAreNotLineNumbers() {
        for marker in [{ (n: Int) in "\(n)." }, { (n: Int) in "\(n))" }, { (n: Int) in "[\(n)]" }] {
            let page = PaperTextSample.rawPage(index: 0, lines: Self.referenceLines(30, marker: marker))
            let paper = PaperTextBuilder().build(from: RawDocument(pages: [page]))
            #expect(!paper.hasMarginLineNumbers, "\(marker(1))")
            #expect(paper.pages[0].lines.allSatisfy { $0.contentRange == $0.range && $0.kind == .body && $0.marginNumber == nil })
        }
    }

    /// The contrast: the same lines with bare leading numbers are lineno numbers in leading mode, and lose them.
    @Test func leadingNumbersFollowedByTextAreLineNumbers() throws {
        let page = PaperTextSample.rawPage(index: 0, lines: Self.referenceLines(30, marker: { "\($0)" }))
        let paper = PaperTextBuilder().build(from: RawDocument(pages: [page]))
        #expect(paper.hasMarginLineNumbers)
        let first = try #require(paper.pages[0].lines.first)
        #expect(first.marginNumber == 1)
        #expect(first.text.hasPrefix("Author1, A."))
        #expect(first.contentRange.location == 2)
        #expect(paper.pages[0].lines.compactMap(\.marginNumber) == Array(1...30))
    }

    // MARK: - Decisions where the plan is silent

    /// Five pages, each with a body text, a line "(1)" in the middle, a repeated word line in the middle, and a page
    /// number at the bottom; page 3 has no page number but a stray "7" as its last line.
    private func furniturePaper() -> PaperText {
        let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet", "kilo", "lima"]
        let pages = (0..<5).map { index -> RawPage in
            var texts = words.indices.map { "Prose \(words[$0]) \(words[(index * 5 + $0) % words.count]) of the body text, long enough." }
            texts.insert("(1)", at: 4)
            texts.insert("DRAFT VERSION", at: 8)
            texts.append(index == 2 ? "7" : "\(index + 1)")
            return PaperTextSample.rawPage(index: index, lines: texts, pitch: 40, top: 760)
        }
        return PaperTextBuilder().build(from: RawDocument(pages: pages))
    }

    @Test func repeatedLinesWithoutALetterStayInTheText() {
        let paper = furniturePaper()
        for page in paper.pages {
            #expect(page.lines.first { $0.text == "(1)" }?.kind == .body)
            #expect(page.lines.first { $0.text == "DRAFT VERSION" }?.kind == .watermark)
        }
    }

    @Test func pageNumbersSurviveAPageWithoutOne() {
        let paper = furniturePaper()
        #expect(paper.pages.map { $0.lines.last?.kind } == [.pageNumber, .pageNumber, .body, .pageNumber, .pageNumber])
        // "– 4 –", "Page 4" and "4 of 5" are page numbers too.
        for (shape, value) in [("– 4 –", 4), ("Page 4", 4), ("4 of 5", 4), ("page 12 of 30", 12), ("12", 12)] {
            let pages = (0..<5).map { index in
                PaperTextSample.rawPage(index: index, lines: ["Body text of the page.", shape.replacingOccurrences(of: "\(value)", with: "\(value - 3 + index)")])
            }
            let built = PaperTextBuilder().build(from: RawDocument(pages: pages))
            #expect(built.pages.allSatisfy { $0.lines.last?.kind == .pageNumber }, "\(shape)")
        }
        for shape in ["12345", "Page", "4 of", "- 4", "Chapter 4", "4.", "(4)"] {
            let pages = (0..<5).map { PaperTextSample.rawPage(index: $0, lines: ["Body text of the page.", shape]) }
            let built = PaperTextBuilder().build(from: RawDocument(pages: pages))
            #expect(built.pages.allSatisfy { $0.lines.last?.kind != .pageNumber }, "\(shape)")
        }
    }

    // MARK: - Step 7

    @Test func titleTextLayerAndFlags() throws {
        for name in PaperTextSample.journalStamped + PaperTextSample.unnumbered where name.hasPrefix("ay") || name.hasPrefix("s1") {
            let paper = try PaperTextSample.paper(name)
            #expect(paper.titleGuess == "Information Aggregation in Sequential Markets: A Fixture", "\(name)")
            #expect(paper.hasTextLayer)
        }
        #expect(try PaperTextSample.paper("num_twocol_links").titleGuess == "A Two-Column Numeric Fixture With Links")
        let scanned = try PaperTextSample.paper("scanned")
        #expect(!scanned.hasTextLayer)
        #expect(scanned.titleGuess == nil)
        #expect(!scanned.hasMarginLineNumbers)

        let noBounds = PaperTextBuilder().build(from: RawDocument(pages: [PaperTextSample.rawPage(index: 0, lines: ["Title", "Text"], pitch: nil)]))
        #expect(noBounds.titleGuess == nil)
    }
}

/// A setting that a test can change between builds.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool

    init(_ value: Bool) {
        stored = value
    }

    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
