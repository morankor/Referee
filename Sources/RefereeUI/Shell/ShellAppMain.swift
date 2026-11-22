import SwiftUI
import AppKit
import RefereeCore
import AppCore

// Wave 0 (plan.md section 11.4, WP0b): a minimal shell. It runs the snapshot mode, opens a review window for a PDF
// path given on the command line, and otherwise shows the placeholder welcome window. WP11 writes the real one
// (section 9.1): application delegate, window manager, main menu, opening files from Finder.

public enum AppMain {
    /// Parses arguments. "--ui-snapshot <dir> …" runs the snapshot mode (section 10.1) and exits; otherwise starts the app.
    /// Not @MainActor: top-level code in main.swift is not main-actor-isolated in Swift 5 mode. The body is
    /// MainActor.assumeIsolated { start(makeDependencies) }.
    public static func run(makeDependencies: @escaping @Sendable (_ environmentOverrides: [String: String]) async -> AppDependencies) -> Never {
        MainActor.assumeIsolated { start(makeDependencies) }
    }

    @MainActor private static func start(_ makeDependencies: @escaping @Sendable ([String: String]) async -> AppDependencies) -> Never {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let application = NSApplication.shared
        if arguments.contains("--ui-snapshot") {
            application.setActivationPolicy(.accessory)
            Task { @MainActor in
                exit(await SnapshotRunner.run(arguments: arguments, makeDependencies: makeDependencies))
            }
        } else {
            application.setActivationPolicy(.regular)
            application.mainMenu = minimalMenu()
            Task { @MainActor in
                let dependencies = await makeDependencies([:])
                let settings = await dependencies.settings.load()
                if let path = arguments.first(where: { !$0.hasPrefix("-") }) {
                    await openReview(URL(fileURLWithPath: path), dependencies: dependencies, settings: settings)
                } else {
                    show(WelcomeView(recent: [], open: { _ in }), title: "Referee", size: NSSize(width: 640, height: 440), isDocumentWindow: false)
                    Log.event("shell.welcome.shown")
                }
                application.activate()
            }
        }
        application.run()
        exit(0)
    }

    /// One review window: its model, its reader (attached at once, section 7.4), then the document.
    @MainActor private static func openReview(_ url: URL, dependencies: AppDependencies, settings: AppSettings) async {
        let model = ReviewSessionModel(dependencies: dependencies, settings: settings)
        let reader = ReaderController(model: model)
        let window = show(ReviewWindowView(model: model, reader: reader), title: url.lastPathComponent, size: NSSize(width: 1280, height: 800),
                          isDocumentWindow: true)
        window.representedURL = url
        reader.attach()
        await model.open(url: url)
        await Task.yield()          // lets the reader, which is told about the paper asynchronously, show it first
        // The only trace a launch leaves for whoever checks it from outside (plan section 11.1): no file name, no text.
        if case .ready = model.phase {
            Log.event("shell.review.ready", ["pages": .int(model.paper?.ref.pageCount ?? 0), "document": .bool(reader.isDocumentLoaded)])
        } else {
            Log.event("shell.review.failed")
        }
    }

    @MainActor private static var windows: [NSWindow] = []      // keeps the windows of the minimal shell alive

    @MainActor @discardableResult
    private static func show(_ root: some View, title: String, size: NSSize, isDocumentWindow: Bool) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.isReleasedWhenClosed = false
        window.styleMask = isDocumentWindow
            ? [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
            : [.titled, .closable, .miniaturizable]
        window.title = title        // .navigationTitle does not reach a window made around NSHostingController (section 7.5)
        window.setContentSize(size)
        if isDocumentWindow { window.contentMinSize = NSSize(width: 1000, height: 640) }
        window.center()
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
        return window
    }

    @MainActor private static func minimalMenu() -> NSMenu {
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "Quit Referee", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let applicationItem = NSMenuItem()
        applicationItem.submenu = applicationMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(applicationItem)
        return mainMenu
    }
}
