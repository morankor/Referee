import Foundation
import Testing
import RefereeCore
import TestSupport
@testable import Persistence

/// WP8a acceptance rows "corrupt file" and "versions" (plan.md section 11.4), for sessions; the settings half of
/// "versions" is in SettingsStoreTests.
@Suite struct SessionRecoveryTests {
    /// Saves `old` and then `current`, so that session.json holds `current` and session.json.bak holds `old`.
    private func folderWithBackup(_ root: URL, sha: String, old: ReviewSession, current: ReviewSession) async throws -> URL {
        let store = FileSessionStore(directory: root)
        try await store.save(old)
        try await store.save(current)
        return root.appendingPathComponent(sha, isDirectory: true)
    }

    private func corruptNames(in folder: URL) -> [String] {
        names(in: folder).filter { $0.hasPrefix("session.corrupt-") && $0.hasSuffix(".json") }
    }

    // ---- corrupt file ----

    @Test func garbageInTheSessionFileLoadsTheBackupAndKeepsTheGarbageAside() async throws {
        try await withTemporaryFolder { root in
            let sha = Samples.sha("a0")
            let old = Samples.session(sha256: sha, notes: "the backup")
            let folder = try await folderWithBackup(root, sha: sha, old: old, current: Samples.session(sha256: sha, notes: "lost"))
            let garbage = Data("{\"comments\": [ {\"anchor\": ".utf8)
            try garbage.write(to: folder.appendingPathComponent("session.json"))

            let store = FileSessionStore(directory: root)
            #expect(try await store.loadSession(sha256: sha) == old)

            // The bad file is renamed session.corrupt-<UTC time>.json, unchanged; the backup stays where it was.
            let moved = corruptNames(in: folder)
            #expect(moved.count == 1)
            let name = try #require(moved.first)
            #expect(name.wholeMatch(of: #/session\.corrupt-\d{8}T\d{6}Z\.json/#) != nil)
            #expect(try Data(contentsOf: folder.appendingPathComponent(name)) == garbage)
            #expect(names(in: folder) == [name, "session.json.bak"])

            // Until the next save the backup is the session; the save then puts session.json back.
            #expect(try await FileSessionStore(directory: root).loadSession(sha256: sha) == old)
            var edited = old
            edited.meta.reviewerNotes = "edited after the recovery"
            try await store.save(edited)
            #expect(try await store.loadSession(sha256: sha) == edited)
            #expect(names(in: folder) == [name, "session.json", "session.json.bak"])
            #expect(try Data(contentsOf: folder.appendingPathComponent("session.json.bak")) == (try referenceEncoder().encode(old)))
        }
    }

    @Test(arguments: [
        "",                                          // empty
        "not json at all",
        "[1, 2, 3]",                                 // JSON, but not an object
        "{\"schemaVersion\": 1}",                    // an object without the fields of a session
        "{\"schemaVersion\": \"1\", \"comments\": []}",
    ])
    func everyKindOfDamageIsTreatedAlike(_ damage: String) async throws {
        try await withTemporaryFolder { root in
            let sha = Samples.sha("a1")
            let old = Samples.session(sha256: sha, notes: "the backup")
            let folder = try await folderWithBackup(root, sha: sha, old: old, current: Samples.session(sha256: sha))
            try Data(damage.utf8).write(to: folder.appendingPathComponent("session.json"))
            #expect(try await FileSessionStore(directory: root).loadSession(sha256: sha) == old)
            #expect(corruptNames(in: folder).count == 1)
        }
    }

