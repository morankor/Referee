import Foundation
import Testing
import RefereeCore
import TestSupport
@testable import Persistence

/// What Gate 1 added to `SessionStoring` (plan.md Appendix A.7, sections 4.5 and 9.6): the store says when it loaded
/// the backup, and it can delete every review at once.
@Suite struct SessionStoreContractTests {
    @Test func aLoadThatFellBackToTheBackupSaysSoAndACleanLoadDoesNot() async throws {
        try await withTemporaryFolder { root in
            let sha = Samples.sha("c0")
            let store = FileSessionStore(directory: root)
            let old = Samples.session(sha256: sha, notes: "the backup")
            try await store.save(old)
            try await store.save(Samples.session(sha256: sha, notes: "lost"))
            #expect(try await store.loadSession(sha256: sha) != nil)
            #expect(await store.recoveryNotice(sha256: sha) == nil)        // nothing was repaired

            let folder = root.appendingPathComponent(sha, isDirectory: true)
            try Data("not json".utf8).write(to: folder.appendingPathComponent("session.json"))
            #expect(try await store.loadSession(sha256: sha) == old)
            let notice = try #require(await store.recoveryNotice(sha256: sha))
            let moved = try #require(names(in: folder).first { $0.hasPrefix("session.corrupt-") })
            #expect(notice == "The saved review was damaged, so its previous version was loaded from the backup. The damaged file was kept as \(moved).")
            #expect(!notice.contains(root.path))                             // the file's name, not where the data folder is

            // The next load reads the backup again, which repairs nothing new: no second banner.
            #expect(try await store.loadSession(sha256: sha) == old)
            #expect(await store.recoveryNotice(sha256: sha) == nil)
            #expect(await InMemorySessionStore().recoveryNotice(sha256: sha) == nil)   // the default
        }
    }

    @Test func deletingEverythingRemovesEveryReviewFolderAndNothingElse() async throws {
        try await withTemporaryFolder { root in
            let store = FileSessionStore(directory: root)
            let readable = Samples.sha("d1")
            let damaged = Samples.sha("d2")
            try await store.save(Samples.session(sha256: readable))
            try await store.save(Samples.session(sha256: damaged))
            try Data("not json".utf8).write(to: root.appendingPathComponent(damaged).appendingPathComponent("session.json"))
            let newer = Samples.sha("d3")
            try FileManager.default.createDirectory(at: root.appendingPathComponent(newer), withIntermediateDirectories: true)
            try Data(#"{"schemaVersion": 9}"#.utf8).write(to: root.appendingPathComponent(newer).appendingPathComponent("session.json"))
            try Data("x".utf8).write(to: root.appendingPathComponent("not a review.txt"))       // not a document folder: kept
            #expect(await store.listSessions().map(\.id) == [readable])       // the damaged and the newer one are not listed

            try await store.deleteAllSessions()
            #expect(names(in: root) == ["not a review.txt"])
            #expect(await store.listSessions().isEmpty)
        }
    }

    @Test func theDefaultDeleteAllRemovesWhatTheListShows() async throws {
        let store = InMemorySessionStore()
        try await store.save(Samples.session(sha256: Samples.sha("e1")))
        try await store.save(Samples.session(sha256: Samples.sha("e2")))
        try await store.deleteAllSessions()
        #expect(await store.listSessions().isEmpty)
    }
}
