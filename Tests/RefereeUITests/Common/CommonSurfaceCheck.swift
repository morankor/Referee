import AppKit
import Observation
import PDFKit
import SwiftUI
import RefereeCore
import AppCore
import PDFBridge
import TestSupport
import RefereeUI

// Gate 0, step 2 (plan.md section 11.4): the public surface of section 11.3, named with its printed argument labels and
// types. This half covers TestSupport, PDFBridge, AppCore (section 11.3 and every member of Appendix A.9) and RefereeUI
// (with `Theme`, `CommonTag` and the `UIActions` block of section 9.1); the other half is Tests/IntegrationTests/SurfaceCheck.swift.
// Switches over enums are exhaustive on purpose: a public case added without a contract note stops the build here.
//
// Nothing here is ever called: the file only has to compile. If it stops compiling, a declaration of section 11.3 or
// Appendix A.9 was changed. Change the code back, or record the change as a contract problem (section 11.1); do not
// edit this file.

private func isActor<T: Actor>(_: T.Type) {}
private func isClass<T: AnyObject>(_: T.Type) {}
private func isValue<T: Sendable & Equatable>(_: T.Type) {}
private func isEquatable<T: Equatable>(_: T.Type) {}
private func isIdentifiable<T: Identifiable>(_: T.Type) {}
private func isObservable<T: Observable>(_: T.Type) {}

/// The builder `PDFPaperService` is given here; this target does not depend on PaperText.
private struct SurfaceBuilder: PaperTextBuilding {
    func build(from raw: RawDocument) -> PaperText { identityPaperText(from: raw) }
}

