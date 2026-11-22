import Foundation
import Testing
import RefereeCore
@testable import ScholarKit
import TestSupport

/// Acceptance row "cache per document" (plan.md section 11.4, WP7; step 0 of section 8.7 and section 4.2).
@Suite struct ScholarKitCacheTests {
    private static let day: Double = 86_400

    @Test func aSecondResolveOfTheSameEntryForTheSameDocumentMakesNoRequest() async throws {
        StubURLProtocol.setHandler(Stub.services(crossref: Bodies.crossrefHochreiter, openAlex: Bodies.openAlexHochreiter))
        let harness = ResolverHarness()
        defer { harness.cleanUp() }
        let entry = try Entries.hochreiter()

        let first = await harness.resolver.resolve(entry, documentSHA256: Documents.first)
        #expect(StubURLProtocol.recordedRequests.count == 2)
        harness.clock.advance(by: 3_600)
        let second = await harness.resolver.resolve(entry, documentSHA256: Documents.first)

        #expect(StubURLProtocol.recordedRequests.count == 2)
        #expect(second == first)
        // The file is sessions/<sha>/references.json, keyed by the SHA-256 of the folded entry text.
        #expect(visibleFiles(in: harness.home) == ["sessions"])
        #expect(visibleFiles(in: harness.documentFolder(Documents.first)) == ["references.json"])
        let stored = try Self.storedLookups(harness, Documents.first)
        #expect(stored == [ReferenceText.sha256Hex(ReferenceText.fold(entry.rawText)): first])
    }

