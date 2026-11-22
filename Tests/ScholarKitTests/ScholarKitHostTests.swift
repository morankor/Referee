import Foundation
import Testing
import RefereeCore
@testable import ScholarKit
import TestSupport

/// Acceptance row "nothing else is called" (plan.md section 11.4, WP7; sections 8.7 and 12.3).
@Suite struct ScholarKitHostTests {
    @Test func noRequestGoesToAHostOtherThanTheTwoServicesAndThePDFsOwn() async throws {
        // Every host gets an answer, so that a stray request would be recorded rather than refused unseen.
        StubURLProtocol.setHandler { request in
            switch request.url?.host {
            case "api.crossref.org": return Stub.json(Bodies.crossrefHochreiter)
            case "api.openalex.org": return Stub.json(Bodies.openAlexOpenAccess)
            case "example.org": return Stub.pdf()
            default: return Stub.json("{}")
            }
        }
        let harness = ResolverHarness()
        defer { harness.cleanUp() }
        let resolver = harness.resolver
        let hochreiter = try Entries.hochreiter(), devlin = try Entries.devlin(), cho = try Entries.cho()

        let found = await resolver.resolve(hochreiter, documentSHA256: Documents.first)          // Crossref, then OpenAlex
        _ = await resolver.resolve(cho, documentSHA256: Documents.first)                         // OpenAlex
        _ = await resolver.resolve(devlin, documentSHA256: Documents.first)                      // nothing
        _ = await resolver.resolve(Entries.withoutSurname, documentSHA256: Documents.first)       // nothing
        _ = await resolver.resolve(hochreiter, documentSHA256: Documents.first)                  // the cache
        _ = resolver.searchURL(for: hochreiter)                                                   // only an address
        #expect(found.openAccessPDFURL == "https://example.org/paper.pdf")
        let file = try await resolver.fetchPDF(for: found)                                       // the PDF's host
        #expect(FileManager.default.fileExists(atPath: file.path))
        await resolver.forget(documentSHA256: Documents.first)

        let requests = StubURLProtocol.recordedRequests
        #expect(requests.compactMap { $0.url?.host } == ["api.crossref.org", "api.openalex.org", "api.openalex.org", "example.org"])
        #expect(Set(requests.compactMap { $0.url?.scheme }) == ["https"])
        for request in requests {
            // Nothing but the reference text or identifier: no cookie, no credentials, no address, no name.
            #expect(request.httpMethod == "GET")
            #expect(request.httpBody == nil)
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "Referee/0.1.0")
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        }
    }
}
