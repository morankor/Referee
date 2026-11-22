import Foundation
import Testing
import RefereeCore
@testable import Persistence

/// WP8a acceptance rows "store round trip", "atomicity", "listing and delete" (plan.md section 11.4), and the safety of
/// the document key. Every store works in a temporary folder of its own.
@Suite struct SessionStoreTests {
    // ---- store round trip ----

    @Test func aSavedSessionComesBackEqualAndASecondSaveKeepsTheFirstAsTheBackup() async throws {
        try await withTemporaryFolder { root in
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            let store = FileSessionStore(directory: sessions)
            let sha = Samples.sha("9f")
            let first = Samples.richSession(sha256: sha)
            let folder = sessions.appendingPathComponent(sha, isDirectory: true)
            let file = folder.appendingPathComponent("session.json")

            try await store.save(first)
            #expect(try await store.loadSession(sha256: sha) == first)
            #expect(names(in: folder) == ["session.json"])

            // Pretty-printed, keys sorted, slashes not escaped, ISO 8601 dates: byte for byte what section 3.7 prescribes.
            let firstBytes = try Data(contentsOf: file)
            #expect(firstBytes == (try referenceEncoder().encode(first)))
            let text = try #require(String(data: firstBytes, encoding: .utf8))
            let topLevelKeys = text.split(separator: "\n").compactMap { line -> String? in
                guard line.hasPrefix("  \""), !line.hasPrefix("   ") else { return nil }
                return line.dropFirst(3).split(separator: "\"").first.map(String.init)
            }
            #expect(topLevelKeys == topLevelKeys.sorted())
            #expect(topLevelKeys.first == "comments" && topLevelKeys.last == "updatedAt")
            #expect(text.contains("\n  \"schemaVersion\" : 1,\n"))
            #expect(text.contains("\"lastKnownPath\" : \"/path/to/manuscript.pdf\""))
            #expect(text.contains("\"createdAt\" : \"2027-01-15T08:00:00Z\""))

            var second = first
            second.meta.reviewerNotes = "Second thoughts."
            second.comments[1].status = .rejected
            second.updatedAt = first.updatedAt.addingTimeInterval(60)
            try await store.save(second)

            #expect(try await store.loadSession(sha256: sha) == second)
            #expect(try await FileSessionStore(directory: sessions).loadSession(sha256: sha) == second)
            #expect(names(in: folder) == ["session.json", "session.json.bak"])
            #expect(try Data(contentsOf: folder.appendingPathComponent("session.json.bak")) == firstBytes)
            #expect(try Data(contentsOf: file) == (try referenceEncoder().encode(second)))
        }
    }

    @Test func eachSaveKeepsExactlyOneBackupTheVersionBeforeIt() async throws {
        try await withTemporaryFolder { root in
            let store = FileSessionStore(directory: root)
            let sha = Samples.sha("ab")
            let folder = root.appendingPathComponent(sha, isDirectory: true)
            var versions: [Data] = []
            for round in 0..<4 {
                let session = Samples.session(sha256: sha, notes: "round \(round)")
                try await store.save(session)
                versions.append(try Data(contentsOf: folder.appendingPathComponent("session.json")))
                #expect(try await store.loadSession(sha256: sha) == session)
            }
            #expect(names(in: folder) == ["session.json", "session.json.bak"])
            #expect(try Data(contentsOf: folder.appendingPathComponent("session.json.bak")) == versions[2])
        }
    }

    @Test func aDocumentWithoutASessionLoadsAsNil() async throws {
        try await withTemporaryFolder { root in
            let store = FileSessionStore(directory: root.appendingPathComponent("sessions", isDirectory: true))
            let loaded = try await store.loadSession(sha256: Samples.sha("00"))
            #expect(loaded == nil)
            #expect(await store.listSessions().isEmpty)
            #expect(names(in: root).isEmpty)          // neither loading nor listing creates anything
        }
    }

    @Test func nonFiniteNumbersDoNotStopASave() async throws {
        try await withTemporaryFolder { root in
            let store = FileSessionStore(directory: root)
            let sha = Samples.sha("cd")
            var session = Samples.session(sha256: sha)
            var comment = Samples.comment(.pending)
            comment.anchor = Anchor(quote: "x", rects: [PageRect(pageIndex: 0, x: .infinity, y: -.infinity, width: 0, height: 0)],
                                    pageIndex: 0, confidence: .exact, locationLabel: "p. 1")
            session.comments = [comment]
            try await store.save(session)
            let loaded = try #require(try await store.loadSession(sha256: sha))
            #expect(loaded.comments[0].anchor.rects[0].x == .infinity)
            #expect(loaded.comments[0].anchor.rects[0].y == -.infinity)
        }
    }

