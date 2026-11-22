import Foundation
import Testing
import UniformTypeIdentifiers
import RefereeCore
import AppCore
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
