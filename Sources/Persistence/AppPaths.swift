import Foundation
import RefereeCore

// Written in Wave 0 (plan.md section 11.4, WP0a) in its final shape, because every later step relies on REFEREE_HOME
// keeping tests, the command-line tool and snapshot runs out of the user's Library; kept by WP8a and tested in
// Tests/PersistenceTests/AppPathsTests.swift. Both functions only compute URLs: nothing is created or read here.

/// Where Referee keeps its data (plan.md sections 4.2 and 10.6). An empty REFEREE_HOME counts as unset.
public enum AppPaths {                                   // honours REFEREE_HOME: data = $REFEREE_HOME, caches = $REFEREE_HOME/Caches
    /// Settings and sessions: $REFEREE_HOME when it is set, otherwise "Application Support/Referee" in the user's Library.
    public static func dataDirectory(environment: [String: String]) -> URL {
        if let home = home(in: environment) { return home }
        return library(.applicationSupportDirectory, named: "Application Support").appendingPathComponent("Referee", isDirectory: true)
    }

    /// Downloaded papers: $REFEREE_HOME/Caches when REFEREE_HOME is set, otherwise "Caches/Referee" in the user's Library.
    public static func cacheDirectory(environment: [String: String]) -> URL {
        if let home = home(in: environment) { return home.appendingPathComponent("Caches", isDirectory: true) }
        return library(.cachesDirectory, named: "Caches").appendingPathComponent("Referee", isDirectory: true)
    }

    private static func home(in environment: [String: String]) -> URL? {
        guard let path = environment["REFEREE_HOME"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func library(_ directory: FileManager.SearchPathDirectory, named name: String) -> URL {
        FileManager.default.urls(for: directory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
    }
}
