import Foundation
import Observation
import RefereeCore

// Wave 0 placeholder (plan.md section 11.4, WP0a): every member of Appendix A.9, as printed there. WP8b writes the model.
//
// Almost every body is empty or returns a neutral value. The exceptions pass the call on to an injected dependency:
// `open(url:)` loads the paper through the paper service and `close()` unloads it (the Wave 0 window and snapshot
// runner need a loaded paper), `reloadSettings` keeps the settings it is given, and `exportReport`, `reportText` and
// `fetchReferencePDF` go to the exporter and the resolver. No session is created, nothing is saved, no job is started.

@MainActor @Observable
public final class ReviewSessionModel {
    private let dependencies: AppDependencies

    // ---- state (read by views) ----
    public private(set) var phase: DocumentPhase = .empty
    public private(set) var paper: LoadedPaper?
    public private(set) var session: ReviewSession?
    public private(set) var citations: CitationIndex?
    public private(set) var settings: AppSettings
    public private(set) var runState: RunState = .idle
    public private(set) var drafts: [DraftComment] = []           // comments being streamed
    public private(set) var streamingReplyText: String = ""       // reply lane: discussion or chat answer in flight
    public private(set) var streamingTargetID: UUID?              // comment or conversation receiving the reply
    public private(set) var streamingReportText: String = ""      // review lane: report or voice revision in flight
    public private(set) var banner: Banner?
    public private(set) var consentRequest: ConsentRequest?
    public private(set) var activeProvider: ProviderDescriptor?   // nil = nothing usable is configured
    public private(set) var activeModel: String?                  // nil = the provider's own default
    public private(set) var sendPlan: SendPlan?                   // what a review would send now; refreshed when paper, provider, model list or settings change
    public private(set) var lintFindings: [LintFinding] = []
    public private(set) var citationLookup: CitationLookup = .idle
    public private(set) var readerCommand: (serial: Int, command: ReaderCommand)?
    public private(set) var selection: SelectionInfo?            // normalised: no margin numbers, watermarks, headers or footers
    public private(set) var composing: ComposingComment?
    public var selectedCommentID: UUID?
    public var openThreadCommentID: UUID?        // the comment whose discussion thread is expanded
    public var editingCommentID: UUID?           // the comment being edited in place
    public var filter: CommentFilter = .all
    public var sidebarTab: SidebarTab = .comments

    // ---- derived ----
    /// Filtered by `filter`, then ordered by page, then by the position of the first span's line in that page's
    /// PageText.lines, then by creation time. A comment with a page but no span (.pageOnly) comes first on its page;
    /// a comment with no page (.none) comes last. This is the only ordering rule; the sidebar and J/K use it.
    public var visibleComments: [ReviewComment] { session?.comments ?? [] }
    public var triage: (decided: Int, total: Int) { (decided: 0, total: 0) }
    public var canStartReview: Bool { false }             // paper ready, review lane idle, a provider is active, and sendPlan?.blockingReason == nil
    public var selectableProviders: [ProviderDescriptor] { [] }   // enabled providers; non-local ones are left out when Local only is on

    public init(dependencies: AppDependencies, settings: AppSettings) {
        self.dependencies = dependencies
        self.settings = settings
    }

    // ---- document ----
    public func open(url: URL) async {
        phase = .loading(fileName: url.lastPathComponent)
        do {
            paper = try await dependencies.paperService.load(url: url)
            phase = .ready
        } catch {
            paper = nil
            phase = .failed(message: (error as? any RefereeError)?.userMessage ?? "The file could not be opened.")
        }
    }
    public func close() async {
        if let paper { await dependencies.paperService.unload(paper.ref) }
        paper = nil
        session = nil
        citations = nil
        phase = .empty
    }
    /// "Delete Review Data…": cancels jobs, deletes sessions/<sha256>/ and that document's lookup cache, then closes.
    public func deleteReviewData() async {}

    // ---- provider & consent ----
    public func setActiveProvider(_ ref: ProviderRef) {}
    public func answerConsent(granted: Bool) {}
    public func reloadSettings(_ settings: AppSettings) { self.settings = settings }   // called by WindowManager on .refereeSettingsDidChange

    // ---- review run ----
    public func startReview() {}                   // asks consent first when required
    public func cancelRun() {}                     // review lane: review, report, voice revision
    public func cancelReply() {}                   // reply lane: discussion, question
    public func retryLastFailedJob() {}

    // ---- triage ----
    public func setStatus(_ status: CommentStatus, for id: UUID) {}
    public func selectNextComment(pendingOnly: Bool) {}
    public func selectPreviousComment() {}
    public func revealSelectedCommentInPDF() {}
    public func setKind(_ kind: CommentKind, for id: UUID) {}
    public func editComment(_ id: UUID, kind: CommentKind, category: String, title: String, body: String, suggestion: String?) {}
    public func deleteComment(_ id: UUID) {}
    public func deletePendingAIComments() {}      // "Clear undecided AI comments" before running a review again
    public func beginComposingComment() {}        // captures the current selection; the sidebar shows the editor card
    public func cancelComposing() {}
    public func addUserComment(kind: CommentKind, category: String, title: String, body: String, anchoredTo selection: SelectionInfo?) {}   // also ends composing
    public func reanchorComment(_ id: UUID, to selection: SelectionInfo) {}
    public func setIncludeInReport(_ include: Bool, for id: UUID) {}

    // ---- discussion ----
    public func sendDiscussionMessage(_ text: String, commentID: UUID) {}
    public func acceptProposedRevision(commentID: UUID) {}
    public func discardProposedRevision(commentID: UUID) {}

    // ---- questions (selection Q&A and general chat) ----
    public func ask(_ question: String, about selection: SelectionInfo?, in conversationID: UUID?) {}
    public func convertReplyToComment(conversationID: UUID, messageID: UUID, kind: CommentKind) {}
    public func deleteConversation(_ id: UUID) {}

    // ---- report ----
    public func generateReport() {}
    public func updateReportMarkdown(_ markdown: String) {}     // user edits; re-lints (debounced)
    public func setRecommendation(_ recommendation: Recommendation?) {}
    public func reviseReportVoice() {}
    public func restoreReportVersion(at index: Int) {}
    public func exportReport(format: ExportFormat, to url: URL) throws {
        try ReportExporter.data(markdown: session?.report?.markdown ?? "", format: format).write(to: url, options: .atomic)
    }
    public func reportText(format: ExportFormat) -> String {
        let markdown = session?.report?.markdown ?? ""
        return format == .plainText ? ReportExporter.plainText(fromMarkdown: markdown) : markdown
    }   // for the pasteboard (.markdown / .plainText)

    // ---- citations ----
    public func lookUpCitation(mentionID: Int) {}
    public func lookUpEntry(entryID: Int) {}
    public func fetchReferencePDF(_ reference: ResolvedReference) async throws -> URL {
        try await dependencies.resolver.fetchPDF(for: reference)
    }

    // ---- called by the PDF view ----
    public func readerSelectionChanged(_ selection: SelectionInfo?) {}   // normalises against paper.text, then refreshes rects
    public func readerClickedComment(_ id: UUID) {}
    public func readerClickedCitation(mentionID: Int) {}

    // ---- misc ----
    public func dismissBanner() {}
    public func dismissTransientUI() {}            // Esc: citation card, composing, editing, open thread, then the PDF selection
    public func updateMeta(_ meta: ManuscriptMeta) {}
    public func flushPendingSave() async {}
}
