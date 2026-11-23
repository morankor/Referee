import Foundation
import Testing
import UniformTypeIdentifiers
import RefereeCore
import AppCore
import TestSupport
@testable import RefereeUI

/// What the Report tab says about the report (plan.md sections 6.10 and 9.8), the editor's title rule, and the export
/// file names. None of these opens a panel.
@Suite struct SidebarReportFactsTests {
    typealias Sample = SidebarTestData

    @Test func theApprovedCountGroupsTheReportsCommentsByKind() {
        var comments: [ReviewComment] = []
        comments += (0..<3).map { _ in Sample.comment(status: .approved, kind: .major) }
        comments += (0..<4).map { _ in Sample.comment(status: .approved, kind: .minor) }
        comments.append(Sample.comment(status: .approved, kind: .question))
        comments.append(Sample.comment(status: .approved, kind: .strength, includeInReport: false))   // not in the report
        comments.append(Sample.comment(status: .pending, kind: .major))
        comments.append(Sample.comment(status: .rejected, kind: .minor))
        #expect(SidebarReportFacts.approvedSummary(of: comments) == "8 approved comments (3 major, 4 minor, 1 question)")
    }

    @Test func singularsPluralsAndNone() {
        #expect(SidebarReportFacts.approvedSummary(of: [Sample.comment(status: .approved, kind: .strength)]) == "1 approved comment (1 strength)")
        let two = [Sample.comment(status: .approved, kind: .question), Sample.comment(status: .approved, kind: .question)]
        #expect(SidebarReportFacts.approvedSummary(of: two) == "2 approved comments (2 questions)")
        #expect(SidebarReportFacts.approvedSummary(of: [Sample.comment()]) == "No approved comments yet")
        #expect(SidebarReportFacts.approvedSummary(of: []) == "No approved comments yet")
    }

    /// The summary row breaks between the count and the kinds when it has to (D8).
    @Test func theSummaryInItsTwoParts() {
        let comments = [Sample.comment(status: .approved, kind: .major), Sample.comment(status: .approved, kind: .minor)]
        let parts = SidebarReportFacts.approvedSummaryParts(of: comments)
        #expect(parts.count == "2 approved comments")
        #expect(parts.kinds == "(1 major, 1 minor)")
        #expect(SidebarReportFacts.approvedSummaryParts(of: []).kinds == nil)
    }

    // ---- D8: the style check's titles ----

    @Test func everyRuleOfAppendixB7HasATitle() {
        let titles = ["banned-word": "Machine-sounding word", "check-word": "Word to check", "em-dash": "Em dash",
                      "not-only": "“Not only … but also”", "copula": "“Serves as”", "gerund-tail": "Trailing -ing clause",
                      "third-person": "Third person", "hedge-stack": "Stacked hedge", "flattering-opener": "Opening praise",
                      "optimistic-closer": "Optimistic ending", "template-heading": "Template heading",
                      "missing-section": "Missing section", "opens-with-summary": "Opens with a summary",
                      "recommendation-mismatch": "Recommendation mismatch"]
        for (rule, title) in titles {
            #expect(SidebarReportFacts.ruleTitle(rule) == title, "\(rule)")
        }
        #expect(SidebarReportFacts.ruleTitles.count == titles.count)
        #expect(SidebarReportFacts.ruleTitle("new-rule-id") == "New rule id")
        #expect(SidebarReportFacts.ruleTitle("x") == "X")
    }

    // ---- D33: the journal's two boxes ----

    static func sampleReport() throws -> String {
        try String(contentsOf: Fixtures.url("llm/report_sample.txt"), encoding: .utf8)
    }

    @Test func theAuthorsGetEverySectionButTheRecommendationAndTheProbability() throws {
        let authors = SidebarReportFacts.authorsMarkdown(try Self.sampleReport())
        #expect(authors.hasPrefix("## Summary assessment"))
        for heading in ["## Major concerns", "## Minor concerns", "## Questions for the authors"] {
            #expect(authors.contains(heading), "\(heading)")
        }
        #expect(!authors.contains("## Recommendation"))
        #expect(!authors.contains("## Publication probability"))
        #expect(!authors.contains("Major revision."))
        #expect(!authors.contains("10–20%"))
        #expect(authors.contains("1. Does Proposition 1 require bounded signals?"))
    }

