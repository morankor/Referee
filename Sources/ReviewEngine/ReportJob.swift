import Foundation
import RefereeCore

/// The report (plan.md section 6.10) and the voice revision (Appendix B.5): `.started`, the text as `.textDelta`s,
/// then `.finished(draft, run:)`; a `.notice` before a restart with text when the provider refused the PDF.
///
/// On success the draft is the model's Markdown (an outer code fence removed) with the recommendation parsed from it.
/// `versions` is the previous draft's history as it stands: the model pushes the old draft (section WP8b), so the engine
/// does not. A revised draft keeps the revised one's comment ids and versions, and its recommendation when the new
/// text names none. On a failure or a cancellation the draft is the one the job started from (the session's report,
/// or the draft given for revision), so a caller that stores it loses nothing; the run says what happened.
final class ReportJob {
    enum Kind {
        case report(ReviewSession)
        case voiceRevision(ReportDraft, findings: [LintFinding])
    }

    static let noApprovedComments = "Approve at least one comment first."
    static let emptyAnswer = "The model returned an empty report."

    private let dependencies: EngineDependencies
    private let paper: LoadedPaper?
    private let context: EngineContext
    private let kind: Kind
    private let sink: JobSink<ReportEvent>
    private let book: RunBook

    init(dependencies: EngineDependencies, paper: LoadedPaper?, kind: Kind, context: EngineContext, sink: JobSink<ReportEvent>) {
        self.dependencies = dependencies
        self.paper = paper
        self.context = context
        self.kind = kind
        self.sink = sink
        switch kind {
        case .report: book = RunBook(kind: .report, context: context, dependencies: dependencies)
        case .voiceRevision: book = RunBook(kind: .revise, context: context, dependencies: dependencies)
        }
    }

    /// What `.finished` carries when no new text is accepted.
    private var unchanged: ReportDraft {
        switch kind {
        case .report(let session):
            return session.report ?? ReportDraft(markdown: "", userEdited: false)
        case .voiceRevision(let draft, _):
            return draft
        }
    }

    func run() async {
        sink.send(.started(book.run))
        guard let provider = book.provider else { return finish(unchanged, .failed(book.missingProvider.userMessage)) }
        var approved: [ReviewComment] = []
        if case .report(let session) = kind {
            approved = Self.approvedInReportOrder(session.comments, paper: paper?.text)
            guard !approved.isEmpty else { return finish(unchanged, .failed(Self.noApprovedComments)) }
        }
        var forceText = false
        while true {
            let built: (parts: [LLMPart], budget: TokenBudget, sendsPDF: Bool)
            switch kind {
            case .report(let session):
                guard let paper else { return finish(unchanged, .failed(Self.emptyAnswer)) }
                let paperContext = PaperContext(paper: paper, context: context, descriptor: provider.descriptor, anchorPage: nil, job: .report,
                                                dependencies: dependencies, forceText: forceText)
                let task = PromptBuilder.reportTask(comments: approved, meta: session.meta, template: context.prompts.reportTemplate)
                built = (paperContext.parts + [.cacheBoundary, .text(paperContext.taskPrefix + task)], paperContext.budget, paperContext.sendsPDF)
            case .voiceRevision(let draft, let findings):
                let budget = TokenBudget(descriptor: provider.descriptor, settings: context.providerSettings, model: context.model, job: .report,
                                         physicalMemoryBytes: dependencies.physicalMemoryBytes)
                built = ([.text(PromptBuilder.voiceRevisionTask(reportMarkdown: draft.markdown, findings: findings))], budget, false)
            }
            guard built.budget.inputBudget >= Planning.minimumInputBudget else { return finish(unchanged, .failed(Planning.contextTooSmall)) }
            let limits = built.budget.requestLimits(settings: context.providerSettings)
            let request = LLMRequest(model: context.provider.model, system: system, parts: built.parts, maxOutputTokens: limits.maxOutputTokens,
                                     contextWindow: limits.contextWindow, purpose: purpose)
            var text = ""
            do {
                _ = try await book.stream(request, onDelta: { delta in
                    text += delta
                    sink.send(.textDelta(delta))
                })
                let markdown = Self.cleaned(text)
                guard !markdown.isEmpty else { return finish(unchanged, .failed(Self.emptyAnswer)) }
                return finish(draft(markdown, approved: approved), .completed)
            } catch JobInterruption.cancelled {
                return finish(unchanged, .cancelled)
            } catch JobInterruption.failed(let error) {
                if built.sendsPDF, !forceText, text.isEmpty, RunBook.isPDFRejection(error) {
                    forceText = true
                    sink.send(.notice(RunBook.textFallbackNotice(error, job: "the report is written from the text extracted from it")))
                    Log.event("engine.report.textfallback", ["provider": .id(provider.descriptor.id), "error": .id(error.logName)])
                    continue
                }
                return finish(unchanged, .failed(error.userMessage))
            } catch {
                return finish(unchanged, .failed(LLMError.malformedResponse("\(type(of: error))").userMessage))
            }
        }
    }

