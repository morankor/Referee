import SwiftUI
import AppKit
import CryptoKit
import UniformTypeIdentifiers
import RefereeCore
import AppCore

/// Every window of the app (plan.md section 9.1): one review window per document, found by the SHA-256 of the file's
/// bytes (opening a document that is open brings its window forward); reference viewers; the one settings window;
/// the welcome window; help. It holds the app's one `SettingsModel` and passes each settings change to every open
/// review (`reloadSettings`, on `.refereeSettingsDidChange`).
@MainActor final class ShellWindowManager {
    let dependencies: AppDependencies
    let settingsModel: SettingsModel
    let settingsNavigation = ShellSettingsNavigation()

    private(set) var reviewControllers: [ShellReviewWindowController] = []
    /// Windows that have closed and whose model is still closing (cancelling jobs, saving), kept alive until it is done.
    private var closing: [ObjectIdentifier: (controller: ShellReviewWindowController, task: Task<Void, Never>)] = [:]
    private var openingFiles: Set<String> = []
    private var settingsWindow: NSWindow?
    private var welcomeWindow: NSWindow?
    private var helpWindow: NSWindow?
    private var auxiliaryWindows: [ObjectIdentifier: (window: NSWindow, observer: NSObjectProtocol)] = [:]
    private var settingsObserver: NSObjectProtocol?
    /// Bumped by every request for the welcome window and by every document opened: a welcome window whose recent
    /// list arrives after a document was opened is not shown over it.
    private var welcomeGeneration = 0

