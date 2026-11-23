import Foundation
import Observation
import RefereeCore

// The model of one review window (plan.md sections 2.3-2.5, 4.5, 6.3-6.10, 7.4, 9.3-9.9; Appendix A.9; WP8b).
// Views read its properties and call its methods; it reaches the PDF view only through `readerCommand`.
//
// Where the plan leaves a choice, this file decides (all listed in docs/contract-notes/wp8b-models.md):
// - Lanes. A lane is busy from the moment a job is accepted, through its consent card, to the end of its run;
//   `canStartReview` is false meanwhile and a second job for that lane is ignored. `runState` describes the review
//   lane only (`.running` from the start of the run, not while the consent card is up); the reply lane shows through
//   `streamingTargetID`, set while a reply runs.
// - Pre-flight is synchronous: `startReview()` and the other job methods return with the banner or the consent card
//   already in place whenever no plan has to be computed first (Task.immediate).
// - The consent card's plan is `sendPlan` when it was computed for the job's provider and context, else
//   `engine.plan` for that provider. `answerConsent(granted: true)` records consent unless `askAgain` is set ("Ask
//   again next time"). A pending consent card is answered "no" by `cancelRun`/`cancelReply` of its lane and by close.
// - Banners: info notices fade after 6 s; errors and warnings stay until dismissed; a banner never replaces one of a
//   more serious style. Failures: "Review stopped: …", "Report stopped: …", "Voice revision stopped: …",
//   each with Retry; a missing or disabled provider: "Set up an AI provider" (Open Settings); Local only: "Remote
//   providers are blocked by Local only"; both are errors. A failed reply is no banner: `replyFailure` shows it inline.
// - Every run that started is recorded in `session.runs`, also when it was cancelled or its stream threw. A stream that
//   ends without `.finished` was cancelled (Appendix A.6): recorded as cancelled, no banner.
// - A run is recorded when it starts (its `.started` record, status `.running`) and that record is replaced by how it
//   ended (step 5c): the comments of a review under way name that run's own provider and model, whatever the document's
//   provider is meanwhile. A session saved while a run was under way (the app quit or crashed) is still read as usual;
//   when it is opened again, a run left `.running` is marked failed ("The app quit before this run ended.").
// - unload is called once per successful load: by close, and by open when the document it loaded is no longer wanted.
// - Provider status (step 5, O2; docs/contract-notes/step5a-foundation.md): only a local active provider is asked for
//   its `availability()`, whenever the active provider changes and when the window asks. A check of the same provider
//   keeps the last answer until the new one arrives, so the indicator does not flicker; a new provider starts at nil.

@MainActor @Observable
public final class ReviewSessionModel {
    private let dependencies: AppDependencies
    /// Dates and waits (tests inject a clock they advance by hand).
    let clock: any ModelClock

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
    public private(set) var activeAvailability: ProviderAvailability?   // the active provider's status when it is local; nil for a remote one or none (step 5, O2)
    public private(set) var sendPlan: SendPlan?                   // what a review would send now; refreshed when paper, provider, model list or settings change
    public private(set) var lintFindings: [LintFinding] = []
    public private(set) var citationLookup: CitationLookup = .idle
    public private(set) var readerCommand: (serial: Int, command: ReaderCommand)?
    public private(set) var selection: SelectionInfo?            // normalised: no margin numbers, watermarks, headers or footers
    public private(set) var composing: ComposingComment?
    public private(set) var replyFailure: ReplyFailure?          // a reply that failed, shown inline with Retry (sections 9.3, 9.9)
    public private(set) var references: [Int: ResolvedReference] = [:]   // entry id → its latest lookup (References list icons, card)
    public var selectedCommentID: UUID?
    public var openThreadCommentID: UUID?        // the comment whose discussion thread is expanded
    public var editingCommentID: UUID?           // the comment being edited in place
    public var filter: CommentFilter = .all
    public var sidebarTab: SidebarTab = .comments

    // ---- lanes, consent, retry ----
    private var reviewLaneJob: UUID?                                       // observed: `canStartReview` depends on it
    private var replyLaneJob: UUID?
    @ObservationIgnored private(set) var reviewLaneTask: Task<Void, Never>?
    @ObservationIgnored private(set) var replyLaneTask: Task<Void, Never>?
    @ObservationIgnored private var consentContinuation: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var consentLane: ModelLane?
    @ObservationIgnored private(set) var lastFailedJob: ModelJob?          // review lane: the banner's Retry
    @ObservationIgnored private(set) var failedReplyJob: ModelJob?         // reply lane: the inline Retry

    // ---- document, providers, plan ----
    @ObservationIgnored private var matcher: (any QuoteMatching)?
    @ObservationIgnored private var openGeneration = 0
    @ObservationIgnored private var fetchedModels: [ProviderID: [ModelInfo]] = [:]   // lists this window fetched itself
    @ObservationIgnored private var modelListRequested: Set<ProviderID> = []           // once per provider per window
    @ObservationIgnored private var planGeneration = 0
    @ObservationIgnored private var sendPlanContext: EngineContext?                    // the context `sendPlan` was computed for
    @ObservationIgnored private var availabilityGeneration = 0
    @ObservationIgnored private var availabilityProviderID: ProviderID?                // whose status `activeAvailability` holds

    // ---- persistence (section 4.5) ----
    @ObservationIgnored private var persistenceEnabled = false
    @ObservationIgnored private var hasUnsavedChanges = false
    @ObservationIgnored private(set) var autosaveTask: Task<Void, Never>?
    @ObservationIgnored private var saveChain: Task<Void, Never>?

    // ---- other background work ----
    @ObservationIgnored private var backgroundTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private(set) var lintTask: Task<Void, Never>?
    @ObservationIgnored private var bannerFadeTask: Task<Void, Never>?
    @ObservationIgnored private var selectionGeneration = 0
    @ObservationIgnored private var lookupGeneration = 0
    @ObservationIgnored private var readerSerial = 0

    static let autosaveDelay: TimeInterval = 1.0          // section 4.5
    static let lintDelay: TimeInterval = 0.5              // section 6.10
    static let noticeLifetime: TimeInterval = 6.0         // section 9.9
    static let modelListMaxAge: TimeInterval = 86_400     // section 6.4: a cached list older than a day is fetched again

    enum Message {
        static let setUpProvider = "Set up an AI provider"
        static let localOnly = "Remote providers are blocked by Local only"
        static let protectedPDF = "This PDF is protected. Its text is readable, so reviews send the text, not the file."
        static let noTextLayer = "This PDF has no text layer. Comments can be tied to pages only, and only providers that accept PDF files can review it."
        static let approveFirst = "Approve at least one comment first."
        static let interruptedRun = "The app quit before this run ended."
        static func reviewStopped(_ reason: String) -> String { "Review stopped: " + reason }
        static func reportStopped(_ reason: String) -> String { "Report stopped: " + reason }
        static func revisionStopped(_ reason: String) -> String { "Voice revision stopped: " + reason }
    }

    // ---- derived ----
    /// Filtered by `filter`, then ordered by page, then by the position of the first span's line in that page's
    /// PageText.lines, then by creation time. A comment with a page but no span (.pageOnly) comes first on its page;
    /// a comment with no page (.none) comes last. This is the only ordering rule; the sidebar and J/K use it.
    public var visibleComments: [ReviewComment] {
        guard let session else { return [] }
        return CommentOrdering.sorted(session.comments.filter { CommentOrdering.matches($0, filter) }, in: paper?.text)
    }
    public var triage: (decided: Int, total: Int) {
        let comments = session?.comments ?? []
        return (decided: comments.filter { $0.status != .pending }.count, total: comments.count)
    }
    public var canStartReview: Bool {             // paper ready, review lane idle, a provider is active, and sendPlan?.blockingReason == nil
        phase == .ready && paper != nil && session != nil && reviewLaneJob == nil && activeProvider != nil
            && sendPlan != nil && sendPlan?.blockingReason == nil
    }
    public var selectableProviders: [ProviderDescriptor] {   // enabled providers; non-local ones are left out when Local only is on
        registeredProviders.filter { descriptor in
            settings.providers[descriptor.id]?.enabled == true && (!settings.privacy.localOnly || descriptor.isLocal)
        }
    }
    /// The descriptors of every registered provider, in the registry's order, switched on or not and whatever Local only
    /// says (step 5c): what names the provider of an earlier run once it has been switched off (the sidebar's labels of
    /// who wrote a comment, "Sent so far" in the destination menu).
    public var registeredProviders: [ProviderDescriptor] { dependencies.providers.all.map(\.descriptor) }
    /// Where a discussion reply or a chat answer would go now, as `activeProvider` is where a review would: the job's
    /// provider, `session.preferredProvider ?? settings.defaults.chat ?? settings.defaults.review`, if it is registered
    /// and enabled; nil when it is not (the job would then fail with "Set up an AI provider"). Read-only, observable
    /// through `session` and `settings` (step 5, O1: the indicator names it when it differs, design review D4).
    public var chatProvider: ProviderDescriptor? { resolveTarget(for: .chat)?.descriptor }
    /// The same for the report and its voice revision (`settings.defaults.report`).
    public var reportProvider: ProviderDescriptor? { resolveTarget(for: .report)?.descriptor }
    /// True while the document has no provider of its own ("Custom" in the destination menu, what every new document
    /// starts with): each job goes to its default of Settings ▸ Providers, with that default's model (step 5b).
    public var usesCustomProviders: Bool { session?.preferredProvider == nil }

