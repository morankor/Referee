import Foundation
import Testing
import RefereeCore
@testable import ScholarKit
import TestSupport

/// What Gate 1 added to `ReferenceResolving` and `ResolvedReference` (plan.md Appendix A.3, sections 8.6 and 9.6): a
/// failed lookup says why, and the PDF cache can be measured and cleared.
@Suite struct ScholarKitContractTests {
    @Test func aLookupThatCannotReachTheServiceSaysWhyWithoutNamingTheReference() async throws {
        StubURLProtocol.setHandler { _ in nil }                          // connection refused
        let harness = ResolverHarness()
        defer { harness.cleanUp() }
        let entry = try Entries.hochreiter()
        let reference = await harness.resolver.resolve(entry, documentSHA256: Documents.first)
        #expect(reference.status == .failed)
        #expect(reference.failureReason == "Crossref could not be reached; check the connection and try again.")
        #expect(!(reference.failureReason ?? "").contains("Hochreiter"))
    }

    @Test(arguments: [
        ("rate-limited", "Crossref is busy; try again in a minute."),
        ("server", "Crossref had a problem answering; try again later."),
        ("network", "Crossref could not be reached; check the connection and try again."),
        ("cancelled", "the lookup was cancelled."),
        ("unreadable", "Crossref sent an answer the app could not read."),
        ("http-403", "Crossref refused the request (HTTP 403)."),
        ("something-new", "Crossref did not answer as expected."),
    ])
    func everyReasonReadsAsASentence(_ reason: String, _ sentence: String) {
        #expect(ReferenceLookup.failureReason(reason, service: "Crossref") == sentence)
    }

    @Test func theCacheIsMeasuredAndCleared() async throws {
        StubURLProtocol.setHandler { request in request.url?.host == "example.org" ? Stub.pdf(size: 5_000) : nil }
        let harness = ResolverHarness()
        defer { harness.cleanUp() }
        #expect(await harness.resolver.cachedPDFBytes() == 0)            // no folder yet
        for name in ["one", "two"] {
            let reference = ResolvedReference(entryID: 0, status: .resolved, openAccessPDFURL: "https://example.org/\(name).pdf", confidence: 1,
                                              resolvedAt: Date(timeIntervalSince1970: 1_800_000_000))
            _ = try await harness.resolver.fetchPDF(for: reference)
        }
        #expect(await harness.resolver.cachedPDFBytes() == 2 * Stub.pdfBody(size: 5_000).count)
        try Data("not a pdf".utf8).write(to: harness.papersDirectory.appendingPathComponent("notes.txt"))   // only PDFs count and go
        await harness.resolver.clearPDFCache()
        #expect(await harness.resolver.cachedPDFBytes() == 0)
        #expect(allFiles(in: harness.papersDirectory) == ["notes.txt"])
        #expect(await FakeResolver().cachedPDFBytes() == 0)              // the protocol's default
    }
}
