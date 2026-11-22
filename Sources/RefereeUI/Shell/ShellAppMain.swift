import SwiftUI
import AppKit
import RefereeCore
import AppCore

// Wave 0 placeholder (plan.md section 11.4, WP0a). WP0b replaces `start` with a minimal shell that opens a review
// window for a PDF path and runs the snapshot mode; WP11 writes the real one (section 9.1).

public enum AppMain {
    /// Parses arguments. "--ui-snapshot <dir> …" runs the snapshot mode (section 10.1) and exits; otherwise starts the app.
    /// Not @MainActor: top-level code in main.swift is not main-actor-isolated in Swift 5 mode. The body is
    /// MainActor.assumeIsolated { start(makeDependencies) }.
    public static func run(makeDependencies: @escaping @Sendable (_ environmentOverrides: [String: String]) async -> AppDependencies) -> Never {
        MainActor.assumeIsolated { start(makeDependencies) }
    }

    /// Placeholder shell. With "--ui-snapshot" it asks the snapshot runner and exits with its code. Otherwise it
    /// shows the (still empty) welcome window and a menu with Quit, so that a launched build is visible and can be closed.
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
            application.mainMenu = placeholderMenu()
            let window = NSWindow(contentViewController: NSHostingController(rootView: WelcomeView(recent: [], open: { _ in })))
            window.title = "Referee"
            window.setContentSize(NSSize(width: 560, height: 360))
            window.center()
            window.makeKeyAndOrderFront(nil)
            welcomeWindow = window
            application.activate()
        }
        application.run()
        exit(0)
    }

    @MainActor private static var welcomeWindow: NSWindow?      // keeps the placeholder window alive

    @MainActor private static func placeholderMenu() -> NSMenu {
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "Quit Referee", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let applicationItem = NSMenuItem()
        applicationItem.submenu = applicationMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(applicationItem)
        return mainMenu
    }
}