    public init(dependencies: AppDependencies, settings: AppSettings) {
        self.dependencies = dependencies
        self.settings = settings
        self.clock = SystemModelClock()
        refreshPlan()
    }

    /// For tests: the same model on a clock of the caller's.
    init(dependencies: AppDependencies, settings: AppSettings, clock: any ModelClock) {
        self.dependencies = dependencies
        self.settings = settings
        self.clock = clock
        refreshPlan()
    }

    // ---- document ----

    /// `.loading` → the paper → its session by hash (or a new one) → anchors that have a quote but no spans located
    /// again → the citation index, off the main actor, with rectangles for text mentions → the plan → `.ready`.
    public func open(url: URL) async {
        if phase != .empty || paper != nil || session != nil { await close() }
        openGeneration += 1
        let generation = openGeneration
        phase = .loading(fileName: url.lastPathComponent)

        let loaded: LoadedPaper
        do {
            loaded = try await dependencies.paperService.load(url: url)
        } catch {
            guard generation == openGeneration else { return }
            phase = .failed(message: Self.message(for: error, otherwise: "The file could not be opened."))
            return
        }
        guard generation == openGeneration else {
            // Closed or replaced while loading: `close` did not see this paper, so it is unloaded here (one unload per load).
            await dependencies.paperService.unload(loaded.ref)
            return
        }
        paper = loaded
        Log.event("model.open", ["pages": .int(loaded.ref.pageCount), "encrypted": .bool(loaded.isEncrypted)])

        var stored: ReviewSession?
        var storeProblem: String?
        var persist = true
        var recovery: String?
        do {
            stored = try await dependencies.sessions.loadSession(sha256: loaded.ref.sha256)
            recovery = await dependencies.sessions.recoveryNotice(sha256: loaded.ref.sha256)
        } catch {
            storeProblem = Self.message(for: error, otherwise: "The saved review could not be read.")
            // A damaged file has been moved aside by the store, so a new session may take its place. Anything else (a
            // newer format, an I/O error) leaves the file untouched: this window keeps its session in memory only.
            if let storeError = error as? StoreError, case .corrupt = storeError { persist = true } else { persist = false }
        }
        guard generation == openGeneration else { return }

        let now = clock.now()
        var session: ReviewSession
        var changed: Bool
        if var existing = stored {
            changed = existing.document.lastKnownPath != url.path || existing.document.fileName != url.lastPathComponent
            existing.document.lastKnownPath = url.path
            existing.document.fileName = url.lastPathComponent
            session = existing
        } else {
            var document = loaded.ref
            document.fileName = url.lastPathComponent
            document.lastKnownPath = url.path
            session = ReviewSession(schemaVersion: 1, id: UUID(), document: document,
                                    meta: ManuscriptMeta(title: loaded.text.titleGuess, reviewerNotes: ""), createdAt: now, updatedAt: now)
            changed = true
        }

        // No run of this document can be under way while it opens: one still `.running` was cut off when the app quit.
        for index in session.runs.indices where session.runs[index].status == .running {
            session.runs[index].status = .failed(Message.interruptedRun)
            changed = true
        }

        let matcher = await Self.makeMatcher(dependencies.matcherFactory, for: loaded.text)
        guard generation == openGeneration else { return }
        self.matcher = matcher
        if await healAnchors(of: &session, with: matcher, paper: loaded) { changed = true }
        guard generation == openGeneration else { return }

        let index = await fillMentionRects(of: await Self.buildIndex(dependencies.citationIndexer, for: loaded), paper: loaded)
        guard generation == openGeneration else { return }

        persistenceEnabled = persist
        if changed { session.updatedAt = now }
        self.session = session
        if changed { scheduleAutosave() }
        citations = index
        lintFindings = session.report.map { dependencies.engine.lint(reportMarkdown: $0.markdown) } ?? []
        await refreshPlan()?.value
        guard generation == openGeneration else { return }
        phase = .ready

        if loaded.isEncrypted { showBanner(.info, Message.protectedPDF) }
        if !loaded.text.hasTextLayer { showBanner(.warning, Message.noTextLayer) }
        if let recovery { showBanner(.warning, recovery) }                       // section 4.5: the backup was loaded
        if let storeProblem { showBanner(.error, storeProblem) }
        if settings.privacy.resolveReferencesInBackground { lookUpAllReferences() }   // section 8.7, off by default
    }

    /// Answers a pending consent card with "no", stops both lanes, saves what is pending, and forgets the document.
    public func close() async {
        openGeneration += 1
        resolveConsent(granted: false)
        let lanes = [reviewLaneTask, replyLaneTask]
        for lane in lanes { lane?.cancel() }
        for lane in lanes { await lane?.value }
        for task in backgroundTasks.values { task.cancel() }
        lintTask?.cancel()
        bannerFadeTask?.cancel()
        await flushPendingSave()
        if let paper { await dependencies.paperService.unload(paper.ref) }

        phase = .empty
        paper = nil
        session = nil
        citations = nil
        runState = .idle
        drafts = []
        streamingReplyText = ""
        streamingTargetID = nil
        streamingReportText = ""
        banner = nil
        consentRequest = nil
        lintFindings = []
        citationLookup = .idle
        selection = nil
        composing = nil
        replyFailure = nil
        references = [:]
        selectedCommentID = nil
        openThreadCommentID = nil
        editingCommentID = nil
        matcher = nil
        lastFailedJob = nil
        failedReplyJob = nil
        persistenceEnabled = false
        hasUnsavedChanges = false
        refreshPlan()
    }

    /// "Delete Review Data…": cancels jobs, deletes sessions/<sha256>/ and that document's lookup cache, then closes.
    public func deleteReviewData() async {
        guard let sha256 = session?.document.sha256 ?? paper?.ref.sha256 else {
            await close()
            return
        }
        // Nothing may be written from here on, or the folder would come back.
        persistenceEnabled = false
        hasUnsavedChanges = false
        autosaveTask?.cancel()
        autosaveTask = nil
        resolveConsent(granted: false)
        let lanes = [reviewLaneTask, replyLaneTask]
        for lane in lanes { lane?.cancel() }
        for lane in lanes { await lane?.value }
        await saveChain?.value
        do {
            try await dependencies.sessions.deleteSession(sha256: sha256)
        } catch {
            Log.event("model.delete.failed")
        }
        await dependencies.resolver.forget(documentSHA256: sha256)
        await close()
    }

    // ---- provider & consent ----

    /// The destination menu's choice for this document, stored as `session.preferredProvider`. Only a provider of
    /// `selectableProviders` can be chosen.
    public func setActiveProvider(_ ref: ProviderRef) {
        guard session != nil, selectableProviders.contains(where: { $0.id == ref.providerID }) else { return }
        mutateSession { $0.preferredProvider = ref }
        refreshPlan()
    }

    /// "Custom" in the destination menu (step 5b): the document's own choice goes, so that each job (review, chat,
    /// report) goes to its own default of Settings ▸ Providers again. Nothing else of the session changes.
    public func useCustomProviders() {
        guard session?.preferredProvider != nil else { return }
        mutateSession { $0.preferredProvider = nil }
        refreshPlan()
    }

