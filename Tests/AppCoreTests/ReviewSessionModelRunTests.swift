import Foundation
import Testing
import RefereeCore
@testable import AppCore
import TestSupport

/// Acceptance rows "review flow" and "lanes" (plan.md section 11.4, WP8b; sections 2.3 and 6.6).
@Suite struct ReviewSessionModelRunTests {
    static func draft(_ id: UUID, title: String?, body: String = "") -> DraftComment {
        DraftComment(id: id, kind: .major, category: "claims", page: 1, quote: "a quote", title: title, body: body)
    }

    // ---- review flow ----

    @Test @MainActor func draftsAppearAreUpdatedAndAreReplacedByTheirComments() async throws {
        let harness = try await makeHarness()
        await harness.open()
        let model = harness.model
        let first = UUID()
        let second = UUID()
        var progress = RunProgress(startedAt: Sample.start)
        model.applyReviewEvent(.draft(Self.draft(first, title: nil)), to: &progress)
        #expect(model.drafts.map(\.id) == [first])
        model.applyReviewEvent(.draft(Self.draft(first, title: "Growing", body: "More text")), to: &progress)
        #expect(model.drafts.count == 1)                                 // updated in place, by id
        #expect(model.drafts.first?.title == "Growing")
        model.applyReviewEvent(.draft(Self.draft(second, title: "Second")), to: &progress)
        #expect(model.drafts.map(\.id) == [first, second])

        let one = Sample.comment("One", page: nil)
        model.applyReviewEvent(.comment(one, replacesDraft: first), to: &progress)
        #expect(model.drafts.map(\.id) == [second])
        #expect(model.session?.comments.map(\.id) == [one.id])
        let two = Sample.comment("Two", page: nil)
        model.applyReviewEvent(.comment(two, replacesDraft: second), to: &progress)
        #expect(model.drafts.isEmpty)
        #expect(model.session?.comments.map(\.id) == [one.id, two.id])

        model.applyReviewEvent(.digest("notes"), to: &progress)
        #expect(model.session?.paperDigest == "notes")
        model.applyReviewEvent(.phase(.reading(part: 2, of: 5)), to: &progress)
        #expect(model.runState == .running(kind: .review, phase: .reading(part: 2, of: 5), startedAt: Sample.start))
    }

    @Test @MainActor func aScriptedReviewAppendsCommentsInOrderAndRecordsTheRun() async throws {
        let firstDraft = UUID()
        let secondDraft = UUID()
        let one = Sample.comment("One", page: nil)
        let two = Sample.comment("Two", page: nil)
        let started = Sample.run(.review, .running)
        var finished = started
        finished.status = .completed
        finished.finishedAt = Sample.start.addingTimeInterval(30)
        let events: [ReviewEvent] = [.started(started), .phase(.preparing), .phase(.reading(part: 1, of: 1)),
                                     .draft(Self.draft(firstDraft, title: "One")), .comment(one, replacesDraft: firstDraft),
                                     .draft(Self.draft(secondDraft, title: "Two")), .comment(two, replacesDraft: secondDraft),
                                     .notice("The model ignored the output format."), .finished(finished)]
        let harness = try await makeHarness(engine: ScriptedReviewEngine(plan: Sample.localPlan, review: events))
        await harness.open()
        harness.model.startReview()
        await harness.finishJobs()
        let session = try #require(harness.model.session)
        #expect(session.comments.map(\.title) == ["One", "Two"])
        #expect(session.runs == [finished])
        #expect(harness.model.drafts.isEmpty)
        #expect(harness.model.runState == .idle)
        #expect(harness.model.banner?.style == .info)
        #expect(harness.model.banner?.message == "The model ignored the output format.")
        #expect(harness.lastContext(of: "review")?.provider == ProviderRef(providerID: "mock", model: "mock"))

        // Saved before the run started (section 4.5), and again after it.
        let before = harness.store.saveCount
        #expect(before >= 1)
        harness.clock.advance(by: 1.5)
        await harness.model.autosaveTask?.value
        #expect(harness.store.saveCount == before + 1)
        #expect(try await harness.store.loadSession(sha256: harness.paper.ref.sha256)?.comments.count == 2)
    }

