import Foundation
import Testing
import RefereeCore
@testable import AppCore
import TestSupport

/// Acceptance row "consent" (plan.md section 11.4, WP8b; section 9.7), and the banners of a job that has no provider.
@Suite struct ReviewSessionModelConsentTests {
    static let review: [ReviewEvent] = [.started(Sample.run(.review, .running, provider: "mock-remote")),
                                        .finished(Sample.run(.review, .completed, provider: "mock-remote"))]

    /// "mock-remote" (not local) is the review default; the engine's plan is the remote one.
    @MainActor static func remoteHarness(_ change: (inout AppSettings) -> Void = { _ in }, seed comments: [ReviewComment] = []) async throws -> Harness {
        let settings = Sample.settings { settings in
            settings.defaults.review = ProviderRef(providerID: "mock-remote", model: nil)
            change(&settings)
        }
        let reply = ThreadMessage(id: UUID(), role: .assistant, text: "Fine.", createdAt: Sample.start)
        let engine = ScriptedReviewEngine(plan: Sample.remotePlan, review: review,
                                          reply: [.finished(reply: reply, proposal: nil, run: Sample.run(.discussion, .completed, provider: "mock-remote"))])
        let paper = try makeSamplePaper()
        let harness = try await makeHarness(paper: paper, settings: settings, engine: engine,
                                            seed: comments.isEmpty ? nil : Sample.session(for: paper, comments: comments))
        await harness.open()
        return harness
    }

    @Test @MainActor func aNonLocalProviderAsksFirstAndSendsNothing() async throws {
        let harness = try await Self.remoteHarness()
        let before = harness.model.session
        harness.model.startReview()
        let request = try #require(harness.model.consentRequest)
        #expect(request.provider.id == "mock-remote")
        #expect(request.provider.isLocal == false)
        #expect(request.model == "mock")
        #expect(request.plan == Sample.remotePlan)
        #expect(harness.calls(of: "review") == 0)
        #expect(harness.model.runState == .idle)
        #expect(harness.model.session == before)
        #expect(harness.model.canStartReview == false)              // the lane waits for the answer
    }

    @Test @MainActor func yesRecordsConsentStartsTheJobAndTheNextJobDoesNotAsk() async throws {
        let comment = Sample.comment("Discussed", page: nil)
        let harness = try await Self.remoteHarness(seed: [comment])
        harness.model.startReview()
        #expect(harness.model.consentRequest != nil)
        harness.model.answerConsent(granted: true)
        #expect(harness.model.consentRequest == nil)
        #expect(harness.model.session?.consents.map(\.providerID) == ["mock-remote"])
        #expect(harness.model.session?.consents.first?.grantedAt == harness.clock.now())
        await harness.finishJobs()
        #expect(harness.calls(of: "review") == 1)
        #expect(harness.model.session?.runs.count == 1)

        // A second job for the same provider and document does not ask again, in either lane.
        harness.model.startReview()
        #expect(harness.model.consentRequest == nil)
        await harness.finishJobs()
        #expect(harness.calls(of: "review") == 2)
        harness.model.sendDiscussionMessage("Is this fair?", commentID: comment.id)
        #expect(harness.model.consentRequest == nil)
        await harness.finishJobs()
        #expect(harness.calls(of: "discuss") == 1)
        #expect(harness.model.session?.consents.count == 1)
    }

    @Test @MainActor func noLeavesEverythingAsItWas() async throws {
        let harness = try await Self.remoteHarness()
        await harness.model.flushPendingSave()
        let before = try #require(harness.model.session)
        harness.model.startReview()
        #expect(harness.model.consentRequest != nil)
        harness.model.answerConsent(granted: false)
        await harness.finishJobs()
        #expect(harness.model.consentRequest == nil)
        #expect(harness.model.session == before)
        #expect(harness.model.runState == .idle)
        #expect(harness.calls(of: "review") == 0)
        #expect(harness.model.banner == nil)
        #expect(harness.model.canStartReview)                       // and the next attempt asks again
        harness.model.startReview()
        #expect(harness.model.consentRequest != nil)
        harness.model.cancelRun()                                   // Cancel while the card is up: the same as no
        #expect(harness.model.consentRequest == nil)
        await harness.finishJobs()
        #expect(harness.calls(of: "review") == 0)
        #expect(harness.model.session == before)
    }

