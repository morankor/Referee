import Foundation
import Testing
import RefereeCore
@testable import AppCore
import TestSupport

/// The scripted engine, except that `lint` reads the text: one finding per em dash, its range that of the dash. The
/// scripted engine returns the same findings whatever it is given, so a test could not see which text was linted.
final class TextLintEngine: ReviewEngineProtocol, @unchecked Sendable {
    private let base: ScriptedReviewEngine
    private let lock = NSLock()
    private var texts: [String] = []

    init(_ base: ScriptedReviewEngine) { self.base = base }

    var lintedTexts: [String] { lock.withLock { texts } }

    func plan(paper: LoadedPaper, context: EngineContext) async -> SendPlan { await base.plan(paper: paper, context: context) }
    func review(paper: LoadedPaper, existing: [ReviewComment], context: EngineContext) -> AsyncThrowingStream<ReviewEvent, Error> {
        base.review(paper: paper, existing: existing, context: context)
    }
    func discuss(paper: LoadedPaper, comment: ReviewComment, message: String, context: EngineContext) -> AsyncThrowingStream<ReplyEvent, Error> {
        base.discuss(paper: paper, comment: comment, message: message, context: context)
    }
    func ask(paper: LoadedPaper, conversation: Conversation, question: String, context: EngineContext) -> AsyncThrowingStream<ReplyEvent, Error> {
        base.ask(paper: paper, conversation: conversation, question: question, context: context)
    }
    func generateReport(paper: LoadedPaper, session: ReviewSession, context: EngineContext) -> AsyncThrowingStream<ReportEvent, Error> {
        base.generateReport(paper: paper, session: session, context: context)
    }
    func reviseVoice(draft: ReportDraft, findings: [LintFinding], context: EngineContext) -> AsyncThrowingStream<ReportEvent, Error> {
        base.reviseVoice(draft: draft, findings: findings, context: context)
    }
    func lint(reportMarkdown: String) -> [LintFinding] {
        lock.withLock { texts.append(reportMarkdown) }
        let string = reportMarkdown as NSString
        var findings: [LintFinding] = []
        var searchFrom = 0
        while searchFrom < string.length {
            let found = string.range(of: "\u{2014}", range: NSRange(location: searchFrom, length: string.length - searchFrom))
            if found.location == NSNotFound { break }
            findings.append(LintFinding(id: findings.count, range: RefereeCore.TextRange(found), rule: "em-dash", message: "An em dash."))
            searchFrom = found.upperBound
        }
        return findings
    }
}

/// Acceptance row "report" (plan.md section 11.4, WP8b; sections 6.10 and 9.8).
@Suite struct ReviewSessionModelReportTests {
    static let firstReport = "## Summary assessment\n\nThe paper overstates its result \u{2014} the interval includes one.\n\n## Recommendation\n\nMajor revision.\n"
    static let draft = ReportDraft(markdown: firstReport, recommendation: .majorRevision, generatedAt: ModelSample.start,
                                   provider: ProviderRef(providerID: "mock", model: "mock"), userEdited: false)

    static func events(_ draft: ReportDraft, _ status: RunStatus = .completed) -> [ReportEvent] {
        [.started(ModelSample.run(.report, .running)), .textDelta("## Summary assessment\n"), .textDelta("…"), .finished(draft, run: ModelSample.run(.report, status))]
    }