    // ---- atomicity ----

    @Test func aFailureBetweenTheTemporaryWriteAndTheRenameLeavesTheOldFileReadable() async throws {
        try await withTemporaryFolder { root in
            let sha = Samples.sha("ef")
            let folder = root.appendingPathComponent(sha, isDirectory: true)
            let store = FileSessionStore(directory: root)
            let old = Samples.session(sha256: sha, notes: "the version before")
            let current = Samples.session(sha256: sha, notes: "the version on disk")
            let next = Samples.session(sha256: sha, notes: "the version that never lands")
            try await store.save(old)
            try await store.save(current)
            let before = try contents(of: folder)

            let seenInTemporaryFile = Box<Data?>(nil)
            let failing = FileSessionStore(directory: root, beforeReplacing: { temporary in
                seenInTemporaryFile.value = try? Data(contentsOf: temporary)
                throw SimulatedFailure()
            })
            let error = await #expect(throws: StoreError.self) { try await failing.save(next) }
            if case .io? = error {} else { Issue.record("expected StoreError.io, got \(String(describing: error))") }

            // The failure struck after the new content was complete in session.json.tmp…
            #expect(seenInTemporaryFile.value == (try referenceEncoder().encode(next)))
            // …and left session.json and the backup byte for byte as they were, with no temporary file behind.
            #expect(try contents(of: folder) == before)
            #expect(try await store.loadSession(sha256: sha) == current)
            #expect(try await FileSessionStore(directory: root).loadSession(sha256: sha) == current)

            // The next save works normally.
            try await store.save(next)
            #expect(try await store.loadSession(sha256: sha) == next)
        }
    }

    @Test func aTemporaryFileLeftByACrashIsIgnoredAndReplacedByTheNextSave() async throws {
        try await withTemporaryFolder { root in
            let sha = Samples.sha("12")
            let folder = root.appendingPathComponent(sha, isDirectory: true)
            let store = FileSessionStore(directory: root)
            let current = Samples.session(sha256: sha, notes: "saved")
            try await store.save(current)
            let currentBytes = try Data(contentsOf: folder.appendingPathComponent("session.json"))
            // A crash in the middle of writing the temporary file.
            try Data("{\n  \"comments\" : [\n    {\n      \"anch".utf8).write(to: folder.appendingPathComponent("session.json.tmp"))

            #expect(try await FileSessionStore(directory: root).loadSession(sha256: sha) == current)
            let next = Samples.session(sha256: sha, notes: "saved again")
            try await store.save(next)
            #expect(try await store.loadSession(sha256: sha) == next)
            #expect(names(in: folder) == ["session.json", "session.json.bak"])
            #expect(try Data(contentsOf: folder.appendingPathComponent("session.json.bak")) == currentBytes)
        }
    }

    // ---- listing and delete ----