    init(dependencies: AppDependencies, settingsModel: SettingsModel) {
        self.dependencies = dependencies
        self.settingsModel = settingsModel
        settingsObserver = NotificationCenter.default.addObserver(forName: .refereeSettingsDidChange, object: settingsModel,
                                                                  queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsDidChange() }
        }
    }

    private func settingsDidChange() {
        let settings = settingsModel.settings
        for controller in reviewControllers { controller.model.reloadSettings(settings) }
    }

    // ---- what the windows get ----

    /// The closures panes reach through the environment (section 9.1).
    var uiActions: UIActions {
        var actions = UIActions()
        actions.openReferenceViewer = { [weak self] fileURL, title in self?.openReferenceViewer(fileURL: fileURL, title: title) }
        actions.openSettings = { [weak self] in self?.showSettings() }
        actions.openInBrowser = { url in
            // Addresses can come from a model's output or a reference service: only web pages are opened.
            guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return }
            NSWorkspace.shared.open(url)
        }
        return actions
    }

    var windowServices: ShellWindowServices {
        ShellWindowServices(settings: settingsModel,
                            openSettings: { [weak self] tab in self?.showSettings(tab: tab) },
                            showOpenPanel: { [weak self] in self?.showOpenPanel() },
                            openFiles: { [weak self] urls in for url in urls { self?.open(url) } },
                            uiActions: uiActions)
    }

    private var settingsServices: ShellSettingsServices {
        ShellSettingsServices(deleteAllReviewData: { [weak self] model in
            await self?.closeAllReviewWindows()
            try await model.deleteAllReviewData()
        }, revealInFinder: { url in NSWorkspace.shared.activateFileViewerSelecting([url]) })
    }

    // ---- review windows ----

    /// Opens a PDF, or brings its window forward.
    func open(_ url: URL) {
        Task { @MainActor in await openReview(url: url) }
    }

    /// One window per document hash (section 9.1): a document that is open already has its window brought forward. The
    /// same path asked for twice while it is being read (Finder and the command line can both hand a file over at
    /// launch) is opened once. A file that cannot be read still gets a window, which says why (section 9.9).
    func openReview(url: URL) async {
        let file = url.standardizedFileURL
        guard !openingFiles.contains(file.path) else { return }
        openingFiles.insert(file.path)
        welcomeGeneration += 1
        let hash = await ShellWindowManager.sha256(of: file)
        // A window of this document that is still closing saves first; the new window then reads what it saved.
        if let hash, let previous = closing.values.first(where: { $0.controller.documentHash == hash }) { await previous.task.value }
        openingFiles.remove(file.path)
        // From here to the window's registration nothing waits, so two copies of one document cannot both get a window.
        if let hash, let existing = reviewControllers.first(where: { $0.documentHash == hash }) {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let model = ReviewSessionModel(dependencies: dependencies, settings: settingsModel.settings)
        let controller = ShellReviewWindowController(model: model, url: file, documentHash: hash, manager: self)
        reviewControllers.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        welcomeWindow?.close()
        await controller.load()
        if case .ready = model.phase { NSDocumentController.shared.noteNewRecentDocumentURL(file) }
    }

    /// Called by a review window that is closing: its model stops its jobs, saves and lets the paper go.
    func reviewWindowWillClose(_ controller: ShellReviewWindowController) {
        reviewControllers.removeAll { $0 === controller }
        let key = ObjectIdentifier(controller)
        let task = Task { @MainActor in await controller.model.close() }
        closing[key] = (controller, task)
        Task { @MainActor [weak self] in
            await task.value
            self?.closing[key] = nil
        }
    }

    /// Settings ▸ Privacy ▸ "Delete all review data…" closes every review window first, so that none saves its session again.
    func closeAllReviewWindows() async {
        for controller in reviewControllers { controller.window?.close() }
        for entry in closing.values { await entry.task.value }
    }

    /// Before the app quits: every text field hands over what is typed in it (fields save on leaving them), every open
    /// review saves now, closing ones finish, and the settings save a change still waiting for its 0.5 s debounce
    /// (`SettingsModel.flushPendingSave`, public since Wave 3).
    func flushAll() async {
        for window in NSApp.windows { window.makeFirstResponder(nil) }
        try? await Task.sleep(for: .milliseconds(150))        // the views see the focus go and commit
        for controller in reviewControllers { await controller.model.flushPendingSave() }
        for entry in closing.values { await entry.task.value }
        await settingsModel.flushPendingSave()
    }

    /// The SHA-256 of a file's bytes, read off the main actor; nil when the file cannot be read.
    @concurrent nonisolated static func sha256(of url: URL) async -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // ---- other windows ----

    /// File ▸ Open…
    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose a manuscript to review."
        panel.prompt = "Open"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated {
                for url in urls { self?.open(url) }
            }
        }
    }

    /// A cited paper, in a window of its own (section 7.7).
    func openReferenceViewer(fileURL: URL, title: String) {
        let hosting = NSHostingController(rootView: ReferenceViewerView(fileURL: fileURL, title: title).environment(\.uiActions, uiActions))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        window.title = title
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.setContentSize(NSSize(width: 900, height: 700))
        window.center()
        keepUntilClosed(window)
        window.makeKeyAndOrderFront(nil)
    }

    /// The one settings window (section 9.6), on `tab` when one is given.
    func showSettings(tab: ShellSettingsTab? = nil) {
        if let tab { settingsNavigation.tab = tab }
        if settingsWindow == nil {
            let view = SettingsRootView(model: settingsModel, navigation: settingsNavigation, services: settingsServices)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view.environment(\.uiActions, uiActions)))
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.title = "Settings"
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.setContentSize(SettingsRootView.size)
            window.center()
            window.setFrameAutosaveName("Referee.Settings")
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// The welcome window (section 9.1), with the recent reviews as they are now.
    func showWelcome() {
        welcomeGeneration += 1
        let generation = welcomeGeneration
        Task { @MainActor in
            let recent = Array(await dependencies.sessions.listSessions().prefix(20))
            guard generation == welcomeGeneration else { return }       // a document was opened meanwhile
            let view = WelcomeView(recent: recent, open: { [weak self] url in
                if let url { self?.open(url) } else { self?.showOpenPanel() }
            }, providerLine: { [weak self] in
                guard let self else { return .unknown }
                return ShellDestination.welcomeLine(settings: self.settingsModel.settings, providers: self.settingsModel.providers)
            }, openSettings: { [weak self] in self?.showSettings(tab: .providers) })
            if let window = welcomeWindow, let hosting = window.contentViewController as? NSHostingController<WelcomeView> {
                hosting.rootView = view
            } else {
                let window = NSWindow(contentViewController: NSHostingController(rootView: view))
                window.styleMask = [.titled, .closable, .miniaturizable]
                window.title = "Referee"
                window.isReleasedWhenClosed = false
                window.isRestorable = false
                window.center()
                welcomeWindow = window
            }
            welcomeWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }

    /// Help ▸ Referee Help: the keys and where things are, and the README when it can be found.
    func showHelp() {
        if helpWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: ShellHelpView(readme: ShellHelpView.findReadme())))
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.title = "Referee Help"
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.center()
            helpWindow = window
        }
        helpWindow?.makeKeyAndOrderFront(nil)
    }

    /// Keeps a window of no other owner alive until it closes.
    private func keepUntilClosed(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let entry = self.auxiliaryWindows[key] else { return }
                NotificationCenter.default.removeObserver(entry.observer)
                self.auxiliaryWindows[key] = nil
            }
        }
        auxiliaryWindows[key] = (window, observer)
    }
}
