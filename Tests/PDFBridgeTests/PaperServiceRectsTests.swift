import Foundation
import PDFKit
import Testing
import RefereeCore
import PDFBridge
import TestSupport

/// WP2 rows "equation and table" and "rects exclude margin numbers" (plan.md section 11.4), the bounds of lines whose
/// margin number was stripped (section 7.2), and spans that make no sense.
@Suite struct PaperServiceRectsTests {
    private static func contains(_ outer: PageRect, _ inner: PageRect, slack: Double = 0.5) -> Bool {
        inner.x >= outer.x - slack && inner.x + inner.width <= outer.x + outer.width + slack
            && inner.y >= outer.y - slack && inner.y + inner.height <= outer.y + outer.height + slack
    }

    // MARK: - Equation and table

    /// Page 2 of ay_round_nolinks has the displayed fraction, page 3 the table.
    @Test(arguments: [1, 2])
    func aSpanOfEachLineGivesOneRectangleInsideTheLine(pageIndex: Int) async throws {
        let service = PDFPaperService(builder: IdentityTextBuilder())
        let paper = try await service.load(url: Fixtures.url("pdf/ay_round_nolinks.pdf"))
        let page = paper.text.pages[pageIndex]
        #expect(page.lines.count > 15)
        for line in page.lines {
            let rects = await service.rects(for: [TextSpan(pageIndex: pageIndex, range: line.range)], in: paper.ref)
            #expect(rects.count == 1, "\(line.text)")
            guard let rect = rects.first, let bounds = line.bounds else { continue }
            #expect(rect.pageIndex == pageIndex)
            #expect(rect.width > 0 && rect.height > 0)
            #expect(Self.contains(bounds, rect), "\(line.text): \(rect) is not inside \(bounds)")
        }
    }

    @Test func oneSpanOverTheWholeFractionOrTableGivesOneRectanglePerLine() async throws {
        let service = PDFPaperService(builder: IdentityTextBuilder())
        let paper = try await service.load(url: Fixtures.url("pdf/ay_round_nolinks.pdf"))
        for (pageIndex, firstText, lastText, count) in [(1, "µi =", "(1)", 4), (2, "Table 2: Baseline estimates", "Office fixed effects 0.95 [0.80, 1.12]", 5)] {
            let lines = paper.text.pages[pageIndex].lines
            let first = try #require(lines.firstIndex { $0.text == firstText })
            let last = try #require(lines.firstIndex { $0.text == lastText })
            #expect(last - first + 1 == count)
            let block = TextRange(location: lines[first].range.location, length: lines[last].range.upperBound - lines[first].range.location)
            let rects = await service.rects(for: [TextSpan(pageIndex: pageIndex, range: block)], in: paper.ref)
            var expected: [PageRect] = []
            for line in lines[first...last] { expected += await service.rects(for: [TextSpan(pageIndex: pageIndex, range: line.range)], in: paper.ref) }
            #expect(rects.count == count)
            #expect(rects == expected)
            #expect(Set(rects).count == count)                   // one per line, no two alike
        }
    }

    // MARK: - Margin numbers excluded

    @Test func rectanglesOfTheTable2QuoteExcludeTheMarginNumbers() async throws {
        let service = PDFPaperService(builder: TrailingDigitsBuilder())
        let paper = try await service.load(url: Fixtures.url("pdf/ay_nolinks.pdf"))
        let string = paper.text.pages[0].string as NSString
        let head = string.range(of: "The coefficient in")
        let tail = string.range(of: "Table 2 is 0.91 with a confidence interval that crosses one")
        #expect(head == NSRange(location: 676, length: 18) && tail == NSRange(location: 697, length: 59))   // the spans of section 4.3
        let rects = await service.rects(for: [TextSpan(pageIndex: 0, range: TextRange(head)), TextSpan(pageIndex: 0, range: TextRange(tail))],
                                        in: paper.ref)
        #expect(rects.count == 2)
        for rect in rects {
            #expect(rect.pageIndex == 0)
            #expect(rect.x >= 100, "\(rect)")
            #expect(rect.width < 400, "\(rect)")
        }

        // Each starts where the quote starts on its line. (PDFKit's own bounds of "The coefficient in" begin at x 296.6,
        // because the box it gives the "n" before the glued "13" reaches back to there.)
        let page = try #require(try fixtureDocument("ay_nolinks").page(at: 0))
        let theT = try #require(characterBox(on: page, at: 676))
        let tableT = try #require(characterBox(on: page, at: 697))
        guard rects.count == 2 else { return }
        #expect(abs(rects[0].x - Double(theT.minX)) < 0.01, "\(rects[0]) should start at \(theT.minX)")
        #expect(abs(rects[1].x - Double(tableT.minX)) < 0.01, "\(rects[1]) should start at \(tableT.minX)")
        #expect(rects[0].x > 380 && rects[0].x + rects[0].width < 500)
        #expect(abs(rects[0].y - Double(theT.minY)) < 0.01 && abs(rects[1].y - Double(tableT.minY)) < 0.01)
    }

