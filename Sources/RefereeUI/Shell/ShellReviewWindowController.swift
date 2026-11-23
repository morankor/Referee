import SwiftUI
import AppKit
import UniformTypeIdentifiers
import RefereeCore
import AppCore

/// One review window (plan.md sections 9.1, 9.4, 7.4): it owns the window's `ReviewSessionModel` and `ReaderController`,
/// attaches the reader at once, opens the document, installs the triage key monitor, answers the menu commands of
/// its window, and lets the model save and close when the window closes.
@MainActor final class ShellReviewWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let model: ReviewSessionModel
    let reader: ReaderController
    let windowState: ShellReviewWindowState
    let url: URL
    let documentHash: String?
    private weak var manager: ShellWindowManager?
    private var keyMonitor: Any?
    private var exportFormatPicker: ShellExportFormatPicker?

    static let defaultSize = NSSize(width: 1280, height: 800)
    static let minimumSize = NSSize(width: 1000, height: 640)

    init(model: ReviewSessionModel, url: URL, documentHash: String?, manager: ShellWindowManager) {
        let reader = ReaderController(model: model)
        let windowState = ShellReviewWindowState()
        self.model = model
        self.reader = reader
        self.windowState = windowState
        self.url = url
        self.documentHash = documentHash
        self.manager = manager
        let view = ReviewWindowView(model: model, reader: reader, windowState: windowState, services: manager.windowServices)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        window.title = url.lastPathComponent        // .navigationTitle does not reach a window made around NSHostingController (section 7.5)
        window.representedURL = url
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.contentMinSize = Self.minimumSize
        window.setContentSize(Self.defaultSize)
        window.center()
        if let documentHash { window.setFrameAutosaveName("Referee.Review.\(documentHash)") }   // restores this document's frame
        super.init(window: window)
        window.delegate = self
        reader.attach()                             // right after the controller is made (section 7.4)
        installKeyMonitor()
    }

    required init?(coder: NSCoder) { nil }

    /// Opens the document. The log line is the only trace a launch leaves for whoever checks it from outside
    /// (section 11.5): no file name, no text.
    func load() async {
        await model.open(url: url)
        guard case .ready = model.phase else {
            Log.event("shell.review.failed")
            return
        }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        while !reader.isDocumentLoaded, clock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        Log.event("shell.review.ready", ["pages": .int(model.paper?.ref.pageCount ?? 0), "document": .bool(reader.isDocumentLoaded)])
    }

    // ---- window ----

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        // The frame is kept for the next time; the name is let go now, so that the document can be opened again in a new
        // window while this one's model is still closing.
        if let window, !window.frameAutosaveName.isEmpty {
            window.saveFrame(usingName: window.frameAutosaveName)
            window.setFrameAutosaveName("")
        }
        manager?.reviewWindowWillClose(self)
    }

    // ---- keyboard triage (section 9.4) ----

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKeyDown(event) ?? false }
            return handled ? nil : event
        }
    }

    /// Whether the key was a triage key of this window and was acted on. Keys reach triage only while this window is
    /// key and no text is being edited. While the consent card is up the window is blocked: Esc answers it "no" and the
    /// other triage keys do nothing. Esc also closes the destination menu.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard event.window === window, keysReachTriage else { return false }
        let intent = TriageKeymap.intent(characters: event.charactersIgnoringModifiers ?? "", keyCode: event.keyCode, modifiers: event.modifierFlags)
        if model.consentRequest != nil {
            if intent == .dismiss { model.answerConsent(granted: false) }
            return intent != nil
        }
        if windowState.destinationMenuOpen && intent == .dismiss {
            windowState.destinationMenuOpen = false
            return true
        }
        guard let intent else { return false }
        perform(intent)
        return true
    }

    /// An intent, from a key or from the menu. The thread, the editor and a new comment live in the sidebar, which
    /// opens for them if it is hidden.
    private func perform(_ intent: TriageIntent) {
        TriageKeymap.apply(intent, to: model)
        switch intent {
        case .discuss, .edit, .newComment: windowState.showSidebar = true
        default: break
        }
    }

    /// A text view or a field editor has the keyboard.
    private var isEditingText: Bool {
        window?.firstResponder is NSText
    }

    /// Single keys mean triage only while this window itself is key (not a sheet over it, not another window) and no
    /// text is being edited. The menu's single-key items are enabled under the same condition: a key equivalent of an
    /// enabled item would otherwise take a letter typed into a sheet's text field.
    private var keysReachTriage: Bool {
        guard let window else { return false }
        return window.isKeyWindow && window.attachedSheet == nil && !isEditingText
    }

    // ---- menu commands of this window (target: the first responder; the window's delegate answers) ----

    @objc func shellFind(_ sender: Any?) { reader.showFind() }
    @objc func shellFindNext(_ sender: Any?) { reader.findNext() }
    @objc func shellFindPrevious(_ sender: Any?) { reader.findPrevious() }
    @objc func shellZoomIn(_ sender: Any?) { reader.zoom(.zoomIn) }
    @objc func shellZoomOut(_ sender: Any?) { reader.zoom(.zoomOut) }
    @objc func shellFitWidth(_ sender: Any?) { reader.zoom(.fitWidth) }

    @objc func shellShowComments(_ sender: Any?) { show(.comments) }
    @objc func shellShowChat(_ sender: Any?) { show(.chat) }
    @objc func shellShowReport(_ sender: Any?) { show(.report) }
    @objc func shellToggleNavigator(_ sender: Any?) { windowState.toggleNavigator() }
    @objc func shellToggleSidebar(_ sender: Any?) { windowState.showSidebar.toggle() }

    private func show(_ tab: SidebarTab) {
        model.sidebarTab = tab
        windowState.showSidebar = true
    }

    @objc func shellRunReview(_ sender: Any?) { model.startReview() }
    /// ⌘.: the review lane's job, or else the reply being written; also answers a consent card "no".
    @objc func shellCancel(_ sender: Any?) {
        if model.consentRequest != nil {
            model.answerConsent(granted: false)
        } else if case .running = model.runState {
            model.cancelRun()
        } else {
            model.cancelReply()
        }
    }
    @objc func shellGenerateReport(_ sender: Any?) {
        model.generateReport()
        show(.report)
    }

    @objc func shellApprove(_ sender: Any?) { perform(.approve) }
    @objc func shellReject(_ sender: Any?) { perform(.reject) }
    @objc func shellDiscuss(_ sender: Any?) { perform(.discuss) }
    @objc func shellEditComment(_ sender: Any?) { perform(.edit) }
    @objc func shellNextComment(_ sender: Any?) { perform(.next) }
    @objc func shellPreviousComment(_ sender: Any?) { perform(.previous) }
    @objc func shellNewComment(_ sender: Any?) { perform(.newComment) }

    /// File ▸ Export Report…: a save panel with the four formats of section 6.10.
    @objc func shellExportReport(_ sender: Any?) {
        guard let window, model.session?.report != nil else { return }
        let panel = NSSavePanel()
        panel.title = "Export Report"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + " report"
        let picker = ShellExportFormatPicker(panel: panel)
        exportFormatPicker = picker
        panel.accessoryView = picker.view
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                let format = picker.format
                self.exportFormatPicker = nil
                guard response == .OK, let destination = panel.url else { return }
                do {
                    try self.model.exportReport(format: format, to: destination)
                } catch {
                    let message = (error as? any RefereeError)?.userMessage ?? "The report could not be exported."
                    self.windowState.notice = ShellNotice(style: .error, message: message)
                }
            }
        }
    }

    /// File ▸ Delete Review Data…: after confirmation the review's folder goes, and the window closes (section 9.1).
    @objc func shellDeleteReviewData(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete the review data of “\(url.lastPathComponent)”?"
        alert.informativeText = "Its comments, discussions, questions, report and reference lookups are deleted from this Mac. "
            + "The PDF itself is not changed. This cannot be undone."
        let delete = alert.addButton(withTitle: "Delete")
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                guard let self else { return }
                await self.model.deleteReviewData()
                self.window?.close()
            }
        }
    }

    // ---- enabling the menu items ----

    /// While a sheet is over the window (the export panel, the delete confirmation) only the view commands work: a
    /// second sheet, a review behind a pending deletion or a key taken from the sheet's text field must not happen.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let blocked = model.consentRequest != nil
        let ready = model.phase == .ready && model.session != nil
        let triage = ready && !blocked && keysReachTriage
        let reviewLaneRunning: Bool = { if case .running = model.runState { return true } else { return false } }()
        let viewCommands: Set<Selector> = [#selector(shellToggleNavigator(_:)), #selector(shellToggleSidebar(_:)),
                                           #selector(shellShowComments(_:)), #selector(shellShowChat(_:)), #selector(shellShowReport(_:))]
        if window?.attachedSheet != nil, let action = item.action, !viewCommands.contains(action) { return false }
        switch item.action {
        case #selector(shellFind(_:)), #selector(shellFindNext(_:)), #selector(shellFindPrevious(_:)),
             #selector(shellZoomIn(_:)), #selector(shellZoomOut(_:)), #selector(shellFitWidth(_:)):
            return reader.isDocumentLoaded
        case #selector(shellToggleNavigator(_:)):
            item.title = windowState.showsNavigator ? "Hide Navigator" : "Show Navigator"
            return true
        case #selector(shellToggleSidebar(_:)):
            item.title = windowState.showSidebar ? "Hide Sidebar" : "Show Sidebar"
            return true
        case #selector(shellShowComments(_:)):
            item.state = model.sidebarTab == .comments ? .on : .off
            return true
        case #selector(shellShowChat(_:)):
            item.state = model.sidebarTab == .chat ? .on : .off
            return true
        case #selector(shellShowReport(_:)):
            item.state = model.sidebarTab == .report ? .on : .off
            return true
        case #selector(shellRunReview(_:)):
            return model.canStartReview
        case #selector(shellCancel(_:)):
            return blocked || reviewLaneRunning || model.streamingTargetID != nil
        case #selector(shellGenerateReport(_:)):
            return ready && !blocked && !reviewLaneRunning
        case #selector(shellApprove(_:)), #selector(shellReject(_:)), #selector(shellDiscuss(_:)), #selector(shellEditComment(_:)):
            return triage && model.selectedCommentID != nil
        case #selector(shellNextComment(_:)), #selector(shellPreviousComment(_:)):
            return triage && !model.visibleComments.isEmpty
        case #selector(shellNewComment(_:)):
            return triage
        case #selector(shellExportReport(_:)):
            return model.session?.report != nil
        case #selector(shellDeleteReviewData(_:)):
            return model.session != nil
        default:
            return true
        }
    }
}

