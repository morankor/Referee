import SwiftUI
import AppKit
import UniformTypeIdentifiers
import RefereeCore
import AppCore

/// The application delegate (plan.md section 9.1): builds the main menu; at launch makes the dependencies and the one
/// `SettingsModel`, hands them to the window manager and applies the first-run defaults once; opens the files it is
/// given (Finder's "Open With", the Dock, PDF paths on the command line) or else the welcome window; keeps running
/// when the last window closes; saves every review before quitting.
@MainActor final class ShellAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    /// The delegate of the running app. `NSApplication.delegate` is weak, so this keeps it alive.
    static var running: ShellAppDelegate?

    private let makeDependencies: @Sendable ([String: String]) async -> AppDependencies
    private let launchFiles: [URL]
    private(set) var windowManager: ShellWindowManager?
    private var pendingFiles: [URL] = []
    private var keyWindowObservers: [NSObjectProtocol] = []

    init(makeDependencies: @escaping @Sendable ([String: String]) async -> AppDependencies, arguments: [String]) {
        self.makeDependencies = makeDependencies
        self.launchFiles = ShellAppDelegate.files(in: arguments, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath,
                                                                                isDirectory: true))
        super.init()
    }

    /// The PDFs named on the command line ("scripts/run.sh paper.pdf"; "open -n Referee.app --args /path/to/paper.pdf",
    /// whose path must be absolute because Launch Services starts the app in "/"): the arguments that are not options
    /// and name an existing file, relative paths read from the current directory.
    nonisolated static func files(in arguments: [String], relativeTo directory: URL) -> [URL] {
        arguments.filter { !$0.hasPrefix("-") }.compactMap { argument in
            let url = argument.hasPrefix("/") ? URL(fileURLWithPath: argument) : URL(fileURLWithPath: argument, relativeTo: directory)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
            return url.absoluteURL.standardizedFileURL
        }
    }

    // ---- launch ----

    func applicationWillFinishLaunching(_ notification: Notification) {
        ShellMainMenu.install(appDelegate: self)
        ShellMainMenu.setReaderKeys(enabled: false, in: NSApp.mainMenu)
        // Find and zoom keep their keys only while a review window is key (ShellMainMenu.setReaderKeys). A window that
        // resigns is followed by the next one becoming key, or by none (the app went to the background), so both
        // notifications look at the key window a moment later, once AppKit has settled which one it is.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyWindowObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    ShellMainMenu.setReaderKeys(enabled: ShellMainMenu.reviewWindowIsKey(NSApp.keyWindow), in: NSApp.mainMenu)
                }
            })
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in await self.start() }
        NSApp.activate()
    }

    private func start() async {
        let dependencies = await makeDependencies([:])
        let settings = await dependencies.settings.load()
        let settingsModel = SettingsModel(dependencies: dependencies, settings: settings)
        let manager = ShellWindowManager(dependencies: dependencies, settingsModel: settingsModel)
        windowManager = manager
        Task { await settingsModel.applyFirstRunDefaultsIfNeeded() }      // once, at launch; never enables a remote provider
        var files: [URL] = []
        for file in launchFiles + pendingFiles where !files.contains(file) { files.append(file) }
        pendingFiles = []
        if files.isEmpty {
            manager.showWelcome()
            Log.event("shell.welcome.shown")
        } else {
            for file in files { manager.open(file) }
        }
    }

    /// Finder, the Dock and `open` hand files over here, before or after the app has finished starting.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL).map(\.standardizedFileURL)
        if let windowManager {
            for file in files { windowManager.open(file) }
        } else {
            pendingFiles += files
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// The Dock's count of new comments, or its "✓" after a report, set when a long job ended in the background
    /// (design review D32), goes once the referee is back.
    func applicationDidBecomeActive(_ notification: Notification) {
        NSApp.dockTile.badgeLabel = nil
    }

    /// A click on the Dock icon with no window open shows the welcome window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { windowManager?.showWelcome() }
        return true
    }

    /// Every review saves what is pending before the app quits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let windowManager else { return .terminateNow }
        Task { @MainActor in
            await windowManager.flushAll()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // ---- menu actions of the app (the window actions are in ShellReviewWindowController) ----

    @objc func shellShowSettings(_ sender: Any?) { windowManager?.showSettings() }
    @objc func shellOpenDocument(_ sender: Any?) { windowManager?.showOpenPanel() }
    @objc func shellShowWelcome(_ sender: Any?) { windowManager?.showWelcome() }
    @objc func shellShowHelp(_ sender: Any?) { windowManager?.showHelp() }

    @objc func shellOpenRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        windowManager?.open(url)
    }

    @objc func shellClearRecent(_ sender: Any?) {
        NSDocumentController.shared.clearRecentDocuments(sender)
    }

    /// File ▸ Open Recent, built when it opens: the system's list of recent documents, then "Clear Menu". The icon is
    /// the one of PDFs, not the file's own: asking for a file's icon touches the file, which can hang on a volume that
    /// is gone.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.identifier == ShellMainMenu.openRecentIdentifier else { return }
        menu.removeAllItems()
        let recent = NSDocumentController.shared.recentDocumentURLs
        let icon = NSWorkspace.shared.icon(for: .pdf)
        icon.size = NSSize(width: 16, height: 16)
        for url in recent {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(shellOpenRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.image = icon
            item.toolTip = (url.path as NSString).abbreviatingWithTildeInPath
            menu.addItem(item)
        }
        if !recent.isEmpty { menu.addItem(.separator()) }
        let clear = NSMenuItem(title: "Clear Menu", action: recent.isEmpty ? nil : #selector(shellClearRecent(_:)), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    /// Open Recent has no key equivalents. Without this answer AppKit would build the menu on every key press to look
    /// for one.
    func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
                              action: UnsafeMutablePointer<Selector?>) -> Bool {
        false
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        windowManager != nil || item.action == #selector(shellClearRecent(_:))
    }
}