    @Test @MainActor func aFailedReviewKeepsItsCommentsAndOffersRetry() async throws {
        let one = Sample.comment("Kept", page: nil)
        let draftID = UUID()
        let started = Sample.run(.review, .running)
        var failed = started
        failed.status = .failed("The provider is overloaded.")
        let events: [ReviewEvent] = [.started(started), .comment(one, replacesDraft: UUID()), .draft(Self.draft(draftID, title: "Cut off")),
                                     .finished(failed)]
        let harness = try await makeHarness(engine: ScriptedReviewEngine(plan: Sample.localPlan, review: events))
        await harness.open()
        harness.model.startReview()
        await harness.finishJobs()
        #expect(harness.model.session?.comments.map(\.title) == ["Kept"])
        #expect(harness.model.drafts.isEmpty)                            // the open draft is discarded
        #expect(harness.model.session?.runs.last?.status == .failed("The provider is overloaded."))
        #expect(harness.model.banner?.style == .error)
        #expect(harness.model.banner?.message == "Review stopped: The provider is overloaded.")
        #expect(harness.model.banner?.action == .retry)
        #expect(harness.model.runState == .idle)

        harness.model.retryLastFailedJob()
        #expect(harness.model.banner == nil)
        await harness.finishJobs()
        #expect(harness.calls(of: "review") == 2)
        #expect(harness.model.session?.comments.count == 1)              // the same comment id comes back: replaced, not doubled
    }

    @Test @MainActor func aNoticeDoesNotHideAnError() async throws {
        let started = Sample.run(.review, .running)
        var failed = started
        failed.status = .failed("Network error: offline")
        let harness = try await makeHarness(engine: ScriptedReviewEngine(plan: Sample.localPlan, review: [.started(started), .finished(failed)]))
        await harness.open()
        harness.model.startReview()
        await harness.finishJobs()
        var progress = RunProgress(startedAt: Sample.start)
        harness.model.applyReviewEvent(.notice("Later notice"), to: &progress)
        #expect(harness.model.banner?.message == "Review stopped: Network error: offline")
        harness.model.dismissBanner()
        #expect(harness.model.banner == nil)
    }

    @Test @MainActor func cancellingAReviewRecordsACancelledRunWithoutABanner() async throws {
        let one = Sample.comment("Arrived", page: nil)
        let events: [ReviewEvent] = [.started(Sample.run(.review, .running)), .comment(one, replacesDraft: UUID()),
                                     .draft(Self.draft(UUID(), title: "Unfinished")), .draft(Self.draft(UUID(), title: "Never shown")),
                                     .finished(Sample.run(.review, .completed))]
        let harness = try await makeHarness(engine: ScriptedReviewEngine(plan: Sample.localPlan, review: events, delayPerEvent: .milliseconds(400)))
        await harness.open()
        harness.model.startReview()
        #expect(await waitUntil { harness.model.drafts.first?.title == "Unfinished" })
        harness.model.cancelRun()
        await harness.finishJobs()
        #expect(harness.model.runState == .idle)
        #expect(harness.model.drafts.isEmpty)
        #expect(harness.model.session?.comments.map(\.title) == ["Arrived"])
        #expect(harness.model.session?.runs.last?.status == .cancelled)
        #expect(harness.model.banner == nil)
    }

    @Test @MainActor func clearingUndecidedAIComments() async throws {
        let paper = try makeSamplePaper()
        let pendingAI = Sample.comment("Pending AI", page: nil)
        let approvedAI = Sample.comment("Approved AI", page: nil, status: .approved)
        let own = Sample.comment("Own", page: nil, origin: .user)
        var similar = Sample.comment("Similar to the pending one", page: nil, status: .rejected)
        similar.similarTo = pendingAI.id
        let harness = try await makeHarness(paper: paper, seed: Sample.session(for: paper, comments: [pendingAI, approvedAI, own, similar]))
        await harness.open()
        harness.model.selectedCommentID = pendingAI.id
        harness.model.deletePendingAIComments()
        #expect(harness.model.session?.comments.map(\.title) == ["Approved AI", "Own", "Similar to the pending one"])
        #expect(harness.model.session?.comments.last?.similarTo == nil)
        #expect(harness.model.selectedCommentID == nil)
    }

    // ---- lanes ----

