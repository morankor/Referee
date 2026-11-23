import Foundation
import Testing
import RefereeCore
import Persistence

/// WP8a acceptance row "paths" (plan.md section 11.4). `AppPaths` only computes URLs from the dictionary it is given,
/// so these tests pass environments and never set a variable or create anything in the user's Library.
@Suite struct AppPathsTests {
    @Test func refereeHomeIsTheDataDirectoryWithTheCachesInside() {
        for environment in [["REFEREE_HOME": "/x"], ["REFEREE_HOME": "/x/"], ["REFEREE_HOME": "/x", "HOME": "/elsewhere", "TMPDIR": "/t"]] {
            #expect(AppPaths.dataDirectory(environment: environment).path == "/x")
            #expect(AppPaths.cacheDirectory(environment: environment).path == "/x/Caches")
        }
    }

    @Test func withoutRefereeHomeTheUsersApplicationSupportAndCachesAreUsed() throws {
        let manager = FileManager.default
        let applicationSupport = try #require(manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let caches = try #require(manager.urls(for: .cachesDirectory, in: .userDomainMask).first)
        let home = manager.homeDirectoryForCurrentUser.standardizedFileURL.path

        for environment in [[:], ["REFEREE_HOME": ""], ["HOME": "/elsewhere"]] {
            let data = AppPaths.dataDirectory(environment: environment)
            let cache = AppPaths.cacheDirectory(environment: environment)
            #expect(data.standardizedFileURL == applicationSupport.appendingPathComponent("Human in the Loop", isDirectory: true).standardizedFileURL)
            #expect(cache.standardizedFileURL == caches.appendingPathComponent("Human in the Loop", isDirectory: true).standardizedFileURL)
            #expect(data.path.hasSuffix("/Library/Application Support/Human in the Loop"))
            #expect(cache.path.hasSuffix("/Library/Caches/Human in the Loop"))
            #expect(data.standardizedFileURL.path.hasPrefix(home + "/"))
            #expect(cache.standardizedFileURL.path.hasPrefix(home + "/"))
        }
    }

