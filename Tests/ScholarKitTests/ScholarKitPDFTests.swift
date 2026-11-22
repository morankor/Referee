import Foundation
import Testing
import RefereeCore
@testable import ScholarKit
import TestSupport

/// Acceptance row "PDF fetch" (plan.md section 11.4, WP7; "Fetching the PDF" in section 8.7).
@Suite struct ScholarKitPDFTests {
    private static let address = "https://example.org/paper.pdf"

    private static func reference(_ address: String?) -> ResolvedReference {
        ResolvedReference(entryID: 3, status: .resolved, title: "Long Short-Term Memory", doi: "10.1162/neco.1997.9.8.1735",
                          openAccessPDFURL: address, source: .crossref, confidence: 1, resolvedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func aStubbedPDFIsStoredInThePDFCache() async throws {
        StubURLProtocol.setHandler { request in request.url?.host == "example.org" ? Stub.pdf(size: 5_000) : nil }
        let harness = ResolverHarness()
        defer { harness.cleanUp() }

        let file = try await harness.resolver.fetchPDF(for: Self.reference(Self.address))

        #expect(file.deletingLastPathComponent().path == harness.papersDirectory.path)
        #expect(file.lastPathComponent == ReferenceText.sha256Hex(Self.address) + ".pdf")
        let bytes = try Data(contentsOf: file)
        #expect(bytes.starts(with: Data("%PDF-".utf8)))
        #expect(bytes == Stub.pdfBody(size: 5_000))
        #expect(allFiles(in: harness.papersDirectory) == [file.lastPathComponent])               // no partial file left
        let request = try #require(StubURLProtocol.recordedRequests.first)
        #expect(request.url?.absoluteString == Self.address)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Referee/0.1.0")

        // Asked again: handed out from the cache.
        #expect(try await harness.resolver.fetchPDF(for: Self.reference(Self.address)) == file)
        #expect(StubURLProtocol.recordedRequests.count == 1)
    }

    @Test(arguments: ["<!DOCTYPE html><html><body>Sign in to read this article</body></html>", "%PD", ""])
    func aBodyThatIsNotAPDFIsRefused(_ body: String) async throws {
        StubURLProtocol.setHandler { _ in StubURLProtocol.Response(status: 200, headers: ["Content-Type": "text/html"], chunks: [Data(body.utf8)]) }
        let harness = ResolverHarness()
        defer { harness.cleanUp() }

        await #expect(throws: ResolverError.notAPDF) { _ = try await harness.resolver.fetchPDF(for: Self.reference(Self.address)) }

        #expect(allFiles(in: harness.papersDirectory).isEmpty)
    }

    @Test func anHTTPAddressIsNotFetched() async throws {
        StubURLProtocol.setHandler { _ in Stub.pdf() }
        let harness = ResolverHarness()
        defer { harness.cleanUp() }

        await #expect(throws: ResolverError.noOpenAccessPDF) {
            _ = try await harness.resolver.fetchPDF(for: Self.reference("http://example.org/paper.pdf"))
        }
        #expect(StubURLProtocol.recordedRequests.isEmpty)
    }

    @Test(arguments: [nil, "", "not a url", "https:///paper.pdf"] as [String?])
    func aReferenceWithoutAUsablePDFAddressHasNothingToFetch(_ address: String?) async throws {
        StubURLProtocol.setHandler { _ in Stub.pdf() }
        let harness = ResolverHarness()
        defer { harness.cleanUp() }

        await #expect(throws: ResolverError.noOpenAccessPDF) { _ = try await harness.resolver.fetchPDF(for: Self.reference(address)) }
        #expect(StubURLProtocol.recordedRequests.isEmpty)
    }

    @Test func aServerErrorIsADownloadFailure() async throws {
        StubURLProtocol.setHandler { _ in Stub.status(404) }
        let harness = ResolverHarness()
        defer { harness.cleanUp() }

        await #expect(throws: ResolverError.downloadFailed("HTTP 404")) { _ = try await harness.resolver.fetchPDF(for: Self.reference(Self.address)) }
        #expect(allFiles(in: harness.papersDirectory).isEmpty)
    }

    @Test func aRefusedConnectionIsADownloadFailure() async throws {
        StubURLProtocol.setHandler(nil)
        let harness = ResolverHarness()
        defer { harness.cleanUp() }

        await #expect(throws: ResolverError.downloadFailed("the connection failed")) {
            _ = try await harness.resolver.fetchPDF(for: Self.reference(Self.address))
        }
    }

    @Test func aBodyOverTheSizeLimitIsStoppedAndDiscarded() async throws {
        let chunk = Stub.pdfBody(size: 1_000)
        let endless = StubURLProtocol.Response(status: 200, headers: ["Content-Type": "application/pdf"],
                                               chunks: Array(repeating: chunk, count: 50), delayPerChunk: .milliseconds(20))
        StubURLProtocol.setHandler { _ in endless }
        let harness = ResolverHarness(maxPDFBytes: 2_500)
        defer { harness.cleanUp() }

        await #expect(throws: ResolverError.downloadFailed("it is larger than 2500 bytes")) {
            _ = try await harness.resolver.fetchPDF(for: Self.reference(Self.address))
        }