    /// The consent card's answer. Yes lets the job run and records consent for the provider in this session, unless
    /// `askAgain` ("Ask again next time" ticked): then the next job to that provider asks again. No leaves everything
    /// as it was.
    public func answerConsent(granted: Bool, askAgain: Bool = false) {
        guard let request = consentRequest else { return }
        if granted, !askAgain, session?.consents.contains(where: { $0.providerID == request.provider.id }) == false {
            let record = ConsentRecord(providerID: request.provider.id, grantedAt: clock.now())
            mutateSession { $0.consents.append(record) }
        }
        resolveConsent(granted: granted)
    }

    public func reloadSettings(_ settings: AppSettings) {   // called by WindowManager on .refereeSettingsDidChange
        guard settings != self.settings else { return }
        self.settings = settings
        refreshPlan()
    }

    /// Fills `activeAvailability` (step 5, O2). A local active provider is asked for its `availability()`, which costs
    /// nothing (Ollama: `/api/version` on loopback, 2 s, no key read). A remote provider, or none, is never asked (an
    /// API provider's check reads the Keychain, a CLI's starts a process): `activeAvailability` becomes nil at once.
    /// The model calls this whenever the active provider changes; the window calls it when the app becomes active and
    /// when the destination menu opens (D13). While the answer is on its way, the last answer of the same provider
    /// stays; a provider not asked before has nil.
    public func refreshActiveAvailability() {
        availabilityGeneration += 1
        let generation = availabilityGeneration
        guard let descriptor = activeProvider, descriptor.isLocal, let provider = dependencies.providers.provider(id: descriptor.id) else {
            availabilityProviderID = nil
            if activeAvailability != nil { activeAvailability = nil }
            return
        }
        if availabilityProviderID != descriptor.id {
            availabilityProviderID = descriptor.id
            if activeAvailability != nil { activeAvailability = nil }
        }
        track { [weak self] in
            let status = await Self.availability(of: provider)
            guard let self, generation == self.availabilityGeneration, self.activeProvider?.id == descriptor.id else { return }
            if self.activeAvailability != status { self.activeAvailability = status }
        }
    }

    // ---- review run ----

    public func startReview() {                   // asks consent first when required
        start(.review)
    }

    public func cancelRun() {                     // review lane: review, report, voice revision
        cancelLane(.review)
    }

    public func cancelReply() {                   // reply lane: discussion, question
        cancelLane(.reply)
    }

    /// Runs again the review-lane job whose failure the banner reports.
    public func retryLastFailedJob() {
        guard let job = lastFailedJob, laneJob(job.lane) == nil else { return }
        lastFailedJob = nil
        if banner?.action == .retry { dismissBanner() }
        start(job)
    }

    /// Sends again the discussion message or question whose reply failed (`replyFailure`); the message is not added
    /// to the thread a second time.
    public func retryFailedReply() {
        guard let job = failedReplyJob, laneJob(.reply) == nil else { return }
        failedReplyJob = nil
        replyFailure = nil
        start(job)
    }

    // ---- triage ----

    /// Approving also includes the comment in the report. After a decision (approve or reject), with
    /// "Advance after decision" on, the next pending comment in visible order is selected and revealed.
    public func setStatus(_ status: CommentStatus, for id: UUID) {
        guard session?.comments.contains(where: { $0.id == id }) == true else { return }
        updateComment(id) { comment in
            comment.status = status
            if status == .approved { comment.includeInReport = true }
        }
        guard status != .pending, settings.ui.autoAdvanceAfterTriage, let next = nextPending(after: id) else { return }
        selectedCommentID = next
        revealSelectedCommentInPDF()
    }

    /// The next comment of `visibleComments` after the selected one (the first when none is selected), selected and
    /// revealed. `pendingOnly`: the next pending one, wrapping round to the first.
    public func selectNextComment(pendingOnly: Bool) {
        let candidates = visibleComments.filter { !pendingOnly || $0.status == .pending }
        guard let first = candidates.first else { return }
        let ordered = orderedComments
        guard let selected = selectedCommentID, let position = ordered.firstIndex(where: { $0.id == selected }) else {
            select(first.id)
            return
        }
        let ids = Set(candidates.map(\.id))
        if let next = ordered[(position + 1)...].first(where: { ids.contains($0.id) }) {
            select(next.id)
        } else if pendingOnly, first.id != selected {
            select(first.id)
        }
    }

    /// The comment of `visibleComments` before the selected one (the last when none is selected), selected and revealed.
    public func selectPreviousComment() {
        let candidates = visibleComments
        guard let last = candidates.last else { return }
        let ordered = orderedComments
        guard let selected = selectedCommentID, let position = ordered.firstIndex(where: { $0.id == selected }) else {
            select(last.id)
            return
        }
        let ids = Set(candidates.map(\.id))
        if let previous = ordered[..<position].last(where: { ids.contains($0.id) }) { select(previous.id) }
    }

    /// `.reveal` of the selected comment's rectangles, or `.goToPage` when it has none.
    public func revealSelectedCommentInPDF() {
        guard let id = selectedCommentID, let anchor = session?.comments.first(where: { $0.id == id })?.anchor else { return }
        reveal(anchor)
    }

    /// The Chat tab's quoted passage (section 9.5): `.reveal` of the conversation's rectangles, or `.goToPage`. A
    /// conversation about the whole paper has no passage.
    public func revealConversationInPDF(_ id: UUID) {
        guard let anchor = session?.conversations.first(where: { $0.id == id })?.anchor else { return }
        reveal(anchor)
    }

    private func reveal(_ anchor: Anchor) {
        if !anchor.rects.isEmpty {
            issue(.reveal(rects: anchor.rects, flash: true))
        } else if let page = anchor.spans.first?.pageIndex ?? anchor.pageIndex {
            issue(.goToPage(page))
        }
    }

    public func setKind(_ kind: CommentKind, for id: UUID) {
        updateComment(id) { $0.kind = kind }
    }

    /// Saves an edit; the version before it goes to `previousVersions` (at most 20). Ends editing of that comment.
    public func editComment(_ id: UUID, kind: CommentKind, category: String, title: String, body: String, suggestion: String?) {
        if editingCommentID == id { editingCommentID = nil }
        let suggestion = ModelSupport.cleanedSuggestion(suggestion)
        guard let current = session?.comments.first(where: { $0.id == id }),
              current.kind != kind || current.category != category || current.title != title || current.body != body
                || current.suggestion != suggestion else { return }
        updateComment(id) { comment in
            ModelSupport.pushCurrentVersion(of: &comment)
            comment.kind = kind
            comment.category = category
            comment.title = title
            comment.body = body
            comment.suggestion = suggestion
        }
    }

    public func deleteComment(_ id: UUID) {
        removeComments { $0.id == id }
    }

    public func deletePendingAIComments() {      // "Clear undecided AI comments" before running a review again
        removeComments { comment in
            if case .ai = comment.origin { return comment.status == .pending }
            return false
        }
    }

    public func beginComposingComment() {        // captures the current selection; the sidebar shows the editor card
        composing = ComposingComment(selection: selection)
        sidebarTab = .comments
    }

    public func cancelComposing() {
        composing = nil
    }

    /// An own comment: approved, included in the report, anchored to the normalised selection (confidence `.exact`,
    /// label from the matcher), or unanchored (`quote == ""`, `.none`) without one. A blank suggestion is none, as in
    /// `editComment`; the parameter was added at Wave 3, so that the composing card can have a suggestion editor.
    public func addUserComment(kind: CommentKind, category: String, title: String, body: String, suggestion: String? = nil,
                               anchoredTo selection: SelectionInfo?) {   // also ends composing
        composing = nil
        guard session != nil, let paper else { return }
        let now = clock.now()
        let anchor = self.anchor(from: selection, in: paper) ?? Anchor(quote: "", confidence: .none, locationLabel: "")
        let comment = ReviewComment(id: UUID(), origin: .user, status: .approved, kind: kind, category: category, title: title, body: body,
                                    suggestion: ModelSupport.cleanedSuggestion(suggestion), anchor: anchor, includeInReport: true,
                                    createdAt: now, updatedAt: now)
        mutateSession { $0.comments.append(comment) }
        fillRectsIfNeeded(for: .comment(comment.id))
    }

    /// "Attach to selection": the comment's anchor becomes the normalised selection, its quote included.
    public func reanchorComment(_ id: UUID, to selection: SelectionInfo) {
        guard let paper, let anchor = anchor(from: selection, in: paper) else { return }
        updateComment(id) { $0.anchor = anchor }
        fillRectsIfNeeded(for: .comment(id))
    }

