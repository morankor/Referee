import Foundation
import Testing
import RefereeCore
import PaperText
import TestSupport

/// WP1 acceptance (plan.md section 11.4), the rows "robustness" and "speed".
@Suite struct PaperTextRobustnessTests {
    /// Everything the three types offer, once; it only has to return.
    private func exercise(_ raw: RawDocument, quotes: [String] = []) {
        let paper = PaperTextBuilder().build(from: raw)
        _ = PaperTextBuilder(stripMarginLineNumbers: { false }).build(from: raw)
        let matcher = QuoteMatcher(paper: paper)
        for quote in quotes + ["", "a", "the", "this sentence is not in the paper at all whatsoever"] {
            for hint in [nil, 0, 1, -1, 1_000] as [Int?] {
                if let match = matcher.locate(quote: quote, pageHint: hint) {
                    #expect(!match.spans.isEmpty)
                    _ = matcher.locationLabel(for: match.spans)
                }
            }
        }
        _ = matcher.locationLabel(for: [])
        _ = matcher.locationLabel(for: [TextSpan(pageIndex: 0, range: TextRange(location: 0, length: 1))])
        let renderer = PaperRenderer()
        let text = renderer.render(paper, pages: nil)
        #expect(text.isEmpty || text.hasSuffix("\n"))
        _ = renderer.render(paper, pages: 0..<1)
        let ranges = renderer.chunkPageRanges(paper, maxCharacters: 4_000)
        #expect(ranges.reduce(0) { $0 + $1.count } == paper.pages.count)
    }

    @Test func emptyDocuments() {
        exercise(RawDocument())
        let paper = PaperTextBuilder().build(from: RawDocument())
        #expect(paper.pages.isEmpty && !paper.hasTextLayer && !paper.hasMarginLineNumbers && paper.titleGuess == nil)
        #expect(QuoteMatcher(paper: paper).locate(quote: "anything at all, long enough", pageHint: 0) == nil)
        #expect(PaperRenderer().render(paper, pages: nil) == "")
        #expect(PaperRenderer().chunkPageRanges(paper, maxCharacters: 10).isEmpty)

        // Pages with no lines, and pages whose string is empty.
        let blank = RawDocument(pages: (0..<12).map { RawPage(index: $0, size: PageSize(width: 612, height: 792), string: "") })
        exercise(blank)
        #expect(PaperRenderer().render(PaperTextBuilder().build(from: blank), pages: 0..<2) == "[[page 1]]\n[[page 2]]\n")
    }

    @Test func oneCharacterPages() {
        for character in ["x", "1", "-", "…", " ", "\n", "\u{FB01}", "\u{1D44E}", "\u{0301}", "\u{200B}", "😀"] {
            let pages = (0..<12).map { index in
                RawPage(index: index, size: PageSize(width: 612, height: 792), string: character,
                        lines: [RawLine(range: TextRange(location: 0, length: character.utf16.count), text: character,
                                        bounds: PageRect(pageIndex: index, x: 300, y: 80, width: 6, height: 10))])
            }
            exercise(RawDocument(pages: pages), quotes: [character, String(repeating: character, count: 20)])
            exercise(RawDocument(pages: [pages[0]]), quotes: [character])
        }
    }

