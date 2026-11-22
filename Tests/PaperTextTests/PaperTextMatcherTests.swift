import Foundation
import Testing
import RefereeCore
import PaperText
import TestSupport

/// WP1 acceptance (plan.md section 11.4), the matcher rows: anchors, fuzzy matching, labels.
@Suite struct PaperTextMatcherTests {
    private static let exactQuotes: [(quote: String, page: Int)] = [
        ("The coefficient in Table 2 is 0.91 with a confidence interval that crosses one", 0),
        ("Herding has been studied extensively since Banerjee", 0),
        ("office-specific identification threshold", 0),
        ("an information cascade begins with positive probability", 1),
        ("It is easy to see that the inequality is preserved when both sides are multiplied by the likelihood ratio.", 1),
    ]
    private static let acrossAPage = "verify the differentiability of the payoff function"
    private static let table2 = "The coefficient in Table 2 is 0.91 with a confidence interval that crosses one"

    private func matcher(_ name: String) throws -> (paper: PaperText, matcher: QuoteMatcher) {
        let paper = try PaperTextSample.paper(name)
        return (paper, QuoteMatcher(paper: paper))
    }

    /// One span per text line touched: each span inside the content of exactly one body line, no line twice, in text
    /// order; and together the spans hold the quote's letters and digits, nothing more.
    private func expectOneSpanPerLine(_ match: AnchorMatch, quote: String, in paper: PaperText,
                                      sourceLocation: SourceLocation = #_sourceLocation) {
        var seen: [TextLine] = []
        for span in match.spans {
            let holders = PaperTextSample.bodyLines(holding: span, in: paper)
            #expect(holders.count == 1, "span \(span) is not inside one body line", sourceLocation: sourceLocation)
            if let line = holders.first {
                #expect(!seen.contains(line), "two spans on one line", sourceLocation: sourceLocation)
                seen.append(line)
            }
        }
        let ordered = match.spans.sorted { ($0.pageIndex, $0.range.location) < ($1.pageIndex, $1.range.location) }
        #expect(ordered == match.spans, "spans not in text order", sourceLocation: sourceLocation)
        let covered = match.spans.compactMap { PaperTextSample.text(of: $0, in: paper) }.joined()
        #expect(PaperTextSample.letters(covered) == PaperTextSample.letters(quote), sourceLocation: sourceLocation)
    }

    @Test(arguments: PaperTextSample.journalStamped)
    func exactAnchors(name: String) throws {
        let (paper, matcher) = try matcher(name)
        for (quote, page) in Self.exactQuotes {
            let match = try #require(matcher.locate(quote: quote, pageHint: nil), "\(name): \(quote)")
            #expect(match.confidence == .exact, "\(name): \(quote)")
            #expect(match.spans.allSatisfy { $0.pageIndex == page }, "\(name): \(quote)")
            expectOneSpanPerLine(match, quote: quote, in: paper)
            // A hint changes nothing for a quote that occurs once.
            #expect(matcher.locate(quote: quote, pageHint: 3) == match)
        }
    }

    @Test(arguments: PaperTextSample.journalStamped + ["ay_round_nolinks", "ay_links"])
    func acrossAPage(name: String) throws {
        let (paper, matcher) = try matcher(name)
        let match = try #require(matcher.locate(quote: Self.acrossAPage, pageHint: nil))
        #expect(match.confidence == .exact)
        #expect(match.spans.map(\.pageIndex) == [0, 1])
        expectOneSpanPerLine(match, quote: Self.acrossAPage, in: paper)
    }

