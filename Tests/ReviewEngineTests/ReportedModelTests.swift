import Foundation
import Testing
@testable import ReviewEngine
import RefereeCore
import TestSupport

/// A mock whose stream first names a model, as the adapters do when the provider's own stream names one (`LLMEvent.model`,
/// step 5c). Every other answer is the wrapped mock's.
private final class NamingMockProvider: LLMProvider, @unchecked Sendable {
    let base: MockLLMProvider
    let names: [String]

    init(_ base: MockLLMProvider, naming names: [String]) {
        self.base = base
        self.names = names
    }

    var descriptor: ProviderDescriptor { base.descriptor }
    func availability() async -> ProviderAvailability { await base.availability() }
    func listModels() async throws -> [ModelInfo] { try await base.listModels() }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        let names = names
        let inner = base.stream(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                for name in names { continuation.yield(.model(name)) }
                do {
                    for try await event in inner { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Step 5c: the model a provider's stream names is kept in the run's record (`RunRecord.reportedModel`, the last one
/// named) and in an answer (`ThreadMessage.reportedModel`); the started record has none yet, and a stream that names no
/// model leaves both nil.
@Suite struct ReportedModelTests {
    @Test func aReviewKeepsTheModelTheStreamNamedInItsRecord() async throws {
        let paper = try makeSamplePaper()
        let provider = NamingMockProvider(MockLLMProvider(), naming: ["claude-sonnet-4-6"])
        let events = try await EngineTest.collect(EngineTest.engine([provider], paper: paper)
            .review(paper: paper, existing: [], context: EngineTest.context()))
        #expect(events.startedRun?.reportedModel == nil)
        #expect(events.finishedRun?.status == .completed)
        #expect(events.finishedRun?.reportedModel == "claude-sonnet-4-6")
        #expect(events.finishedRun?.provider == ProviderRef(providerID: "mock", model: "mock"))     // what was asked stays
        #expect(!events.comments.isEmpty)
    }

    @Test func aStreamThatNamesNoModelLeavesItUnrecorded() async throws {
        let paper = try makeSamplePaper()
        let events = try await EngineTest.collect(EngineTest.engine([MockLLMProvider()], paper: paper)
            .review(paper: paper, existing: [], context: EngineTest.context()))
        #expect(events.finishedRun?.status == .completed)
        #expect(events.finishedRun?.reportedModel == nil)
    }

    @Test func aDiscussionReplyAndAnAnswerCarryTheModelTheirStreamNamed() async throws {
        let paper = try makeSamplePaper()
        let provider = NamingMockProvider(MockLLMProvider(), naming: ["first-name", "gemma4:e4b"])
        let engine = EngineTest.engine([provider], paper: paper)
        let comment = ReviewComment(id: UUID(), origin: .ai(runID: UUID()), status: .pending, kind: .major, category: "claims",
                                    title: "A title", body: "A body.", anchor: Anchor(quote: "", confidence: .none, locationLabel: ""),
                                    includeInReport: true, createdAt: Date(), updatedAt: Date())
        let discussion = try await EngineTest.collect(engine.discuss(paper: paper, comment: comment, message: "Is it fair?",
                                                                     context: EngineTest.context()))
        guard case .finished(let reply, _, let run)? = discussion.last else {
            Issue.record("expected .finished, got \(discussion)")
            return
        }
        #expect(reply.reportedModel == "gemma4:e4b")                 // the last name the stream gave
        #expect(run.reportedModel == "gemma4:e4b")
        #expect(reply.provider == ProviderRef(providerID: "mock", model: "mock"))

        let conversation = Conversation(id: UUID(), createdAt: Date())
        let answer = try await EngineTest.collect(engine.ask(paper: paper, conversation: conversation, question: "What is claimed?",
                                                             context: EngineTest.context()))
        guard case .finished(let message, _, let askRun)? = answer.last else {
            Issue.record("expected .finished, got \(answer)")
            return
        }
        #expect(message.reportedModel == "gemma4:e4b")
        #expect(askRun.reportedModel == "gemma4:e4b")
    }

    @Test func theReportsRecordKeepsTheModelItsStreamNamed() async throws {
        let paper = try makeSamplePaper()
        let provider = NamingMockProvider(MockLLMProvider(), naming: ["gpt-x-2026-10-01"])
        let approved = ReviewComment(id: UUID(), origin: .user, status: .approved, kind: .major, category: "claims", title: "A title",
                                     body: "A body.", anchor: Anchor(quote: "", confidence: .none, locationLabel: ""), includeInReport: true,
                                     createdAt: Date(), updatedAt: Date())
        let session = ReviewSession(schemaVersion: 1, id: UUID(), document: paper.ref, meta: ManuscriptMeta(reviewerNotes: ""),
                                    comments: [approved], createdAt: Date(), updatedAt: Date())
        let events = try await EngineTest.collect(EngineTest.engine([provider], paper: paper)
            .generateReport(paper: paper, session: session, context: EngineTest.context()))
        guard case .finished(_, let run)? = events.last else {
            Issue.record("expected .finished, got \(events)")
            return
        }
        #expect(run.status == .completed)
        #expect(run.reportedModel == "gpt-x-2026-10-01")
    }
}
