import Foundation
import Testing
import RefereeCore
@testable import ScholarKit
import TestSupport

/// Acceptance row "identifier short-circuits" (plan.md section 11.4, WP7; section 8.7 steps 1 and 2).
@Suite struct ScholarKitIdentifierTests {
    @Test func anArxivIDMakesNoRequestAndGivesTheAbstractAndPDFAddresses() async throws {
        StubURLProtocol.setHandler { _ in Stub.json(Bodies.openAlexHochreiter) }        // would answer anything
        let harness = ResolverHarness()
        defer { harness.cleanUp() }
        let entry = try Entries.devlin()
        #expect(entry.rawText.hasSuffix("understanding. In NAACL, 2019. arXiv:1810.04805."))

        let reference = await harness.resolver.resolve(entry, documentSHA256: Documents.first)

        #expect(StubURLProtocol.recordedRequests.isEmpty)
        #expect(reference == ResolvedReference(entryID: entry.id, status: .resolved, title: entry.parsed.title, authors: entry.parsed.authorSurnames,
                                               year: 2019, arxivID: "1810.04805", landingURL: "https://arxiv.org/abs/1810.04805",
                                               openAccessPDFURL: "https://arxiv.org/pdf/1810.04805", source: .entryText, confidence: 1.0,
                                               resolvedAt: harness.clock.now()))
    }

    @Test func aDOIMakesExactlyOneRequestToOpenAlex() async throws {
        StubURLProtocol.setHandler { request in
            request.url?.host == "api.openalex.org" ? Stub.json(Bodies.openAlexHochreiter) : Stub.json(Bodies.crossrefHochreiter)
        }
        let harness = ResolverHarness()
        defer { harness.cleanUp() }
        var entry = try Entries.hochreiter()
        entry.parsed.doi = "10.1162/neco.1997.9.8.1735"

        let reference = await harness.resolver.resolve(entry, documentSHA256: Documents.first)

        let requests = StubURLProtocol.recordedRequests
        #expect(requests.count == 1)
        #expect(requests.first?.httpMethod == "GET")
        #expect(requests.first?.url?.absoluteString == "https://api.openalex.org/works/doi:10.1162/neco.1997.9.8.1735"
                + "?select=id,doi,title,publication_year,authorships,primary_location,open_access,best_oa_location")
        #expect(reference == ResolvedReference(entryID: entry.id, status: .resolved, title: "Long Short-Term Memory",
                                               authors: ["Sepp Hochreiter", "Jürgen Schmidhuber"], year: 1997, venue: "Neural Computation",
                                               doi: "10.1162/neco.1997.9.8.1735", landingURL: "https://doi.org/10.1162/neco.1997.9.8.1735",
                                               openAccessPDFURL: nil, source: .entryText, confidence: 1.0, resolvedAt: harness.clock.now()))
    }

    @Test func theFixturesDOIBrokenAcrossTwoLinesGoesToOpenAlexWhole() async throws {
        StubURLProtocol.setHandler { _ in Stub.status(404) }
        let harness = ResolverHarness()
        defer { harness.cleanUp() }
        let entry = try Entries.cho()
        #expect(entry.rawText.hasSuffix("In EMNLP, 2014. https://doi.org/10.3115/v1/D14-1179"))

        let reference = await harness.resolver.resolve(entry, documentSHA256: Documents.first)

        #expect(StubURLProtocol.recordedRequests.map { $0.url?.path } == ["/works/doi:10.3115/v1/d14-1179"])
        // 404: the DOI is kept, with what the entry itself says.
        #expect(reference == ResolvedReference(entryID: entry.id, status: .resolved, title: entry.parsed.title, authors: entry.parsed.authorSurnames,
                                               year: 2014, doi: "10.3115/v1/d14-1179", landingURL: "https://doi.org/10.3115/v1/d14-1179",
                                               source: .entryText, confidence: 1.0, resolvedAt: harness.clock.now()))
    }

    @Test func anArxivIDIsUsedBeforeADOI() async throws {
        StubURLProtocol.setHandler { _ in Stub.json(Bodies.openAlexHochreiter) }
        let harness = ResolverHarness()
        defer { harness.cleanUp() }
        var entry = try Entries.devlin()
        entry.parsed.doi = "10.18653/v1/n19-1423"

        let reference = await harness.resolver.resolve(entry, documentSHA256: Documents.first)

        #expect(StubURLProtocol.recordedRequests.isEmpty)
        #expect(reference.landingURL == "https://arxiv.org/abs/1810.04805")
        #expect(reference.doi == "10.18653/v1/n19-1423")
    }

    @Test(arguments: ["10.1162/NECO.1997.9.8.1735", "https://doi.org/10.1162/neco.1997.9.8.1735", "doi: 10.1162/neco.1997.9.8.1735.",
                      "http://dx.doi.org/10.1162/neco.1997.9.8.1735,"])
    func aDOIIsSentBareAndInLowerCase(_ printed: String) async throws {
        StubURLProtocol.setHandler { _ in Stub.json(Bodies.openAlexHochreiter) }
        let harness = ResolverHarness()
        defer { harness.cleanUp() }
        var entry = try Entries.hochreiter()
        entry.parsed.doi = printed

        let reference = await harness.resolver.resolve(entry, documentSHA256: Documents.first)

        #expect(StubURLProtocol.recordedRequests.map { $0.url?.path } == ["/works/doi:10.1162/neco.1997.9.8.1735"])
        #expect(reference.doi == "10.1162/neco.1997.9.8.1735")
    }

    @Test func charactersThatWouldEndThePathAreEncodedInTheDOI() async throws {
        StubURLProtocol.setHandler { _ in Stub.status(404) }
        let harness = ResolverHarness()
        defer { harness.cleanUp() }
        var entry = try Entries.hochreiter()
        entry.parsed.doi = "10.1002/(sici)1097-4571(199806)49:8<693::aid-asi4>3.0.co;2-o"

        let reference = await harness.resolver.resolve(entry, documentSHA256: Documents.first)

        let url = try #require(StubURLProtocol.recordedRequests.first?.url)
        #expect(url.host == "api.openalex.org")
        #expect(url.absoluteString.contains("/works/doi:10.1002/(sici)1097-4571(199806)49:8%3C693::aid-asi4%3E3.0.co;2-o?select="))
        #expect(reference.doi == "10.1002/(sici)1097-4571(199806)49:8<693::aid-asi4>3.0.co;2-o")
        #expect(reference.landingURL == "https://doi.org/10.1002/(sici)1097-4571(199806)49:8%3C693::aid-asi4%3E3.0.co;2-o")
    }
}