        #expect(await waitUntil { await harness.session.allTasks.isEmpty })     // the transfer was stopped, not read to its end
        #expect(allFiles(in: harness.papersDirectory).isEmpty)
    }

    @Test func aDeclaredLengthOverTheLimitIsRefusedBeforeTheBody() async throws {
        StubURLProtocol.setHandler { _ in
            StubURLProtocol.Response(status: 200, headers: ["Content-Type": "application/pdf", "Content-Length": "5000"], chunks: [Stub.pdfBody(size: 5_000)])
        }
        let harness = ResolverHarness(maxPDFBytes: 2_500)
        defer { harness.cleanUp() }

        await #expect(throws: ResolverError.downloadFailed("it is larger than 2500 bytes")) {
            _ = try await harness.resolver.fetchPDF(for: Self.reference(Self.address))
        }
    }

    @Test func evictionKeepsTheFolderUnderTheLimit() async throws {
        StubURLProtocol.setHandler { _ in Stub.pdf(size: 300_000) }
        let harness = ResolverHarness(pdfCacheLimitMB: 1)
        defer { harness.cleanUp() }
        // Three papers of 400 kB fetched earlier, the oldest three days ago: 1.2 MB, over the 1 MB limit already.
        let old = try Self.placeOldPapers(in: harness, ages: [3, 2, 1])

        let file = try await harness.resolver.fetchPDF(for: Self.reference(Self.address))

        #expect(Self.folderSize(harness.papersDirectory) <= 1_000_000)
        #expect(visibleFiles(in: harness.papersDirectory) == [old[2], file.lastPathComponent].sorted())     // the two oldest went
    }

    @Test func aPaperHandedOutAgainCountsAsRecentlyUsed() async throws {
        StubURLProtocol.setHandler { _ in Stub.pdf(size: 300_000) }
        let harness = ResolverHarness(pdfCacheLimitMB: 1)
        defer { harness.cleanUp() }
        let first = try await harness.resolver.fetchPDF(for: Self.reference("https://example.org/first.pdf"))
        harness.clock.advance(by: 60)
        let second = try await harness.resolver.fetchPDF(for: Self.reference("https://example.org/second.pdf"))
        harness.clock.advance(by: 60)
        _ = try await harness.resolver.fetchPDF(for: Self.reference("https://example.org/first.pdf"))   // from the cache
        harness.clock.advance(by: 60)

        let third = try await harness.resolver.fetchPDF(for: Self.reference("https://example.org/third.pdf"))
        harness.clock.advance(by: 60)
        let fourth = try await harness.resolver.fetchPDF(for: Self.reference("https://example.org/fourth.pdf"))

        #expect(StubURLProtocol.recordedRequests.count == 4)
        // 4 × 300 kB is over 1 MB: the least recently used, "second", went; "first" stayed.
        #expect(visibleFiles(in: harness.papersDirectory) == [first, third, fourth].map(\.lastPathComponent).sorted())
        #expect(!FileManager.default.fileExists(atPath: second.path))
    }

    @Test func aPaperLargerThanTheWholeLimitIsStillHandedOut() async throws {
        StubURLProtocol.setHandler { _ in Stub.pdf(size: 300_000) }
        let harness = ResolverHarness(pdfCacheLimitMB: 0)
        defer { harness.cleanUp() }
        _ = try Self.placeOldPapers(in: harness, ages: [1])

        let file = try await harness.resolver.fetchPDF(for: Self.reference(Self.address))

        #expect(visibleFiles(in: harness.papersDirectory) == [file.lastPathComponent])
    }

    @Test func anAbandonedPartialDownloadIsCleanedUp() async throws {
        StubURLProtocol.setHandler { _ in Stub.pdf() }
        let harness = ResolverHarness()
        defer { harness.cleanUp() }
        try FileManager.default.createDirectory(at: harness.papersDirectory, withIntermediateDirectories: true)
        let abandoned = harness.papersDirectory.appendingPathComponent(".abandoned.partial")
        let recent = harness.papersDirectory.appendingPathComponent(".recent.partial")
        try Data(count: 10).write(to: abandoned)
        try Data(count: 10).write(to: recent)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7_200)], ofItemAtPath: abandoned.path)

        let file = try await harness.resolver.fetchPDF(for: Self.reference(Self.address))

        #expect(allFiles(in: harness.papersDirectory) == [".recent.partial", file.lastPathComponent].sorted())
    }

    // ---- helpers ----

    /// PDFs of 400 kB in the cache folder, last used the given numbers of days before the test clock's start.
    private static func placeOldPapers(in harness: ResolverHarness, ages: [Int]) throws -> [String] {
        try FileManager.default.createDirectory(at: harness.papersDirectory, withIntermediateDirectories: true)
        return try ages.enumerated().map { index, age in
            let name = ReferenceText.sha256Hex("https://example.org/old-\(index).pdf") + ".pdf"
            let file = harness.papersDirectory.appendingPathComponent(name)
            try Stub.pdfBody(size: 400_000).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: harness.clock.now().addingTimeInterval(-Double(age) * 86_400)],
                                                  ofItemAtPath: file.path)
            return name
        }
    }

    private static func folderSize(_ folder: URL) -> Int {
        visibleFiles(in: folder).reduce(0) { total, name in
            let size = (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.size] as? NSNumber)?.intValue
            return total + (size ?? 0)
        }
    }
}