    @Test @MainActor func aLocalProviderNeverAsks() async throws {
        let review: [ReviewEvent] = [.started(Sample.run(.review, .running)), .finished(Sample.run(.review, .completed))]
        let harness = try await makeHarness(engine: ScriptedReviewEngine(plan: Sample.localPlan, review: review))
        await harness.open()
        #expect(harness.model.activeProvider?.isLocal == true)
        harness.model.startReview()
        #expect(harness.model.consentRequest == nil)
        await harness.finishJobs()
        #expect(harness.calls(of: "review") == 1)
        #expect(harness.model.session?.consents.isEmpty == true)
    }

    @Test @MainActor func withoutTheAskSettingARemoteProviderDoesNotAsk() async throws {
        let harness = try await Self.remoteHarness { $0.privacy.confirmFirstSendPerDocument = false }
        harness.model.startReview()
        #expect(harness.model.consentRequest == nil)
        await harness.finishJobs()
        #expect(harness.calls(of: "review") == 1)
    }

    @Test @MainActor func localOnlyBlocksARemoteProviderWithABanner() async throws {
        let harness = try await Self.remoteHarness { $0.privacy.localOnly = true }
        #expect(harness.model.activeProvider?.id == "mock-remote")      // the indicator shows "Remote blocked (Local only)"
        harness.model.startReview()
        #expect(harness.model.consentRequest == nil)
        #expect(harness.model.banner?.message == "Remote providers are blocked by Local only")
        #expect(harness.model.banner?.style == .error)
        await harness.finishJobs()
        #expect(harness.calls(of: "review") == 0)
        #expect(harness.model.runState == .idle)
        // It cannot be chosen either.
        #expect(harness.model.selectableProviders.map(\.id) == ["mock"])
        harness.model.setActiveProvider(ProviderRef(providerID: "mock-remote", model: nil))
        #expect(harness.model.session?.preferredProvider == nil)
    }

    @Test @MainActor func aJobWithoutAnEnabledProviderAsksForSetUp() async throws {
        let harness = try await makeHarness(settings: Sample.settings { $0.defaults.review = nil })
        await harness.open()
        harness.model.startReview()
        #expect(harness.model.banner?.message == "Set up an AI provider")
        #expect(harness.model.banner?.action == .openSettings)
        #expect(harness.calls(of: "review") == 0)

        let disabled = try await makeHarness(settings: Sample.settings { $0.providers["mock"]?.enabled = false })
        await disabled.open()
        disabled.model.startReview()
        #expect(disabled.model.banner?.message == "Set up an AI provider")

        // A provider the settings know but the registry does not is not usable either.
        let unknown = try await makeHarness(settings: Sample.settings { $0.defaults.review = ProviderRef(providerID: "mock-fail", model: nil) })
        await unknown.open()
        #expect(unknown.model.activeProvider == nil)
        unknown.model.startReview()
        #expect(unknown.model.banner?.action == .openSettings)
    }

    @Test @MainActor func aChatJobAsksForItsOwnProviderWithThatProvidersPlan() async throws {
        let comment = Sample.comment("Discussed", page: nil)
        let harness = try await Self.remoteHarness({ settings in
            settings.defaults.review = ProviderRef(providerID: "mock", model: nil)            // the review stays on this Mac
            settings.defaults.chat = ProviderRef(providerID: "mock-remote", model: nil)
        }, seed: [comment])
        let plans = harness.calls(of: "plan")
        harness.model.sendDiscussionMessage("Is this fair?", commentID: comment.id)
        #expect(await waitUntil { harness.model.consentRequest != nil })   // after a plan for that provider
        #expect(harness.model.consentRequest?.provider.id == "mock-remote")
        #expect(harness.calls(of: "plan") == plans + 1)
        #expect(harness.lastContext(of: "plan")?.provider.providerID == "mock-remote")
        #expect(harness.model.session?.comments.first?.thread.isEmpty == true)              // nothing joins the thread before the answer
        harness.model.answerConsent(granted: true)
        await harness.finishJobs()
        #expect(harness.calls(of: "discuss") == 1)
        #expect(harness.model.session?.comments.first?.thread.map(\.role) == [.user, .assistant])
        harness.model.startReview()                                                       // local: no card
        #expect(harness.model.consentRequest == nil)
        await harness.finishJobs()
        #expect(harness.calls(of: "review") == 1)
    }

    @Test @MainActor func closingAnswersAPendingCardWithNo() async throws {
        let harness = try await Self.remoteHarness()
        harness.model.startReview()
        #expect(harness.model.consentRequest != nil)
        await harness.model.close()
        #expect(harness.model.consentRequest == nil)
        #expect(harness.calls(of: "review") == 0)
        #expect(try await harness.store.loadSession(sha256: harness.paper.ref.sha256)?.consents.isEmpty == true)
    }
}
