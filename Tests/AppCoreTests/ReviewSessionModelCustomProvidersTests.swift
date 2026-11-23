import Foundation
import Testing
import RefereeCore
@testable import AppCore
import TestSupport

/// Step 5b, the user's request: the provider and model chosen for a document in the toolbar's destination control are
/// the ones every job of that document uses; "Custom" (`useCustomProviders()`, what a new document starts with) hands
/// each job to its own default of Settings ▸ Providers. The consent card follows the provider of each job.
@Suite struct ReviewSessionModelCustomProvidersTests {
    static let chosen = ProviderRef(providerID: "mock-remote", model: "chosen-model")

    /// A review, a reply and a report the scripted engine plays for every call of its kind.
    static func engine(plan: SendPlan = ModelSample.localPlan) -> ScriptedReviewEngine {
        let reply = ThreadMessage(id: UUID(), role: .assistant, text: "An answer.", createdAt: ModelSample.start)
        let draft = ReportDraft(markdown: "## Summary assessment\n\nA report.\n", generatedAt: ModelSample.start, userEdited: false)
        return ScriptedReviewEngine(plan: plan,
                                    review: [.started(ModelSample.run(.review, .running)), .finished(ModelSample.run(.review, .completed))],
                                    reply: [.finished(reply: reply, proposal: nil, run: ModelSample.run(.question, .completed))],
                                    report: [.started(ModelSample.run(.report, .running)), .finished(draft, run: ModelSample.run(.report, .completed))])
    }

    /// The snapshot settings with consent off (these tests are about where jobs go, not about the card) and `change`.
    @MainActor static func harness(_ change: (inout AppSettings) -> Void = { _ in }) async throws -> (ModelHarness, ReviewComment) {
        let comment = ModelSample.comment("Approved", page: nil, status: .approved)
        let settings = ModelSample.settings { settings in
            settings.privacy.confirmFirstSendPerDocument = false
            change(&settings)
        }
        let paper = try makeSamplePaper()
        let harness = try await makeModelHarness(paper: paper, settings: settings, engine: engine(),
                                                 seed: ModelSample.session(for: paper, comments: [comment]))
        await harness.open()
        return (harness, comment)
    }

    /// Runs a review, a discussion reply, a question, the report and its voice revision, one after another.
    @MainActor static func runEveryJob(_ harness: ModelHarness, discussing comment: ReviewComment) async {
        harness.model.startReview()
        await harness.finishJobs()
        harness.model.sendDiscussionMessage("Is this fair?", commentID: comment.id)
        await harness.finishJobs()
        harness.model.ask("What does the paper claim?", about: nil, in: nil)
        await harness.finishJobs()
        harness.model.generateReport()
        await harness.finishJobs()
        harness.model.reviseReportVoice()
        await harness.finishJobs()
    }

    @Test @MainActor func aProviderAndModelChosenForTheDocumentRunEveryJob() async throws {
        let (harness, comment) = try await Self.harness { settings in
            // Defaults that differ from the choice, so that the test sees the choice win over each of them.
            settings.defaults.chat = ProviderRef(providerID: "mock", model: "mock")
            settings.defaults.report = ProviderRef(providerID: "mock", model: "mock")
        }
        #expect(harness.model.usesCustomProviders)                         // a new document: nothing chosen
        harness.model.setActiveProvider(Self.chosen)
        #expect(!harness.model.usesCustomProviders)
        #expect(harness.model.activeProvider?.id == "mock-remote")
        #expect(harness.model.activeModel == "chosen-model")
        #expect(harness.model.chatProvider?.id == "mock-remote")
        #expect(harness.model.reportProvider?.id == "mock-remote")

        await Self.runEveryJob(harness, discussing: comment)
        for call in ["review", "discuss", "ask", "report", "revise"] {
            #expect(harness.calls(of: call) == 1, "\(call)")
            #expect(harness.lastContext(of: call)?.provider == Self.chosen, "\(call)")
        }
    }

    @Test @MainActor func customHandsEachJobToItsDefault() async throws {
        let (harness, comment) = try await Self.harness { settings in
            settings.defaults.review = ProviderRef(providerID: "mock", model: "mock")
            settings.defaults.chat = ProviderRef(providerID: "mock-remote", model: "chat-model")
            settings.defaults.report = ProviderRef(providerID: "mock-remote", model: "report-model")
        }
        harness.model.setActiveProvider(Self.chosen)
        await harness.model.waitForBackgroundWork()
        let commentsBefore = harness.model.session?.comments

        harness.model.useCustomProviders()
        #expect(harness.model.usesCustomProviders)
        #expect(harness.model.session?.preferredProvider == nil)
        #expect(harness.model.session?.comments == commentsBefore)         // nothing else of the document changes
        #expect(harness.model.activeProvider?.id == "mock")
        #expect(harness.model.activeModel == "mock")
        #expect(harness.model.chatProvider?.id == "mock-remote")
        await harness.model.waitForBackgroundWork()
        #expect(harness.lastContext(of: "plan")?.provider == ProviderRef(providerID: "mock", model: "mock"))   // the plan follows

        await Self.runEveryJob(harness, discussing: comment)
        #expect(harness.lastContext(of: "review")?.provider == ProviderRef(providerID: "mock", model: "mock"))
        #expect(harness.lastContext(of: "discuss")?.provider == ProviderRef(providerID: "mock-remote", model: "chat-model"))
        #expect(harness.lastContext(of: "ask")?.provider == ProviderRef(providerID: "mock-remote", model: "chat-model"))
        #expect(harness.lastContext(of: "report")?.provider == ProviderRef(providerID: "mock-remote", model: "report-model"))
        #expect(harness.lastContext(of: "revise")?.provider == ProviderRef(providerID: "mock-remote", model: "report-model"))

        // Already in Custom: nothing to do, and nothing is saved again.
        let session = harness.model.session
        harness.model.useCustomProviders()
        #expect(harness.model.session == session)
    }

    /// A Custom document whose reviews stay on this Mac but whose chat goes to a remote provider asks before the
    /// first question, and sends nothing until it is answered.
    @Test @MainActor func aCustomDocumentAsksBeforeTheFirstQuestionToARemoteChatProvider() async throws {
        let (harness, _) = try await Self.harness { settings in
            settings.privacy.confirmFirstSendPerDocument = true
            settings.defaults.review = ProviderRef(providerID: "mock", model: "mock")
            settings.defaults.chat = ProviderRef(providerID: "mock-remote", model: "mock")
        }
        #expect(harness.model.usesCustomProviders)
        harness.model.startReview()                                        // local: no question
        #expect(harness.model.consentRequest == nil)
        await harness.finishJobs()
        #expect(harness.calls(of: "review") == 1)

        harness.model.ask("What does the paper claim?", about: nil, in: nil)
        await waitForModel { harness.model.consentRequest != nil }
        let request = try #require(harness.model.consentRequest)
        #expect(request.provider.id == "mock-remote")
        #expect(harness.calls(of: "ask") == 0)                            // nothing sent before the answer
        harness.model.answerConsent(granted: false)
        await harness.finishJobs()
        #expect(harness.calls(of: "ask") == 0)
        #expect(harness.model.session?.consents.isEmpty == true)
    }
}
