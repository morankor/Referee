import Foundation
import Testing
@testable import ReviewEngine
import RefereeCore
import TestSupport

/// The style check of Appendix B.7: row "lint" of WP6.
@Suite struct LintTests {
    /// A report that passes every rule; `major` lines become its numbered major concerns.
    static func report(summary: String = "I am not convinced that the main estimate supports the claim in the abstract. The design could work.",
                       recommendation: String = "Major revision. The identifying assumption is not defended.",
                       major: [String] = ["The interval in Table 2 includes one (p. 1)."],
                       minor: [String] = ["The step before Proposition 1 needs the sign of the ratio (p. 2)."],
                       questions: [String] = ["Does Proposition 1 require bounded signals?"],
                       extra: String = "") -> String {
        func list(_ items: [String]) -> String { items.isEmpty ? "None." : items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n") }
        return """
            ## Summary assessment

            \(summary)

            ## Recommendation

            \(recommendation)

            ## Publication probability

            10–20% at a top field journal. The concerns are fundamental.

            ## Major concerns

            \(list(major))

            ## Minor concerns

            \(list(minor))

            ## Questions for the authors

            \(list(questions))
            """ + extra
    }

    private func rules(_ markdown: String) -> [String] { ReportLinter.lint(markdown).map(\.rule) }

    @Test func aCleanReportHasNoFindings() {
        #expect(ReportLinter.lint(Self.report()).isEmpty)
        #expect(ReportLinter.lint(Self.report(recommendation: "Minor revision. The result stands.", major: [])).isEmpty)
    }

    /// One sentence put into a major concern of the clean report.
    @Test(arguments: [
        ("We delve into the data.", ["banned-word"]),
        ("The section is pivotal to the argument.", ["banned-word"]),
        ("The authors utilize a new estimator.", ["banned-word"]),
        ("The authors leveraged a panel.", ["banned-word"]),
        ("Two paradigms collide.", ["banned-word"]),
        ("The result is robust.", ["check-word"]),
        ("The robustness checks in Table 4 are adequate.", []),
        ("The policy landscape changed in 2019.", ["check-word"]),
        ("This holds — mostly.", ["em-dash"]),
        ("This holds - mostly, and the en dash in 10–20 is fine.", []),
        ("The paper not only estimates the effect but also tests it.", ["not-only"]),
        ("Table 2 serves as the main evidence.", ["copula"]),
        ("The estimate is large, highlighting the need for further research.", ["gerund-tail"]),
        ("The estimate is large, underscoring the gap.", ["gerund-tail", "banned-word"]),    // the clause starts at its comma
        ("This reviewer is not convinced.", ["third-person"]),
        ("The reviewer believes the sample is small.", ["third-person"]),
        ("It should be noted that the sample is small.", ["third-person"]),
        ("The result could potentially be driven by selection.", ["hedge-stack"]),
        ("It could be argued that the instrument is weak.", ["hedge-stack"]),
        ("The instrument may be weak.", []),
        ("The sample is small and the design is clear.", []),
    ] as [(String, [String])])
    func sentences(_ sentence: String, _ expected: [String]) {
        let markdown = Self.report(major: [sentence])
        let findings = ReportLinter.lint(markdown)
        #expect(findings.map(\.rule) == expected)
        // Each finding points at the words it is about.
        let text = markdown as NSString
        for finding in findings where finding.rule != "gerund-tail" && finding.rule != "not-only" {
            let flagged = text.substring(with: finding.range.nsRange).lowercased()
            #expect(sentence.lowercased().contains(flagged), "\(finding.rule) flagged \(flagged)")
        }
    }

    @Test func theSampleReportHasItsThreeDeliberateHits() throws {
        let markdown = try Fixtures.text("llm/report_sample.txt")
        let findings = ReportLinter.lint(markdown)
        #expect(findings.map(\.rule) == ["em-dash", "check-word", "copula"])
        let text = markdown as NSString
        #expect(findings.map { text.substring(with: $0.range.nsRange) } == ["—", "robust", "serves as"])
        #expect(findings.map(\.id) == [0, 1, 2])
        #expect(findings[0].message == "Em dash: use a comma, parentheses or a new sentence.")
        #expect(findings[1].message == "Keep 'robust' only in its literal sense (for 'robust': a named robustness check).")
        #expect(findings[2].message == "Write 'is'.")
    }

    @Test func structuralRules() {
        #expect(rules(Self.report(summary: "This is an interesting paper on herding. I am not convinced by its main estimate.")) == ["flattering-opener"])
        #expect(rules(Self.report(summary: "The paper is well-written but the estimate does not support the claim.")) == ["flattering-opener"])
        #expect(rules(Self.report(extra: "\n\nThe approach is promising and I look forward to the revision.")) == ["optimistic-closer"])
        #expect(rules(Self.report(extra: "\n\n## Strengths and Weaknesses\n\nThe data are new.")) == ["template-heading"])

        let missing = Self.report().replacingOccurrences(of: "## Minor concerns", with: "")
        let findings = ReportLinter.lint(missing)
        #expect(findings.map(\.rule) == ["missing-section"])
        #expect(findings.first?.message == "Section 'Minor concerns' is missing.")

        let longSummary = "This paper investigates herding in markets. It uses a rollout. It reports an interval. It calls the effect large. "
            + "It concludes that disclosure helps."
        #expect(rules(Self.report(summary: longSummary)) == ["opens-with-summary"])
        #expect(rules(Self.report(summary: "This paper investigates herding in markets. I do not think the estimate supports it.")) == [])
    }

    @Test func recommendationAgainstMajorConcerns() {
        // Accept or minor revision with a major concern listed, or reject or major revision with none: a mismatch.
        #expect(rules(Self.report(recommendation: "Accept. Only small fixes are needed.")) == ["recommendation-mismatch"])
        #expect(rules(Self.report(recommendation: "Minor revision. Small fixes.")) == ["recommendation-mismatch"])
        #expect(rules(Self.report(recommendation: "Reject. The design fails.", major: [])) == ["recommendation-mismatch"])
        #expect(rules(Self.report(recommendation: "Major revision. Much to do.", major: [])) == ["recommendation-mismatch"])
        #expect(rules(Self.report(recommendation: "Reject. The design fails.")) == [])
        #expect(rules(Self.report(recommendation: "Accept. Only small fixes are needed.", major: [])) == [])
        // The finding covers the recommendation's text.
        let markdown = Self.report(recommendation: "Accept. Only small fixes are needed.")
        let finding = ReportLinter.lint(markdown).first
        #expect(finding.map { (markdown as NSString).substring(with: $0.range.nsRange) } == "Accept. Only small fixes are needed.")
    }

    @Test func theEngineLintsWithTheSameRules() async throws {
        let engine = EngineTest.engine([], paper: try makeSamplePaper())
        let markdown = try Fixtures.text("llm/report_sample.txt")
        #expect(engine.lint(reportMarkdown: markdown) == ReportLinter.lint(markdown))
        #expect(engine.lint(reportMarkdown: "").map(\.rule) == Array(repeating: "missing-section", count: 6))
    }
}