    @Test @MainActor func aDiscussionRunsBesideAReviewButASecondReviewDoesNot() async throws {
        let comment = Sample.comment("Early comment", page: nil)
        let review: [ReviewEvent] = [.started(Sample.run(.review, .running)), .phase(.preparing), .phase(.reading(part: 1, of: 2)),
                                     .phase(.reading(part: 2, of: 2)), .finished(Sample.run(.review, .completed))]
        let reply = ThreadMessage(id: UUID(), role: .assistant, text: "Because.", createdAt: Sample.start)
        let replies: [ReplyEvent] = [.started(Sample.run(.discussion, .running)), .textDelta("Because"), .textDelta("."),
                                     .finished(reply: reply, proposal: nil, run: Sample.run(.discussion, .completed))]
        let paper = try makeSamplePaper()
        let harness = try await makeHarness(paper: paper, engine: ScriptedReviewEngine(plan: Sample.localPlan, review: review, reply: replies,
                                                                                       delayPerEvent: .seconds(1)),
                                            seed: Sample.session(for: paper, comments: [comment]))
        await harness.open()
        let model = harness.model
        model.startReview()
        #expect(await waitUntil { harness.calls(of: "review") == 1 })
        if case .running(kind: .review, _, _) = model.runState {} else { Issue.record("the review is not running: \(model.runState)") }

        model.sendDiscussionMessage("Why?", commentID: comment.id)
        #expect(await waitUntil { harness.calls(of: "discuss") == 1 })
        #expect(model.streamingTargetID == comment.id)
        #expect(model.session?.comments.first?.thread.map(\.text) == ["Why?"])

        model.startReview()                                              // busy lane: ignored
        model.sendDiscussionMessage("And?", commentID: comment.id)       // busy lane: ignored
        #expect(await waitUntil { model.streamingReplyText.hasPrefix("Because") })    // both runs have reported their start by now
        #expect(harness.calls(of: "review") == 1)
        #expect(harness.calls(of: "discuss") == 1)
        #expect(model.session?.comments.first?.thread.map(\.text) == ["Why?"])
        #expect(model.canStartReview == false)

        model.cancelReply()
        model.cancelRun()
        await harness.finishJobs()
        #expect(model.streamingTargetID == nil)
        #expect(model.streamingReplyText == "")
        #expect(model.runState == .idle)
        #expect(model.session?.runs.map(\.kind) == [.review, .discussion] || model.session?.runs.map(\.kind) == [.discussion, .review])
        #expect(model.session?.runs.allSatisfy { $0.status == .cancelled } == true)
        #expect(model.session?.comments.first?.thread.map(\.text) == ["Why?"])     // a cancelled reply is not kept
        #expect(model.banner == nil)
    }

    @Test @MainActor func aReportAndAReplyStreamIntoTheirOwnProperties() async throws {
        let comment = Sample.comment("Approved", page: nil, status: .approved)
        let reply = ThreadMessage(id: UUID(), role: .assistant, text: "Reply text", createdAt: Sample.start)
        let replies: [ReplyEvent] = [.started(Sample.run(.discussion, .running)), .textDelta("Reply"), .textDelta(" text"),
                                     .finished(reply: reply, proposal: nil, run: Sample.run(.discussion, .completed))]
        let draft = ReportDraft(markdown: "ABC", userEdited: false)
        let report: [ReportEvent] = [.started(Sample.run(.report, .running)), .textDelta("A"), .textDelta("B"), .textDelta("C"),
                                     .finished(draft, run: Sample.run(.report, .completed))]
        let paper = try makeSamplePaper()
        let harness = try await makeHarness(paper: paper, engine: ScriptedReviewEngine(plan: Sample.localPlan, reply: replies, report: report,
                                                                                       delayPerEvent: .seconds(1)),
                                            seed: Sample.session(for: paper, comments: [comment]))
        await harness.open()
        let model = harness.model
        model.generateReport()
        model.sendDiscussionMessage("Why?", commentID: comment.id)
        #expect(await waitUntil { !model.streamingReportText.isEmpty && !model.streamingReplyText.isEmpty })
        #expect("ABC".hasPrefix(model.streamingReportText))              // report text only
        #expect("Reply text".hasPrefix(model.streamingReplyText))        // reply text only
        #expect(model.streamingTargetID == comment.id)
        if case .running(kind: .report, _, _) = model.runState {} else { Issue.record("the report is not running: \(model.runState)") }

        await harness.finishJobs()
        #expect(model.streamingReportText == "")
        #expect(model.streamingReplyText == "")
        #expect(model.session?.report?.markdown == "ABC")
        #expect(model.session?.comments.first?.thread.map(\.text) == ["Why?", "Reply text"])
    }

    @Test @MainActor func aReportAloneLeavesTheReplyTextAlone() async throws {
        let comment = Sample.comment("Approved", page: nil, status: .approved)
        let report: [ReportEvent] = [.started(Sample.run(.report, .running)), .textDelta("Streaming report"),
                                     .finished(ReportDraft(markdown: "Streaming report", userEdited: false), run: Sample.run(.report, .completed))]
        let paper = try makeSamplePaper()
        let harness = try await makeHarness(paper: paper, engine: ScriptedReviewEngine(plan: Sample.localPlan, report: report,
                                                                                       delayPerEvent: .milliseconds(500)),
                                            seed: Sample.session(for: paper, comments: [comment]))
        await harness.open()
        harness.model.generateReport()
        #expect(await waitUntil { harness.model.streamingReportText == "Streaming report" })
        #expect(harness.model.streamingReplyText == "")
        #expect(harness.model.streamingTargetID == nil)
        await harness.finishJobs()
        #expect(harness.model.streamingReplyText == "")
    }
}
