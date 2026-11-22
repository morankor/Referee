import Foundation
import Testing
import RefereeCore
import AppCore
import TestSupport
import PaperText

/// Gate 1 (plan.md section 11.4), rows "pipeline on every fixture", "citations with line numbers" and "selection on a
/// real page": the real PDF service, builder, matcher, renderer and indexer together, as `LiveDependencies` wires them.
@Suite struct IntegrationPipelineTests {
    static let exactQuotes: [(quote: String, page: Int)] = [
        ("The coefficient in Table 2 is 0.91 with a confidence interval that crosses one", 0),
        ("Herding has been studied extensively since Banerjee", 0),
        ("office-specific identification threshold", 0),
        ("an information cascade begins with positive probability", 1),
        ("It is easy to see that the inequality is preserved when both sides are multiplied by the likelihood ratio.", 1),
    ]
    static let acrossAPage = "verify the differentiability of the payoff function"
    static let table2 = "The coefficient in Table 2 is 0.91 with a confidence interval that crosses one"
    static let pageCounts = ["ay_nolinks": 4, "s1_ruler": 4, "ay_round_nolinks": 4, "ay_links": 4, "num_links": 4, "num_twocol_links": 2,
                             "scanned": 1, "ay_long": 16]

    private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func line(_ paper: PaperText, page: Int, startingWith prefix: String) -> TextLine? {
        paper.pages[page].lines.first { trimmed($0.text).hasPrefix(prefix) }
    }

    // ---- pipeline on every fixture ----

    @Test(arguments: Fixture.all)
    func thePipelineCompletesOnEveryFixture(name: String) async throws {
        let graph = await LiveGraph.make(mock: false)
        defer { graph.remove() }
        let service = graph.dependencies.paperService
        let paper = try await service.load(url: Fixture.url(name))
        defer { Task { await service.unload(paper.ref) } }
        #expect(paper.ref.pageCount == Self.pageCounts[name])
        #expect(paper.text.hasTextLayer == (name != "scanned"))
        #expect(paper.text.hasMarginLineNumbers == (name == "ay_nolinks" || name == "s1_ruler"))    // "no false positives", ay_long included
        let matcher = graph.dependencies.matcherFactory(paper.text)
        #expect(matcher.locate(quote: "this sentence is not in the paper at all whatsoever", pageHint: nil) == nil)
        let index = graph.dependencies.citationIndexer.buildIndex(paper: paper.text, links: paper.links)
        let rendered = PaperRenderer().render(paper.text, pages: nil)
        if name == "scanned" {
            #expect(index.entries.isEmpty)
        } else {
            #expect(!index.entries.isEmpty)
            #expect(rendered.hasPrefix("[[page 1]]\n"))
        }
    }

    // ---- the WP1 rows marked ● for the two journal fixtures, through the real service ----