    @Test func theEditorGetsTheAssessmentTheRecommendationAndTheProbability() throws {
        let editor = SidebarReportFacts.editorMarkdown(try Self.sampleReport())
        #expect(editor.hasPrefix("## Summary assessment"))
        #expect(editor.contains("## Recommendation\n\nMajor revision."))
        #expect(editor.contains("## Publication probability\n\n10–20%"))
        #expect(!editor.contains("## Major concerns"))
        #expect(!editor.contains("Questions for the authors"))
    }

    @MainActor @Test func eachBoxIsCopiedAsPlainText() throws {
        let report = try Self.sampleReport()
        let authors = SidebarReportFacts.authorsText(report)
        #expect(authors.hasPrefix("Summary assessment\n\n"))
        #expect(!authors.contains("##"))
        #expect(!authors.contains("Recommendation"))
        let editor = SidebarReportFacts.editorText(report)
        #expect(editor.hasPrefix("Summary assessment\n\n"))
        #expect(editor.contains("Recommendation\n\nMajor revision."))
        #expect(editor.contains("Publication probability"))
        #expect(!editor.contains("Major concerns"))
    }

    /// Headings are found by their text whatever their case, with or without a colon, under a title of a higher level;
    /// text before the first heading goes to the authors only; nothing to copy gives an empty text.
    @Test func headingsAreMatchedByTheirText() {
        let report = """
        Thank you for the opportunity to review.

        # Referee report

        ## SUMMARY ASSESSMENT:

        Sound.

        ## Recommendation

        Minor revision.

        ### Why

        Small fixes.

        ## Comments

        1. A sign.
        """
        let authors = SidebarReportFacts.authorsMarkdown(report)
        #expect(authors.hasPrefix("Thank you for the opportunity to review."))
        #expect(authors.contains("# Referee report"))
        #expect(authors.contains("## SUMMARY ASSESSMENT:"))
        #expect(!authors.contains("Minor revision."))
        #expect(!authors.contains("Small fixes."))                        // a subsection goes with its section
        #expect(authors.contains("1. A sign."))
        let editor = SidebarReportFacts.editorMarkdown(report)
        #expect(editor == "## SUMMARY ASSESSMENT:\n\nSound.\n\n## Recommendation\n\nMinor revision.\n\n### Why\n\nSmall fixes.")
        #expect(SidebarReportFacts.editorMarkdown("No headings at all.") == "")
        #expect(SidebarReportFacts.authorsMarkdown("") == "")
    }

    static let report = """
    ## Summary assessment

    1. Not a concern: this list is under another heading.

    ## Major concerns

    1. The interval includes one.
    2. Rollout timing.
       Continued on a second line.

    ## Minor concerns

    1. A sign.
    """

    @Test func majorConcernsAreTheNumberedItemsUnderTheirHeading() {
        #expect(SidebarReportFacts.majorConcernCount(in: Self.report) == 2)
        #expect(SidebarReportFacts.majorConcernCount(in: "## Major concerns\n\nNone.\n\n## Minor concerns\n\n1. A sign.") == 0)
        #expect(SidebarReportFacts.majorConcernCount(in: "No headings at all.\n1. An item.") == 0)
        #expect(SidebarReportFacts.majorConcernCount(in: "# Report\n## Major concerns\n1. One\n### Detail\n2. Two\n## Minor concerns\n1. x") == 2)
    }

    /// Rule `recommendation-mismatch` of Appendix B.7, for the picker's value.
    @Test func theRecommendationMustMatchTheConcerns() {
        let withMajors = Self.report
        let withoutMajors = "## Major concerns\n\nNone.\n"
        #expect(SidebarReportFacts.recommendationMismatch(.accept, markdown: withMajors))
        #expect(SidebarReportFacts.recommendationMismatch(.minorRevision, markdown: withMajors))
        #expect(!SidebarReportFacts.recommendationMismatch(.majorRevision, markdown: withMajors))
        #expect(!SidebarReportFacts.recommendationMismatch(.reject, markdown: withMajors))
        #expect(SidebarReportFacts.recommendationMismatch(.majorRevision, markdown: withoutMajors))
        #expect(SidebarReportFacts.recommendationMismatch(.reject, markdown: withoutMajors))
        #expect(!SidebarReportFacts.recommendationMismatch(.accept, markdown: withoutMajors))
        #expect(!SidebarReportFacts.recommendationMismatch(nil, markdown: withMajors))
    }