    @MainActor static func harness(comments: [ReviewComment] = [ModelSample.comment("Approved", page: nil, status: .approved)],
                                   report: [ReportEvent] = events(draft), existing: ReportDraft? = nil) async throws -> (ModelHarness, TextLintEngine) {
        let paper = try makeSamplePaper()
        var lintEngine: TextLintEngine?
        let harness = try await makeModelHarness(paper: paper, engine: ScriptedReviewEngine(plan: ModelSample.localPlan, report: report),
                                                 wrap: { scripted in
                                                     let wrapped = TextLintEngine(scripted)
                                                     lintEngine = wrapped
                                                     return wrapped
                                                 },
                                                 seed: ModelSample.session(for: paper, comments: comments, report: existing))
        await harness.open()
        return (harness, try #require(lintEngine))
    }

    @Test @MainActor func generatingGivesTheDraftItsRecommendationAndLintFindings() async throws {
        let (harness, lint) = try await Self.harness()
        let model = harness.model
        #expect(model.session?.report == nil)
        model.generateReport()
        if case .running(kind: .report, _, _) = model.runState {} else { Issue.record("the report is not running: \(model.runState)") }
        await harness.finishJobs()
        let report = try #require(model.session?.report)
        #expect(report.markdown == Self.firstReport)
        #expect(report.recommendation == .majorRevision)
        #expect(report.userEdited == false)
        #expect(report.versions.isEmpty)
        #expect(report.provider == ProviderRef(providerID: "mock", model: "mock"))
        #expect(model.lintFindings.map(\.rule) == ["em-dash"])
        #expect(lint.lintedTexts.last == Self.firstReport)
        #expect(model.session?.runs.last?.kind == .report)
        #expect(model.runState == .idle)
        #expect(model.streamingReportText == "")
    }

    @Test @MainActor func withoutAnApprovedCommentTheReportDoesNotRun() async throws {
        let (harness, _) = try await Self.harness(comments: [ModelSample.comment("Pending", page: nil),
                                                             ModelSample.comment("Approved but left out", page: nil, status: .approved, includeInReport: false)])
        harness.model.generateReport()
        await harness.finishJobs()
        #expect(harness.calls(of: "report") == 0)
        #expect(harness.model.session?.report == nil)
        #expect(harness.model.banner?.message == "Approve at least one comment first.")
    }

    @Test @MainActor func anEditMarksTheDraftAndIsLintedAgainAfterHalfASecond() async throws {
        let (harness, lint) = try await Self.harness()
        let model = harness.model
        model.generateReport()
        await harness.finishJobs()
        let linted = lint.lintedTexts.count

        let edited = "## Summary assessment\n\nTwo dashes \u{2014} here \u{2014} and here.\n"
        model.updateReportMarkdown("## Summary assessment\n\nA first edit.\n")
        model.updateReportMarkdown(edited)
        #expect(model.session?.report?.markdown == edited)
        #expect(model.session?.report?.userEdited == true)
        #expect(model.lintFindings.count == 1)                           // not yet: the lint waits for the typing to stop
        harness.clock.advance(by: 0.3)
        await Task.yield()
        #expect(lint.lintedTexts.count == linted)
        harness.clock.advance(by: 0.3)
        await model.lintTask?.value
        #expect(lint.lintedTexts.count == linted + 1)                    // two edits within 0.5 s: one lint, of the last text
        #expect(lint.lintedTexts.last == edited)
        #expect(model.lintFindings.count == 2)
        #expect(model.session?.report?.recommendation == .majorRevision)
    }

    @Test @MainActor func regeneratingPushesTheOldDraftAndARestoreBringsItBack() async throws {
        let (harness, _) = try await Self.harness()
        let model = harness.model
        model.generateReport()
        await harness.finishJobs()
        model.updateReportMarkdown("My own words.")
        model.setRecommendation(.reject)
        #expect(model.session?.report?.recommendation == .reject)

        model.generateReport()
        await harness.finishJobs()
        let regenerated = try #require(model.session?.report)
        #expect(regenerated.markdown == Self.firstReport)
        #expect(regenerated.userEdited == false)
        #expect(regenerated.versions.map(\.markdown) == ["My own words."])
        #expect(regenerated.versions.first?.note == "before regenerate")

        model.restoreReportVersion(at: 0)
        let restored = try #require(model.session?.report)
        #expect(restored.markdown == "My own words.")
        #expect(restored.userEdited)
        #expect(restored.versions.map(\.markdown) == ["My own words.", Self.firstReport])
        #expect(restored.versions.last?.note == "before restore")
        #expect(model.lintFindings.isEmpty)                              // linted at once: the restored text has no dash
        model.restoreReportVersion(at: 7)                                // no such version: nothing happens
        #expect(model.session?.report == restored)
    }

    @Test @MainActor func atMostTenVersionsAreKept() async throws {
        let (harness, _) = try await Self.harness()
        let model = harness.model
        for number in 1...12 {
            model.updateReportMarkdown("Draft \(number)")
            model.generateReport()
            await harness.finishJobs()
        }
        let versions = try #require(model.session?.report?.versions)
        #expect(versions.count == 10)
        #expect(versions.last?.markdown == "Draft 12")
        #expect(versions.first?.markdown == "Draft 3")
    }

    @Test @MainActor func aVoiceRevisionReplacesTheTextAndKeepsTheOldOne() async throws {
        let revised = ReportDraft(markdown: "## Summary assessment\n\nThe interval includes one.\n", userEdited: false)
        let existing = ReportDraft(markdown: Self.firstReport, recommendation: .majorRevision, generatedAt: ModelSample.start,
                                   basedOnCommentIDs: [UUID()], userEdited: true)
        let (harness, _) = try await Self.harness(report: Self.events(revised), existing: existing)
        let model = harness.model
        #expect(model.lintFindings.count == 1)                           // a stored report is linted when it opens
        model.reviseReportVoice()
        await harness.finishJobs()
        #expect(harness.calls(of: "revise") == 1)
        let report = try #require(model.session?.report)
        #expect(report.markdown == revised.markdown)
        #expect(report.recommendation == .majorRevision)                 // kept: the revision names none
        #expect(report.basedOnCommentIDs == existing.basedOnCommentIDs)
        #expect(report.versions.map(\.markdown) == [Self.firstReport])
        #expect(report.versions.first?.note == "before voice revision")
        #expect(model.lintFindings.isEmpty)
        #expect(model.session?.runs.last?.kind == .report)                // as the scripted engine recorded it
    }

    @Test @MainActor func aFailedReportKeepsThePreviousDraftAndOffersRetry() async throws {
        let existing = ReportDraft(markdown: "The earlier draft.", userEdited: true)
        let (harness, _) = try await Self.harness(report: Self.events(Self.draft, .failed("The provider is overloaded.")), existing: existing)
        let model = harness.model
        model.generateReport()
        await harness.finishJobs()
        #expect(model.session?.report == existing)
        #expect(model.banner?.message == "Report stopped: The provider is overloaded.")
        #expect(model.banner?.action == .retry)
        #expect(model.session?.runs.last?.status == .failed("The provider is overloaded."))
        model.retryLastFailedJob()
        await harness.finishJobs()
        #expect(harness.calls(of: "report") == 2)
    }

    @Test @MainActor func theRecommendationIsReadFromItsSection() {
        #expect(ModelSupport.recommendation(in: "## Recommendation\n\nMinor revision, with a short list of fixes.\n\n## Major concerns\n\nI reject X.") == .minorRevision)
        #expect(ModelSupport.recommendation(in: "## Recommendation\nReject. I cannot accept the main claim.") == .reject)
        #expect(ModelSupport.recommendation(in: "## Recommendation\n\nAccept with minor revisions.") == .accept)
        #expect(ModelSupport.recommendation(in: "### Recommendation\n\nmajor revision") == .majorRevision)
        #expect(ModelSupport.recommendation(in: "## Summary assessment\n\nReject.") == nil)
    }
}