    private var purpose: RequestPurpose {
        if case .report = kind { return .report }
        return .revise
    }

    private var system: String {
        switch kind {
        case .report: return context.prompts.reportSystem.trimmingCharacters(in: .whitespacesAndNewlines)
        case .voiceRevision: return context.prompts.voiceRevisionSystem.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func draft(_ markdown: String, approved: [ReviewComment]) -> ReportDraft {
        switch kind {
        case .report(let session):
            return ReportDraft(markdown: markdown, recommendation: ReportStructure.recommendation(in: markdown), generatedAt: Date(),
                               provider: context.provider, basedOnCommentIDs: approved.map(\.id), userEdited: false,
                               versions: session.report?.versions ?? [])
        case .voiceRevision(let revised, _):
            return ReportDraft(markdown: markdown, recommendation: ReportStructure.recommendation(in: markdown) ?? revised.recommendation,
                               generatedAt: Date(), provider: context.provider, basedOnCommentIDs: revised.basedOnCommentIDs, userEdited: false,
                               versions: revised.versions)
        }
    }

    private func finish(_ draft: ReportDraft, _ status: RunStatus) {
        sink.finish(final: .finished(draft, run: book.finished(status)))
    }

    /// The model's answer without surrounding whitespace and without an outer code fence (```markdown … ```).
    static func cleaned(_ text: String) -> String {
        var lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        if lines.count >= 2, lines[0].trimmingCharacters(in: .whitespaces).hasPrefix("```"),
           lines[lines.count - 1].trimmingCharacters(in: .whitespaces) == "```" {
            lines.removeFirst()
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Approved comments marked for the report: major, minor, question, strength, each group in document order (by
    /// page, then by the line of the first span in that page's `PageText.lines`, a page-only comment first on its page
    /// and an unanchored one last, then by creation time: the rule of `ReviewSessionModel.visibleComments`).
    static func approvedInReportOrder(_ comments: [ReviewComment], paper: PaperText?) -> [ReviewComment] {
        let rank: [CommentKind: Int] = [.major: 0, .minor: 1, .question: 2, .strength: 3]
        func position(_ comment: ReviewComment) -> (Int, Int) {
            guard let page = comment.anchor.pageIndex else { return (Int.max, 0) }
            guard let span = comment.anchor.spans.first else { return (page, -1) }
            let lines = paper?.pages.first { $0.index == span.pageIndex }?.lines ?? []
            let line = lines.firstIndex { line in
                line.range.location <= span.range.location && span.range.location < max(line.range.upperBound, line.range.location + 1)
            } ?? Int.max - 1
            return (span.pageIndex, line)
        }
        return comments.filter { $0.status == .approved && $0.includeInReport }
            .enumerated()
            .sorted { first, second in
                let a = first.element, b = second.element
                if rank[a.kind]! != rank[b.kind]! { return rank[a.kind]! < rank[b.kind]! }
                let (pageA, lineA) = position(a), (pageB, lineB) = position(b)
                if pageA != pageB { return pageA < pageB }
                if lineA != lineB { return lineA < lineB }
                if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
                return first.offset < second.offset
            }
            .map(\.element)
    }
}
