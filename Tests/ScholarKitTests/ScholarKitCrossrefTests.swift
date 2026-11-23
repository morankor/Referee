import Foundation
import Testing
import RefereeCore
@testable import ScholarKit
import TestSupport

/// Acceptance row "Crossref path" (plan.md section 11.4, WP7; section 8.7 step 3).
@Suite struct ScholarKitCrossrefTests {
    /// Made here rather than written out, so that the tree holds no email address (plan.md section 11.1).
    private static let contactAddress = ["referee-test", "example.org"].joined(separator: "@")

    @Test func theHochreiterFixtureIsFoundOnCrossrefAndThenLookedUpOnOpenAlex() async throws {
        StubURLProtocol.setHandler(Stub.services(crossref: Bodies.crossrefHochreiter, openAlex: Bodies.openAlexHochreiter))
        let harness = ResolverHarness()
        defer { harness.cleanUp() }
        let entry = try Entries.hochreiter()
        #expect(entry.rawText == "[4] Sepp Hochreiter and Jürgen Schmidhuber. Long short-term memory. Neural Computation, 9(8):1735–1780, 1997.")

        let reference = await harness.resolver.resolve(entry, documentSHA256: Documents.first)

        let requests = StubURLProtocol.recordedRequests
        #expect(requests.map { $0.url?.host } == ["api.crossref.org", "api.openalex.org"])
        let crossref = try #require(requests.first)
        #expect(crossref.httpMethod == "GET")
        #expect(crossref.url?.path == "/works")
        #expect(crossref.queryNames == ["query.bibliographic", "rows", "select"])
        #expect(crossref.query == ["query.bibliographic": entry.rawText, "rows": "3", "select": "DOI,title,author,issued,container-title,score,type"])
        let agent = try #require(crossref.value(forHTTPHeaderField: "User-Agent"))
        #expect(agent == "HumanInTheLoop/0.1.0")
        #expect(!agent.contains("@") && !agent.contains("mailto"))
        #expect(requests.last?.url?.path == "/works/doi:10.1162/neco.1997.9.8.1735")

        #expect(reference == ResolvedReference(entryID: entry.id, status: .resolved, title: "Long Short-Term Memory",
                                               authors: ["Sepp Hochreiter", "Jürgen Schmidhuber"], year: 1997, venue: "Neural Computation",
                                               doi: "10.1162/neco.1997.9.8.1735", landingURL: "https://doi.org/10.1162/neco.1997.9.8.1735",
                                               openAccessPDFURL: nil, source: .crossref, confidence: 1.0, resolvedAt: harness.clock.now()))
    }

    @Test func aContactAddressGoesToCrossrefInTheQueryAndTheUserAgentAndNowhereElse() async throws {
        StubURLProtocol.setHandler(Stub.services(crossref: Bodies.crossrefHochreiter, openAlex: Bodies.openAlexHochreiter))
        let address = Self.contactAddress
        let harness = ResolverHarness(mailto: "  \(address) ")
        defer { harness.cleanUp() }

        let reference = await harness.resolver.resolve(try Entries.hochreiter(), documentSHA256: Documents.first)

        #expect(reference.status == .resolved)
        let requests = StubURLProtocol.recordedRequests
        let crossref = try #require(requests.first { $0.url?.host == "api.crossref.org" })
        #expect(crossref.queryNames == ["query.bibliographic", "rows", "select", "mailto"])
        #expect(crossref.query["mailto"] == address)
        #expect(crossref.value(forHTTPHeaderField: "User-Agent") == "HumanInTheLoop/0.1.0 (mailto:\(address))")
        let openAlex = try #require(requests.first { $0.url?.host == "api.openalex.org" })
        #expect(openAlex.url?.absoluteString.contains("mailto") == false)
        #expect(openAlex.value(forHTTPHeaderField: "User-Agent") == "HumanInTheLoop/0.1.0")
    }

    /// Each setting is put together from its parts, joined by "@".
    @Test(arguments: [["not an address"], ["two", "at", "signs.org"], ["(paren)", "example.org"], ["nodot", "example"], ["spaced name", "example.org"]])
    func anAddressThatCannotBeSentSafelyIsLeftOut(_ parts: [String]) async throws {
        StubURLProtocol.setHandler(Stub.services(crossref: Bodies.crossrefHochreiter, openAlex: Bodies.openAlexHochreiter))
        let harness = ResolverHarness(mailto: parts.joined(separator: "@"))
        defer { harness.cleanUp() }

        _ = await harness.resolver.resolve(try Entries.hochreiter(), documentSHA256: Documents.first)

        let crossref = try #require(StubURLProtocol.recordedRequests.first)
        #expect(crossref.queryNames == ["query.bibliographic", "rows", "select"])
        #expect(crossref.value(forHTTPHeaderField: "User-Agent") == "HumanInTheLoop/0.1.0")
    }

    @Test func theQueryIsTheFirst300CharactersAndCannotAlterTheRequest() async throws {
        StubURLProtocol.setHandler { _ in Stub.json(Bodies.crossrefEmpty) }
        let harness = ResolverHarness()
        defer { harness.cleanUp() }
        let start = "Smith, J. and Jones, K. (2019). R&D + growth = welfare? \"Quoted\" #1 \n\t of  them. "
        let entry = BibEntry(id: 0, rawText: start + String(repeating: "Long text of the entry. ", count: 20),
                             parsed: ParsedReference(authorSurnames: ["Smith", "Jones"], year: 2019))

        let reference = await harness.resolver.resolve(entry, documentSHA256: Documents.first)

        #expect(reference.status == .notFound)
        let crossref = try #require(StubURLProtocol.recordedRequests.first)
        let sent = try #require(crossref.query["query.bibliographic"])
        #expect(sent.count == 300)
        #expect(sent.hasPrefix("Smith, J. and Jones, K. (2019). R&D + growth = welfare? \"Quoted\" #1 of them. Long text"))
        #expect(crossref.queryNames == ["query.bibliographic", "rows", "select"])
        let url = try #require(crossref.url)
        let raw = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        #expect(raw.hasPrefix("query.bibliographic=Smith%2C%20J.%20and%20Jones%2C%20K.%20%282019%29.%20R%26D%20%2B%20growth%20%3D%20welfare%3F%20%22Quoted%22%20%231%20of%20them."))
    }

    @Test func anEntryWithoutASurnameIsNotSentAnywhere() async {
        StubURLProtocol.setHandler(Stub.services(crossref: Bodies.crossrefHochreiter, openAlex: Bodies.openAlexHochreiter))
        let harness = ResolverHarness()
        defer { harness.cleanUp() }

        let reference = await harness.resolver.resolve(Entries.withoutSurname, documentSHA256: Documents.first)

        #expect(reference.status == .notFound)
        #expect(StubURLProtocol.recordedRequests.isEmpty)
    }

    @Test(arguments: ["<html><body>Service unavailable</body></html>", "{\"status\":\"ok\"}", "[1,2,3]", ""])
    func anAnswerThatIsNotAWorkListIsAFailure(_ body: String) async throws {
        StubURLProtocol.setHandler { _ in Stub.json(body) }
        let harness = ResolverHarness()
        defer { harness.cleanUp() }

        let reference = await harness.resolver.resolve(try Entries.hochreiter(), documentSHA256: Documents.first)

        #expect(reference.status == .failed)
        #expect(StubURLProtocol.recordedRequests.count == 1)
        #expect(!FileManager.default.fileExists(atPath: harness.referencesFile(Documents.first).path))
    }

    @Test func aCrossrefHitWhoseDOIOpenAlexDoesNotKnowKeepsCrossrefsRecord() async throws {
        StubURLProtocol.setHandler { request in
            request.url?.host == "api.crossref.org" ? Stub.json(Bodies.crossrefHochreiter) : Stub.status(404)
        }
        let harness = ResolverHarness()
        defer { harness.cleanUp() }
        let entry = try Entries.hochreiter()

        let reference = await harness.resolver.resolve(entry, documentSHA256: Documents.first)

        #expect(reference == ResolvedReference(entryID: entry.id, status: .resolved, title: "Long Short-Term Memory",
                                               authors: ["Sepp Hochreiter", "Jürgen Schmidhuber"], year: 1997, venue: "Neural Computation",
                                               doi: "10.1162/neco.1997.9.8.1735", landingURL: "https://doi.org/10.1162/neco.1997.9.8.1735",
                                               source: .crossref, confidence: 1.0, resolvedAt: harness.clock.now()))
    }
}