    @Test func spansThatIncludeTheMarginDigitsAreCutToTheText() async throws {
        let service = PDFPaperService(builder: TrailingDigitsBuilder())
        let paper = try await service.load(url: Fixtures.url("pdf/ay_nolinks.pdf"))
        let lines = paper.text.pages[0].lines
        let numbered = lines.filter { $0.contentRange.length > 0 && $0.contentRange != $0.range }
        #expect(numbered.count >= 10)
        // The whole raw line, digits included; and a span running from inside one line into the next, as a drag gives.
        for line in numbered {
            let rects = await service.rects(for: [TextSpan(pageIndex: 0, range: line.range)], in: paper.ref)
            #expect(rects.count == 1)
            for rect in rects {
                #expect(rect.x >= 100 && rect.width < 400, "\(line.text): \(rect)")
            }
        }
        let string = paper.text.pages[0].string as NSString
        let start = string.range(of: " As shown by Acemoglu").location
        let end = NSMaxRange(string.range(of: "network structure determines wheth"))
        let drag = await service.rects(for: [TextSpan(pageIndex: 0, range: TextRange(location: start, length: end - start))], in: paper.ref)
        #expect(drag.count == 2)
        #expect(drag.allSatisfy { $0.x >= 100 && $0.width < 400 }, "\(drag)")
    }

    /// A builder whose `contentRange` leaves out the first word of every line, on a page without margin numbers: what
    /// lies outside the content counts for neither the rectangles nor the bounds, whatever PDFKit's boxes are.
    private struct FirstWordOutsideBuilder: PaperTextBuilding {
        func build(from raw: RawDocument) -> PaperText {
            var text = identityPaperText(from: raw)
            for page in text.pages.indices {
                let string = text.pages[page].string as NSString
                for index in text.pages[page].lines.indices {
                    let line = text.pages[page].lines[index]
                    let space = string.range(of: " ", options: [], range: line.range.nsRange)
                    guard space.location != NSNotFound, NSMaxRange(space) < line.range.upperBound else { continue }
                    let content = NSRange(location: NSMaxRange(space), length: line.range.upperBound - NSMaxRange(space))
                    text.pages[page].lines[index].contentRange = TextRange(content)
                    text.pages[page].lines[index].text = string.substring(with: content)
                }
            }
            return text
        }
    }

    @Test func onlyThePartOfASpanInsideTheContentRangeCounts() async throws {
        let service = PDFPaperService(builder: FirstWordOutsideBuilder())
        let paper = try await service.load(url: Fixtures.url("pdf/ay_round_nolinks.pdf"))
        let page = try #require(try fixtureDocument("ay_round_nolinks").page(at: 1))
        let cut = paper.text.pages[1].lines.filter { $0.contentRange != $0.range }
        #expect(cut.count >= 15)
        for line in cut {
            let box = try #require(characterBox(on: page, at: line.contentRange.location))
            let rects = await service.rects(for: [TextSpan(pageIndex: 1, range: line.range)], in: paper.ref)
            #expect(rects.count == 1, "\(line.text)")
            #expect(rects.first.map { abs($0.x - Double(box.minX)) < 0.01 } == true, "\(line.text): \(rects) should start at \(box.minX)")
            #expect(line.bounds.map { abs($0.x - Double(box.minX)) < 0.01 } == true, "\(line.text): \(String(describing: line.bounds))")
            // A span on the first word alone touches no content.
            let firstWord = TextRange(location: line.range.location, length: line.contentRange.location - 1 - line.range.location)
            #expect(await service.rects(for: [TextSpan(pageIndex: 1, range: firstWord)], in: paper.ref).isEmpty, "\(line.text)")
        }
    }