@MainActor func surfaceCheckOfTheApplication(dependencies: AppDependencies, raw: RawDocument, paperText: PaperText, loaded: LoadedPaper,
                                             selection: SelectionInfo, reference: ResolvedReference, descriptor: ProviderDescriptor,
                                             file: URL, id: UUID) async throws {
    // ==== TestSupport ====
    let _: URL = Fixtures.root
    let _: URL = Fixtures.url("pdf/ay_nolinks.pdf")
    let _: RawDocument = try Fixtures.rawDocument("ay_nolinks")
    let _: String = try Fixtures.text("llm/review_clean.txt")
    let _: PaperText = identityPaperText(from: raw)
    let _: LoadedPaper = try makeSamplePaper(fixture: "ay_round_nolinks")
    let _: LoadedPaper = try makeSamplePaper()

    var response = MockResponse(text: "x", chunkSize: 7, delayPerChunk: .zero, failAfterChunks: nil, failure: nil, stallAfterChunks: nil, stop: .endOfTurn)
    response = MockResponse(text: "x")
    response.text = "y"
    response.chunkSize = 1
    response.delayPerChunk = .milliseconds(1)
    response.failAfterChunks = 1
    response.failure = .cancelled
    response.stallAfterChunks = 2
    response.stop = .maxTokens
    var script = MockScript(responses: [.review: [response]])
    script.responses[.ping] = [MockResponse(text: "OK")]
    let _: [MockScript] = [script, MockScript.sample, MockScript.failsAfterTwoComments, MockScript.stallsAfterTwoComments]
    let mock = MockLLMProvider(id: "mock", script: .sample, isLocal: true, supportsNativePDF: false)
    let _: any LLMProvider = MockLLMProvider()
    let _: [LLMRequest] = mock.recordedRequests
    isClass(MockLLMProvider.self)
    let _: any LLMProvider = StaticProvider(descriptor: descriptor, availability: .ready(detail: "Key set"), models: [])
    let _: [any LLMProvider] = SnapshotSupport.providers()
    let _: AppSettings = SnapshotSupport.settings()

    var stub = StubURLProtocol.Response(status: 200, headers: [:], chunks: [Data()], delayPerChunk: .zero)
    stub = StubURLProtocol.Response(chunks: [])
    stub.status = 404
    stub.headers = ["Content-Type": "application/json"]
    stub.chunks = [Data("{}".utf8)]
    stub.delayPerChunk = .milliseconds(5)
    let answer = stub
    StubURLProtocol.setHandler { _ in answer }
    StubURLProtocol.setHandler(nil)
    let _: URLSession = StubURLProtocol.session()
    let _: [URLRequest] = StubURLProtocol.recordedRequests
    let _: URLProtocol.Type = StubURLProtocol.self

    let sessions = InMemorySessionStore()
    let _: any SessionStoring = sessions
    let _: Int = sessions.saveCount
    let _: any SettingsStoring = InMemorySettingsStore(DefaultSettings.make())
    let _: any SettingsStoring = InMemorySettingsStore()
    let secrets = InMemorySecretStore(["anthropic-api": "key"])
    let _: any SecretStoring = InMemorySecretStore()
    secrets.failReads = true
    let _: Bool = secrets.failReads
    let _: any PaperService = FakePaperService(paper: loaded)
    let _: any QuoteMatching = FakeQuoteMatcher(paper: paperText)
    let _: any CitationIndexing = FakeCitationIndexer(index: CitationIndex(style: .numeric))
    let _: any CitationIndexing = FakeCitationIndexer()
    let _: any PaperRendering = FakePaperRenderer()
    let resolver = FakeResolver()
    let _: any ReferenceResolving = resolver
    let _: [String] = resolver.forgottenDocuments
    let plan = SendPlan(sendsPDF: false, requestCount: 1, estimatedInputTokens: 0, destination: "this Mac", isLocal: true)
    let engine = ScriptedReviewEngine(plan: plan, review: [], reply: [], report: [], lint: [], delayPerEvent: .zero)
    let _: any ReviewEngineProtocol = ScriptedReviewEngine(plan: plan)
    let _: [String] = engine.calls
    let _: [EngineContext] = engine.contexts
    isClass(InMemorySessionStore.self)
    isClass(InMemorySettingsStore.self)
    isClass(InMemorySecretStore.self)
    isClass(FakePaperService.self)
    isClass(FakeResolver.self)
    isClass(ScriptedReviewEngine.self)

    // ==== PDFBridge ====
    let _: any PaperService = PDFPaperService(builder: SurfaceBuilder())
    isActor(PDFPaperService.self)
    let document = PDFDocument()
    let _: RawDocument = RawExtractor.extract(from: document)
    let _: SelectionInfo? = SelectionInfoBuilder.make(from: PDFSelection(document: document), in: document)

    // ==== AppCore, besides Appendix A.9 ====
    let size: PaperSize = .current
    switch size { case .letter, .a4: break }
    let _: String = ReportExporter.plainText(fromMarkdown: "## Summary assessment")
    let _: Data = try ReportExporter.data(markdown: "", format: .pdf, paper: .a4)
    let _: Data = try ReportExporter.data(markdown: "", format: .markdown)
    let _: SelectionInfo? = SelectionNormalizer.normalize(selection, in: paperText)

    // ==== AppCore, Appendix A.9: the value types ====
    let phase: DocumentPhase = .loading(fileName: "a.pdf")
    switch phase { case .empty, .loading(fileName: _), .ready, .failed(message: _): break }
    let runState: RunState = .running(kind: .review, phase: .reading(part: 1, of: 2), startedAt: Date())
    switch runState { case .idle, .running(kind: _, phase: _, startedAt: _): break }
    var banner = Banner(id: UUID(), style: .error, message: "Review stopped.", action: .retry)
    banner = Banner(style: .info, message: "Notice.")
    banner.id = id
    banner.style = .warning
    banner.message = ""
    banner.action = .openSettings
    switch banner.style { case .info, .warning, .error: break }
    switch banner.action { case .retry?, .openSettings?, nil: break }
    var consent = ConsentRequest(id: UUID(), provider: descriptor, model: "mock", plan: plan)
    consent = ConsentRequest(provider: descriptor, plan: plan)
    consent.id = id
    consent.provider = descriptor
    consent.model = nil
    consent.plan = plan
    var composing = ComposingComment(selection: nil)
    composing = ComposingComment()
    composing.selection = selection
    _ = (consent, composing)
    let filter: CommentFilter = .kind(.major)
    switch filter { case .all, .pending, .approved, .rejected, .kind(_): break }
    let tab: SidebarTab = .chat
    switch tab { case .comments, .chat, .report: break }
    let _: [SidebarTab] = SidebarTab.allCases
    let _: String = tab.rawValue
    let format: ExportFormat = .docx
    switch format { case .markdown, .plainText, .docx, .pdf: break }
    let _: [ExportFormat] = ExportFormat.allCases
    var failure = ReplyFailure(targetID: id, message: "The provider is overloaded.")       // Gate 1
    failure.targetID = id
    failure.message = ""
    isValue(ReplyFailure.self)
    let exportError: ExportError = .couldNotWrite("disk full")
    switch exportError { case .couldNotCreate(_), .couldNotWrite(_): break }
    let _: any RefereeError = exportError
    isValue(ExportError.self)
    let command: ReaderCommand = .reveal(rects: [], flash: true)
    switch command { case .reveal(rects: _, flash: _), .goToPage(_), .clearSelection: break }
    let lookup: CitationLookup = .resolved(target: .entry(0), entries: [], references: [reference])
    switch lookup { case .idle, .resolving(target: _), .resolved(target: _, entries: _, references: _): break }
    let target: CitationLookup.Target = .mention(3)
    switch target { case .mention(_), .entry(_): break }
    isValue(DocumentPhase.self)
    isValue(RunState.self)
    isValue(Banner.self)
    isIdentifiable(Banner.self)
    isValue(ConsentRequest.self)
    isIdentifiable(ConsentRequest.self)
    isValue(ComposingComment.self)
    isValue(CommentFilter.self)
    isValue(SidebarTab.self)
    isValue(ExportFormat.self)
    isValue(ReaderCommand.self)
    isValue(CitationLookup.self)

    // ==== AppCore, Appendix A.9: ReviewSessionModel ====
    let model = ReviewSessionModel(dependencies: dependencies, settings: DefaultSettings.make())
    isClass(ReviewSessionModel.self)
    isObservable(ReviewSessionModel.self)
    let _: DocumentPhase = model.phase
    let _: LoadedPaper? = model.paper
    let _: ReviewSession? = model.session
    let _: CitationIndex? = model.citations
    let _: AppSettings = model.settings
    let _: RunState = model.runState
    let _: [DraftComment] = model.drafts
    let _: String = model.streamingReplyText
    let _: UUID? = model.streamingTargetID
    let _: String = model.streamingReportText
    let _: Banner? = model.banner
    let _: ConsentRequest? = model.consentRequest
    let _: ProviderDescriptor? = model.activeProvider
    let _: String? = model.activeModel
    let _: SendPlan? = model.sendPlan
    let _: [LintFinding] = model.lintFindings
    let _: CitationLookup = model.citationLookup
    let _: (serial: Int, command: ReaderCommand)? = model.readerCommand
    let _: SelectionInfo? = model.selection
    let _: ComposingComment? = model.composing
    let _: ReplyFailure? = model.replyFailure
    let _: [Int: ResolvedReference] = model.references
    model.selectedCommentID = id
    model.openThreadCommentID = nil
    model.editingCommentID = nil
    model.filter = .pending
    model.sidebarTab = .report
    let _: [ReviewComment] = model.visibleComments
    let _: (decided: Int, total: Int) = model.triage
    let _: Bool = model.canStartReview
    let _: [ProviderDescriptor] = model.selectableProviders
    let _: ProviderDescriptor? = model.chatProvider                     // step 5 (O1)
    let _: ProviderDescriptor? = model.reportProvider
    let _: ProviderAvailability? = model.activeAvailability             // step 5 (O2)
    model.refreshActiveAvailability()
    let _: [ProviderDescriptor] = model.registeredProviders             // step 5c
    await model.open(url: file)
    await model.close()
    await model.deleteReviewData()
    model.setActiveProvider(ProviderRef(providerID: "mock-remote", model: nil))
    model.answerConsent(granted: true)
    model.answerConsent(granted: true, askAgain: true)
    model.reloadSettings(DefaultSettings.make())
    model.startReview()
    model.cancelRun()
    model.cancelReply()
    model.retryLastFailedJob()
    model.retryFailedReply()
    model.setStatus(.approved, for: id)
    model.selectNextComment(pendingOnly: true)
    model.selectPreviousComment()
    model.revealSelectedCommentInPDF()
    model.revealConversationInPDF(id)
    model.setKind(.question, for: id)
    model.editComment(id, kind: .minor, category: "other", title: "", body: "", suggestion: nil)
    model.deleteComment(id)
    model.deletePendingAIComments()
    model.beginComposingComment()
    model.cancelComposing()
    model.addUserComment(kind: .minor, category: "other", title: "", body: "", anchoredTo: selection)
    model.addUserComment(kind: .minor, category: "other", title: "", body: "", suggestion: "Say so.", anchoredTo: nil)   // Wave 3
    model.reanchorComment(id, to: selection)
    model.setIncludeInReport(false, for: id)
    model.sendDiscussionMessage("Why?", commentID: id)
    model.acceptProposedRevision(commentID: id)
    model.discardProposedRevision(commentID: id)
    model.ask("Why?", about: selection, in: nil)
    model.convertReplyToComment(conversationID: id, messageID: id, kind: .question)
    model.deleteConversation(id)
    model.generateReport()
    model.updateReportMarkdown("## Summary assessment")
    model.setRecommendation(.majorRevision)
    model.reviseReportVoice()
    model.restoreReportVersion(at: 0)
    try model.exportReport(format: .docx, to: file)
    let _: String = model.reportText(format: .plainText)
    model.lookUpCitation(mentionID: 0)
    model.lookUpEntry(entryID: 0)
    let _: URL = try await model.fetchReferencePDF(reference)
    let _: URL = model.searchURL(for: BibEntry(id: 0, rawText: "Lee, J. (2021).", parsed: ParsedReference()))
    model.readerSelectionChanged(selection)
    model.readerClickedComment(id)
    model.readerClickedCitation(mentionID: 0)
    model.dismissBanner()
    model.dismissCitationLookup()                                       // Wave 3
    model.dismissTransientUI()
    model.updateMeta(ManuscriptMeta(reviewerNotes: ""))
    await model.flushPendingSave()

    // ==== AppCore, Appendix A.9: SettingsModel ====
    let _: Notification.Name = .refereeSettingsDidChange
    let settings = SettingsModel(dependencies: dependencies, settings: DefaultSettings.make())
    isClass(SettingsModel.self)
    isObservable(SettingsModel.self)
    let _: AppSettings = settings.settings
    let _: [ProviderID: ProviderAvailability] = settings.availability
    let _: [ProviderID: [ModelInfo]] = settings.models
    let _: [ProviderID: String] = settings.modelErrors
    let _: Set<String> = settings.storedSecrets
    let _: [String: String] = settings.secretErrors
    let _: Int? = settings.pdfCacheBytes
    let _: URL? = settings.dataDirectory
    let _: [ProviderDescriptor] = settings.providers
    settings.update { $0.privacy.localOnly = true }
    await settings.setSecret(nil, for: "anthropic-api")
    await settings.refreshAvailability(of: nil)
    await settings.refreshModels(of: "ollama")
    await settings.refreshModels(of: "openai-api", includeHidden: true)
    await settings.refreshPDFCacheSize()
    await settings.clearPDFCache()
    try await settings.deleteAllReviewData()
    let _: Result<String, LLMError> = await settings.sendTestPrompt(to: "ollama")
    settings.resetPromptsToDefaults()
    await settings.applyFirstRunDefaultsIfNeeded()
    await settings.flushPendingSave()                                   // public since Wave 3

    // ==== RefereeUI/Common ====
    let window = NSWindow()
    let reader = ReaderController(model: model)
    let context = SnapshotContext(window: window, model: model, reader: reader, settings: settings)
    let _: SnapshotContext = SnapshotContext(window: window)
    let _: NSWindow = context.window
    let _: ReviewSessionModel? = context.model
    let _: ReaderController? = context.reader
    let _: SettingsModel? = context.settings
    var scene = SnapshotScene(name: "example", kind: .review, fixturePDF: "ay_nolinks.pdf", fixtureSession: "sample.json", settleSeconds: 2.0,
                              prepare: { _ in }, verify: { _ in [] })
    scene = SnapshotScene(name: "example", kind: .welcome)
    scene.name = "other"
    scene.kind = .referenceViewer
    scene.fixturePDF = nil
    scene.fixtureSession = nil
    scene.settleSeconds = 1
    scene.prepare = { (_: SnapshotContext) async in }
    scene.verify = { (_: SnapshotContext) async -> [String] in [] }
    switch scene.kind { case .review, .settings, .welcome, .referenceViewer: break }
    let _: Int32 = await SnapshotRunner.run(arguments: ["--ui-snapshot", "build/snapshots"], makeDependencies: { _ in dependencies })
    let _: [SnapshotScene] = IntegrationScenes.all

    let _: Color = Theme.kindColor(.major)
    let _: Color = Theme.statusColor(.pending)
    let _: Color = Theme.ownColor
    let highlight: Theme.Highlight = .question
    switch highlight { case .pending, .approved, .rejected, .own, .question: break }
    let _: [Theme.Highlight] = Theme.Highlight.allCases
    isValue(Theme.Highlight.self)
    let _: NSColor = Theme.highlightHue(.own)
    let _: CGFloat = Theme.highlightAlpha(.own, selected: true)
    let _: CGFloat = Theme.highlightAlpha(.own)
    let _: NSColor = Theme.highlightColor(.pending, selected: false)
    let _: NSColor = Theme.highlightColor(.pending)
    let _: CGFloat = Theme.fuzzyBorderWidth
    let _: [CGFloat] = Theme.fuzzyBorderDash
    let _: NSColor = Theme.pdfBackground
    let _: [CGFloat] = [Theme.cardCornerRadius, Theme.cardPadding, Theme.listSpacing, Theme.sidebarPadding]
    let _: [Font] = [Theme.cardTitleFont, Theme.bodyFont, Theme.quoteFont, Theme.metadataFont]
    let _: Font = Theme.tagFont                                         // step 5 (D16)
    let _: Duration = Theme.feedbackDuration
    let _: any View = CommonTag("Open access", color: .green)

    var actions = UIActions()
    actions.openReferenceViewer = { (_: URL, _: String) in }
    actions.openSettings = {}
    actions.openInBrowser = { (_: URL) in }
    var environment = EnvironmentValues()
    environment.uiActions = actions
    let _: UIActions = environment.uiActions

    // ==== RefereeUI/Reader ====
    let _: PDFView = RefereePDFView()
    let step: ZoomStep = .fitWidth
    switch step { case .zoomIn, .zoomOut, .fitWidth: break }
    isClass(ReaderController.self)
    let _: RefereePDFView = reader.pdfView
    reader.attach()
    let _: Bool = reader.isDocumentLoaded
    reader.showFind()
    reader.findNext()
    reader.findPrevious()
    let _: Bool = reader.dismissFind()                                  // Wave 3
    reader.zoom(step)
    let _: any View = ReaderPane(controller: reader)
    let _: any View = NavigatorPane(controller: reader)
    let _: any View = ReferenceViewerView(fileURL: file, title: "A cited paper")
    let _: [SnapshotScene] = ReaderScenes.all

    // ==== RefereeUI/Sidebar ====
    let _: any View = ReviewSidebar(model: model)
    let _: [SnapshotScene] = SidebarScenes.all

    // ==== RefereeUI/Shell ====
    let _: (@escaping @Sendable ([String: String]) async -> AppDependencies) -> Never = AppMain.run(makeDependencies:)
    let _: any View = ReviewWindowView(model: model, reader: reader)
    let _: any View = SettingsRootView(model: settings)
    let _: any View = WelcomeView(recent: [SessionSummary](), open: { (_: URL?) in })
    let intent: TriageIntent? = TriageKeymap.intent(characters: "j", keyCode: 38, modifiers: NSEvent.ModifierFlags())
    switch intent {
    case .next?, .previous?, .nextPending?, .approve?, .reject?, .resetStatus?, .discuss?, .edit?, .reveal?, .newComment?, .setKind(_)?, .dismiss?, nil: break
    }
    TriageKeymap.apply(.setKind(.strength), to: model)
    isEquatable(TriageIntent.self)
    let _: [SnapshotScene] = ShellScenes.all
}
