import Foundation
import RefereeCore

// Wave 0a placeholder (see Placeholder.swift): the scripted events are not played and no call is recorded.

/// Plays the given events; `calls` lists the jobs requested, in order ("plan", "review", "discuss", "ask", "report", "revise").
public final class ScriptedReviewEngine: ReviewEngineProtocol, @unchecked Sendable {
    private let scriptedPlan: SendPlan

    public init(plan: SendPlan, review: [ReviewEvent] = [], reply: [ReplyEvent] = [], report: [ReportEvent] = [], lint: [LintFinding] = [],
                delayPerEvent: Duration = .zero) {
        scriptedPlan = plan
    }

    public var calls: [String] { [] }
    public var contexts: [EngineContext] { [] }                    // the EngineContext of each call, for assertions on model and digest

    public func plan(paper: LoadedPaper, context: EngineContext) async -> SendPlan { scriptedPlan }

    public func review(paper: LoadedPaper, existing: [ReviewComment], context: EngineContext) -> AsyncThrowingStream<ReviewEvent, Error> {
        Self.finished()
    }

    public func discuss(paper: LoadedPaper, comment: ReviewComment, message: String, context: EngineContext) -> AsyncThrowingStream<ReplyEvent, Error> {
        Self.finished()
    }

    public func ask(paper: LoadedPaper, conversation: Conversation, question: String, context: EngineContext) -> AsyncThrowingStream<ReplyEvent, Error> {
        Self.finished()
    }

    public func generateReport(paper: LoadedPaper, session: ReviewSession, context: EngineContext) -> AsyncThrowingStream<ReportEvent, Error> {
        Self.finished()
    }

    public func reviseVoice(reportMarkdown: String, findings: [LintFinding], context: EngineContext) -> AsyncThrowingStream<ReportEvent, Error> {
        Self.finished()
    }

    public func lint(reportMarkdown: String) -> [LintFinding] { [] }

    /// A stream that ends at once without an event.
    private static func finished<Event: Sendable>() -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }
}
