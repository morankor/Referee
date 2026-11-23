import Foundation
import Testing
import RefereeCore
@testable import AppCore
import TestSupport

/// The scripted engine, recording the venue of every style check (the scripted engine's own `lint` ignores it).
final class VenueRecordingEngine: ReviewEngineProtocol, @unchecked Sendable {
    private let base: ScriptedReviewEngine
    private let lock = NSLock()
    private var venues: [VenueProfile] = []

    init(_ base: ScriptedReviewEngine) { self.base = base }

    var lintVenues: [VenueProfile] { lock.withLock { venues } }

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
    func lint(reportMarkdown: String) -> [LintFinding] { base.lint(reportMarkdown: reportMarkdown) }
    func lint(reportMarkdown: String, venue: VenueProfile) -> [LintFinding] {
        lock.withLock { venues.append(venue) }
        return base.lint(reportMarkdown: reportMarkdown)
    }
}

/// The paper's venue (plan.md Appendix G.9): `venues`, `currentVenue`, `setVenue(id:)`, the engine context, and the
/// recommendation on the venue's scale.
@Suite struct ReviewSessionModelVenueTests {
    static let defaults = DefaultSettings.make()
    static var jet: VenueProfile { defaults.venue(id: "jet") }
    static var ec: VenueProfile { defaults.venue(id: "ec") }

    static let conferenceText = "## Summary assessment\n\nNew, but the proof has a gap.\n\n## Recommendation\n\nWeak accept. The gap can be closed.\n"

