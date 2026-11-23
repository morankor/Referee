import Foundation
import Testing
import RefereeCore
@testable import AppCore
import TestSupport

/// Step 5c, the coordinator's decision (e), on the user's requests of step 5b: switching providers never removes a
/// comment, and every AI comment names the provider and model of its own run. A paper is reviewed with provider A and
/// model x, moved to provider B and model y, and reviewed again: both sets of comments stay, the decisions taken on the
/// first set too; each comment points to its own run, which names its provider, the model asked for and the model the
/// provider reported; a comment of the second review on a passage the first already covered is folded (`similarTo`) and
/// kept. Back in Custom, with reviews on this Mac and chat questions going to a remote default, the first question asks
/// for consent before anything is sent.
@Suite struct ReviewSessionModelTwoProvidersTests {
    static let providerA = ProviderRef(providerID: "mock", model: "model-x")
    static let providerB = ProviderRef(providerID: "mock-remote", model: "model-y")

    /// What each review writes. The first: two comments. The second: one on the first review's first passage, of the same
    /// kind, folded under it as the engine folds it (§6.6), and two new ones. Every comment belongs to the call's own run.
    static let reviews: StagedReviewEngine.Script = { call, _, existing, run in
        let origin = CommentOrigin.ai(runID: run.id)
        let created = Double(call) * 600
        if call == 0 {
            return [ModelSample.comment("A1 on the identification", page: 0, range: RefereeCore.TextRange(location: 10, length: 40), kind: .major,
                                        origin: origin, created: created + 1),
                    ModelSample.comment("A2 on the standard errors", page: 0, range: RefereeCore.TextRange(location: 200, length: 30), kind: .minor,
                                        origin: origin, created: created + 2)]
        }
        var folded = ModelSample.comment("B1 on the identification, again", page: 0, range: RefereeCore.TextRange(location: 12, length: 36),
                                         kind: .major, origin: origin, created: created + 1)
        folded.similarTo = existing.first { $0.title == "A1 on the identification" }?.id
        return [folded,
                ModelSample.comment("B2 on the sample", page: 0, range: RefereeCore.TextRange(location: 300, length: 20), kind: .question,
                                    origin: origin, created: created + 2),
                ModelSample.comment("B3 on the abstract", page: nil, kind: .minor, origin: origin, created: created + 3)]
    }

    /// The model each provider says it ran.
    static let reported: @Sendable (EngineContext) -> String? = { context in
        context.provider.providerID == "mock" ? "model-x-2026-11" : "model-y-2026-11"
    }

    /// The four mocks of the snapshot settings, "mock-chat" (remote) too, consent on.
    static func settings() -> AppSettings {
        ModelSample.settings { settings in
            settings.providers["mock-chat"] = ProviderSettings(enabled: true, model: "chat-model", inputMode: .auto)
            settings.privacy.confirmFirstSendPerDocument = true
        }
    }

    static func providers() -> [any LLMProvider] {
        ModelSample.providers() + [MockLLMProvider(id: "mock-chat", isLocal: false)]
    }