    @Test(arguments: ["ay_nolinks", "s1_ruler"])
    func theJournalFixturesHoldTheirMeasuredFactsThroughTheRealService(name: String) async throws {
        let graph = await LiveGraph.make(mock: false)
        defer { graph.remove() }
        let service = graph.dependencies.paperService
        let loaded = try await service.load(url: Fixture.url(name))
        defer { Task { await service.unload(loaded.ref) } }
        let paper = loaded.text
        try #require(paper.pages.count == 4)
        #expect(paper.hasMarginLineNumbers)

        if name == "ay_nolinks" {
            // "line numbers on text lines"
            let expected = [Array(1...16), Array(17...33), Array(34...48), Array(49...54)]
            for (position, page) in paper.pages.enumerated() {
                let numbers = page.lines.filter { $0.kind == .marginNumberOnly || $0.contentRange != $0.range }.compactMap(\.marginNumber).sorted()
                #expect(numbers == expected[position], "page \(position + 1)")
            }
            #expect(paper.pages.map { $0.lines.filter { $0.kind == .marginNumberOnly }.count } == [4, 1, 3, 2])
            let table2 = try #require(Self.line(paper, page: 0, startingWith: "Table 2 is 0.91"))
            #expect(table2.marginNumber == 14)
            #expect(table2.text.hasSuffix("difficult to"))
            #expect(Self.line(paper, page: 1, startingWith: "function.")?.marginNumber == 17)
            #expect(Self.line(paper, page: 3, startingWith: "A Course in Game Theory. MIT Press.")?.marginNumber == 52)
            let unnumbered: Set<String> = ["Table 2: Baseline estimates", "Specification Estimate 95% interval", "Baseline 0.91 [0.78, 1.06]",
                                           "Staggered rollout 0.87 [0.74, 1.02]", "Office fixed effects 0.95 [0.80, 1.12]",
                                           "µi =", "πf(si |H)", "πf(si |H) + (1−π)f(si |L).", "(1)"]
            let bodyLines: [TextLine] = paper.pages.flatMap(\.lines).filter { $0.kind == .body && $0.marginNumber == nil }
            let withoutNumber = Set(bodyLines.map { Self.trimmed($0.text) })
            #expect(withoutNumber == unnumbered)
            // "page furniture"
            let confidential = paper.pages.flatMap(\.lines).filter { Self.trimmed($0.text) == "CONFIDENTIAL" }
            #expect(confidential.count == 4 && confidential.allSatisfy { $0.kind == .watermark })
            #expect(paper.pages.allSatisfy { $0.lines.last?.kind == .pageNumber })
        } else {
            // "ruler"
            for page in paper.pages {
                #expect(page.lines.filter { $0.kind == .marginNumberOnly }.compactMap(\.marginNumber) == Array(1...60), "page \(page.index + 1)")
            }
            #expect(Self.line(paper, page: 0, startingWith: "ficient in Table 2 is 0.91")?.marginNumber == 49)
            #expect(Self.line(paper, page: 0, startingWith: "We study how sequential traders")?.marginNumber == 28)
            let digitsOnly = paper.pages.flatMap(\.lines).filter { line in
                let text = Self.trimmed(line.text)
                return line.kind == .body && !text.isEmpty && text.allSatisfy(\.isNumber)
            }
            #expect(digitsOnly.isEmpty)
            // "page furniture"
            for page in paper.pages {
                let n = page.index + 1
                #expect(Self.line(paper, page: page.index, startingWith: "Journal of Synthetic Economics")?.kind == .runningHeader, "page \(n)")
                #expect(Self.line(paper, page: page.index, startingWith: "Page \(n) of 4")?.kind == .pageNumber, "page \(n)")
                #expect(Self.line(paper, page: page.index, startingWith: "https://mc.example.org/jse")?.kind == .runningFooter, "page \(n)")
                #expect(Self.line(paper, page: page.index, startingWith: "For Peer Review")?.kind == .watermark, "page \(n)")
            }
        }

        // "exact anchors", with highlight rectangles that start at the text block and not in the margin
        let matcher = graph.dependencies.matcherFactory(paper)
        for (quote, page) in Self.exactQuotes {
            let match = try #require(matcher.locate(quote: quote, pageHint: nil), "\(name): \(quote)")
            #expect(match.confidence == .exact, "\(name): \(quote)")
            #expect(match.spans.allSatisfy { $0.pageIndex == page }, "\(name): \(quote)")
            let rects = await service.rects(for: match.spans, in: loaded.ref)
            #expect(rects.count == match.spans.count, "\(name): one rectangle per line touched: \(quote)")
            #expect(rects.allSatisfy { $0.x >= 100 && $0.width < 400 }, "\(name): \(quote): \(rects)")
        }
        // "across a page", "absent", "fuzzy", "labels"
        let across = try #require(matcher.locate(quote: Self.acrossAPage, pageHint: nil))
        #expect(across.confidence == .exact)
        #expect(across.spans.map(\.pageIndex) == [0, 1])
        #expect(matcher.locate(quote: "this sentence is not in the paper at all whatsoever", pageHint: nil) == nil)
        let table2 = try #require(matcher.locate(quote: Self.table2, pageHint: nil))
        let staggered = try #require(matcher.locate(quote: "Staggered rollout 0.87", pageHint: nil))
        if name == "ay_nolinks" {
            let fuzzy = try #require(matcher.locate(quote: "The coefficient in Table 2 equals 0.91 with a confidence interval which crosses one, which is difficult to reconcile",
                                                    pageHint: nil))
            guard case .fuzzy(let score) = fuzzy.confidence else {
                Issue.record("expected a fuzzy match, got \(fuzzy.confidence)")
                return
            }
            #expect(score >= 0.85)
            #expect(matcher.locationLabel(for: table2.spans) == "p. 1, lines 13–14")
            let herding = try #require(matcher.locate(quote: "Herding has been studied extensively since Banerjee", pageHint: nil))
            #expect(matcher.locationLabel(for: herding.spans) == "p. 1, line 9")
            #expect(matcher.locationLabel(for: across.spans) == "pp. 1–2 (p. 1 line 16 to p. 2 line 17)")
            #expect(matcher.locationLabel(for: staggered.spans) == "p. 3")
        } else {
            #expect(matcher.locationLabel(for: table2.spans) == "p. 1, lines 47–49")
            #expect(matcher.locationLabel(for: across.spans) == "pp. 1–2 (p. 1 line 53 to p. 2 line 8)")
            #expect(matcher.locationLabel(for: staggered.spans) == "p. 3, line 12")
        }

        // "rendering"
        let text = PaperRenderer().render(paper, pages: nil)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
        #expect(lines.count == 37)
        #expect(text.hasPrefix("[[page 1]]\n") && text.hasSuffix("\n") && !text.hasSuffix("\n\n"))
        #expect(lines.filter { $0.hasPrefix("[[page ") } == ["[[page 1]]", "[[page 2]]", "[[page 3]]", "[[page 4]]"])
        #expect(lines.contains("2 Model") && lines.contains("µi ="))
        for row in ["Specification Estimate 95% interval", "Baseline 0.91 [0.78, 1.06]", "Staggered rollout 0.87 [0.74, 1.02]",
                    "Office fixed effects 0.95 [0.80, 1.12]"] {
            #expect(lines.contains(row), "\(row)")
        }
        #expect(text.contains("difficult to reconcile with the claim of a robust effect") && text.contains("predecessors"))
        let page2 = try #require(lines.firstIndex(of: "[[page 2]]"))
        let payoff = try #require(lines.firstIndex { $0.contains("the payoff function.") })
        #expect(payoff < page2)
        #expect(lines[page2 + 1].hasPrefix("In Banerjee"))
        for absent in ["CONFIDENTIAL", "to14", "Journal of Synthetic", "mc.example.org", "For Peer Review"] {
            #expect(!text.contains(absent), "\(absent)")
        }
        #expect(!lines.contains { !$0.isEmpty && $0.allSatisfy(\.isNumber) })
    }

    // ---- citations with line numbers ----

    /// WP3's targets on the round-bracket text: page 1 Banerjee, Bikhchandani, Avery, Smith, Acemoglu, Smith, Kogan, Lee;
    /// page 2 Banerjee, Avery, Lee, Smith, Osborne, Dekel, Bikhchandani (entries in alphabetical order, from 0).
    static let mentionTargets = [2, 3, 1, 8, 0, 8, 5, 6, 2, 1, 6, 8, 7, 4, 3]
    static let firstSurnames = ["Acemoglu", "Avery", "Banerjee", "Bikhchandani", "Dekel", "Kogan", "Lee", "Osborne", "Smith"]

    @Test(arguments: ["ay_nolinks", "s1_ruler", "ay_round_nolinks"])
    func citationsAreFoundOnTheJournalFixtures(name: String) async throws {
        let graph = await LiveGraph.make(mock: false)
        defer { graph.remove() }
        let service = graph.dependencies.paperService
        let paper = try await service.load(url: Fixture.url(name))
        defer { Task { await service.unload(paper.ref) } }
        let index = graph.dependencies.citationIndexer.buildIndex(paper: paper.text, links: paper.links)
        #expect(index.style == .authorYear)
        #expect(index.entries.map { $0.parsed.authorSurnames.first ?? "" } == Self.firstSurnames)
        #expect(index.mentions.map(\.entryIDs) == Self.mentionTargets.map { [$0] })
        #expect(index.mentions.allSatisfy { $0.source == .textPattern && !$0.spans.isEmpty })
        // Their rectangles, as the model fills them (section 8.4), lie on the text, not in the margin.
        for mention in index.mentions {
            let rects = await service.rects(for: mention.spans, in: paper.ref)
            #expect(!rects.isEmpty && rects.allSatisfy { $0.x >= 100 }, "mention \(mention.id): \(rects)")
        }
    }

    // ---- selection on a real page ----

    @Test @MainActor func aSelectionAcrossTwoLinesIsNormalised() async throws {
        let graph = await LiveGraph.make()
        defer { graph.remove() }
        let model = ReviewSessionModel(dependencies: graph.dependencies, settings: try await graph.mockSettings())
        await model.open(url: Fixture.url("ay_nolinks"))
        try #require(model.phase == .ready)
        let page1 = try #require(model.paper?.text.pages.first?.string)
        let first = try uniqueRange(of: " As shown by Acemoglu et al. [2011],11", in: page1)
        let second = try uniqueRange(of: "network structure determines wheth", in: page1)
        let raw = SelectionInfo(text: " As shown by Acemoglu et al. [2011],11\nnetwork structure determines wheth",
                                spans: [TextSpan(pageIndex: 0, range: first), TextSpan(pageIndex: 0, range: second)])
        model.readerSelectionChanged(raw)
        #expect(model.selection?.text == "As shown by Acemoglu et al. [2011], network structure determines wheth")
        #expect(await waitUntil { model.selection?.rects.count == 2 })
        let rects = try #require(model.selection?.rects)
        #expect(rects.allSatisfy { $0.x >= 100 && $0.width < 400 }, "\(rects)")

        // Page 3, from one reference entry's first line to its continuation, across the watermark line and the line
        // that is only the number 42: one raw span per line touched, as PDFKit reports a drag.
        let page3 = try #require(model.paper?.text.pages[2])
        let start = try uniqueRange(of: "Bikhchandani, S., Hirshleifer, D., and Welch, I. (1992). A theory of fads,41", in: page3.string)
        let end = try uniqueRange(of: "fashion, custom, and cultural change as informational cascades. Journal", in: page3.string)
        let touched = page3.lines.filter { $0.range.upperBound > start.location && $0.range.location < end.upperBound }
        #expect(touched.contains { Self.trimmed($0.text) == "CONFIDENTIAL" })
        #expect(touched.contains { Self.trimmed($0.text) == "42" || $0.kind == .marginNumberOnly })
        let spans = touched.map { line -> TextSpan in
            let lower = max(line.range.location, start.location)
            let upper = min(line.range.upperBound, end.upperBound)
            return TextSpan(pageIndex: 2, range: TextRange(location: lower, length: upper - lower))
        }
        let text = spans.map { (page3.string as NSString).substring(with: $0.range.nsRange) }.joined(separator: "\n")
        model.readerSelectionChanged(SelectionInfo(text: text, spans: spans))
        let normalised = try #require(model.selection?.text)
        for absent in ["CONFIDENTIAL", "41", "42"] { #expect(!normalised.contains(absent), "\(absent) in \(normalised)") }
        #expect(normalised.hasPrefix("Bikhchandani, S., Hirshleifer, D., and Welch, I. (1992). A theory of fads,"))
        #expect(normalised.hasSuffix("informational cascades. Journal"))
        await model.close()
    }
}
