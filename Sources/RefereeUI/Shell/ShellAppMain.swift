import SwiftUI
import AppKit
import RefereeCore
import AppCore

// The entry point (plan.md section 9.1). AppKit owns the lifecycle and the windows; every window's content is SwiftUI
// in an NSHostingController. "--ui-snapshot <dir> …" runs the snapshot mode instead (section 10.1) and exits.

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
            let delegate = ShellAppDelegate(makeDependencies: makeDependencies, arguments: arguments)
            ShellAppDelegate.running = delegate          // NSApplication holds its delegate weakly
            application.delegate = delegate
        }
        application.run()
        exit(0)
    }
}