    @Test func twoColumnsSmoke() throws {
        let (paper, matcher) = try matcher("num_twocol_links")
        let first = "column of this page contains the sentence that must be anchored before the second column begins"
        let match = try #require(matcher.locate(quote: first, pageHint: nil))
        #expect(match.confidence == .exact)
        #expect(match.spans.allSatisfy { $0.pageIndex == 0 })
        expectOneSpanPerLine(match, quote: first, in: paper)

        let second = "Table 1 reports a BLEU score of 28.4 for the base model"
        let other = try #require(matcher.locate(quote: second, pageHint: nil))
        #expect(other.confidence == .exact)
        #expect(other.spans.allSatisfy { $0.pageIndex == 1 })

        // Runs from the bottom of the left column into the top of the right one: not contiguous in the text.
        let crossing = matcher.locate(quote: "Aliquam vestibulum fringilla lorem. Sed neque lectus, consectetuer at", pageHint: nil)
        if let crossing { #expect(crossing.spans.allSatisfy { $0.pageIndex == 1 }) }
        _ = matcher.locate(quote: "Aliquam vestibulum fringilla lorem. Sed neque lectus, consectetuer at", pageHint: 1)
    }

    @Test func fuzzy() throws {
        let (paper, matcher) = try matcher("ay_nolinks")
        let quote = "The coefficient in Table 2 equals 0.91 with a confidence interval which crosses one, which is difficult to reconcile"
        let match = try #require(matcher.locate(quote: quote, pageHint: nil))
        guard case .fuzzy(let score) = match.confidence else {
            Issue.record("expected a fuzzy match, got \(match.confidence)")
            return
        }
        #expect(score >= 0.85)
        #expect(score <= 1)
        #expect(match.spans.allSatisfy { $0.pageIndex == 0 })
        // Trimmed to the first and the last matched token.
        let covered = PaperTextSample.letters(match.spans.compactMap { PaperTextSample.text(of: $0, in: paper) }.joined())
        #expect(covered.hasPrefix("thecoefficient"))
        #expect(covered.hasSuffix("difficulttoreconcile"))
        #expect(match.spans.count == 3)

        // Five tokens are too few for the fuzzy stage; the same change with six tokens is found.
        #expect(matcher.locate(quote: "confidence interval which crosses one", pageHint: nil) == nil)
        #expect(matcher.locate(quote: "confidence interval which crosses one", pageHint: 0) == nil)
        let six = try #require(matcher.locate(quote: "a confidence interval which crosses one", pageHint: nil))
        guard case .fuzzy = six.confidence else {
            Issue.record("expected a fuzzy match, got \(six.confidence)")
            return
        }
    }

    @Test func ellipsis() throws {
        let (paper, matcher) = try matcher("ay_nolinks")
        for quote in ["The coefficient in Table 2 is 0.91 … reconcile with the claim of a robust effect",
                      "The coefficient in Table 2 is 0.91 ... reconcile with the claim of a robust effect",
                      "The coefficient in Table 2 is 0.91 [...] reconcile with the claim of a robust effect"] {
            let match = try #require(matcher.locate(quote: quote, pageHint: nil), "\(quote)")
            #expect(match.spans.allSatisfy { $0.pageIndex == 0 })
            #expect(match.confidence == .fuzzy(score: 0.9))
            let covered = PaperTextSample.letters(match.spans.compactMap { PaperTextSample.text(of: $0, in: paper) }.joined())
            #expect(covered.hasPrefix("thecoefficientintable2is091"))
            #expect(covered.hasSuffix("reconcilewiththeclaimofarobusteffect"))
        }
    }

    @Test func longQuoteWithAChangeInTheMiddleIsFoundByHeadAndTail() throws {
        let (_, matcher) = try matcher("ay_round_nolinks")
        let quote = "Herding has been studied extensively since Banerjee (1992) and Bikhchandani et al. (1992). Later work extends the "
            + "framework to stock markets (Avery and Zemsky, 1998; Smith and Sørensen, 2000). As shown by Acemoglu et al. (2011), "
            + "network structure determines whether learning is efficient"
        let match = try #require(matcher.locate(quote: quote, pageHint: nil))
        #expect(match.confidence == .fuzzy(score: 0.9))
        #expect(match.spans.allSatisfy { $0.pageIndex == 0 })
        #expect(match.spans.count == 4)
    }

    @Test(arguments: PaperTextSample.journalStamped + PaperTextSample.unnumbered)
    func absent(name: String) throws {
        let (_, matcher) = try matcher(name)
        #expect(matcher.locate(quote: "this sentence is not in the paper at all whatsoever", pageHint: nil) == nil)
        #expect(matcher.locate(quote: "this sentence is not in the paper at all whatsoever", pageHint: 0) == nil)
        #expect(matcher.locate(quote: "", pageHint: nil) == nil)
        #expect(matcher.locate(quote: "… — !!", pageHint: 0) == nil)
    }

    @Test func shortQuotes() throws {
        let (_, matcher) = try matcher("ay_nolinks")
        #expect(matcher.locate(quote: "Table 2", pageHint: nil) == nil)
        let hinted = try #require(matcher.locate(quote: "Table 2", pageHint: 0))
        #expect(hinted.confidence == .exact)
        #expect(hinted.spans.map(\.pageIndex) == [0])
        // With a hint, only that page and its neighbours are searched.
        #expect(matcher.locate(quote: "Table 2", pageHint: 2)?.spans.map(\.pageIndex) == [2])
        #expect(matcher.locate(quote: "Kogan [2020]", pageHint: 3)?.spans.map(\.pageIndex) == nil)
        #expect(matcher.locate(quote: "Kogan [2020]", pageHint: 1)?.spans.map(\.pageIndex) == [0])
    }

    @Test func repeatedText() throws {
        let sentence = "Repeated evidence of herding appears here."
        let paper = PaperTextSample.plainPaper([[sentence, "Only on the first page."], ["Something else entirely."], ["Another line.", sentence]])
        let matcher = QuoteMatcher(paper: paper)
        #expect(matcher.locate(quote: sentence, pageHint: nil)?.spans.map(\.pageIndex) == [0])
        #expect(matcher.locate(quote: sentence, pageHint: 0)?.spans.map(\.pageIndex) == [0])
        #expect(matcher.locate(quote: sentence, pageHint: 2)?.spans.map(\.pageIndex) == [2])
        #expect(matcher.locate(quote: sentence, pageHint: 1)?.spans.map(\.pageIndex) == [0])       // both one page away: the first
        #expect(matcher.locate(quote: sentence, pageHint: 7)?.spans.map(\.pageIndex) == [2])       // the nearest

        // On a fixture: "Bikhchandani et al. (1992)" stands on pages 1 and 2.
        let (_, fixture) = try self.matcher("ay_round_nolinks")
        #expect(fixture.locate(quote: "Bikhchandani et al. (1992)", pageHint: nil)?.spans.first?.pageIndex == 0)
        #expect(fixture.locate(quote: "Bikhchandani et al. (1992)", pageHint: 1)?.spans.map(\.pageIndex) == [1])
    }

    @Test func folding() throws {
        let line = "The \u{FB01}rst estimate x\u{00B2} of \u{1D44E} is signi\u{FB01}cant"   // ﬁ, ², 𝑎 (mathematical italic small a)
        let paper = PaperTextSample.plainPaper([[line]])
        let matcher = QuoteMatcher(paper: paper)
        let match = try #require(matcher.locate(quote: "The first estimate x2 of a is significant", pageHint: nil))
        #expect(match.confidence == .exact)
        #expect(match.spans == [TextSpan(pageIndex: 0, range: TextRange(location: 0, length: line.utf16.count))])
        // Case, spaces, hyphens, dashes and quotation marks do not matter either.
        #expect(matcher.locate(quote: "“THE FIRST — estimate X2 of a is signi-ficant”", pageHint: nil)?.confidence == .exact)
        // µ (micro sign) and μ (Greek mu) are the same letter.
        let mu = QuoteMatcher(paper: PaperTextSample.plainPaper([["The posterior \u{00B5}i is computed for every agent"]]))
        #expect(mu.locate(quote: "The posterior \u{03BC}i is computed", pageHint: nil)?.confidence == .exact)
    }

    /// Decisions where the plan is silent: accents and apostrophes that PDF text carries as separate characters (a
    /// combining mark, a spacing modifier letter such as U+02C6 or U+02BC) fold to nothing, as composed letters lose
    /// their accents.
    @Test func accentsAndApostrophesWrittenApart() {
        let paper = PaperTextSample.plainPaper([["A fore\u{02C6}t of Ce\u{0301}line and don\u{02BC}t forget the cafe\u{0301} rule"]])
        let matcher = QuoteMatcher(paper: paper)
        #expect(matcher.locate(quote: "A forêt of Céline and don't forget the café rule", pageHint: nil)?.confidence == .exact)
        #expect(matcher.locate(quote: "A foret of Celine and dont forget the cafe rule", pageHint: nil)?.confidence == .exact)
    }

    @Test func hintsDecideBetweenEqualFuzzyAndHeadAndTailMatches() throws {
        let paragraph = ["The estimated elasticity of substitution between domestic and foreign varieties is large in every",
                         "specification we consider, which suggests that consumers switch readily between suppliers."]
        let paper = PaperTextSample.plainPaper([paragraph, ["An unrelated page about something else entirely."], paragraph])
        let matcher = QuoteMatcher(paper: paper)

        let fuzzy = "The estimated elasticity of replacement between domestic and foreign products is large in every specification"
        #expect(matcher.locate(quote: fuzzy, pageHint: nil)?.spans.map(\.pageIndex) == [0, 0])
        #expect(matcher.locate(quote: fuzzy, pageHint: 2)?.spans.map(\.pageIndex) == [2, 2])
        guard case .fuzzy = try #require(matcher.locate(quote: fuzzy, pageHint: 2)).confidence else {
            Issue.record("expected a fuzzy match")
            return
        }

        let elided = "The estimated elasticity of substitution … consumers switch readily between suppliers."
        #expect(matcher.locate(quote: elided, pageHint: nil)?.spans.map(\.pageIndex) == [0, 0])
        #expect(matcher.locate(quote: elided, pageHint: 2)?.spans.map(\.pageIndex) == [2, 2])
        #expect(matcher.locate(quote: elided, pageHint: 2)?.confidence == .fuzzy(score: 0.9))
    }