    @Test func aDamagedSessionWithADamagedBackupThrowsCorruptAndKeepsBothAside() async throws {
        try await withTemporaryFolder { root in
            let sha = Samples.sha("a2")
            let folder = try await folderWithBackup(root, sha: sha, old: Samples.session(sha256: sha), current: Samples.session(sha256: sha))
            try Data("garbage one".utf8).write(to: folder.appendingPathComponent("session.json"))
            try Data("garbage two".utf8).write(to: folder.appendingPathComponent("session.json.bak"))

            let store = FileSessionStore(directory: root)
            let error = await #expect(throws: StoreError.self) { try await store.loadSession(sha256: sha) }
            guard case .corrupt(let path)? = error else {
                Issue.record("expected StoreError.corrupt, got \(String(describing: error))")
                return
            }
            // The error names the renamed session.json, which keeps its bytes; the backup is moved aside as well.
            let named = URL(fileURLWithPath: path)
            #expect(named.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
            #expect(named.lastPathComponent.wholeMatch(of: #/session\.corrupt-\d{8}T\d{6}Z\.json/#) != nil)
            #expect(try Data(contentsOf: named) == Data("garbage one".utf8))
            let moved = corruptNames(in: folder)
            #expect(moved.count == 2)
            #expect(moved.contains { $0.hasSuffix("-backup.json") })
            #expect(names(in: folder) == moved)

            // Both kept aside: the document now has no session, and a new one can be saved.
            #expect(try await store.loadSession(sha256: sha) == nil)
            let fresh = Samples.session(sha256: sha, notes: "a fresh start")
            try await store.save(fresh)
            #expect(try await store.loadSession(sha256: sha) == fresh)
        }
    }