    @MainActor static func harness(settings: AppSettings = ModelSample.settings(), meta: ManuscriptMeta? = nil, comments: [ReviewComment] = [],
                                   conversations: [Conversation] = [], report: ReportDraft? = nil, reportEvents: [ReportEvent] = [])
        async throws -> (ModelHarness, VenueRecordingEngine) {
        let paper = try makeSamplePaper()
        var seed: ReviewSession?
        if let meta {
            var session = ModelSample.session(for: paper, comments: comments, conversations: conversations, report: report)
            session.meta = meta
            seed = session
        }
        var recorder: VenueRecordingEngine?
        let harness = try await makeModelHarness(paper: paper, settings: settings,
                                                 engine: ScriptedReviewEngine(plan: ModelSample.localPlan, report: reportEvents),
                                                 wrap: { scripted in
                                                     let wrapped = VenueRecordingEngine(scripted)
                                                     recorder = wrapped
                                                     return wrapped
                                                 }, seed: seed)
        await harness.open()
        return (harness, try #require(recorder))
    }

    @Test @MainActor func aNewPaperGetsTheDefaultVenueOfTheSettings() async throws {
        let (plain, _) = try await Self.harness()
        let meta = try #require(plain.model.session?.meta)
        #expect(meta.venueID == VenueProfile.journalID)
        #expect(meta.targetVenue == nil)
        #expect(plain.model.currentVenue == .unspecifiedJournal)
        #expect(plain.model.venues == DefaultSettings.venues)
        #expect(plain.model.recommendationScale == ["Accept", "Minor revision", "Major revision", "Reject"])

        let (chosen, _) = try await Self.harness(settings: ModelSample.settings { $0.defaultVenueID = "jet" })
        #expect(chosen.model.session?.meta.venueID == "jet")
        #expect(chosen.model.session?.meta.targetVenue == "Journal of Economic Theory (JET)")
        #expect(chosen.model.currentVenue == Self.jet)
    }

    @Test @MainActor func aSessionSavedBeforeVenuesOpensOnJournalUnspecifiedAndKeepsItsText() async throws {
        let old = ManuscriptMeta(title: "A stored review", targetVenue: "Journal of Examples", reviewerNotes: "Be brief.")   // no venue id
        let (harness, _) = try await Self.harness(meta: old)
        #expect(harness.model.currentVenue == .unspecifiedJournal)
        #expect(harness.model.session?.meta == old)                          // opening changes nothing in it
        harness.model.setVenue(id: VenueProfile.journalID)                    // the venue it is already on: nothing happens
        #expect(harness.model.session?.meta == old)
        harness.model.startReview()
        await harness.finishJobs()
        let context = try #require(harness.lastContext(of: "review"))
        #expect(context.venue == .unspecifiedJournal)
        #expect(context.meta.targetVenue == "Journal of Examples")             // still named in the prompts, as before
    }

    @Test @MainActor func settingTheVenueSavesRefreshesThePlanAndKeepsEveryComment() async throws {
        let comments = [ModelSample.comment("Pending", page: nil), ModelSample.comment("Approved", page: 0, status: .approved),
                        ModelSample.comment("Rejected", page: nil, status: .rejected), ModelSample.comment("Own", page: nil, origin: .user)]
        let conversation = Conversation(id: UUID(), messages: [ThreadMessage(id: UUID(), role: .user, text: "Why?", createdAt: ModelSample.start)],
                                        createdAt: ModelSample.start)
        let report = ReportDraft(markdown: Self.conferenceText, recommendation: .minorRevision, userEdited: true)
        let (harness, recorder) = try await Self.harness(meta: ManuscriptMeta(title: "T", reviewerNotes: "", venueID: "journal"), comments: comments,
                                                         conversations: [conversation], report: report)
        let model = harness.model
        let before = try #require(model.session)
        let saves = harness.store.saveCount
        let plans = harness.calls(of: "plan")

        model.setVenue(id: "ec")
        await model.waitForBackgroundWork()
        let after = try #require(model.session)
        #expect(after.meta.venueID == "ec")
        #expect(after.meta.targetVenue == "ACM Conference on Economics and Computation (EC)")
        #expect(after.meta.title == before.meta.title)
        #expect(after.comments == before.comments)                            // every comment, as it was
        #expect(after.conversations == before.conversations)
        #expect(after.report == before.report)                               // the report and its recommendation too
        #expect(model.currentVenue == Self.ec)
        #expect(harness.store.saveCount == saves + 1)                        // saved at once, not after the autosave delay
        let stored = try await harness.store.loadSession(sha256: harness.paper.ref.sha256)
        #expect(stored?.meta.venueID == "ec")
        #expect(stored?.comments == before.comments)
        #expect(harness.calls(of: "plan") == plans + 1)                       // the plan is computed again, for the new context
        #expect(harness.lastContext(of: "plan")?.venue == Self.ec)
        #expect(recorder.lintVenues.last == Self.ec)                          // and the report checked for the new venue
        #expect(model.recommendationScale == DefaultSettings.conferenceScale)

        model.setVenue(id: "ec")                                              // the same venue again: nothing
        model.setVenue(id: "no-such-venue")                                   // an unknown id: nothing
        await model.waitForBackgroundWork()
        #expect(harness.store.saveCount == saves + 1)
        #expect(harness.calls(of: "plan") == plans + 1)
        #expect(model.session?.meta.venueID == "ec")

        model.setVenue(id: VenueProfile.journalID)                            // an unspecified venue names nothing
        await model.waitForBackgroundWork()
        #expect(model.session?.meta.venueID == VenueProfile.journalID)
        #expect(model.session?.meta.targetVenue == nil)
        #expect(model.session?.comments == before.comments)
    }

    @Test @MainActor func theEngineContextOfEveryJobCarriesTheVenue() async throws {
        let comment = ModelSample.comment("Approved", page: nil, status: .approved)
        let (harness, _) = try await Self.harness(meta: ManuscriptMeta(reviewerNotes: ""), comments: [comment])
        let model = harness.model
        #expect(harness.lastContext(of: "plan")?.venue == .unspecifiedJournal)
        model.setVenue(id: "jet")
        await model.waitForBackgroundWork()
        model.startReview()
        await harness.finishJobs()
        model.sendDiscussionMessage("Is this fair?", commentID: comment.id)
        await harness.finishJobs()
        model.ask("What is the main claim?", about: nil, in: nil)
        await harness.finishJobs()
        model.generateReport()
        await harness.finishJobs()
        for call in ["plan", "review", "discuss", "ask", "report"] {
            #expect(harness.lastContext(of: call)?.venue == Self.jet, "\(call)")
            #expect(harness.lastContext(of: call)?.meta.venueID == "jet", "\(call)")
        }
    }

    @Test @MainActor func theVenueFollowsTheSettingsAndADeletedOneFallsBackToJournalUnspecified() async throws {
        let wine = VenueProfile(id: "wine", shortName: "WINE", fullName: "Web and Internet Economics", kind: .conference, guidance: "Weigh it.")
        var settings = ModelSample.settings()
        settings.venues.append(wine)
        let (harness, _) = try await Self.harness(settings: settings, meta: ManuscriptMeta(reviewerNotes: ""))
        let model = harness.model
        model.setVenue(id: "wine")
        #expect(model.currentVenue == wine)
        #expect(model.venues.map(\.id) == ["journal", "conference", "jet", "ec", "wine"])

        var edited = settings
        edited.venues[4].guidance = "Weigh it twice."
        model.reloadSettings(edited)
        #expect(model.currentVenue.guidance == "Weigh it twice.")
        model.startReview()
        await harness.finishJobs()
        #expect(harness.lastContext(of: "review")?.venue.guidance == "Weigh it twice.")

        var deleted = edited
        deleted.venues.removeAll { $0.id == "wine" }
        model.reloadSettings(deleted)
        #expect(model.currentVenue == .unspecifiedJournal)
        #expect(model.session?.meta.venueID == "wine")                        // the paper keeps its choice; the settings decide what it means
        #expect(model.session?.meta.targetVenue == "Web and Internet Economics (WINE)")
    }

    @Test @MainActor func withoutAPaperTheVenueIsTheDefaultAndCannotBeSet() async throws {
        let paper = try makeSamplePaper()
        let harness = try await makeModelHarness(paper: paper, settings: ModelSample.settings { $0.defaultVenueID = "ec" })
        #expect(harness.model.currentVenue == Self.ec)
        harness.model.setVenue(id: "jet")
        #expect(harness.model.session == nil)
        #expect(harness.model.currentVenue == Self.ec)
        #expect(harness.model.recommendationLabel == nil)
    }

    // ---- the recommendation on the venue's scale ----

    static func reportEvents(_ draft: ReportDraft) -> [ReportEvent] {
        [.started(ModelSample.run(.report, .running)), .textDelta(draft.markdown), .finished(draft, run: ModelSample.run(.report, .completed))]
    }

    @Test @MainActor func aConferenceReportTakesALabelOfTheScaleAndNoRecommendation() async throws {
        // The scripted engine hands over a draft with a journal's recommendation and no label: the model reads the label
        // from the text for a conference, and drops the journal recommendation.
        let draft = ReportDraft(markdown: Self.conferenceText, recommendation: .majorRevision, userEdited: false)
        let (harness, recorder) = try await Self.harness(meta: ManuscriptMeta(reviewerNotes: "", venueID: "ec"),
                                                         comments: [ModelSample.comment("Approved", page: nil, status: .approved)],
                                                         reportEvents: Self.reportEvents(draft))
        let model = harness.model
        model.generateReport()
        await harness.finishJobs()
        let report = try #require(model.session?.report)
        #expect(report.recommendation == nil)
        #expect(report.recommendationLabel == "Weak accept")
        #expect(model.recommendationLabel == "Weak accept")
        #expect(recorder.lintVenues.last == Self.ec)
        #expect(harness.lastContext(of: "report")?.venue == Self.ec)

        model.setRecommendation(label: "borderline")                         // the scale's spelling is kept
        #expect(model.session?.report?.recommendationLabel == "Borderline")
        model.setRecommendation(label: "Major revision")                     // not on the scale: nothing
        #expect(model.recommendationLabel == "Borderline")
        model.setRecommendation(label: nil)
        #expect(model.session?.report?.recommendationLabel == nil)
        #expect(model.recommendationLabel == nil)

        // A restored version is read on the venue's scale.
        model.updateReportMarkdown("## Recommendation\n\nWeak reject. The gap is real.\n")
        model.generateReport()
        await harness.finishJobs()
        let versions = try #require(model.session?.report?.versions)
        model.restoreReportVersion(at: versions.count - 1)
        #expect(model.session?.report?.recommendationLabel == "Weak reject")
        #expect(model.session?.report?.recommendation == nil)
    }

    @Test @MainActor func aJournalKeepsItsRecommendationAndTheLabelAPIMapsOntoIt() async throws {
        let draft = ReportDraft(markdown: "## Recommendation\n\nMajor revision.\n", userEdited: false)     // no recommendation given
        let (harness, _) = try await Self.harness(meta: ManuscriptMeta(reviewerNotes: "", venueID: "jet"),
                                                  comments: [ModelSample.comment("Approved", page: nil, status: .approved)],
                                                  reportEvents: Self.reportEvents(draft))
        let model = harness.model
        model.generateReport()
        await harness.finishJobs()
        #expect(model.session?.report?.recommendation == .majorRevision)    // read from the text, as before
        #expect(model.session?.report?.recommendationLabel == nil)
        #expect(model.recommendationLabel == "Major revision")
        model.setRecommendation(label: "minor REVISION")
        #expect(model.session?.report?.recommendation == .minorRevision)
        #expect(model.recommendationLabel == "Minor revision")
        model.setRecommendation(label: "Weak accept")                        // a conference's label: nothing
        #expect(model.session?.report?.recommendation == .minorRevision)

        // On a conference the journal recommendation is not a label of the scale, and the report is left as it is.
        model.setVenue(id: "ec")
        #expect(model.session?.report?.recommendation == .minorRevision)
        #expect(model.recommendationLabel == nil)
    }
}