    @Test func hyphenatedWordsAndGluedLinesAreFoundWhicheverWayTheyAreWritten() throws {
        let (_, matcher) = try matcher("ay_nolinks")
        for quote in ["office-specific identification", "office- specific identi- fication", "officespecific identification",
                      "Herding has been studied extensively", "HerdinghasbeenstudiedextensivelysinceBanerjee"] {
            #expect(matcher.locate(quote: quote, pageHint: nil)?.confidence == .exact, "\(quote)")
        }
    }

    // MARK: - Labels

    private func label(_ name: String, _ quote: String) throws -> String {
        let (_, matcher) = try matcher(name)
        let match = try #require(matcher.locate(quote: quote, pageHint: nil), "\(name): \(quote)")
        return matcher.locationLabel(for: match.spans)
    }

    @Test func labels() throws {
        #expect(try label("ay_nolinks", Self.table2) == "p. 1, lines 13–14")
        #expect(try label("s1_ruler", Self.table2) == "p. 1, lines 47–49")
        #expect(try label("ay_links", Self.table2) == "p. 1")
        #expect(try label("ay_nolinks", "Herding has been studied extensively since Banerjee") == "p. 1, line 9")
        #expect(try label("ay_nolinks", Self.acrossAPage) == "pp. 1–2 (p. 1 line 16 to p. 2 line 17)")
        #expect(try label("s1_ruler", Self.acrossAPage) == "pp. 1–2 (p. 1 line 53 to p. 2 line 8)")
        #expect(try label("ay_round_nolinks", Self.acrossAPage) == "pp. 1–2")
        #expect(try label("ay_nolinks", "Staggered rollout 0.87") == "p. 3")
        #expect(try label("s1_ruler", "Staggered rollout 0.87") == "p. 3, line 12")
    }