    public func setIncludeInReport(_ include: Bool, for id: UUID) {
        updateComment(id) { $0.includeInReport = include }
    }

    // ---- discussion ----

    /// The message joins the thread once the job may run; the reply streams into `streamingReplyText`.
    public func sendDiscussionMessage(_ text: String, commentID: UUID) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, session?.comments.contains(where: { $0.id == commentID }) == true else { return }
        start(.discussion(commentID: commentID, message: message, sentMessageID: nil))
    }

    /// Pushes the current version, applies kind, title, body and suggestion, keeps anchor and status (section 6.8).
    /// A proposed withdrawal rejects the comment instead.
    public func acceptProposedRevision(commentID: UUID) {
        guard let proposal = session?.comments.first(where: { $0.id == commentID })?.proposedRevision else { return }
        updateComment(commentID) { comment in
            if proposal.withdraw {
                comment.status = .rejected
            } else {
                ModelSupport.pushCurrentVersion(of: &comment)
                comment.kind = proposal.kind
                comment.title = proposal.title
                comment.body = proposal.body
                comment.suggestion = proposal.suggestion
            }
            comment.proposedRevision = nil
        }
    }

    public func discardProposedRevision(commentID: UUID) {
        updateComment(commentID) { $0.proposedRevision = nil }
    }

    // ---- questions (selection Q&A and general chat) ----

    /// A follow-up in `conversationID`, or a new conversation anchored to the normalised selection (nil = about the
    /// whole paper). The Chat tab opens when the question is sent.
    public func ask(_ question: String, about selection: SelectionInfo?, in conversationID: UUID?) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, session != nil else { return }
        if let conversationID, session?.conversations.contains(where: { $0.id == conversationID }) != true { return }
        sidebarTab = .chat
        start(.question(conversationID: conversationID, selection: conversationID == nil ? selection : nil, question: question, sentMessageID: nil))
    }

    /// A pending own comment of `kind` and category "other": the answer's text as body, its first ten words as title,
    /// anchored where the conversation is.
    public func convertReplyToComment(conversationID: UUID, messageID: UUID, kind: CommentKind) {
        guard let conversation = session?.conversations.first(where: { $0.id == conversationID }),
              let message = conversation.messages.first(where: { $0.id == messageID }) else { return }
        let body = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let now = clock.now()
        let comment = ReviewComment(id: UUID(), origin: .user, status: .pending, kind: kind, category: "other",
                                    title: ModelSupport.title(fromBody: body), body: body,
                                    anchor: conversation.anchor ?? Anchor(quote: "", confidence: .none, locationLabel: ""),
                                    includeInReport: true, createdAt: now, updatedAt: now)
        mutateSession { $0.comments.append(comment) }
    }

    public func deleteConversation(_ id: UUID) {
        if streamingTargetID == id { cancelReply() }
        if replyFailure?.targetID == id { clearReplyFailure() }
        mutateSession { $0.conversations.removeAll { $0.id == id } }
    }

    // ---- report ----

    /// Runs only when at least one comment is approved and included (otherwise an info banner says so). The new draft
    /// replaces `session.report` at the end; the old one goes to `versions` ("before regenerate", at most 10).
    public func generateReport() {
        guard let session else { return }
        guard session.comments.contains(where: { $0.status == .approved && $0.includeInReport }) else {
            showBanner(.info, Message.approveFirst)
            return
        }
        start(.report)
    }

    public func updateReportMarkdown(_ markdown: String) {     // user edits; re-lints (debounced)
        guard let session, session.report?.markdown != markdown else { return }
        mutateSession { session in
            if session.report == nil {
                session.report = ReportDraft(markdown: markdown, userEdited: true)
            } else {
                session.report?.markdown = markdown
                session.report?.userEdited = true
            }
        }
        scheduleLint(of: markdown)
    }

    public func setRecommendation(_ recommendation: Recommendation?) {
        guard session?.report != nil else { return }
        mutateSession { $0.report?.recommendation = recommendation }
    }

    public func reviseReportVoice() {
        guard let report = session?.report, !report.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        start(.reviseVoice)
    }

    /// The version's text becomes the draft (marked as edited); the text it replaces is kept as a version ("before restore").
    public func restoreReportVersion(at index: Int) {
        guard var report = session?.report, report.versions.indices.contains(index) else { return }
        let restored = report.versions[index]
        report.versions = ModelSupport.versions(afterSaving: report, note: "before restore", at: clock.now())
        report.markdown = restored.markdown
        report.recommendation = ModelSupport.recommendation(in: restored.markdown)
        report.userEdited = true
        mutateSession { $0.report = report }
        lint(report.markdown)
    }

    /// Throws `ExportError`.
    public func exportReport(format: ExportFormat, to url: URL) throws {
        let data = try ReportExporter.data(markdown: session?.report?.markdown ?? "", format: format)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ExportError.couldNotWrite(error.localizedDescription)
        }
    }

    public func reportText(format: ExportFormat) -> String {   // for the pasteboard (.markdown / .plainText)
        let markdown = session?.report?.markdown ?? ""
        return format == .plainText ? ReportExporter.plainText(fromMarkdown: markdown) : markdown
    }

    // ---- citations ----

    /// `.resolving(target: .mention(id))`, then every candidate entry resolved at once, then `.resolved`.
    public func lookUpCitation(mentionID: Int) {
        guard let paper, let index = citations, let mention = index.mentions.first(where: { $0.id == mentionID }) else { return }
        let entries = mention.entryIDs.compactMap { id in index.entries.first { $0.id == id } }
        resolve(entries, for: .mention(mentionID), document: paper.ref.sha256)
    }

    /// `.resolving(target: .entry(id))`, then `.resolved` with that entry alone.
    public func lookUpEntry(entryID: Int) {
        guard let paper, let entry = citations?.entries.first(where: { $0.id == entryID }) else { return }
        resolve([entry], for: .entry(entryID), document: paper.ref.sha256)
    }

    public func fetchReferencePDF(_ reference: ResolvedReference) async throws -> URL {
        try await dependencies.resolver.fetchPDF(for: reference)
    }

    /// The card's "Search Google Scholar" (section 8.6): `ReferenceResolving.searchURL(for:)`. No request is made.
    public func searchURL(for entry: BibEntry) -> URL {
        dependencies.resolver.searchURL(for: entry)
    }

    // ---- called by the PDF view ----

    /// Normalises against `paper.text` and publishes the result at once, with empty rectangles; they follow from
    /// `PaperService.rects`. A selection that normalises to nothing is nil.
    public func readerSelectionChanged(_ selection: SelectionInfo?) {   // normalises against paper.text, then refreshes rects
        selectionGeneration += 1
        let generation = selectionGeneration
        guard let selection, let paper, let normalised = SelectionNormalizer.normalize(selection, in: paper.text) else {
            if self.selection != nil { self.selection = nil }
            return
        }
        self.selection = normalised
        let service = dependencies.paperService
        track { [weak self] in
            let rects = await service.rects(for: normalised.spans, in: paper.ref)
            guard let self, generation == self.selectionGeneration else { return }
            self.selection?.rects = rects
        }
    }

    /// Selects the comment and shows the Comments tab; a conversation's passage shows the Chat tab.
    public func readerClickedComment(_ id: UUID) {
        if session?.comments.contains(where: { $0.id == id }) == true {
            selectedCommentID = id
            sidebarTab = .comments
        } else if session?.conversations.contains(where: { $0.id == id }) == true {
            sidebarTab = .chat
        }
    }

    public func readerClickedCitation(mentionID: Int) {
        lookUpCitation(mentionID: mentionID)
    }

    // ---- misc ----

    public func dismissBanner() {
        bannerFadeTask?.cancel()
        bannerFadeTask = nil
        banner = nil
    }

    /// Closes the citation card and nothing else (Wave 3): the reader calls it on a click elsewhere in the PDF, a page
    /// change, or a mention scrolled out of sight. A lookup still under way is forgotten, so its card does not come back.
    public func dismissCitationLookup() {
        guard citationLookup != .idle else { return }
        lookupGeneration += 1
        citationLookup = .idle
    }

    public func dismissTransientUI() {            // Esc: citation card, composing, editing, open thread, then the PDF selection
        if citationLookup != .idle {
            dismissCitationLookup()
        } else if composing != nil {
            composing = nil
        } else if editingCommentID != nil {
            editingCommentID = nil
        } else if openThreadCommentID != nil {
            openThreadCommentID = nil
        } else if selection != nil {
            selectionGeneration += 1
            selection = nil
            issue(.clearSelection)
        }
    }

    public func updateMeta(_ meta: ManuscriptMeta) {
        mutateSession { $0.meta = meta }
    }

    /// Writes pending changes now, and waits for a save already under way.
    public func flushPendingSave() async {
        autosaveTask?.cancel()
        autosaveTask = nil
        if hasUnsavedChanges && persistenceEnabled {
            await save()
        } else {
            await saveChain?.value
        }
    }

    // =================================================================================================================
    // ---- jobs (section 2.3: two lanes; section 9.7: one gate) ----

    private func laneJob(_ lane: ModelLane) -> UUID? {
        lane == .review ? reviewLaneJob : replyLaneJob
    }

    private func setLaneJob(_ token: UUID?, task: Task<Void, Never>?, of lane: ModelLane) {
        switch lane {
        case .review:
            reviewLaneJob = token
            reviewLaneTask = task
        case .reply:
            replyLaneJob = token
            replyLaneTask = task
        }
    }

    /// Starting a job in a busy lane is ignored (the UI disables the buttons).
    private func start(_ job: ModelJob) {
        guard phase == .ready, paper != nil, session != nil, laneJob(job.lane) == nil else { return }
        let token = UUID()
        setLaneJob(token, task: nil, of: job.lane)
        let task = Task.immediate { [weak self] in
            await self?.execute(job)
            self?.endLane(job.lane, token: token)
        }
        if laneJob(job.lane) == token { setLaneJob(token, task: task, of: job.lane) }
    }

    private func endLane(_ lane: ModelLane, token: UUID) {
        guard laneJob(lane) == token else { return }
        setLaneJob(nil, task: nil, of: lane)
    }

    private func cancelLane(_ lane: ModelLane) {
        if consentLane == lane { resolveConsent(granted: false) }
        (lane == .review ? reviewLaneTask : replyLaneTask)?.cancel()
    }

    private func execute(_ job: ModelJob) async {
        guard let target = resolveTarget(for: job.task) else {
            showBanner(.error, Message.setUpProvider, action: .openSettings)
            return
        }
        requestModelList(for: target.descriptor)
        guard await authorize(job: PendingJob(job: job, target: target)), !Task.isCancelled else { return }
        if job.lane == .review { runState = .running(kind: job.runKind, phase: nil, startedAt: clock.now()) }
        await flushPendingSave()                                // section 4.5: before any run starts
        // The context is built again: the consent card may have been up for a while.
        guard !Task.isCancelled, let paper, session != nil, let current = resolveTarget(for: job.task),
              current.descriptor.id == target.descriptor.id else {
            if job.lane == .review { runState = .idle }
            return
        }
        Log.event("model.run.start", ["kind": .id(job.runKind.rawValue), "provider": .id(current.descriptor.id)])
        switch job {
        case .review:
            await runReview(current, paper: paper)
        case .report:
            await runReport(current, paper: paper, revising: false)
        case .reviseVoice:
            await runReport(current, paper: paper, revising: true)
        case .discussion(let commentID, let message, let sentMessageID):
            await runDiscussion(commentID: commentID, message: message, sentMessageID: sentMessageID, target: current, paper: paper)
        case .question(let conversationID, let selection, let question, let sentMessageID):
            await runQuestion(conversationID: conversationID, selection: selection, question: question, sentMessageID: sentMessageID,
                              target: current, paper: paper)
        }
    }

    /// The one gate every job passes before anything is sent (section 9.7): Local only blocks a non-local provider
    /// with a banner; a non-local provider not yet in `session.consents` needs the consent card's yes when
    /// "Ask before the first send of each document" is on. Local providers never ask.
    private func authorize(job pending: PendingJob) async -> Bool {
        let provider = pending.target.descriptor
        if settings.privacy.localOnly && !provider.isLocal {
            showBanner(.error, Message.localOnly)
            return false
        }
        guard let session, let paper else { return false }
        if provider.isLocal || !settings.privacy.confirmFirstSendPerDocument
            || session.consents.contains(where: { $0.providerID == provider.id }) {
            return true
        }
        guard consentRequest == nil, consentContinuation == nil else { return false }    // one card at a time
        let plan: SendPlan
        if let sendPlan, sendPlanContext == pending.target.context {
            plan = sendPlan
        } else {
            plan = await dependencies.engine.plan(paper: paper, context: pending.target.context)
            guard !Task.isCancelled, self.session != nil, consentRequest == nil, consentContinuation == nil else { return false }
        }
        consentRequest = ConsentRequest(provider: provider, model: pending.target.ref.model, plan: plan)
        consentLane = pending.job.lane
        return await withCheckedContinuation { continuation in
            consentContinuation = continuation
        }
    }

    private func resolveConsent(granted: Bool) {
        consentRequest = nil
        consentLane = nil
        let continuation = consentContinuation
        consentContinuation = nil
        continuation?.resume(returning: granted)
    }

    /// The provider of a job: `session.preferredProvider ?? settings.defaults.<job> ?? settings.defaults.review`, if it
    /// is registered and enabled; with the engine context of section 6.1 for it.
    private func resolveTarget(for task: ModelTask) -> JobTarget? {
        let defaults = settings.defaults
        let jobDefault: ProviderRef?
        switch task {
        case .review: jobDefault = defaults.review
        case .chat: jobDefault = defaults.chat
        case .report: jobDefault = defaults.report
        }
        guard let ref = session?.preferredProvider ?? jobDefault ?? defaults.review,
              let provider = dependencies.providers.provider(id: ref.providerID),
              let providerSettings = settings.providers[ref.providerID], providerSettings.enabled else { return nil }
        let modelID = ref.model ?? providerSettings.model
        let context = EngineContext(provider: ProviderRef(providerID: ref.providerID, model: modelID), providerSettings: providerSettings,
                                    model: modelInfo(providerID: ref.providerID, modelID: modelID), prompts: settings.prompts,
                                    rubric: settings.rubric, meta: session?.meta ?? ManuscriptMeta(reviewerNotes: ""),
                                    paperDigest: session?.paperDigest)
        return JobTarget(descriptor: provider.descriptor, context: context)
    }

    /// The entry for the chosen model id: from a fresh `cachedModels`, else from the list this window fetched, else from
    /// a stale cache. nil until a list has it (planning then assumes its defaults, section 6.4).
    private func modelInfo(providerID: ProviderID, modelID: String?) -> ModelInfo? {
        guard let modelID else { return nil }
        let cached = settings.providers[providerID]?.cachedModels ?? []
        let fetched = fetchedModels[providerID] ?? []
        for list in cachedModelsAreFresh(for: providerID) ? [cached, fetched] : [fetched, cached] {
            if let entry = list.first(where: { $0.id == modelID }) { return entry }
        }
        return nil
    }

    private func cachedModelsAreFresh(for providerID: ProviderID) -> Bool {
        guard let entry = settings.providers[providerID], !entry.cachedModels.isEmpty, let fetchedAt = entry.cachedModelsAt else { return false }
        return clock.now().timeIntervalSince(fetchedAt) <= Self.modelListMaxAge
    }

    /// `listModels()` once per provider per window, when the cached list is empty or more than a day old; never for a
    /// non-local provider while Local only is on. The plan is computed again when the list arrives.
    private func requestModelList(for descriptor: ProviderDescriptor) {
        let id = descriptor.id
        guard !modelListRequested.contains(id), !cachedModelsAreFresh(for: id), !settings.privacy.localOnly || descriptor.isLocal,
              let provider = dependencies.providers.provider(id: id) else { return }
        modelListRequested.insert(id)
        track { [weak self] in
            let list = try? await provider.listModels()
            guard let self else { return }
            self.fetchedModels[id] = list ?? []
            if list?.isEmpty == false, self.activeProvider?.id == id { self.refreshPlan() }
        }
    }

    /// The review provider and model shown by the destination indicator, and `sendPlan` for them. A plan computed for
    /// another provider or model is dropped at once; the new one follows. A new provider is asked for its status
    /// (`refreshActiveAvailability()`, local providers only).
    @discardableResult
    private func refreshPlan() -> Task<Void, Never>? {
        planGeneration += 1
        let generation = planGeneration
        let target = resolveTarget(for: .review)
        if activeProvider != target?.descriptor {
            activeProvider = target?.descriptor
            refreshActiveAvailability()
        }
        if activeModel != target?.ref.model { activeModel = target?.ref.model }
        guard let target, let paper else {
            if sendPlan != nil { sendPlan = nil }
            sendPlanContext = nil
            return nil
        }
        if sendPlanContext?.provider != target.ref {
            if sendPlan != nil { sendPlan = nil }
            sendPlanContext = nil
        }
        requestModelList(for: target.descriptor)
        let engine = dependencies.engine
        let context = target.context
        return track { [weak self] in
            let plan = await engine.plan(paper: paper, context: context)
            guard let self, generation == self.planGeneration else { return }
            if self.sendPlan != plan { self.sendPlan = plan }
            self.sendPlanContext = context
        }
    }

    // ---- runs ----

    /// Review events (section 6.6): drafts are created or updated by id; a comment replaces its draft and joins the
    /// session; a notice is an info banner; the digest becomes `session.paperDigest`.
    func applyReviewEvent(_ event: ReviewEvent, to progress: inout RunProgress) {
        switch event {
        case .started(let run):
            progress.started = run
            progress.startedAt = run.startedAt
            recordStart(of: run)
            runState = .running(kind: .review, phase: progress.phase, startedAt: run.startedAt)
        case .phase(let phase):
            progress.phase = phase
            runState = .running(kind: .review, phase: phase, startedAt: progress.startedAt)
        case .draft(let draft):
            if let index = drafts.firstIndex(where: { $0.id == draft.id }) { drafts[index] = draft } else { drafts.append(draft) }
        case .comment(let comment, let draftID):
            drafts.removeAll { $0.id == draftID }
            mutateSession { session in
                if let index = session.comments.firstIndex(where: { $0.id == comment.id }) {
                    session.comments[index] = comment
                } else {
                    session.comments.append(comment)
                }
            }
        case .notice(let text):
            showBanner(.info, text)
        case .digest(let notes):
            mutateSession { $0.paperDigest = notes }
        case .finished(let run):
            progress.finished = run
        }
    }

    private func runReview(_ target: JobTarget, paper: LoadedPaper) async {
        var progress = RunProgress(startedAt: clock.now())
        runState = .running(kind: .review, phase: nil, startedAt: progress.startedAt)
        drafts = []
        var thrown: String?
        do {
            for try await event in dependencies.engine.review(paper: paper, existing: session?.comments ?? [], context: target.context) {
                if Task.isCancelled { break }
                applyReviewEvent(event, to: &progress)
            }
        } catch {
            thrown = Self.message(for: error, otherwise: "The review stopped.")
        }
        drafts = []                                             // open drafts are discarded (section 6.6)
        let status = record(started: progress.started, finished: progress.finished, thrown: thrown)
        runState = .idle
        if case .failed(let reason) = status {
            lastFailedJob = .review
            showBanner(.error, Message.reviewStopped(reason), action: .retry)
        }
    }

    private func runReport(_ target: JobTarget, paper: LoadedPaper, revising: Bool) async {
        guard let session else { return }
        let previous = session.report
        if revising && previous == nil { return }
        let kind: RunKind = revising ? .revise : .report
        runState = .running(kind: kind, phase: nil, startedAt: clock.now())
        streamingReportText = ""
        let stream = revising
            ? dependencies.engine.reviseVoice(draft: previous ?? ReportDraft(markdown: "", userEdited: false), findings: lintFindings,
                                              context: target.context)
            : dependencies.engine.generateReport(paper: paper, session: session, context: target.context)
        var started: RunRecord?
        var finished: (draft: ReportDraft, run: RunRecord)?
        var thrown: String?
        do {
            for try await event in stream {
                if Task.isCancelled { break }
                switch event {
                case .started(let run):
                    started = run
                    recordStart(of: run)
                    runState = .running(kind: kind, phase: nil, startedAt: run.startedAt)
                case .textDelta(let text):
                    streamingReportText += text
                case .notice(let text):
                    showBanner(.info, text)
                case .finished(let draft, let run):
                    finished = (draft, run)
                }
            }
        } catch {
            thrown = Self.message(for: error, otherwise: "The report stopped.")
        }
        let status = record(started: started, finished: finished?.run, thrown: thrown)
        streamingReportText = ""
        runState = .idle
        switch status {
        case .failed(let reason):
            lastFailedJob = revising ? .reviseVoice : .report
            showBanner(.error, revising ? Message.revisionStopped(reason) : Message.reportStopped(reason), action: .retry)
        case .cancelled:
            break
        case .completed, .running:
            guard let draft = finished?.draft else { break }
            if revising { applyRevisedReport(draft, target: target) } else { applyGeneratedReport(draft, target: target) }
        }
    }

    private func applyGeneratedReport(_ draft: ReportDraft, target: JobTarget) {
        let now = clock.now()
        var report = draft
        report.versions = ModelSupport.versions(afterSaving: session?.report, note: "before regenerate", at: now)
        report.generatedAt = draft.generatedAt ?? now
        report.provider = draft.provider ?? target.ref
        report.recommendation = draft.recommendation ?? ModelSupport.recommendation(in: draft.markdown)
        report.userEdited = false
        if report.basedOnCommentIDs.isEmpty {
            report.basedOnCommentIDs = session?.comments.filter { $0.status == .approved && $0.includeInReport }.map(\.id) ?? []
        }
        mutateSession { $0.report = report }
        lint(report.markdown)
    }

    /// The engine's draft is the revised one with its new text (Appendix A.6); the old text goes to `versions`.
    private func applyRevisedReport(_ draft: ReportDraft, target: JobTarget) {
        guard let old = session?.report else { return }
        let now = clock.now()
        var report = draft
        report.versions = ModelSupport.versions(afterSaving: old, note: "before voice revision", at: now)
        report.recommendation = draft.recommendation ?? ModelSupport.recommendation(in: draft.markdown) ?? old.recommendation
        report.generatedAt = draft.generatedAt ?? now
        report.provider = draft.provider ?? target.ref
        if report.basedOnCommentIDs.isEmpty { report.basedOnCommentIDs = old.basedOnCommentIDs }
        report.userEdited = false
        mutateSession { $0.report = report }
        lint(report.markdown)
    }

    private struct ReplyOutcome {
        var started: RunRecord?
        var finished: (reply: ThreadMessage, proposal: CommentRevision?, run: RunRecord)?
        var thrown: String?
    }

    private func playReply(_ stream: AsyncThrowingStream<ReplyEvent, Error>) async -> ReplyOutcome {
        var outcome = ReplyOutcome()
        do {
            for try await event in stream {
                if Task.isCancelled { break }
                switch event {
                case .started(let run):
                    outcome.started = run
                    recordStart(of: run)
                case .textDelta(let text): streamingReplyText += text
                case .notice(let text): showBanner(.info, text)
                case .finished(let reply, let proposal, let run): outcome.finished = (reply, proposal, run)
                }
            }
        } catch {
            outcome.thrown = Self.message(for: error, otherwise: "The reply stopped.")
        }
        return outcome
    }

    private func runDiscussion(commentID: UUID, message: String, sentMessageID: UUID?, target: JobTarget, paper: LoadedPaper) async {
        guard let comment = session?.comments.first(where: { $0.id == commentID }) else { return }
        var transcript = comment                                // the thread before the new message
        let messageID: UUID
        if let sentMessageID, let position = comment.thread.firstIndex(where: { $0.id == sentMessageID }) {
            transcript.thread = Array(comment.thread[..<position])
            messageID = sentMessageID
        } else {
            let sent = ThreadMessage(id: UUID(), role: .user, text: message, createdAt: clock.now())
            messageID = sent.id
            updateComment(commentID) { $0.thread.append(sent) }
        }
        clearReplyFailure()
        streamingTargetID = commentID
        streamingReplyText = ""
        let outcome = await playReply(dependencies.engine.discuss(paper: paper, comment: transcript, message: message, context: target.context))
        let status = record(started: outcome.started, finished: outcome.finished?.run, thrown: outcome.thrown)
        streamingTargetID = nil
        streamingReplyText = ""
        switch status {
        case .failed(let reason):
            failedReplyJob = .discussion(commentID: commentID, message: message, sentMessageID: messageID)
            replyFailure = ReplyFailure(targetID: commentID, message: reason)
        case .cancelled:
            break
        case .completed, .running:
            guard let finished = outcome.finished else { break }
            var reply = finished.reply
            if reply.provider == nil { reply.provider = target.ref }
            updateComment(commentID) { comment in
                comment.thread.append(reply)
                if let proposal = finished.proposal { comment.proposedRevision = proposal }
            }
        }
    }

    private func runQuestion(conversationID: UUID?, selection: SelectionInfo?, question: String, sentMessageID: UUID?, target: JobTarget,
                             paper: LoadedPaper) async {
        let conversation: Conversation
        if let conversationID {
            guard let existing = session?.conversations.first(where: { $0.id == conversationID }) else { return }
            conversation = existing
        } else {
            conversation = Conversation(id: UUID(), anchor: anchor(from: selection, in: paper), createdAt: clock.now())
            mutateSession { $0.conversations.append(conversation) }
            fillRectsIfNeeded(for: .conversation(conversation.id))
        }
        var transcript = conversation                           // the messages before the new question
        let messageID: UUID
        if let sentMessageID, let position = conversation.messages.firstIndex(where: { $0.id == sentMessageID }) {
            transcript.messages = Array(conversation.messages[..<position])
            messageID = sentMessageID
        } else {
            let sent = ThreadMessage(id: UUID(), role: .user, text: question, createdAt: clock.now())
            messageID = sent.id
            updateConversation(conversation.id) { $0.messages.append(sent) }
        }
        sidebarTab = .chat
        clearReplyFailure()
        streamingTargetID = conversation.id
        streamingReplyText = ""
        let outcome = await playReply(dependencies.engine.ask(paper: paper, conversation: transcript, question: question, context: target.context))
        let status = record(started: outcome.started, finished: outcome.finished?.run, thrown: outcome.thrown)
        streamingTargetID = nil
        streamingReplyText = ""
        switch status {
        case .failed(let reason):
            failedReplyJob = .question(conversationID: conversation.id, selection: nil, question: question, sentMessageID: messageID)
            replyFailure = ReplyFailure(targetID: conversation.id, message: reason)
        case .cancelled:
            break
        case .completed, .running:
            guard var reply = outcome.finished?.reply else { break }
            if reply.provider == nil { reply.provider = target.ref }
            updateConversation(conversation.id) { $0.messages.append(reply) }
        }
    }

    /// The run as it starts (its `.started` record, status `.running`) joins `session.runs` at once (step 5c), so that
    /// what it delivers names its own provider and model while it is under way; `record(started:finished:thrown:)`
    /// replaces it by how it ended.
    private func recordStart(of run: RunRecord) {
        mutateSession { session in
            if let index = session.runs.firstIndex(where: { $0.id == run.id }) { session.runs[index] = run } else { session.runs.append(run) }
        }
    }

    /// Puts how the run ended in `session.runs`, in place of the record of its start (else at the end), and returns
    /// how it ended. A run whose stream ended without `.finished` is recorded from its `.started` record: failed when
    /// the stream threw (and the job was not cancelled), cancelled otherwise, since only a consumer cancelled between
    /// two events misses `.finished` (Appendix A.6).
    private func record(started: RunRecord?, finished: RunRecord?, thrown: String?) -> RunStatus {
        let unfinished: RunStatus = Task.isCancelled ? .cancelled : thrown.map { .failed($0) } ?? .cancelled
        var run = finished
        if run == nil, var record = started {
            record.finishedAt = clock.now()
            record.status = unfinished
            run = record
        }
        if let run {
            let replaced = [started?.id, run.id].compactMap { $0 }
            mutateSession { session in
                if let index = session.runs.firstIndex(where: { replaced.contains($0.id) }) {
                    session.runs[index] = run
                    session.runs.removeAll { $0.id != run.id && replaced.contains($0.id) }
                } else {
                    session.runs.append(run)
                }
            }
            let failed: Bool
            if case .failed = run.status { failed = true } else { failed = false }
            Log.event("model.run.end", ["kind": .id(run.kind.rawValue), "failed": .bool(failed)])
            return run.status
        }
        return unfinished
    }

    // ---- comments and anchors ----

    /// Every comment in display order, whatever the filter.
    private var orderedComments: [ReviewComment] {
        CommentOrdering.sorted(session?.comments ?? [], in: paper?.text)
    }

    /// The first pending comment after `id` in visible order, wrapping round; nil when there is none.
    private func nextPending(after id: UUID) -> UUID? {
        let visible = Set(visibleComments.filter { $0.status == .pending }.map(\.id))
        let ordered = orderedComments
        guard let position = ordered.firstIndex(where: { $0.id == id }) else { return ordered.first { visible.contains($0.id) }?.id }
        return (ordered[(position + 1)...].first { visible.contains($0.id) } ?? ordered[..<position].first { visible.contains($0.id) })?.id
    }

    private func select(_ id: UUID) {
        selectedCommentID = id
        revealSelectedCommentInPDF()
    }

    private func updateComment(_ id: UUID, _ change: (inout ReviewComment) -> Void) {
        guard let index = session?.comments.firstIndex(where: { $0.id == id }), var comment = session?.comments[index] else { return }
        let before = comment
        change(&comment)
        guard comment != before else { return }
        comment.updatedAt = clock.now()
        mutateSession { $0.comments[index] = comment }
    }

    private func updateConversation(_ id: UUID, _ change: (inout Conversation) -> Void) {
        guard let index = session?.conversations.firstIndex(where: { $0.id == id }) else { return }
        mutateSession { change(&$0.conversations[index]) }
    }

    /// Removes comments, and what pointed at them: the selection, the editor, the open thread, `similarTo`.
    private func removeComments(where shouldRemove: (ReviewComment) -> Bool) {
        guard let comments = session?.comments else { return }
        let removed = Set(comments.filter(shouldRemove).map(\.id))
        guard !removed.isEmpty else { return }
        mutateSession { session in
            session.comments.removeAll { removed.contains($0.id) }
            for index in session.comments.indices where session.comments[index].similarTo.map(removed.contains) == true {
                session.comments[index].similarTo = nil
            }
        }
        if let id = selectedCommentID, removed.contains(id) { selectedCommentID = nil }
        if let id = editingCommentID, removed.contains(id) { editingCommentID = nil }
        if let id = openThreadCommentID, removed.contains(id) { openThreadCommentID = nil }
        if let id = streamingTargetID, removed.contains(id) { cancelReply() }
        if let id = replyFailure?.targetID, removed.contains(id) { clearReplyFailure() }
    }

    private func clearReplyFailure() {
        replyFailure = nil
        failedReplyJob = nil
    }

    /// The anchor of a passage the referee selected (sections 6.9, 7.4): the normalised selection, confidence `.exact`,
    /// label from the matcher. Its rectangles are the selection's when normalising left the spans as they were;
    /// otherwise `fillRectsIfNeeded` fetches them.
    private func anchor(from selection: SelectionInfo?, in paper: LoadedPaper) -> Anchor? {
        guard let selection, let normalised = SelectionNormalizer.normalize(selection, in: paper.text),
              let first = normalised.spans.first else { return nil }
        let label = matcher?.locationLabel(for: normalised.spans) ?? "p. \(first.pageIndex + 1)"
        return Anchor(quote: normalised.text, spans: normalised.spans, rects: normalised.spans == selection.spans ? selection.rects : [],
                      pageIndex: first.pageIndex, confidence: .exact, locationLabel: label)
    }

    private func anchor(of owner: AnchorOwner) -> Anchor? {
        switch owner {
        case .comment(let id): return session?.comments.first { $0.id == id }?.anchor
        case .conversation(let id): return session?.conversations.first { $0.id == id }?.anchor
        }
    }

    private func fillRectsIfNeeded(for owner: AnchorOwner) {
        guard let paper, let anchor = anchor(of: owner), anchor.rects.isEmpty, !anchor.spans.isEmpty else { return }
        let spans = anchor.spans
        let service = dependencies.paperService
        track { [weak self] in
            let rects = await service.rects(for: spans, in: paper.ref)
            guard let self, !rects.isEmpty, self.anchor(of: owner)?.spans == spans else { return }
            switch owner {
            case .comment(let id): self.updateComment(id) { $0.anchor.rects = rects }
            case .conversation(let id): self.updateConversation(id) { $0.anchor?.rects = rects }
            }
        }
    }

    /// Locates the anchors that have a quote but no spans, and fills the rectangles of anchors that have spans but
    /// none. Returns whether anything changed.
    private func healAnchors(of session: inout ReviewSession, with matcher: any QuoteMatching, paper: LoadedPaper) async -> Bool {
        var changed = false
        for index in session.comments.indices {
            if let anchor = await healed(session.comments[index].anchor, with: matcher, paper: paper) {
                session.comments[index].anchor = anchor
                changed = true
            }
        }
        for index in session.conversations.indices {
            guard let current = session.conversations[index].anchor else { continue }
            if let anchor = await healed(current, with: matcher, paper: paper) {
                session.conversations[index].anchor = anchor
                changed = true
            }
        }
        return changed
    }

    private func healed(_ anchor: Anchor, with matcher: any QuoteMatching, paper: LoadedPaper) async -> Anchor? {
        var result = anchor
        if anchor.spans.isEmpty {
            guard !anchor.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let match = await Self.locate(anchor.quote, pageHint: anchor.pageIndex, with: matcher),
                  let first = match.spans.first else { return nil }
            result.spans = match.spans
            result.confidence = match.confidence
            result.pageIndex = first.pageIndex
            result.locationLabel = matcher.locationLabel(for: match.spans)
            result.rects = []
        } else if !anchor.rects.isEmpty {
            return nil
        }
        let rects = await dependencies.paperService.rects(for: result.spans, in: paper.ref)
        if rects.isEmpty && result == anchor { return nil }
        result.rects = rects
        return result
    }

    private func fillMentionRects(of index: CitationIndex, paper: LoadedPaper) async -> CitationIndex {
        var index = index
        for position in index.mentions.indices where index.mentions[position].rects.isEmpty && !index.mentions[position].spans.isEmpty {
            index.mentions[position].rects = await dependencies.paperService.rects(for: index.mentions[position].spans, in: paper.ref)
        }
        return index
    }

    @concurrent nonisolated private static func makeMatcher(_ factory: @Sendable (PaperText) -> any QuoteMatching,
                                                            for text: PaperText) async -> any QuoteMatching {
        factory(text)
    }

    @concurrent nonisolated private static func locate(_ quote: String, pageHint: Int?, with matcher: any QuoteMatching) async -> AnchorMatch? {
        matcher.locate(quote: quote, pageHint: pageHint)
    }

    @concurrent nonisolated private static func buildIndex(_ indexer: any CitationIndexing, for paper: LoadedPaper) async -> CitationIndex {
        indexer.buildIndex(paper: paper.text, links: paper.links)
    }

    /// A provider's status, off the main actor (`refreshActiveAvailability()` asks local providers only).
    @concurrent nonisolated private static func availability(of provider: any LLMProvider) async -> ProviderAvailability {
        await provider.availability()
    }

    // ---- citations ----

    private func resolve(_ entries: [BibEntry], for target: CitationLookup.Target, document: String) {
        lookupGeneration += 1
        let generation = lookupGeneration
        citationLookup = .resolving(target: target)
        let resolver = dependencies.resolver
        track { [weak self] in
            let references = await Self.resolveAll(entries, with: resolver, document: document)
            guard let self else { return }
            self.remember(references, document: document)            // also when a later lookup took the card over
            guard generation == self.lookupGeneration else { return }
            self.citationLookup = .resolved(target: target, entries: entries, references: references)
        }
    }

    /// Settings ▸ References "Look up all references when a document opens" (section 8.7): every entry, through the
    /// resolver's own rate limits; the results fill `references`, nothing else changes.
    private func lookUpAllReferences() {
        guard let paper, let entries = citations?.entries, !entries.isEmpty else { return }
        let resolver = dependencies.resolver
        let document = paper.ref.sha256
        Log.event("model.references.background", ["entries": .int(entries.count)])
        track { [weak self] in
            let references = await Self.resolveAll(entries, with: resolver, document: document)
            self?.remember(references, document: document)
        }
    }

    /// Keeps each entry's latest result for the References list, if the document is still the one open.
    private func remember(_ results: [ResolvedReference], document: String) {
        guard paper?.ref.sha256 == document else { return }
        for result in results { references[result.entryID] = result }
    }

    /// Every entry at once; the results in the order of `entries`.
    @concurrent nonisolated private static func resolveAll(_ entries: [BibEntry], with resolver: any ReferenceResolving,
                                                           document: String) async -> [ResolvedReference] {
        await withTaskGroup(of: (Int, ResolvedReference).self) { group in
            for (position, entry) in entries.enumerated() {
                group.addTask { (position, await resolver.resolve(entry, documentSHA256: document)) }
            }
            var results: [(Int, ResolvedReference)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    // ---- report lint (section 6.10) ----

    private func lint(_ markdown: String) {
        lintTask?.cancel()
        lintTask = nil
        lintFindings = dependencies.engine.lint(reportMarkdown: markdown)
    }

    private func scheduleLint(of markdown: String) {
        lintTask?.cancel()
        let deadline = clock.now().addingTimeInterval(Self.lintDelay)
        let clock = self.clock
        let engine = dependencies.engine
        lintTask = Task { [weak self] in
            do { try await clock.sleep(until: deadline) } catch { return }
            guard let self, !Task.isCancelled, self.session?.report?.markdown == markdown else { return }
            self.lintFindings = engine.lint(reportMarkdown: markdown)
        }
    }

    // ---- session changes and autosave (sections 2.4, 4.5) ----

    /// Every change of `session` goes through here: it bumps `updatedAt` and schedules the autosave.
    private func mutateSession(_ change: (inout ReviewSession) -> Void) {
        guard var updated = session else { return }
        change(&updated)
        guard updated != session else { return }
        updated.updatedAt = clock.now()
        session = updated
        scheduleAutosave()
    }

    /// A save 1 s after the last change.
    private func scheduleAutosave() {
        guard persistenceEnabled else { return }
        hasUnsavedChanges = true
        autosaveTask?.cancel()
        let deadline = clock.now().addingTimeInterval(Self.autosaveDelay)
        let clock = self.clock
        autosaveTask = Task { [weak self] in
            do { try await clock.sleep(until: deadline) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }

    /// Writes the session if it has changes. Saves run one after another, each writing the session as it is then.
    private func save() async {
        let previous = saveChain
        let task = Task { [weak self] in
            await previous?.value
            guard let self, self.persistenceEnabled, self.hasUnsavedChanges, let session = self.session else { return }
            self.hasUnsavedChanges = false
            do {
                try await self.dependencies.sessions.save(session)
            } catch {
                self.hasUnsavedChanges = true
                Log.event("model.save.failed")
                self.showBanner(.error, Self.message(for: error, otherwise: "The review could not be saved."))
            }
        }
        saveChain = task
        await task.value
    }

    // ---- banner, reader, background work ----

    private func showBanner(_ style: Banner.Style, _ message: String, action: Banner.Action? = nil) {
        if let current = banner, Self.severity(current.style) > Self.severity(style) { return }
        let shown = Banner(style: style, message: message, action: action)
        banner = shown
        bannerFadeTask?.cancel()
        bannerFadeTask = nil
        guard style == .info else { return }
        let deadline = clock.now().addingTimeInterval(Self.noticeLifetime)
        let clock = self.clock
        bannerFadeTask = Task { [weak self] in
            do { try await clock.sleep(until: deadline) } catch { return }
            guard let self, self.banner?.id == shown.id else { return }
            self.banner = nil
        }
    }

    private static func severity(_ style: Banner.Style) -> Int {
        switch style {
        case .info: return 0
        case .warning: return 1
        case .error: return 2
        }
    }

    private func issue(_ command: ReaderCommand) {
        readerSerial += 1
        readerCommand = (serial: readerSerial, command: command)
    }

    /// Runs `operation` on the main actor as a task of this model, which `waitForBackgroundWork()` can wait for.
    @discardableResult
    private func track(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let task = Task { [weak self] in
            await operation()
            self?.backgroundTasks[id] = nil
        }
        backgroundTasks[id] = task
        return task
    }

    /// For tests: waits until the plan, model lists, rectangles and citation lookups in flight have arrived.
    func waitForBackgroundWork() async {
        while let task = backgroundTasks.values.first {
            await task.value
        }
    }

    static func message(for error: Error, otherwise fallback: String) -> String {
        if let error = error as? any RefereeError { return error.userMessage }
        if error is CancellationError { return LLMError.cancelled.userMessage }
        return fallback
    }
}