    @Test func recommendationTitles() {
        #expect(Recommendation.allCases.map(SidebarReportFacts.title) == ["Accept", "Minor revision", "Major revision", "Reject"])
    }

    @Test func aFindingShowsTheTextItPointsAt() {
        let markdown = "Major revision. The concerns go to the result — they are not\nmatters of presentation."
        let dash = (markdown as NSString).range(of: "—")
        let finding = LintFinding(id: 1, range: TextRange(dash), rule: "em-dash", message: "Em dash")
        #expect(SidebarReportFacts.excerpt(of: finding, in: markdown) == "—")
        let across = (markdown as NSString).range(of: "not\nmatters")
        #expect(SidebarReportFacts.excerpt(of: LintFinding(id: 2, range: TextRange(across), rule: "r", message: "m"), in: markdown) == "not matters")
        let long = LintFinding(id: 3, range: TextRange(location: 0, length: 60), rule: "r", message: "m")
        #expect(SidebarReportFacts.excerpt(of: long, in: markdown, limit: 10) == "Major rev…")
        let outside = LintFinding(id: 4, range: TextRange(location: 500, length: 3), rule: "r", message: "m")
        #expect(SidebarReportFacts.excerpt(of: outside, in: markdown) == nil)
    }

    @Test func aFindingsRangeIsClampedToTheTextAsItIsNow() {
        let finding = LintFinding(id: 1, range: TextRange(location: 8, length: 10), rule: "r", message: "m")
        #expect(SidebarReportFacts.clampedRange(of: finding, in: "0123456789") == NSRange(location: 8, length: 2))
        #expect(SidebarReportFacts.clampedRange(of: finding, in: "0123") == NSRange(location: 4, length: 0))
        #expect(SidebarReportFacts.clampedRange(of: finding, in: String(repeating: "x", count: 40)) == NSRange(location: 8, length: 10))
    }

    @Test func theReportCommentsAreTheApprovedIncludedOnes() {
        let included = Sample.comment(status: .approved)
        let excluded = Sample.comment(status: .approved, includeInReport: false)
        #expect(SidebarReportFacts.reportComments([included, excluded, Sample.comment()]).map(\.id) == [included.id])
    }

    // ---- editor rules ----

    @Test func aCommentNeedsATitleOrABody() {
        #expect(SidebarEditorRules.canSave(title: "A title", body: ""))
        #expect(SidebarEditorRules.canSave(title: " ", body: "A body"))
        #expect(!SidebarEditorRules.canSave(title: " \n", body: "\n "))
    }

    @Test func anEmptyTitleBecomesTheFirstTenWordsOfTheBody() {
        #expect(SidebarEditorRules.title("  Typed title ", body: "Body") == "Typed title")
        #expect(SidebarEditorRules.title("Two\nlines", body: "Body") == "Two lines")
        #expect(SidebarEditorRules.title("", body: "one two three four five six seven eight nine ten eleven twelve")
                == "one two three four five six seven eight nine ten")
        let long = String(repeating: "x", count: 130)
        #expect(SidebarEditorRules.title("", body: long).count == 120)
    }

    // ---- export ----

    @Test @MainActor func exportFileNamesFollowThePaper() {
        #expect(SidebarReportExport.suggestedFileName(for: .markdown, documentName: "ay_nolinks.pdf") == "ay_nolinks report.md")
        #expect(SidebarReportExport.suggestedFileName(for: .plainText, documentName: "ay_nolinks.pdf") == "ay_nolinks report.txt")
        #expect(SidebarReportExport.suggestedFileName(for: .docx, documentName: nil) == "Referee report.docx")
        #expect(SidebarReportExport.suggestedFileName(for: .pdf, documentName: "paper.v2.pdf") == "paper.v2 report.pdf")
        #expect(SidebarReportExport.contentType(of: .pdf) == .pdf)
        #expect(SidebarReportExport.contentType(of: .markdown).tags[.filenameExtension]?.contains("md") == true)
        #expect(SidebarReportExport.contentType(of: .docx).preferredFilenameExtension == "docx")
    }

    @Test func versionTitlesNameTheNote() {
        let version = ReportVersion(markdown: "x", savedAt: Sample.created, note: "before regenerate")
        #expect(SidebarReportTab.versionTitle(version).hasPrefix("Before regenerate · "))
    }
}
