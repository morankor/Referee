import Foundation
import RefereeCore

// Written in Wave 0 (plan.md section 11.4, WP0a) in its final shape, because every later step relies on REFEREE_HOME
// keeping tests, the command-line tool and snapshot runs out of the user's Library; kept by WP8a and tested in
// Tests/PersistenceTests/AppPathsTests.swift. `dataDirectory` and `cacheDirectory` only compute URLs: nothing is
// created or read there. Step 5 renamed the app "Human in the Loop" and with it the two folders; the folders of the
// former name move once, through `directoriesMovingFormerFolders` (plan.md section 4.2, docs/brand/brand.md 7.2).

/// Where the app keeps its data (plan.md sections 4.2 and 10.6). An empty REFEREE_HOME counts as unset.
public enum AppPaths {                                   // honours REFEREE_HOME: data = $REFEREE_HOME, caches = $REFEREE_HOME/Caches
    /// The name of the app's folders in the user's Library: the app's name.
    public static let folderName = "Human in the Loop"
    /// Their name before step 5. A folder of this name moves to `folderName` once.
    public static let formerFolderName = "Referee"

    /// Settings and sessions: $REFEREE_HOME when it is set, otherwise "Application Support/Human in the Loop" in the
    /// user's Library.
    public static func dataDirectory(environment: [String: String]) -> URL {
        if let home = home(in: environment) { return home }
        return library(.applicationSupportDirectory, named: "Application Support").appendingPathComponent(folderName, isDirectory: true)
    }

    /// Downloaded papers: $REFEREE_HOME/Caches when REFEREE_HOME is set, otherwise "Caches/Human in the Loop" in the
    /// user's Library.
    public static func cacheDirectory(environment: [String: String]) -> URL {
        if let home = home(in: environment) { return home.appendingPathComponent("Caches", isDirectory: true) }
        return library(.cachesDirectory, named: "Caches").appendingPathComponent(folderName, isDirectory: true)
    }

    /// The data and cache folders the app uses, once those of the former name have moved: the app calls this once,
    /// at launch, before any store opens. With REFEREE_HOME set nothing moves and the result is `dataDirectory` and
    /// `cacheDirectory`. Otherwise each of "Application Support/Referee" and "Caches/Referee" moves to the new name
    /// as `moveFormerFolder` says. `otherCopyRunning` is asked only when a folder would move; `applicationSupport`
    /// and `caches` are the Library's folders (tests pass temporary ones).
    public static func directoriesMovingFormerFolders(environment: [String: String], otherCopyRunning: () -> Bool,
                                                      applicationSupport: URL? = nil, caches: URL? = nil) -> (data: URL, caches: URL) {
        guard home(in: environment) == nil else {
            return (dataDirectory(environment: environment), cacheDirectory(environment: environment))
        }
        let supportFolder = applicationSupport ?? library(.applicationSupportDirectory, named: "Application Support")
        let cachesFolder = caches ?? library(.cachesDirectory, named: "Caches")
        var running: Bool?
        let isRunning = { () -> Bool in
            if let known = running { return known }
            let answer = otherCopyRunning()
            running = answer
            return answer
        }
        let data = moveFormerFolder(supportFolder.appendingPathComponent(formerFolderName, isDirectory: true),
                                    to: supportFolder.appendingPathComponent(folderName, isDirectory: true), otherCopyRunning: isRunning)
        let cache = moveFormerFolder(cachesFolder.appendingPathComponent(formerFolderName, isDirectory: true),
                                     to: cachesFolder.appendingPathComponent(folderName, isDirectory: true), otherCopyRunning: isRunning)
        return (data, cache)
    }

    /// Moves one folder of the former name to its new name and returns the folder to use. Nothing is ever deleted,
    /// merged or copied:
    /// - the new folder exists: it is used, and the former one is left as it is;
    /// - neither exists: the new one is used (the stores create it);
    /// - only the former exists and another copy of the app is running: the former is used for this launch, so that
    ///   it is not moved from under that copy; a later launch moves it;
    /// - only the former exists: it is moved (a rename within the Library: atomic, instant); if the move fails, the
    ///   former is used for this launch and a later launch tries again.
    public static func moveFormerFolder(_ former: URL, to current: URL, otherCopyRunning: () -> Bool) -> URL {
        let manager = FileManager.default
        if manager.fileExists(atPath: current.path) { return current }
        guard manager.fileExists(atPath: former.path) else { return current }
        if otherCopyRunning() {
            Log.event("paths.migrate.deferred")
            return former
        }
        do {
            try manager.moveItem(at: former, to: current)
            Log.event("paths.migrate.moved")
            return current
        } catch {
            Log.event("paths.migrate.failed")
            return former
        }
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
