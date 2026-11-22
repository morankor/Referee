import Foundation
import RefereeCore

// Wave 0 placeholder (plan.md section 11.4, WP0a). WP6 replaces every body with the engine of section 6.
//
// Until then no job sends anything: each stream yields `.started` and then `.finished` with a failed run, and ends
// normally (the caller reads the failure from the run's status, as section 6.6 prescribes). The failed run tells
// apart "the engine found the provider" from "no such provider is registered": its `destination` is the provider's,
// and its message differs.

public final class ReviewEngine: ReviewEngineProtocol {
    private let providers: any ProviderResolving
    private let paperService: any PaperService
    private let matcherFactory: @Sendable (PaperText) -> any QuoteMatching
    private let renderer: any PaperRendering
    private let physicalMemoryBytes: UInt64

    public init(providers: any ProviderResolving, paperService: any PaperService,
                matcherFactory: @escaping @Sendable (PaperText) -> any QuoteMatching, renderer: any PaperRendering,
                physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        self.providers = providers
        self.paperService = paperService
        self.matcherFactory = matcherFactory
        self.renderer = renderer
        self.physicalMemoryBytes = physicalMemoryBytes
    }

    /// Placeholder: one text request of unknown size to the chosen provider, with a warning that nothing will run.
    public func plan(paper: LoadedPaper, context: EngineContext) async -> SendPlan {
        let descriptor = providers.provider(id: context.provider.providerID)?.descriptor
        return SendPlan(sendsPDF: false, requestCount: 1, estimatedInputTokens: 0, destination: descriptor?.destination ?? "",
                        isLocal: descriptor?.isLocal ?? false, warnings: [Self.notImplemented])
    }

    public func review(paper: LoadedPaper, existing: [ReviewComment], context: EngineContext) -> AsyncThrowingStream<ReviewEvent, Error> {
        let (started, failed) = placeholderRun(.review, context)
        return Self.stream([.started(started), .finished(failed)])
    }

    public func discuss(paper: LoadedPaper, comment: ReviewComment, message: String, context: EngineContext) -> AsyncThrowingStream<ReplyEvent, Error> {
        placeholderReply(.discussion, context)
    }

    public func ask(paper: LoadedPaper, conversation: Conversation, question: String, context: EngineContext) -> AsyncThrowingStream<ReplyEvent, Error> {
        placeholderReply(.question, context)
    }

    public func generateReport(paper: LoadedPaper, session: ReviewSession, context: EngineContext) -> AsyncThrowingStream<ReportEvent, Error> {
        let (started, failed) = placeholderRun(.report, context)
        return Self.stream([.started(started), .finished(ReportDraft(markdown: "", userEdited: false), run: failed)])
    }

    /// Placeholder: the report comes back unchanged, with a failed run.
    public func reviseVoice(reportMarkdown: String, findings: [LintFinding], context: EngineContext) -> AsyncThrowingStream<ReportEvent, Error> {
        let (started, failed) = placeholderRun(.revise, context)
        return Self.stream([.started(started), .finished(ReportDraft(markdown: reportMarkdown, userEdited: false), run: failed)])
    }

    /// Placeholder: no findings.
    public func lint(reportMarkdown: String) -> [LintFinding] { [] }

    // ---- placeholder helpers ----

    private static let notImplemented = "The review engine is not implemented yet."

    private func placeholderRun(_ kind: RunKind, _ context: EngineContext) -> (started: RunRecord, failed: RunRecord) {
        let descriptor = providers.provider(id: context.provider.providerID)?.descriptor
        let message = descriptor == nil
            ? LLMError.notConfigured("no provider with the id \(context.provider.providerID) is registered").userMessage
            : Self.notImplemented
        let now = Date()
        let started = RunRecord(id: UUID(), kind: kind, provider: context.provider, destination: descriptor?.destination ?? "", sentPDF: false,
                                requestCount: 0, startedAt: now, status: .running)
        var failed = started
        failed.finishedAt = now
        failed.status = .failed(message)
        return (started, failed)
    }

    private func placeholderReply(_ kind: RunKind, _ context: EngineContext) -> AsyncThrowingStream<ReplyEvent, Error> {
        let (started, failed) = placeholderRun(kind, context)
        let reply = ThreadMessage(id: UUID(), role: .assistant, text: "", createdAt: started.startedAt, provider: context.provider)
        return Self.stream([.started(started), .finished(reply: reply, proposal: nil, run: failed)])
    }

    private static func stream<Event: Sendable>(_ events: [Event]) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}