    @Test func theFileIsWrittenAsTheProjectWritesJSON() async throws {
        StubURLProtocol.setHandler(Stub.services(crossref: Bodies.crossrefHochreiter, openAlex: Bodies.openAlexHochreiter))
        let harness = ResolverHarness()
        defer { harness.cleanUp() }

        _ = await harness.resolver.resolve(try Entries.hochreiter(), documentSHA256: Documents.first)

        let text = try String(contentsOf: harness.referencesFile(Documents.first), encoding: .utf8)
        #expect(text.contains("\"landingURL\" : \"https://doi.org/10.1162/neco.1997.9.8.1735\""))    // pretty, slashes unescaped
        #expect(text.contains("\"resolvedAt\" : \"2027-01-15T08:00:00Z\""))                          // ISO 8601
        #expect(text.contains("\"schemaVersion\" : 1"))
        #expect(!text.contains("Hochreiter and"))                                                    // the key is a hash, not the text
        let attributes = try FileManager.default.attributesOfItem(atPath: harness.documentFolder(Documents.first).path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func theSameEntryForAnotherDocumentMakesARequest() async throws {
        StubURLProtocol.setHandler(Stub.services(crossref: Bodies.crossrefHochreiter, openAlex: Bodies.openAlexHochreiter))
        let harness = ResolverHarness()
        defer { harness.cleanUp() }
        let entry = try Entries.hochreiter()

        _ = await harness.resolver.resolve(entry, documentSHA256: Documents.first)
        _ = await harness.resolver.resolve(entry, documentSHA256: Documents.second)

        #expect(StubURLProtocol.recordedRequests.filter { $0.url?.host == "api.crossref.org" }.count == 2)
        #expect(FileManager.default.fileExists(atPath: harness.referencesFile(Documents.second).path))
    }

    @Test func forgetRemovesTheFileAndTheNextResolveMakesARequest() async throws {
        StubURLProtocol.setHandler(Stub.services(crossref: Bodies.crossrefHochreiter, openAlex: Bodies.openAlexHochreiter))
        let harness = ResolverHarness()
        defer { harness.cleanUp() }
        let entry = try Entries.hochreiter()
        _ = await harness.resolver.resolve(entry, documentSHA256: Documents.first)
        _ = await harness.resolver.resolve(entry, documentSHA256: Documents.second)
        #expect(FileManager.default.fileExists(atPath: harness.referencesFile(Documents.first).path))

        await harness.resolver.forget(documentSHA256: Documents.first)

        #expect(!FileManager.default.fileExists(atPath: harness.referencesFile(Documents.first).path))
        #expect(!FileManager.default.fileExists(atPath: harness.documentFolder(Documents.first).path))   // nothing else was in it
        #expect(FileManager.default.fileExists(atPath: harness.referencesFile(Documents.second).path))   // another review is untouched
        let before = StubURLProtocol.recordedRequests.count
        _ = await harness.resolver.resolve(entry, documentSHA256: Documents.first)
        #expect(StubURLProtocol.recordedRequests.count == before + 2)
        _ = await harness.resolver.resolve(entry, documentSHA256: Documents.second)
        #expect(StubURLProtocol.recordedRequests.count == before + 2)
    }

    @Test func forgetLeavesTheRestOfTheDocumentsFolderAlone() async throws {
        StubURLProtocol.setHandler(Stub.services(crossref: Bodies.crossrefHochreiter, openAlex: Bodies.openAlexHochreiter))
        let harness = ResolverHarness()
        defer { harness.cleanUp() }
        _ = await harness.resolver.resolve(try Entries.hochreiter(), documentSHA256: Documents.first)
        let session = harness.documentFolder(Documents.first).appendingPathComponent("session.json")
        try Data("{}".utf8).write(to: session)

        await harness.resolver.forget(documentSHA256: Documents.first)

        #expect(visibleFiles(in: harness.documentFolder(Documents.first)) == ["session.json"])
    }

    @Test func lookupsOutliveTheResolver() async throws {
        StubURLProtocol.setHandler(Stub.services(crossref: Bodies.crossrefHochreiter, openAlex: Bodies.openAlexHochreiter))
        let harness = ResolverHarness()
        defer { harness.cleanUp() }
        var entry = try Entries.hochreiter()
        let first = await harness.resolver.resolve(entry, documentSHA256: Documents.first)

        entry.id = 7                                       // the same text at another position: the same lookup
        let again = await harness.restartedResolver().resolve(entry, documentSHA256: Documents.first)

        #expect(StubURLProtocol.recordedRequests.count == 2)
        var expected = first
        expected.entryID = 7
        #expect(again == expected)
    }

    @Test func aResolvedLookupIsKept180Days() async throws {
        StubURLProtocol.setHandler(Stub.services(crossref: Bodies.crossrefHochreiter, openAlex: Bodies.openAlexHochreiter))
        let harness = ResolverHarness()
        defer { harness.cleanUp() }
        let entry = try Entries.hochreiter()
        _ = await harness.resolver.resolve(entry, documentSHA256: Documents.first)

        harness.clock.advance(by: 180 * Self.day)
        _ = await harness.resolver.resolve(entry, documentSHA256: Documents.first)
        _ = await harness.restartedResolver().resolve(entry, documentSHA256: Documents.first)
        #expect(StubURLProtocol.recordedRequests.count == 2)

        harness.clock.advance(by: 1)
        let renewed = await harness.resolver.resolve(entry, documentSHA256: Documents.first)
        #expect(StubURLProtocol.recordedRequests.count == 4)
        #expect(renewed.resolvedAt == harness.clock.now())
        _ = await harness.restartedResolver().resolve(entry, documentSHA256: Documents.first)       // the renewed lookup was written
        #expect(StubURLProtocol.recordedRequests.count == 4)
    }

    @Test func aNotFoundLookupIsKept30Days() async throws {
        StubURLProtocol.setHandler(Stub.services(crossref: Bodies.crossrefEmpty, openAlex: Bodies.openAlexHochreiter))
        let harness = ResolverHarness()
        defer { harness.cleanUp() }
        let entry = try Entries.hochreiter()
        #expect(await harness.resolver.resolve(entry, documentSHA256: Documents.first).status == .notFound)
        #expect(StubURLProtocol.recordedRequests.count == 1)

        harness.clock.advance(by: 30 * Self.day)
        #expect(await harness.restartedResolver().resolve(entry, documentSHA256: Documents.first).status == .notFound)
        #expect(StubURLProtocol.recordedRequests.count == 1)

        harness.clock.advance(by: 1)
        _ = await harness.resolver.resolve(entry, documentSHA256: Documents.first)
        #expect(StubURLProtocol.recordedRequests.count == 2)
    }

    @Test func expiredLookupsAreDroppedFromTheFile() async throws {
        StubURLProtocol.setHandler(Stub.services(crossref: Bodies.crossrefEmpty, openAlex: Bodies.openAlexHochreiter))
        let harness = ResolverHarness()
        defer { harness.cleanUp() }
        let old = try Entries.hochreiter()
        _ = await harness.resolver.resolve(old, documentSHA256: Documents.first)                    // notFound, kept 30 days

        harness.clock.advance(by: 31 * Self.day)
        let other = BibEntry(id: 5, rawText: "Smith, L. and Sørensen, P. (2000). Pathological outcomes of observational learning.",
                             parsed: ParsedReference(authorSurnames: ["Smith", "Sørensen"], year: 2000))
        _ = await harness.restartedResolver().resolve(other, documentSHA256: Documents.first)

        #expect(try Self.storedLookups(harness, Documents.first).keys.sorted() == [LookupCacheStore.key(for: other)])
    }

    @Test func aLookupUnderWayWhenItsDocumentIsForgottenIsNotWrittenBack() async throws {
        let slow = StubURLProtocol.Response(status: 200, headers: ["Content-Type": "application/json"],
                                            chunks: [Data(Bodies.crossrefEmpty.utf8)], delayPerChunk: .milliseconds(300))
        StubURLProtocol.setHandler { _ in slow }
        let harness = ResolverHarness()
        defer { harness.cleanUp() }
        let entry = try Entries.hochreiter()
        let resolver = harness.resolver

        let lookup = Task { await resolver.resolve(entry, documentSHA256: Documents.first) }
        #expect(await waitUntil { StubURLProtocol.recordedRequests.count == 1 })
        await resolver.forget(documentSHA256: Documents.first)
        let reference = await lookup.value

        #expect(reference.status == .notFound)                                // still answered
        #expect(!FileManager.default.fileExists(atPath: harness.documentFolder(Documents.first).path))
        _ = await resolver.resolve(entry, documentSHA256: Documents.first)    // and not remembered
        #expect(StubURLProtocol.recordedRequests.count == 2)
    }

    @Test func aLookupThatNeededNoRequestIsNotWritten() async throws {
        StubURLProtocol.setHandler(nil)
        let harness = ResolverHarness()
        defer { harness.cleanUp() }

        #expect(await harness.resolver.resolve(try Entries.devlin(), documentSHA256: Documents.first).status == .resolved)
        #expect(await harness.resolver.resolve(Entries.withoutSurname, documentSHA256: Documents.first).status == .notFound)
        #expect(!FileManager.default.fileExists(atPath: harness.home.path))
    }

    @Test func aDamagedFileCountsAsEmptyAndIsReplaced() async throws {
        StubURLProtocol.setHandler(Stub.services(crossref: Bodies.crossrefHochreiter, openAlex: Bodies.openAlexHochreiter))
        let harness = ResolverHarness()
        defer { harness.cleanUp() }
        try FileManager.default.createDirectory(at: harness.documentFolder(Documents.first), withIntermediateDirectories: true)
        try Data("{\"schemaVersion\": 1, \"lookups\": [".utf8).write(to: harness.referencesFile(Documents.first))
        let entry = try Entries.hochreiter()

        #expect(await harness.resolver.resolve(entry, documentSHA256: Documents.first).status == .resolved)
        #expect(StubURLProtocol.recordedRequests.count == 2)
        #expect(try Self.storedLookups(harness, Documents.first).count == 1)
    }

    @Test(arguments: ["", "../escape", "a/b", String(repeating: "f", count: 200), "abc def"])
    func aDocumentIDThatIsNoPlainNameCachesNothing(_ document: String) async throws {
        StubURLProtocol.setHandler(Stub.services(crossref: Bodies.crossrefHochreiter, openAlex: Bodies.openAlexHochreiter))
        let harness = ResolverHarness()
        defer { harness.cleanUp() }
        let entry = try Entries.hochreiter()

        #expect(await harness.resolver.resolve(entry, documentSHA256: document).status == .resolved)
        #expect(await harness.resolver.resolve(entry, documentSHA256: document).status == .resolved)
        await harness.resolver.forget(documentSHA256: document)

        #expect(StubURLProtocol.recordedRequests.count == 4)
        #expect(!FileManager.default.fileExists(atPath: harness.home.path))
    }

    /// The lookups in a document's references.json.
    private static func storedLookups(_ harness: ResolverHarness, _ document: String) throws -> [String: ResolvedReference] {
        struct File: Decodable { var schemaVersion: Int; var lookups: [String: ResolvedReference] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(File.self, from: Data(contentsOf: harness.referencesFile(document)))
        #expect(file.schemaVersion == 1)
        return file.lookups
    }
}
