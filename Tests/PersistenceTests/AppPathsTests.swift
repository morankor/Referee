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
            #expect(data.standardizedFileURL == applicationSupport.appendingPathComponent("Referee", isDirectory: true).standardizedFileURL)
            #expect(cache.standardizedFileURL == caches.appendingPathComponent("Referee", isDirectory: true).standardizedFileURL)
            #expect(data.path.hasSuffix("/Library/Application Support/Referee"))
            #expect(cache.path.hasSuffix("/Library/Caches/Referee"))
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
}