    @Test @MainActor func twoReviewsByTwoProvidersKeepEveryCommentEachUnderItsOwnRun() async throws {
        let scripted = ScriptedReviewEngine(plan: ModelSample.localPlan)
        let staged = StagedReviewEngine(scripted: scripted, reports: Self.reported, script: Self.reviews)
        let harness = try await makeModelHarness(settings: Self.settings(), providers: Self.providers(), engine: scripted, wrap: { _ in staged })
        await harness.open()
        let model = harness.model

        // ---- review 1: provider A, model x (local: no consent) ----
        model.setActiveProvider(Self.providerA)
        model.startReview()
        await harness.finishJobs()
        let first = try #require(model.session?.comments)
        #expect(first.count == 2)
        let a1 = try #require(first.first { $0.title == "A1 on the identification" })
        let a2 = try #require(first.first { $0.title == "A2 on the standard errors" })
        model.setStatus(.approved, for: a1.id)
        model.setStatus(.rejected, for: a2.id)

        // ---- switch the paper to provider B, model y: nothing is removed ----
        model.setActiveProvider(Self.providerB)
        #expect(model.activeProvider?.id == "mock-remote")
        #expect(model.activeModel == "model-y")
        #expect(model.session?.comments.map(\.id) == first.map(\.id))

        // ---- review 2: provider B is remote, so the consent card comes first ----
        model.startReview()
        #expect(await waitForModel { model.consentRequest != nil })
        #expect(model.consentRequest?.provider.id == "mock-remote")
        #expect(model.consentRequest?.model == "model-y")
        #expect(staged.reviewCalls.count == 1)                                  // nothing sent before the answer
        model.answerConsent(granted: true)
        await harness.finishJobs()

        // Both sets are there, the first review's decisions included.
        let session = try #require(model.session)
        #expect(session.comments.count == 5)
        #expect(Set(first.map(\.id)).isSubset(of: Set(session.comments.map(\.id))))
        #expect(session.comments.first { $0.id == a1.id }?.status == .approved)
        #expect(session.comments.first { $0.id == a2.id }?.status == .rejected)
        #expect(model.visibleComments.count == 5)

        // Each comment names its own run: provider, model asked for, model reported.
        #expect(session.runs.count == 2)
        #expect(session.runs.allSatisfy { $0.kind == .review && $0.status == .completed })
        func run(of comment: ReviewComment) -> RunRecord? {
            guard case .ai(let runID) = comment.origin else { return nil }
            return session.runs.first { $0.id == runID }
        }
        for comment in session.comments {
            let byA = comment.title.hasPrefix("A")
            #expect(run(of: comment)?.provider == (byA ? Self.providerA : Self.providerB), "\(comment.title)")
            #expect(run(of: comment)?.reportedModel == (byA ? "model-x-2026-11" : "model-y-2026-11"), "\(comment.title)")
        }

        // The second review was given the first one's comments, and its comment on the same passage is folded, not dropped.
        #expect(staged.reviewCalls.map(\.context.provider) == [Self.providerA, Self.providerB])
        #expect(Set(staged.reviewCalls[1].existing.map(\.id)) == Set(first.map(\.id)))
        let folded = try #require(session.comments.first { $0.title == "B1 on the identification, again" })
        #expect(folded.similarTo == a1.id)
        #expect(folded.status == .pending)

        // ---- back to Custom: nothing is removed either ----
        model.useCustomProviders()
        #expect(model.usesCustomProviders)
        #expect(model.session?.comments.count == 5)
        #expect(model.session?.runs.count == 2)
    }

    /// Custom, with reviews on this Mac and chat questions going to a remote default: reviews run without a card, the
    /// first question asks for consent before anything is sent, and the answer then comes from the chat default.
    @Test @MainActor func aQuestionInCustomAsksBeforeGoingToARemoteChatDefaultWhileReviewsStayLocal() async throws {
        let reply = ThreadMessage(id: UUID(), role: .assistant, text: "An answer.", createdAt: ModelSample.start)
        let scripted = ScriptedReviewEngine(plan: ModelSample.localPlan,
                                            reply: [.finished(reply: reply, proposal: nil, run: ModelSample.run(.question, .completed, provider: "mock-chat"))])
        let staged = StagedReviewEngine(scripted: scripted, reports: Self.reported, script: Self.reviews)
        let settings = Self.settings()
        var custom = settings
        custom.defaults.review = ProviderRef(providerID: "mock", model: "mock")
        custom.defaults.chat = ProviderRef(providerID: "mock-chat", model: "chat-model")
        let harness = try await makeModelHarness(settings: custom, providers: Self.providers(), engine: scripted, wrap: { _ in staged })
        await harness.open()
        let model = harness.model
        #expect(model.usesCustomProviders)
        #expect(model.activeProvider?.isLocal == true)
        #expect(model.chatProvider?.id == "mock-chat")

        // Reviews stay on this Mac: no card.
        model.startReview()
        #expect(model.consentRequest == nil)
        await harness.finishJobs()
        #expect(staged.reviewCalls.last?.context.provider == ProviderRef(providerID: "mock", model: "mock"))
        let commentsAfterReview = model.session?.comments.count

        // The first question: the card for the chat default, and nothing sent or added until the answer.
        model.ask("Is the effect robust?", about: nil, in: nil)
        #expect(await waitForModel { model.consentRequest != nil })
        #expect(model.consentRequest?.provider.id == "mock-chat")
        #expect(model.consentRequest?.model == "chat-model")
        #expect(harness.calls(of: "ask") == 0)
        #expect(model.session?.conversations.isEmpty == true)
        model.answerConsent(granted: true)
        await harness.finishJobs()
        #expect(harness.calls(of: "ask") == 1)
        #expect(harness.lastContext(of: "ask")?.provider == ProviderRef(providerID: "mock-chat", model: "chat-model"))
        #expect(model.session?.conversations.first?.messages.count == 2)

        // A second question asks nothing; a second review still goes to this Mac without a card; no comment went away.
        model.ask("And the sample?", about: nil, in: model.session?.conversations.first?.id)
        #expect(model.consentRequest == nil)
        await harness.finishJobs()
        #expect(harness.calls(of: "ask") == 2)
        model.startReview()
        #expect(model.consentRequest == nil)
        await harness.finishJobs()
        #expect(staged.reviewCalls.count == 2)
        #expect(staged.reviewCalls.allSatisfy { $0.context.provider.providerID == "mock" })
        #expect((model.session?.comments.count ?? 0) >= (commentsAfterReview ?? 0))
    }
}