    @Test func linesWhoseMarginNumberWasStrippedGetTheBoundsOfTheirText() async throws {
        let paper = try await PDFPaperService(builder: TrailingDigitsBuilder()).load(url: Fixtures.url("pdf/ay_nolinks.pdf"))
        let raw = try Fixtures.rawDocument("ay_nolinks")
        let document = try fixtureDocument("ay_nolinks")
        var recomputed = 0
        for (page, rawPage) in zip(paper.text.pages, raw.pages) {
            let pdfPage = try #require(document.page(at: page.index))
            let string = page.string as NSString
            #expect(page.lines.count == rawPage.lines.count)
            for (line, rawLine) in zip(page.lines, rawPage.lines) {
                if line.contentRange == line.range {
                    #expect(line.bounds == rawLine.bounds, "\(line.text): left as the builder gave it")
                } else if line.contentRange.length == 0 {
                    #expect(line.bounds == nil, "\(rawLine.text): nothing is left of a number-only line")
                } else {
                    recomputed += 1
                    let bounds = try #require(line.bounds, "\(line.text)")
                    #expect(bounds.pageIndex == page.index)
                    // It starts at its first character (centred title lines included) and ends inside the text block.
                    let first = string.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted, options: [], range: line.contentRange.nsRange)
                    let box = try #require(characterBox(on: pdfPage, at: first.location))
                    #expect(abs(bounds.x - Double(box.minX)) < 0.01, "\(line.text): \(bounds) should start at \(box.minX)")
                    #expect(bounds.x >= 100 && bounds.x + bounds.width < 500, "\(line.text): \(bounds)")
                    if let rawBounds = rawLine.bounds { #expect(Self.contains(rawBounds, bounds), "\(line.text)") }
                }
            }
        }
        #expect(recomputed >= 40)
    }

    // MARK: - Spans that make no sense

    @Test func impossibleSpansGiveNothingAndOverlongOnesAreCut() async throws {
        let service = PDFPaperService(builder: IdentityTextBuilder())
        let paper = try await service.load(url: Fixtures.url("pdf/ay_round_nolinks.pdf"))
        let page = paper.text.pages[0]
        let length = (page.string as NSString).length
        let nonsense = [
            TextSpan(pageIndex: -1, range: TextRange(location: 0, length: 10)),
            TextSpan(pageIndex: 4, range: TextRange(location: 0, length: 10)),
            TextSpan(pageIndex: 0, range: TextRange(location: length, length: 10)),
            TextSpan(pageIndex: 0, range: TextRange(location: -5, length: 3)),
            TextSpan(pageIndex: 0, range: TextRange(location: 5, length: -3)),
            TextSpan(pageIndex: 0, range: TextRange(location: 0, length: 0)),
            TextSpan(pageIndex: 0, range: TextRange(location: Int.max - 1, length: Int.max)),
            TextSpan(pageIndex: 0, range: TextRange(location: page.lines[0].range.upperBound, length: 1)),      // the line break
            TextSpan(pageIndex: 0, range: TextRange(location: (page.string as NSString).range(of: " ").location, length: 1)),   // a space
        ]
        #expect(await service.rects(for: nonsense, in: paper.ref).isEmpty)

        let last = try #require(page.lines.last)
        let overlong = await service.rects(for: [TextSpan(pageIndex: 0, range: TextRange(location: last.range.location, length: 1_000_000))], in: paper.ref)
        let exact = await service.rects(for: [TextSpan(pageIndex: 0, range: last.range)], in: paper.ref)
        #expect(overlong.count == 1 && overlong == exact)
        #expect(await service.rects(for: [], in: paper.ref).isEmpty)
    }
}
