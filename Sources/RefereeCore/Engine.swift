import Foundation

/// Everything an engine call needs besides the paper. Built by AppCore from AppSettings at call time.
public struct EngineContext: Sendable, Equatable {
    public var provider: ProviderRef
    public var providerSettings: ProviderSettings
    public var model: ModelInfo?             // the chosen model's entry in the provider's model list; nil = unknown (planning then assumes defaults)
    public var prompts: PromptSet
    public var rubric: [RubricCategory]
    public var meta: ManuscriptMeta
    public var paperDigest: String?          // ReviewSession.paperDigest; the paper context for replies and the report when the paper does not fit
    public var venue: VenueProfile           // the paper's venue (AppSettings.venue(id: meta.venueID)); its kind, name and guidance shape every prompt
    public init(provider: ProviderRef, providerSettings: ProviderSettings, model: ModelInfo? = nil, prompts: PromptSet, rubric: [RubricCategory] = [],
                meta: ManuscriptMeta, paperDigest: String? = nil, venue: VenueProfile = .unspecifiedJournal) {
        self.provider = provider; self.providerSettings = providerSettings; self.model = model; self.prompts = prompts; self.rubric = rubric; self.meta = meta
        self.paperDigest = paperDigest; self.venue = venue
    }
}

public enum ReviewPhase: Sendable, Equatable {
    case preparing
    case reading(part: Int, of: Int)         // 1-based
    case wholePaperPass
}

public struct SendPlan: Sendable, Equatable {
    public var sendsPDF: Bool                // false = extracted text only (equations and tables may be garbled)
    public var requestCount: Int             // 1 = single pass
    public var estimatedInputTokens: Int
    public var destination: String
    public var isLocal: Bool
    public var warnings: [String]            // "Paper will be read in 6 parts", "This PDF is protected, so its text is sent instead of the file", ...
    public var blockingReason: String?       // non-nil = this job cannot run with this provider ("This PDF has no text layer; ..."); the UI disables Review
    public init(sendsPDF: Bool, requestCount: Int, estimatedInputTokens: Int, destination: String, isLocal: Bool, warnings: [String] = [],
                blockingReason: String? = nil) {
        self.sendsPDF = sendsPDF; self.requestCount = requestCount; self.estimatedInputTokens = estimatedInputTokens; self.destination = destination
        self.isLocal = isLocal; self.warnings = warnings; self.blockingReason = blockingReason
    }
}

/// The three event streams of the engine never throw and end with `.finished`, with one exception: a consumer that is
/// cancelled between two events sees its stream end without `.finished` (a cold `AsyncThrowingStream` cannot deliver it
/// then). The consumer records such a run as cancelled itself.
public enum ReviewEvent: Sendable, Equatable {
    case started(RunRecord)
    case phase(ReviewPhase)
    case draft(DraftComment)                           // create-or-update by id while the model writes; a draft that no
                                                       // .comment has replaced when .finished arrives was dropped (a repeat,
                                                       // a third strength comment, a block with neither title nor body): discard it
    case comment(ReviewComment, replacesDraft: UUID)   // parsed, validated, anchored
    case notice(String)                                // user-visible, e.g. "The model ignored the output format."
    case digest(String)                                // the model's notes from a review read in parts; at most once, before .finished
    case finished(RunRecord)                           // last event; status is completed, cancelled or failed
}

public enum ReplyEvent: Sendable, Equatable {
    case started(RunRecord)
    case textDelta(String)
    case notice(String)                                // user-visible, e.g. the provider refused the PDF and the text was sent instead
    case finished(reply: ThreadMessage, proposal: CommentRevision?, run: RunRecord)   // proposal only for discussions
}

public enum ReportEvent: Sendable, Equatable {
    case started(RunRecord)
    case textDelta(String)
    case notice(String)                                // as in ReplyEvent
    case finished(ReportDraft, run: RunRecord)
}

public struct LintFinding: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var range: TextRange              // UTF-16 range in the report Markdown
    public var rule: String                  // "banned-word", "em-dash", "not-only-but-also", ...
    public var message: String
    public init(id: Int, range: TextRange, rule: String, message: String) { self.id = id; self.range = range; self.rule = rule; self.message = message }
}

public protocol ReviewEngineProtocol: Sendable {
    /// No network. Used by the consent card, the toolbar indicator and ReviewSessionModel.canStartReview.
    func plan(paper: LoadedPaper, context: EngineContext) async -> SendPlan
    func review(paper: LoadedPaper, existing: [ReviewComment], context: EngineContext) -> AsyncThrowingStream<ReviewEvent, Error>
    func discuss(paper: LoadedPaper, comment: ReviewComment, message: String, context: EngineContext) -> AsyncThrowingStream<ReplyEvent, Error>
    func ask(paper: LoadedPaper, conversation: Conversation, question: String, context: EngineContext) -> AsyncThrowingStream<ReplyEvent, Error>
    func generateReport(paper: LoadedPaper, session: ReviewSession, context: EngineContext) -> AsyncThrowingStream<ReportEvent, Error>
    /// `draft` is the report being revised: the result is that draft with the new text, its recommendation parsed again
    /// (the old one kept when the new text names none) and its comment ids and versions as they were. For a conference
    /// (`context.venue`) the same holds for `recommendationLabel`, and `recommendation` is nil.
    func reviseVoice(draft: ReportDraft, findings: [LintFinding], context: EngineContext) -> AsyncThrowingStream<ReportEvent, Error>
    func lint(reportMarkdown: String) -> [LintFinding]
    /// The style check of a report written for `venue`: a conference's report has "Chance of acceptance" where a journal's
    /// has "Publication probability", and its recommendation is a label of the venue's scale. Default: the journal rules.
    func lint(reportMarkdown: String, venue: VenueProfile) -> [LintFinding]
}

extension ReviewEngineProtocol {
    public func lint(reportMarkdown: String, venue: VenueProfile) -> [LintFinding] { lint(reportMarkdown: reportMarkdown) }
}
