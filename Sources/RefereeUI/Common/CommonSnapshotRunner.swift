import SwiftUI
import AppKit
import RefereeCore
import AppCore

// Wave 0a placeholder (plan.md section 11.4, WP0a). WP0b writes the mechanism of section 10.1 here.

@MainActor public enum SnapshotRunner {
    /// Runs ShellScenes.all + ReaderScenes.all + SidebarScenes.all + IntegrationScenes.all (or the named ones) and returns the exit code.
    /// Placeholder: captures nothing and returns 1, the code for "not every scene was captured".
    public static func run(arguments: [String], makeDependencies: @escaping @Sendable ([String: String]) async -> AppDependencies) async -> Int32 {
        Log.event("snapshot.unavailable")
        return 1
    }
}