/// The format choice under the export panel's file name; the file name's extension follows the choice.
@MainActor final class ShellExportFormatPicker: NSObject {
    private weak var panel: NSSavePanel?
    private let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let view: NSView
    private(set) var format: ExportFormat = .markdown

    nonisolated static let choices: [(ExportFormat, String)] = [(.markdown, "Markdown"), (.plainText, "Plain text"), (.docx, "Word document"), (.pdf, "PDF")]

    init(panel: NSSavePanel) {
        self.panel = panel
        let label = NSTextField(labelWithString: "Format:")
        let stack = NSStackView(views: [label, popUp])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        view = stack
        super.init()
        for (_, title) in Self.choices { popUp.addItem(withTitle: title) }
        popUp.target = self
        popUp.action = #selector(formatChanged(_:))
        apply()
    }

    @objc private func formatChanged(_ sender: NSPopUpButton) {
        format = Self.choices[max(0, sender.indexOfSelectedItem)].0
        apply()
    }

    /// The file type the panel accepts, and the file name's extension: "md" rather than the Markdown type's own
    /// "markdown", which the panel would otherwise propose.
    private func apply() {
        guard let panel else { return }
        panel.allowedContentTypes = [Self.contentType(format)]
        panel.nameFieldStringValue = Self.fileName(panel.nameFieldStringValue, for: format)
    }

    /// The name with the format's extension: an extension of one of the four formats is replaced, anything else kept
    /// ("paper.v2 report" -> "paper.v2 report.md").
    nonisolated static func fileName(_ name: String, for format: ExportFormat) -> String {
        let known = Set(ExportFormat.allCases.map(fileExtension) + ["markdown"])
        let current = (name as NSString).pathExtension.lowercased()
        let base = known.contains(current) ? (name as NSString).deletingPathExtension : name
        return base + "." + fileExtension(format)
    }

    nonisolated static func fileExtension(_ format: ExportFormat) -> String {
        switch format {
        case .markdown: return "md"
        case .plainText: return "txt"
        case .docx: return "docx"
        case .pdf: return "pdf"
        }
    }

    nonisolated static func contentType(_ format: ExportFormat) -> UTType {
        switch format {
        case .markdown: return UTType(filenameExtension: "md") ?? .plainText
        case .plainText: return .plainText
        case .docx: return UTType(filenameExtension: "docx") ?? .data
        case .pdf: return .pdf
        }
    }
}
