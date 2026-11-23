import Foundation
import Testing
import RefereeCore
@testable import AppCore
import TestSupport

/// Step 5c (the Sidebar's contract problem 2): a run is in `session.runs` from the moment it starts, with its own provider
/// and model, so that the comments of a review under way are attributed to that run and not to whatever the document's
/// provider is meanwhile; when the run ends its record is replaced by how it ended. A session saved while a run was under
/// way still loads, and the run left `running` is marked failed when the document is opened again.
@Suite struct ReviewSessionModelRunRecordTests {
    static let first = ProviderRef(providerID: "mock", model: "model-x")
    static let other = ProviderRef(providerID: "mock-remote", model: "model-y")

    /// One comment per review, attributed to the run the engine made for the call.
    static let oneComment: StagedReviewEngine.Script = { call, _, _, run in
        [ModelSample.comment("Comment \(call + 1)", page: nil, origin: .ai(runID: run.id), created: Double(call) * 600 + 10)]
    }

    @Test @MainActor func aReviewUnderWayIsRecordedWithItsOwnProviderAndKeepsIt() async throws {
        let gate = ModelTestGate()
        let staged = StagedReviewEngine(scripted: ScriptedReviewEngine(plan: ModelSample.localPlan), gates: [0: gate], script: Self.oneComment)
        let settings = ModelSample.settings { $0.privacy.confirmFirstSendPerDocument = false }
        let harness = try await makeModelHarness(settings: settings, wrap: { _ in staged })
        await harness.open()
        harness.model.setActiveProvider(Self.first)
        harness.model.startReview()
        #expect(await waitForModel { harness.model.session?.comments.count == 1 })

        // Under way: the run is recorded, running, with the provider and model it was started with.
        let running = try #require(harness.model.session?.runs.first)
        #expect(harness.model.session?.runs.count == 1)
        #expect(running.status == .running)
        #expect(running.provider == Self.first)
        #expect(running.finishedAt == nil)
        let comment = try #require(harness.model.session?.comments.first)
        #expect(comment.origin == .ai(runID: running.id))

        // The document is moved to another provider while the review runs: the run, and so its comments, keep theirs.
        harness.model.setActiveProvider(Self.other)
        #expect(harness.model.activeProvider?.id == "mock-remote")
        #expect(harness.model.session?.runs.first(where: { $0.id == running.id })?.provider == Self.first)

        gate.open()
        await harness.finishJobs()
        // Ended: one record, the same run, replaced by how it ended.
        let runs = harness.model.session?.runs ?? []
        #expect(runs.count == 1)
        #expect(runs.first?.id == running.id)
        #expect(runs.first?.status == .completed)
        #expect(runs.first?.finishedAt != nil)
        #expect(runs.first?.provider == Self.first)
        #expect(staged.reviewCalls.first?.context.provider == Self.first)
    }

    /// The app quits while a review runs: what was saved last holds the run as `running`. That session loads, its
    /// comments and the run are there, and the run is marked failed ("The app quit before this run ended."), once.
    @Test @MainActor func aSessionSavedWhileARunWasUnderWayStillOpens() async throws {
        let gate = ModelTestGate()
        let staged = StagedReviewEngine(scripted: ScriptedReviewEngine(plan: ModelSample.localPlan), gates: [0: gate], script: Self.oneComment)
        let settings = ModelSample.settings { $0.privacy.confirmFirstSendPerDocument = false }
        let harness = try await makeModelHarness(settings: settings, wrap: { _ in staged })
        await harness.open()
        harness.model.startReview()
        #expect(await waitForModel { harness.model.session?.comments.count == 1 })

        // The autosave, one second after the last change, writes the session with its run under way.
        let saves = harness.store.saveCount
        harness.clock.advance(by: ReviewSessionModel.autosaveDelay + 0.1)
        #expect(await waitForModel { harness.store.saveCount > saves })
        let saved = try #require(try await harness.store.loadSession(sha256: harness.paper.ref.sha256))
        #expect(saved.runs.count == 1)
        #expect(saved.runs.first?.status == .running)
        #expect(saved.comments.count == 1)

        // "Relaunch": a new window on what was saved, while nothing runs.
        let relaunched = try await makeModelHarness(paper: harness.paper, settings: settings, seed: saved)
        await relaunched.open()
        let session = try #require(relaunched.model.session)
        #expect(session.comments.map(\.id) == saved.comments.map(\.id))
        #expect(session.runs.map(\.id) == saved.runs.map(\.id))
        #expect(session.runs.first?.status == .failed("The app quit before this run ended."))
        #expect(session.runs.first?.provider == saved.runs.first?.provider)
        #expect(relaunched.model.runState == .idle)

        gate.open()
        await harness.finishJobs()
        #expect(harness.model.session?.runs.first?.status == .completed)
    }

    /// A reply and a report are recorded at their start too, and their record is replaced when they end.
    @Test @MainActor func everyKindOfRunIsRecordedOnceFromItsStart() async throws {
        let reply = ThreadMessage(id: UUID(), role: .assistant, text: "An answer.", createdAt: ModelSample.start)
        let draft = ReportDraft(markdown: "## Summary assessment\n\nA report.\n", generatedAt: ModelSample.start, userEdited: false)
        let questionRun = ModelSample.run(.question, .running)
        var questionDone = questionRun
        questionDone.status = .completed
        let reportRun = ModelSample.run(.report, .running)
        let engine = ScriptedReviewEngine(plan: ModelSample.localPlan,
                                          reply: [.started(questionRun), .textDelta("An answer."),
                                                  .finished(reply: reply, proposal: nil, run: questionDone)],
                                          report: [.started(reportRun), .textDelta("## Summary assessment"),
                                                   .finished(draft, run: ModelSample.run(.report, .completed))])
        let comment = ModelSample.comment("Approved", page: nil, status: .approved)
        let settings = ModelSample.settings { $0.privacy.confirmFirstSendPerDocument = false }
        let paper = try makeSamplePaper()
        let harness = try await makeModelHarness(paper: paper, settings: settings, engine: engine,
                                                 seed: ModelSample.session(for: paper, comments: [comment]))
        await harness.open()
        harness.model.ask("What does the paper claim?", about: nil, in: nil)
        await harness.finishJobs()
        harness.model.generateReport()
        await harness.finishJobs()
        let runs = harness.model.session?.runs ?? []
        // The question's start and end share an id; the scripted report's do not, and still give one record.
        #expect(runs.map(\.kind) == [.question, .report])
        #expect(runs.allSatisfy { $0.status == .completed })
        #expect(runs.first?.id == questionRun.id)
    }
}