    @Test func computingAPathCreatesNothing() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("referee-paths-\(UUID().uuidString)", isDirectory: true)
        let environment = ["REFEREE_HOME": home.path]
        #expect(AppPaths.dataDirectory(environment: environment).standardizedFileURL == home.standardizedFileURL)
        #expect(AppPaths.cacheDirectory(environment: environment).standardizedFileURL
                == home.appendingPathComponent("Caches", isDirectory: true).standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: home.path))
    }

    @Test func theStoresOfTheCompositionLiveUnderTheDataDirectory() async throws {
        // LiveDependencies builds the stores from these two folders (plan section 11.3); this is the same wiring on a
        // temporary REFEREE_HOME, showing that nothing escapes it.
        try await withTemporaryFolder { root in
            let data = AppPaths.dataDirectory(environment: ["REFEREE_HOME": root.path])
            let sessions = FileSessionStore(directory: data.appendingPathComponent("sessions"))
            let settings = FileSettingsStore(fileURL: data.appendingPathComponent("settings.json"))
            try await settings.save(DefaultSettings.make())
            try await sessions.save(Samples.session(sha256: Samples.sha("ab")))
            #expect(names(in: root) == ["sessions", "settings.json"])
            #expect(names(in: root.appendingPathComponent("sessions")) == [Samples.sha("ab")])
        }
    }

    // ---- step 5: the folders of the former name move once (plan.md section 4.2, docs/brand/brand.md 7.2) ----
    // Every test works in a Library of its own in a temporary folder; none touches the user's.

    @Test func theNamesAreTheAppsOldAndNew() {
        #expect(AppPaths.folderName == "Human in the Loop")
        #expect(AppPaths.formerFolderName == "Referee")
    }

    @Test func theFoldersOfTheFormerNameMoveOnceWhenNoNewOneExists() throws {
        try withTemporaryFolderSync { root in
            let library = try makeLibrary(in: root, former: true, current: false)
            let before = try contents(of: library.support.appendingPathComponent("Referee"))
            var asked = 0
            let used = AppPaths.directoriesMovingFormerFolders(environment: [:], otherCopyRunning: { asked += 1; return false },
                                                               applicationSupport: library.support, caches: library.caches)
            #expect(used.data == library.support.appendingPathComponent("Human in the Loop", isDirectory: true))
            #expect(used.caches == library.caches.appendingPathComponent("Human in the Loop", isDirectory: true))
            #expect(names(in: library.support) == ["Human in the Loop"])
            #expect(names(in: library.caches) == ["Human in the Loop"])
            #expect(try contents(of: used.data) == before)                       // everything moved, byte for byte
            #expect(asked == 1)                                                  // asked once for both folders
            // A second launch finds the new folders and moves nothing.
            let again = AppPaths.directoriesMovingFormerFolders(environment: [:], otherCopyRunning: { asked += 1; return false },
                                                                applicationSupport: library.support, caches: library.caches)
            #expect(again.data == used.data && again.caches == used.caches)
            #expect(asked == 1)
        }
    }

    @Test func whenTheNewFolderExistsItIsUsedAndTheFormerOneIsLeftAsItIs() throws {
        try withTemporaryFolderSync { root in
            let library = try makeLibrary(in: root, former: true, current: true)
            let before = try contents(of: root)
            let used = AppPaths.directoriesMovingFormerFolders(environment: [:], otherCopyRunning: { false },
                                                               applicationSupport: library.support, caches: library.caches)
            #expect(used.data == library.support.appendingPathComponent("Human in the Loop", isDirectory: true))
            #expect(used.caches == library.caches.appendingPathComponent("Human in the Loop", isDirectory: true))
            #expect(try contents(of: root) == before)                            // nothing merged, nothing deleted
        }
    }

    @Test func whileAnotherCopyRunsTheFormerFoldersStayInUseAndALaterLaunchMovesThem() throws {
        try withTemporaryFolderSync { root in
            let library = try makeLibrary(in: root, former: true, current: false)
            let before = try contents(of: root)
            let used = AppPaths.directoriesMovingFormerFolders(environment: [:], otherCopyRunning: { true },
                                                               applicationSupport: library.support, caches: library.caches)
            #expect(used.data == library.support.appendingPathComponent("Referee", isDirectory: true))
            #expect(used.caches == library.caches.appendingPathComponent("Referee", isDirectory: true))
            #expect(try contents(of: root) == before)
            let later = AppPaths.directoriesMovingFormerFolders(environment: [:], otherCopyRunning: { false },
                                                                applicationSupport: library.support, caches: library.caches)
            #expect(later.data.lastPathComponent == "Human in the Loop" && later.caches.lastPathComponent == "Human in the Loop")
        }
    }

    @Test func aMoveThatFailsLeavesTheFormerFolderInUseAndUntouched() throws {
        try withTemporaryFolderSync { root in
            let library = try makeLibrary(in: root, former: true, current: false)
            let former = library.support.appendingPathComponent("Referee", isDirectory: true)
            let before = try contents(of: former)
            // The new folder's parent does not exist, so the move fails.
            let unreachable = root.appendingPathComponent("missing", isDirectory: true).appendingPathComponent("Human in the Loop", isDirectory: true)
            let used = AppPaths.moveFormerFolder(former, to: unreachable, otherCopyRunning: { false })
            #expect(used == former)
            #expect(try contents(of: former) == before)
            #expect(!FileManager.default.fileExists(atPath: unreachable.deletingLastPathComponent().path))
        }
    }

    @Test func withNothingToMoveTheNewFoldersAreUsedAndNothingIsCreatedOrAsked() throws {
        try withTemporaryFolderSync { root in
            let library = try makeLibrary(in: root, former: false, current: false)
            var asked = 0
            let used = AppPaths.directoriesMovingFormerFolders(environment: [:], otherCopyRunning: { asked += 1; return false },
                                                               applicationSupport: library.support, caches: library.caches)
            #expect(used.data.lastPathComponent == "Human in the Loop" && used.caches.lastPathComponent == "Human in the Loop")
            #expect(names(in: library.support).isEmpty && names(in: library.caches).isEmpty)
            #expect(asked == 0)
        }
    }

    /// The snapshot mode, the tests and referee-cli set REFEREE_HOME: nothing in the Library moves, nothing is asked.
    @Test func withRefereeHomeNothingMovesAndNothingIsAsked() throws {
        try withTemporaryFolderSync { root in
            let library = try makeLibrary(in: root, former: true, current: false)
            let before = try contents(of: root)
            let home = root.appendingPathComponent("home", isDirectory: true)
            var asked = 0
            let used = AppPaths.directoriesMovingFormerFolders(environment: ["REFEREE_HOME": home.path], otherCopyRunning: { asked += 1; return true },
                                                               applicationSupport: library.support, caches: library.caches)
            #expect(used.data.standardizedFileURL == home.standardizedFileURL)
            #expect(used.caches.standardizedFileURL == home.appendingPathComponent("Caches", isDirectory: true).standardizedFileURL)
            #expect(try contents(of: root) == before)
            #expect(asked == 0)
        }
    }

    /// A Library with "Application Support" and "Caches"; in each, if asked, a folder of the former name and one of the
    /// new name, each holding a file of its own.
    private func makeLibrary(in root: URL, former: Bool, current: Bool) throws -> (support: URL, caches: URL) {
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        let caches = root.appendingPathComponent("Caches", isDirectory: true)
        for folder in [support, caches] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if former { try place("a review", at: folder.appendingPathComponent("Referee/sessions/a/session.json")) }
            if current { try place("settings", at: folder.appendingPathComponent("Human in the Loop/settings.json")) }
        }
        return (support, caches)
    }

    private func place(_ text: String, at file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
}