    @Test func aDamagedSessionWithoutABackupThrowsCorrupt() async throws {
        try await withTemporaryFolder { root in
            let sha = Samples.sha("a3")
            let folder = root.appendingPathComponent(sha, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("garbage".utf8).write(to: folder.appendingPathComponent("session.json"))
            let error = await #expect(throws: StoreError.self) { try await FileSessionStore(directory: root).loadSession(sha256: sha) }
            if case .corrupt? = error {} else { Issue.record("expected StoreError.corrupt, got \(String(describing: error))") }
            #expect(corruptNames(in: folder).count == 1)
            #expect(!names(in: folder).contains("session.json"))
        }
    }

    @Test func aSessionFileDamagedAfterLoadingNeverBecomesTheBackup() async throws {
        try await withTemporaryFolder { root in
            let sha = Samples.sha("a4")
            let old = Samples.session(sha256: sha, notes: "good backup")
            let folder = try await folderWithBackup(root, sha: sha, old: old, current: Samples.session(sha256: sha))
            let goodBackup = try Data(contentsOf: folder.appendingPathComponent("session.json.bak"))
            try Data("damaged on disk".utf8).write(to: folder.appendingPathComponent("session.json"))

            let next = Samples.session(sha256: sha, notes: "next")
            try await FileSessionStore(directory: root).save(next)
            #expect(try Data(contentsOf: folder.appendingPathComponent("session.json.bak")) == goodBackup)
            #expect(corruptNames(in: folder).count == 1)
            #expect(try await FileSessionStore(directory: root).loadSession(sha256: sha) == next)
        }
    }

    @Test func twoDamagedFilesInTheSameSecondGetTwoNames() throws {
        try withTemporaryFolderSync { folder in
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let one = folder.appendingPathComponent("one")
            let two = folder.appendingPathComponent("two")
            try Data("1".utf8).write(to: one)
            try Data("2".utf8).write(to: two)
            let first = try StoreFiles.quarantine(one, stem: "session.corrupt", now: now)
            let second = try StoreFiles.quarantine(two, stem: "session.corrupt", now: now)
            #expect(first.lastPathComponent == "session.corrupt-20270115T080000Z.json")
            #expect(second.lastPathComponent == "session.corrupt-20270115T080000Z-2.json")
            #expect(try Data(contentsOf: second) == Data("2".utf8))
        }
    }

    // ---- versions ----

    @Test func aNewerSchemaThrowsAndLeavesTheFileUntouched() async throws {
        try await withTemporaryFolder { root in
            let sha = Samples.sha("b0")
            let session = Samples.session(sha256: sha)
            let folder = root.appendingPathComponent(sha, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let newer = try editedJSON(session) { object in
                object["schemaVersion"] = 2
                object["somethingOnlyVersionTwoKnows"] = ["a", "b"]
            }
            try newer.write(to: folder.appendingPathComponent("session.json"))
            let before = try contents(of: folder)

            let store = FileSessionStore(directory: root)
            await #expect(throws: StoreError.newerSchema(found: 2, supported: 1)) { try await store.loadSession(sha256: sha) }
            #expect(try contents(of: folder) == before)

            // The empty session the UI opens instead must not overwrite it either (plan section 4.4).
            await #expect(throws: StoreError.newerSchema(found: 2, supported: 1)) { try await store.save(session) }
            #expect(try contents(of: folder) == before)
            // Nor is it listed: this version cannot say what it holds.
            #expect(await store.listSessions().isEmpty)
        }
    }

    @Test func theSampleOfSection4Point3Decodes() async throws {
        try await withTemporaryFolder { root in
            let key = Samples.sha("9f")
            let folder = root.appendingPathComponent(key, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(Self.sectionFourPointThreeSample.utf8).write(to: folder.appendingPathComponent("session.json"))

            let session = try #require(try await FileSessionStore(directory: root).loadSession(sha256: key))
            let moment = try #require(ISO8601DateFormatter().date(from: "2026-11-18T11:06:40Z"))
            #expect(session.schemaVersion == 1)
            #expect(session.id == UUID(uuidString: "55555555-5555-4555-8555-555555555555"))
            #expect(session.document == DocumentRef(sha256: "9f2c\u{2026}", fileName: "manuscript.pdf", lastKnownPath: "/path/to/manuscript.pdf",
                                                    byteCount: 183_964, pageCount: 4))
            #expect(session.meta == ManuscriptMeta(title: "Information Aggregation in Sequential Markets", reviewerNotes: ""))
            #expect(session.createdAt == moment && session.updatedAt == moment)
            #expect(session.consents == [ConsentRecord(providerID: "anthropic-api", grantedAt: moment)])
            #expect(session.conversations.isEmpty && session.report == nil && session.preferredProvider == nil)

            let comment = try #require(session.comments.first)
            #expect(session.comments.count == 1)
            #expect(comment.origin == .ai(runID: try #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))))
            #expect(comment.status == .approved && comment.kind == .major && comment.category == "claims" && comment.includeInReport)
            #expect(comment.anchor.confidence == .exact)
            #expect(comment.anchor.locationLabel == "p. 1, lines 13\u{2013}14")
            #expect(comment.anchor.spans == [TextSpan(pageIndex: 0, range: TextRange(location: 676, length: 18)),
                                             TextSpan(pageIndex: 0, range: TextRange(location: 697, length: 59))])
            #expect(comment.anchor.rects.first == PageRect(pageIndex: 0, x: 410.2, y: 189.2, width: 88.6, height: 10.6))
            #expect(comment.proposedRevision == CommentRevision(kind: .minor, title: "State the interval", body: "\u{2026}", withdraw: false))
            #expect(comment.thread.map(\.role) == [.user])
            #expect(comment.similarTo == nil && comment.previousVersions.isEmpty)

            let run = try #require(session.runs.first)
            #expect(run.status == .completed && run.kind == .review && !run.sentPDF && run.requestCount == 1)
            #expect(run.provider == ProviderRef(providerID: "ollama", model: "gemma4:e4b"))
            #expect(run.usage == Usage(inputTokens: 21_000, outputTokens: 1_800))
        }
    }

    @Test func theSnapshotSampleSessionDecodes() async throws {
        try await withTemporaryFolder { root in
            let key = Samples.sha("5a")
            let folder = root.appendingPathComponent(key, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: Fixtures.url("sessions/sample.json"), to: folder.appendingPathComponent("session.json"))
            let session = try #require(try await FileSessionStore(directory: root).loadSession(sha256: key))
            #expect(session.comments.count == 7)
            #expect(session.comments.contains { $0.similarTo != nil })
        }
    }

    @Test func aSessionFileWrittenBeforeSimilarToExistedDecodes() async throws {
        try await withTemporaryFolder { root in
            let sha = Samples.sha("b1")
            let first = Samples.comment(.pending, title: "First")
            var session = Samples.session(sha256: sha, comments: [first, Samples.comment(.pending, title: "Second", similarTo: first.id)])
            let folder = root.appendingPathComponent(sha, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let older = try editedJSON(session) { object in
                let comments = object["comments"] as? [[String: Any]] ?? []
                object["comments"] = comments.map { comment in
                    var comment = comment
                    comment["similarTo"] = nil
                    return comment
                }
            }
            #expect(!String(decoding: older, as: UTF8.self).contains("similarTo"))
            try older.write(to: folder.appendingPathComponent("session.json"))

            session.comments[1].similarTo = nil
            #expect(try await FileSessionStore(directory: root).loadSession(sha256: sha) == session)
        }
    }

    /// Plan section 4.3, as printed there ("real output of the types in Appendix A, reformatted for width").
    static let sectionFourPointThreeSample = """
        {
          "comments" : [
            {
              "anchor" : {
                "confidence" : { "exact" : { } },
                "locationLabel" : "p. 1, lines 13\u{2013}14",
                "pageIndex" : 0,
                "quote" : "The coefficient in Table 2 is 0.91 with a confidence interval that crosses one",
                "rects" : [
                  { "height" : 10.6, "pageIndex" : 0, "width" : 88.6, "x" : 410.2, "y" : 189.2 },
                  { "height" : 10.6, "pageIndex" : 0, "width" : 286.2, "x" : 110.9, "y" : 165.2 }
                ],
                "spans" : [ { "pageIndex" : 0, "range" : { "length" : 18, "location" : 676 } },
                            { "pageIndex" : 0, "range" : { "length" : 59, "location" : 697 } } ]
              },
              "body" : "The text calls the effect robust, but Table 2 reports 0.91 with an interval that crosses one.",
              "category" : "claims",
              "createdAt" : "2026-11-18T11:06:40Z",
              "id" : "22222222-2222-4222-8222-222222222222",
              "includeInReport" : true,
              "kind" : "major",
              "origin" : { "ai" : { "runID" : "11111111-1111-4111-8111-111111111111" } },
              "previousVersions" : [ ],
              "proposedRevision" : { "body" : "\u{2026}", "kind" : "minor", "title" : "State the interval", "withdraw" : false },
              "status" : "approved",
              "suggestion" : "Report the interval in the abstract and drop 'robust'.",
              "thread" : [
                { "createdAt" : "2026-11-18T11:06:40Z", "id" : "33333333-3333-4333-8333-333333333333", "role" : "user",
                  "text" : "Is the interval in the text or only in the table?" }
              ],
              "title" : "Confidence interval includes one",
              "updatedAt" : "2026-11-18T11:06:40Z"
            }
          ],
          "consents" : [ { "grantedAt" : "2026-11-18T11:06:40Z", "providerID" : "anthropic-api" } ],
          "conversations" : [ ],
          "createdAt" : "2026-11-18T11:06:40Z",
          "document" : { "byteCount" : 183964, "fileName" : "manuscript.pdf", "lastKnownPath" : "/path/to/manuscript.pdf", "pageCount" : 4, "sha256" : "9f2c\u{2026}" },
          "id" : "55555555-5555-4555-8555-555555555555",
          "meta" : { "reviewerNotes" : "", "title" : "Information Aggregation in Sequential Markets" },
          "runs" : [
            { "destination" : "127.0.0.1:11434", "finishedAt" : "2026-11-18T11:06:40Z", "id" : "11111111-1111-4111-8111-111111111111",
              "kind" : "review", "provider" : { "model" : "gemma4:e4b", "providerID" : "ollama" }, "requestCount" : 1, "sentPDF" : false,
              "startedAt" : "2026-11-18T11:06:40Z", "status" : { "completed" : { } }, "usage" : { "inputTokens" : 21000, "outputTokens" : 1800 } }
          ],
          "schemaVersion" : 1,
          "updatedAt" : "2026-11-18T11:06:40Z"
        }
        """
}
