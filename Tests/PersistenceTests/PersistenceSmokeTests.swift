import Foundation
import Testing
import RefereeCore
import Persistence

/// Wave 0a smoke tests. They hold for the in-memory placeholders and must keep holding for the file stores (WP8a).
/// Everything they touch is inside a temporary directory of their own.
@Suite struct PersistenceSmokeTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("referee-persistence-smoke-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func refereeHomeMovesDataAndCaches() {
        let environment = ["REFEREE_HOME": "/x"]
        #expect(AppPaths.dataDirectory(environment: environment).path == "/x")
        #expect(AppPaths.cacheDirectory(environment: environment).path == "/x/Caches")
    }

    @Test func aSavedSessionCanBeLoadedListedAndDeleted() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSessionStore(directory: directory.appendingPathComponent("sessions", isDirectory: true))
        let sha256 = String(repeating: "ab", count: 32)
        let moment = Date(timeIntervalSince1970: 1_800_000_000)     // whole seconds: survives an ISO 8601 round trip
        let session = ReviewSession(schemaVersion: 1, id: UUID(),
                                    document: DocumentRef(sha256: sha256, fileName: "manuscript.pdf", byteCount: 1_024, pageCount: 4),
                                    meta: ManuscriptMeta(title: "A synthetic manuscript", reviewerNotes: ""), createdAt: moment, updatedAt: moment)

        try await store.save(session)
        #expect(try await store.loadSession(sha256: sha256) == session)
        #expect(await store.listSessions().map(\.id) == [sha256])

        try await store.deleteSession(sha256: sha256)
        #expect(try await store.loadSession(sha256: sha256) == nil)
        #expect(await store.listSessions().isEmpty)
    }

    @Test func settingsAreTheDefaultsUntilSomethingIsSaved() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
        #expect(await store.load() == DefaultSettings.make())
    }
}