    @Test func threeSessionsGiveThreeSummariesWithTheirCountsNewestFirst() async throws {
        try await withTemporaryFolder { root in
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            let store = FileSessionStore(directory: sessions)
            let oldest = Samples.session(sha256: Samples.sha("a1"), fileName: "first.pdf", title: nil, updatedAt: Samples.moment,
                                         comments: [Samples.comment(.pending), Samples.comment(.approved), Samples.comment(.rejected)])
            let newest = Samples.session(sha256: Samples.sha("b2"), fileName: "second.pdf", title: "Second",
                                         updatedAt: Samples.moment.addingTimeInterval(7_200),
                                         comments: [Samples.comment(.pending), Samples.comment(.pending, kind: .question)],
                                         report: ReportDraft(markdown: "## Summary assessment\n", userEdited: false))
            let middle = Samples.session(sha256: Samples.sha("c3"), fileName: "third.pdf", title: "Third",
                                         updatedAt: Samples.moment.addingTimeInterval(3_600))
            for session in [oldest, newest, middle] { try await store.save(session) }
            // Neither a folder holding only reference lookups nor a stray file is a session.
            let lookupsOnly = sessions.appendingPathComponent(Samples.sha("d4"), isDirectory: true)
            try FileManager.default.createDirectory(at: lookupsOnly, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: lookupsOnly.appendingPathComponent("references.json"))
            try Data("x".utf8).write(to: sessions.appendingPathComponent("notes.txt"))

            let summaries = await store.listSessions()
            #expect(summaries == [
                SessionSummary(id: Samples.sha("b2"), fileName: "second.pdf", title: "Second", lastKnownPath: "/path/to/second.pdf",
                               updatedAt: newest.updatedAt, commentCount: 2, pendingCount: 2, hasReport: true),
                SessionSummary(id: Samples.sha("c3"), fileName: "third.pdf", title: "Third", lastKnownPath: "/path/to/third.pdf",
                               updatedAt: middle.updatedAt, commentCount: 0, pendingCount: 0, hasReport: false),
                SessionSummary(id: Samples.sha("a1"), fileName: "first.pdf", title: nil, lastKnownPath: "/path/to/first.pdf",
                               updatedAt: oldest.updatedAt, commentCount: 3, pendingCount: 1, hasReport: false),
            ])
        }
    }

    @Test func theListingReadsTheBackupOfADamagedSessionAndRenamesNothing() async throws {
        try await withTemporaryFolder { root in
            let store = FileSessionStore(directory: root)
            let sha = Samples.sha("e5")
            let folder = root.appendingPathComponent(sha, isDirectory: true)
            let good = Samples.session(sha256: sha, title: "Good")
            try await store.save(good)
            try await store.save(Samples.session(sha256: sha, title: "Later"))
            try Data("garbage".utf8).write(to: folder.appendingPathComponent("session.json"))
            let before = try contents(of: folder)

            #expect(await store.listSessions().map(\.title) == ["Good"])
            #expect(try contents(of: folder) == before)
        }
    }

    @Test func deletingASessionRemovesItsWholeFolderAndNothingElse() async throws {
        try await withTemporaryFolder { root in
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            let store = FileSessionStore(directory: sessions)
            let doomed = Samples.session(sha256: Samples.sha("f6"))
            let kept = Samples.session(sha256: Samples.sha("07"))
            try await store.save(doomed)
            try await store.save(doomed)                       // a backup too
            try await store.save(kept)
            let folder = sessions.appendingPathComponent(Samples.sha("f6"), isDirectory: true)
            try Data("{\"lookups\": []}".utf8).write(to: folder.appendingPathComponent("references.json"))   // as ScholarKit would
            try Data("old damage".utf8).write(to: folder.appendingPathComponent("session.corrupt-20261122T101010Z.json"))
            #expect(names(in: folder) == ["references.json", "session.corrupt-20261122T101010Z.json", "session.json", "session.json.bak"])

            try await store.deleteSession(sha256: Samples.sha("f6"))
            #expect(!FileManager.default.fileExists(atPath: folder.path))
            #expect(names(in: sessions) == [Samples.sha("07")])
            #expect(try await store.loadSession(sha256: Samples.sha("f6")) == nil)
            #expect(try await store.loadSession(sha256: Samples.sha("07")) == kept)
            #expect(await store.listSessions().map(\.id) == [Samples.sha("07")])

            // Deleting what is not there is not an error.
            try await store.deleteSession(sha256: Samples.sha("f6"))
            try await FileSessionStore(directory: root.appendingPathComponent("missing", isDirectory: true)).deleteSession(sha256: Samples.sha("f6"))
        }
    }

    // ---- the document key ----

    @Test func aKeyThatIsNotAPlainFolderNameIsRefusedAndReachesNothing() async throws {
        try await withTemporaryFolder { root in
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            let store = FileSessionStore(directory: sessions)
            let kept = Samples.session(sha256: Samples.sha("08"))
            try await store.save(kept)
            try Data("{}".utf8).write(to: root.appendingPathComponent("settings.json"))
            let before = try contents(of: root)

            for key in ["", ".", "..", "../sessions", "a/b", "/tmp", "with space", "\u{00E9}t\u{00E9}", String(repeating: "a", count: 129)] {
                await #expect(throws: StoreError.self) { try await store.deleteSession(sha256: key) }
                await #expect(throws: StoreError.self) { try await store.loadSession(sha256: key) }
                await #expect(throws: StoreError.self) { try await store.save(Samples.session(sha256: key)) }
            }
            #expect(try contents(of: root) == before)
            #expect(names(in: sessions) == [Samples.sha("08")])
            #expect(try await store.loadSession(sha256: Samples.sha("08")) == kept)
            #expect(FileSessionStore.isValidKey(Samples.sha("9f")))
            #expect(FileSessionStore.isValidKey("ABC_def-123"))
        }
    }
}
