import Foundation
import RefereeCore

/// Plays the given events; `calls` lists the jobs requested, in order ("plan", "review", "discuss", "ask", "report", "revise").
///
/// - `plan` returns the given plan. `review` plays the review events; `discuss` and `ask` play the reply events;
///   `generateReport` and `reviseVoice` play the report events. `lint` returns the given findings and is not listed
///   in `calls`. Nothing is derived from the arguments: every call of a kind plays the same events.
/// - A call is recorded, with its context, when the function is called. The stream is cold: it yields its events,
///   `delayPerEvent` before each, when it is iterated, then ends. It never throws; when the consuming task is
///   cancelled it ends early.
public final class ScriptedReviewEngine: ReviewEngineProtocol, @unchecked Sendable {
    private let scriptedPlan: SendPlan
    private let reviewEvents: [ReviewEvent]
    private let replyEvents: [ReplyEvent]
    private let reportEvents: [ReportEvent]
    private let findings: [LintFinding]
    private let delayPerEvent: Duration
    private let lock = NSLock()
    private var recordedCalls: [String] = []
    private var recordedContexts: [EngineContext] = []

    public init(plan: SendPlan, review: [ReviewEvent] = [], reply: [ReplyEvent] = [], report: [ReportEvent] = [], lint: [LintFinding] = [],
                delayPerEvent: Duration = .zero) {
        scriptedPlan = plan
        reviewEvents = review
        replyEvents = reply
        reportEvents = report
        findings = lint
        self.delayPerEvent = delayPerEvent
    }

    public var calls: [String] {
        lock.withLock { recordedCalls }
    }
    public var contexts: [EngineContext] {                    // the EngineContext of each call, for assertions on model and digest
        lock.withLock { recordedContexts }
    }

    public func plan(paper: LoadedPaper, context: EngineContext) async -> SendPlan {
        record("plan", context)
        return scriptedPlan
    }

    public func review(paper: LoadedPaper, existing: [ReviewComment], context: EngineContext) -> AsyncThrowingStream<ReviewEvent, Error> {
        record("review", context)
        return play(reviewEvents)
    }

    public func discuss(paper: LoadedPaper, comment: ReviewComment, message: String, context: EngineContext) -> AsyncThrowingStream<ReplyEvent, Error> {
        record("discuss", context)
        return play(replyEvents)
    }

    public func ask(paper: LoadedPaper, conversation: Conversation, question: String, context: EngineContext) -> AsyncThrowingStream<ReplyEvent, Error> {
        record("ask", context)
        return play(replyEvents)
    }

    public func generateReport(paper: LoadedPaper, session: ReviewSession, context: EngineContext) -> AsyncThrowingStream<ReportEvent, Error> {
        record("report", context)
        return play(reportEvents)
    }

    public func reviseVoice(draft: ReportDraft, findings: [LintFinding], context: EngineContext) -> AsyncThrowingStream<ReportEvent, Error> {
        record("revise", context)
        return play(reportEvents)
    }

    public func lint(reportMarkdown: String) -> [LintFinding] { findings }

    private func record(_ call: String, _ context: EngineContext) {
        lock.withLock {
            recordedCalls.append(call)
            recordedContexts.append(context)
        }
    }

    /// A cold stream of the events. Each element is produced in the consumer's own task, so cancelling that task
    /// interrupts the delay and ends the stream.
    private func play<Event: Sendable>(_ events: [Event]) -> AsyncThrowingStream<Event, Error> {
        let playback = ScriptedPlayback(events: events, delay: delayPerEvent)
        return AsyncThrowingStream(unfolding: { await playback.next() })
    }
}

private actor ScriptedPlayback<Event: Sendable> {
    private let events: [Event]
    private let delay: Duration
    private var position = 0

    init(events: [Event], delay: Duration) {
        self.events = events
        self.delay = delay
    }

    func next() async -> Event? {
        guard position < events.count else { return nil }
        if delay > .zero {
            do { try await Task.sleep(for: delay) } catch { return nil }
        }
        position += 1
        return events[position - 1]
    }
}
