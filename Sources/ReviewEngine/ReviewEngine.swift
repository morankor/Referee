import Foundation
import RefereeCore

/// The review engine of plan.md section 6: planning, prompt assembly, the streaming comment parser, the review,
/// discussion, question, report and voice-revision jobs, and the report's style check.
///
/// Every LLM job returns a cold stream (nothing is sent until it is iterated) that ends with one `.finished` event and
/// never throws: a failure is the run's status (section 6.6). Cancelling the consuming task cancels the job; a consumer
/// cancelled while it waits for an event still receives `.finished` with a cancelled run (see `JobStream`).
public final class ReviewEngine: ReviewEngineProtocol {
    private let dependencies: EngineDependencies

    /// `debugDumpDirectory`: where the debug transcript of section 10.5 goes; nil = none. `LiveDependencies` passes the
    /// folder named by `REFEREE_DEBUG_DUMP` in the environment it was given.
    public init(providers: any ProviderResolving, paperService: any PaperService,
                matcherFactory: @escaping @Sendable (PaperText) -> any QuoteMatching, renderer: any PaperRendering,
                physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory, debugDumpDirectory: URL? = nil) {
        dependencies = EngineDependencies(providers: providers, paperService: paperService, matcherFactory: matcherFactory, renderer: renderer,
                                          physicalMemoryBytes: physicalMemoryBytes, debugDump: DebugDump(directory: debugDumpDirectory))
    }

    /// What a review would send now (section 6.4). No network.
    public func plan(paper: LoadedPaper, context: EngineContext) async -> SendPlan {
        guard let provider = dependencies.providers.provider(id: context.provider.providerID) else {
            return SendPlan(sendsPDF: false, requestCount: 0, estimatedInputTokens: 0, destination: "", isLocal: false,
                            blockingReason: LLMError.notConfigured("no provider with the id \(context.provider.providerID) is registered").userMessage)
        }
        let rendered = dependencies.renderer.render(paper.text, pages: nil)
        return Planner.review(descriptor: provider.descriptor, context: context, paper: paper, rendered: rendered, renderer: dependencies.renderer,
                              physicalMemoryBytes: dependencies.physicalMemoryBytes).sendPlan
    }

    public func review(paper: LoadedPaper, existing: [ReviewComment], context: EngineContext) -> AsyncThrowingStream<ReviewEvent, Error> {
        let dependencies = self.dependencies
        return JobStream.make { sink in
            await ReviewJob(dependencies: dependencies, paper: paper, existing: existing, context: context, sink: sink).run()
        }
    }

    public func discuss(paper: LoadedPaper, comment: ReviewComment, message: String, context: EngineContext) -> AsyncThrowingStream<ReplyEvent, Error> {
        let dependencies = self.dependencies
        return JobStream.make { sink in
            await ReplyJob(dependencies: dependencies, paper: paper, subject: .discussion(comment, message: message), context: context, sink: sink).run()
        }
    }

    public func ask(paper: LoadedPaper, conversation: Conversation, question: String, context: EngineContext) -> AsyncThrowingStream<ReplyEvent, Error> {
        let dependencies = self.dependencies
        return JobStream.make { sink in
            await ReplyJob(dependencies: dependencies, paper: paper, subject: .question(conversation, question: question), context: context,
                           sink: sink).run()
        }
    }

    public func generateReport(paper: LoadedPaper, session: ReviewSession, context: EngineContext) -> AsyncThrowingStream<ReportEvent, Error> {
        let dependencies = self.dependencies
        return JobStream.make { sink in
            await ReportJob(dependencies: dependencies, paper: paper, kind: .report(session), context: context, sink: sink).run()
        }
    }

    public func reviseVoice(draft: ReportDraft, findings: [LintFinding], context: EngineContext) -> AsyncThrowingStream<ReportEvent, Error> {
        let dependencies = self.dependencies
        return JobStream.make { sink in
            await ReportJob(dependencies: dependencies, paper: nil, kind: .voiceRevision(draft, findings: findings), context: context, sink: sink).run()
        }
    }

    /// The style check of Appendix B.7; deterministic, no model.
    public func lint(reportMarkdown: String) -> [LintFinding] {
        ReportLinter.lint(reportMarkdown)
    }
}