    @Test func labelsOfSpansThatDoNotComeFromTheMatcher() throws {
        let (paper, matcher) = try matcher("ay_nolinks")
        #expect(matcher.locationLabel(for: []) == "")
        let table2 = try #require(PaperTextSample.line(paper, page: 0, startingWith: "Table 2 is 0.91"))
        let span = TextSpan(pageIndex: 0, range: table2.contentRange)
        #expect(matcher.locationLabel(for: [span]) == "p. 1, line 14")
        #expect(matcher.locationLabel(for: [TextSpan(pageIndex: 0, range: TextRange(location: table2.contentRange.location, length: 0))])
                    == "p. 1, line 14")
        // Out of order, a page that does not exist, a range on no line.
        let function = try #require(PaperTextSample.line(paper, page: 1, startingWith: "function."))
        #expect(matcher.locationLabel(for: [TextSpan(pageIndex: 1, range: function.contentRange), span])
                    == "pp. 1–2 (p. 1 line 14 to p. 2 line 17)")
        #expect(matcher.locationLabel(for: [TextSpan(pageIndex: 9, range: TextRange(location: 0, length: 4))]) == "p. 10")
        #expect(matcher.locationLabel(for: [TextSpan(pageIndex: 0, range: TextRange(location: 99_999, length: 4))]) == "p. 1")
    }
}