    @Test(arguments: PaperTextSample.journalStamped + PaperTextSample.unnumbered)
    func linesWithoutBounds(name: String) throws {
        var raw = try PaperTextSample.raw(name)
        for page in raw.pages.indices {
            for line in raw.pages[page].lines.indices { raw.pages[page].lines[line].bounds = nil }
        }
        exercise(raw, quotes: ["verify the differentiability of the payoff function", "Herding has been studied extensively"])
        let paper = PaperTextBuilder().build(from: raw)
        // Step 1 needs no geometry; step 6 does, and the title guess too.
        #expect(paper.hasMarginLineNumbers == PaperTextSample.journalStamped.contains(name))
        #expect(paper.titleGuess == nil)
        let match = QuoteMatcher(paper: paper).locate(quote: "verify the differentiability of the payoff function", pageHint: nil)
        if name.hasPrefix("ay") || name.hasPrefix("s1") { #expect(match?.confidence == .exact) }
    }

    @Test func linesThatDisagreeWithTheirPage() {
        let string = "Short page string."
        let lines = [
            RawLine(range: TextRange(location: 1_000_000, length: 5), text: "beyond the end of the page string 12"),
            RawLine(range: TextRange(location: -3, length: 2), text: "13"),
            RawLine(range: TextRange(location: 0, length: 0), text: "a text longer than its range 14"),
            RawLine(range: TextRange(location: 4, length: 400), text: ""),
        ]
        let pages = (0..<4).map { RawPage(index: $0, size: PageSize(width: 0, height: 0), string: string, lines: lines) }
        exercise(RawDocument(pages: pages), quotes: ["beyond the end of the page string", "a text longer than its range"])
    }

    @Test func randomUnicode() {
        var generator = SeededGenerator(seed: 2026)
        var scalars = String.UnicodeScalarView()
        var bytes = 0
        while bytes < 200 * 1024 {
            let scalar = Self.randomScalar(using: &generator)
            scalars.append(scalar)
            bytes += String(scalar).utf8.count
        }
        let text = String(scalars)
        let all = Array(text.unicodeScalars)

        // Twenty pages; lines cut at line breaks and, at random, inside a run of text.
        var pages: [RawPage] = []
        let perPage = all.count / 20 + 1
        for (index, start) in stride(from: 0, to: all.count, by: perPage).enumerated() {
            let pageScalars = all[start..<min(all.count, start + perPage)]
            var string = String.UnicodeScalarView()
            string.append(contentsOf: pageScalars)
            var lines: [RawLine] = []
            var current = String.UnicodeScalarView()
            var offset = 0              // UTF-16 offset of the next scalar in the page string
            var lineStart = 0
            func finishLine() {
                let line = String(current)
                let bounds: PageRect? = Bool.random(using: &generator)
                    ? PageRect(pageIndex: index, x: 0, y: Double.random(in: -50...900, using: &generator), width: 0,
                               height: Double.random(in: 0...30, using: &generator))
                    : nil
                lines.append(RawLine(range: TextRange(location: lineStart, length: line.utf16.count), text: line, bounds: bounds))
                current = String.UnicodeScalarView()
            }
            for scalar in pageScalars {
                if scalar == "\n" {
                    finishLine()
                    offset += 1
                    lineStart = offset
                    continue
                }
                if !current.isEmpty && Int.random(in: 0..<60, using: &generator) == 0 {
                    finishLine()
                    lineStart = offset
                }
                current.append(scalar)
                offset += scalar.utf16.count
            }
            finishLine()
            pages.append(RawPage(index: index, size: PageSize(width: 612, height: 792), string: String(string), lines: lines))
        }
        let quotes = (0..<20).map { _ -> String in
            let start = Int.random(in: 0..<(all.count - 400), using: &generator)
            var quote = String.UnicodeScalarView()
            quote.append(contentsOf: all[start..<(start + Int.random(in: 1...300, using: &generator))])
            return String(quote)
        }
        exercise(RawDocument(pages: pages), quotes: quotes)
    }

    private static func randomScalar(using generator: inout SeededGenerator) -> Unicode.Scalar {
        let pools: [ClosedRange<UInt32>] = [0x20...0x7E, 0x20...0x7E, 0x30...0x39, 0x0A...0x0A, 0xA0...0x24F, 0x2B0...0x36F, 0x370...0x3FF,
                                            0x2000...0x206F, 0x2070...0x209F, 0xFB00...0xFB06, 0xFF00...0xFFEF, 0x4E00...0x9FFF,
                                            0x1D400...0x1D7FF, 0x1F300...0x1F6FF, 0x0...0x10FFFF]
        while true {
            let pool = pools[Int.random(in: 0..<pools.count, using: &generator)]
            if let scalar = Unicode.Scalar(UInt32.random(in: pool, using: &generator)) { return scalar }
        }
    }

    // MARK: - Speed

    /// A 60-page paper of invented words, with hyphenated line ends, and 50 quotes of every kind.
    @Test func speed() throws {
        var generator = SeededGenerator(seed: 60)
        let syllables = ["ka", "lo", "mi", "ne", "ru", "sa", "ti", "vo", "ze", "pa", "qui", "bra", "sto", "fle", "gri", "an", "el", "or",
                         "un", "is", "de", "tra", "mon", "pel"]
        let vocabulary = (0..<3_000).map { _ in
            (0..<Int.random(in: 1...4, using: &generator)).map { _ in syllables[Int.random(in: 0..<syllables.count, using: &generator)] }.joined()
        }
        var words: [String] = []          // the whole text, word by word, in reading order
        var pages: [RawPage] = []
        for index in 0..<60 {
            var lines: [String] = []
            var line = ""
            while lines.count < 45 {
                let skew = Double.random(in: 0..<1, using: &generator)
                let word = vocabulary[Int(skew * skew * Double(vocabulary.count))]
                words.append(word)
                if line.count + word.count + 1 > 75 {
                    if word.count >= 6 && Bool.random(using: &generator) {
                        let cut = word.index(word.startIndex, offsetBy: 3)
                        lines.append(line + " " + String(word[..<cut]) + "-")
                        line = String(word[cut...])
                    } else {
                        lines.append(line)
                        line = word
                    }
                } else {
                    line += line.isEmpty ? word : " " + word
                }
            }
            if !line.isEmpty { lines.append(line) }
            pages.append(PaperTextSample.rawPage(index: index, lines: lines))
        }
        let paper = PaperTextBuilder().build(from: RawDocument(pages: pages))

        func passage(_ count: Int) -> [String] {
            let start = Int.random(in: 0..<(words.count - count), using: &generator)
            return Array(words[start..<(start + count)])
        }
        var exact: [String] = []
        var changed: [String] = []
        var long: [String] = []
        var elided: [String] = []
        for _ in 0..<20 { exact.append(passage(Int.random(in: 8...25, using: &generator)).joined(separator: " ")) }
        for _ in 0..<10 {
            var quote = passage(16)
            quote[5] = "zzyzx"
            quote[11] = "qwvrt"
            changed.append(quote.joined(separator: " "))
        }
        for _ in 0..<10 {
            var quote = passage(45)
            quote[22] = "zzyzx"
            long.append(quote.joined(separator: " "))
        }
        for _ in 0..<5 {
            let quote = passage(30)
            elided.append(quote[0..<7].joined(separator: " ") + " … " + quote[23...].joined(separator: " "))
        }
        let absent = (0..<5).map { _ in (0..<12).map { _ in "x\(Int.random(in: 0..<1_000_000, using: &generator))y" }.joined(separator: " ") }
        let quotes = exact + changed + long + elided + absent
        #expect(quotes.count == 50)

        let clock = ContinuousClock()
        var results: [AnchorMatch?] = []
        let elapsed = clock.measure {
            let matcher = QuoteMatcher(paper: paper)
            results = quotes.map { matcher.locate(quote: $0, pageHint: nil) }
        }
        #expect(elapsed < .seconds(1), "building the matcher and 50 locate calls took \(elapsed)")

        #expect(results[0..<20].allSatisfy { $0?.confidence == .exact })
        #expect(results[20..<30].allSatisfy { $0 != nil && $0?.confidence != .exact })
        #expect(results[30..<45].allSatisfy { $0?.confidence == .fuzzy(score: 0.9) })
        #expect(results[45..<50].allSatisfy { $0 == nil })
    }
}
