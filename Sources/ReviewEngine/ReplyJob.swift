import Foundation
import RefereeCore

/// A discussion of one comment (plan.md section 6.8) or a question about a selection (section 6.9):
/// `.started`, the visible reply as `.textDelta`s, then `.finished(reply:proposal:run:)`.
///
/// The request is the paper context, the cache boundary, then the comment or the selected passage, the transcript and
/// the new message, flattened into one user turn (section 5.1). In PDF mode a refused PDF restarts the request once
/// with text, with a `.notice`, provided nothing of the reply has been shown yet. On a failure or a cancellation the
/// reply holds what was shown and the proposal is nil; the run says what happened.
final class ReplyJob {
    enum Subject {
        case discussion(ReviewComment, message: String)
        case question(Conversation, question: String)
    }

    private let dependencies: EngineDependencies
    private let paper: LoadedPaper
    private let context: EngineContext
    private let subject: Subject
    private let sink: JobSink<ReplyEvent>
    private let book: RunBook

    init(dependencies: EngineDependencies, paper: LoadedPaper, subject: Subject, context: EngineContext, sink: JobSink<ReplyEvent>) {
        self.dependencies = dependencies
        self.paper = paper
        self.context = context
        self.subject = subject
        self.sink = sink
        switch subject {
        case .discussion: book = RunBook(kind: .discussion, context: context, dependencies: dependencies)
        case .question: book = RunBook(kind: .question, context: context, dependencies: dependencies)
        }
    }

    private var purpose: RequestPurpose {
        if case .discussion = subject { return .discussion }
        return .question
    }

    private var anchorPage: Int? {
        switch subject {
        case .discussion(let comment, _): return comment.anchor.pageIndex
        case .question(let conversation, _): return conversation.anchor?.pageIndex
        }
    }

    private var system: String {
        switch subject {
        case .discussion: return PromptBuilder.discussionSystem(context)
        case .question: return context.prompts.questionSystem.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private var task: String {
        switch subject {
        case .discussion(let comment, let message):
            return PromptBuilder.discussionTask(comment: comment, message: message, venue: context.venue, meta: context.meta)
        case .question(let conversation, let question):
            return PromptBuilder.questionTask(conversation: conversation, question: question, venue: context.venue, meta: context.meta)
        }
    }

    func run() async {
        sink.send(.started(book.run))
        var parser = ReplyParser(parsesProposal: { if case .discussion = subject { return true } else { return false } }())
        guard let provider = book.provider else { return finish(parser, .failed(book.missingProvider.userMessage)) }
        var forceText = false
        while true {
            let paperContext = PaperContext(paper: paper, context: context, descriptor: provider.descriptor, anchorPage: anchorPage, job: .reply,
                                            dependencies: dependencies, forceText: forceText)
            guard paperContext.budget.inputBudget >= Planning.minimumInputBudget else { return finish(parser, .failed(Planning.contextTooSmall)) }
            let limits = paperContext.budget.requestLimits(settings: context.providerSettings)
            let parts = paperContext.parts + [.cacheBoundary, .text(paperContext.taskPrefix + task)]
            let request = LLMRequest(model: context.provider.model, system: system, parts: parts, maxOutputTokens: limits.maxOutputTokens,
                                     contextWindow: limits.contextWindow, purpose: purpose)
            parser = ReplyParser(parsesProposal: parser.parsesProposal)
            var shownAny = false
            do {
                _ = try await book.stream(request, onDelta: { delta in
                    let shown = parser.feed(delta)
                    if !shown.isEmpty {
                        shownAny = true
                        sink.send(.textDelta(shown))
                    }
                })
                let tail = parser.finish()
                if !tail.isEmpty { sink.send(.textDelta(tail)) }
                return finish(parser, .completed)
            } catch JobInterruption.cancelled {
                return finish(parser, .cancelled)
            } catch JobInterruption.failed(let error) {
                if paperContext.sendsPDF, !forceText, !shownAny, RunBook.isPDFRejection(error) {
                    forceText = true
                    sink.send(.notice(RunBook.textFallbackNotice(error, job: "the answer is based on the text extracted from it")))
                    Log.event("engine.reply.textfallback", ["provider": .id(provider.descriptor.id), "error": .id(error.logName)])
                    continue
                }
                return finish(parser, .failed(error.userMessage))
            } catch {
                return finish(parser, .failed(LLMError.malformedResponse("\(type(of: error))").userMessage))
            }
        }
    }

    private func finish(_ parser: ReplyParser, _ status: RunStatus) {
        var proposal: CommentRevision?
        if case .discussion(let comment, _) = subject, status == .completed {
            proposal = parser.proposal(for: comment)
        }
        let reply = ThreadMessage(id: UUID(), role: .assistant, text: parser.reply, createdAt: Date(), provider: context.provider)
        sink.finish(final: .finished(reply: reply, proposal: proposal, run: book.finished(status)))
    }
}
