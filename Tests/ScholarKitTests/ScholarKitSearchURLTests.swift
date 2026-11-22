import Foundation
import Testing
import RefereeCore
@testable import ScholarKit
import TestSupport

/// Acceptance row "search URL" (plan.md section 11.4, WP7; "Manual fallback" in section 8.7). No request is made.
@Suite struct ScholarKitSearchURLTests {
    /// A resolver whose session refuses every request (nothing is written, so there is nothing to clean up).
    private static func resolver() -> ReferenceResolver {
        StubURLProtocol.setHandler(nil)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("referee-scholarkit-search-\(UUID().uuidString)", isDirectory: true)
        return ReferenceResolver(settings: { ReferenceSettings(crossrefMailto: "", pdfCacheLimitMB: 500) }, urlSession: StubURLProtocol.session(),
                                 dataDirectory: home, cacheDirectory: home.appendingPathComponent("Caches", isDirectory: true))
    }

    @Test func aTitleWithQuotesAmpersandsAndNonASCIILettersIsPercentEncoded() {
        let title = "Smith & Wesson: \"Quoted\" Müller–Ørsted café"
        let entry = BibEntry(id: 0, rawText: "Smith, A. (2020). \(title). Journal.", parsed: ParsedReference(authorSurnames: ["Smith"], year: 2020, title: title))

        let url = Self.resolver().searchURL(for: entry)

        #expect(url.absoluteString == "https://scholar.google.com/scholar?q="
                + "Smith%20%26%20Wesson%3A%20%22Quoted%22%20M%C3%BCller%E2%80%93%C3%98rsted%20caf%C3%A9")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        #expect(items == [URLQueryItem(name: "q", value: title)])
        #expect(StubURLProtocol.recordedRequests.isEmpty)
    }

    @Test func charactersThatWouldChangeTheQueryAreEncoded() {
        let title = "a+b=c #1? 50% / 100"
        let url = Self.resolver().searchURL(for: BibEntry(id: 0, rawText: "x", parsed: ParsedReference(title: title)))
        #expect(url.absoluteString == "https://scholar.google.com/scholar?q=a%2Bb%3Dc%20%231%3F%2050%25%20%2F%20100")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == title)
    }

    @Test func withoutATitleTheFirst200CharactersOfTheEntryAreUsed() throws {
        let raw = "Banerjee, A. V.  (1992).\nA simple model of herd behavior. " + String(repeating: "Quarterly Journal of Economics. ", count: 10)
        let entry = BibEntry(id: 0, rawText: raw, parsed: ParsedReference(authorSurnames: ["Banerjee"], year: 1992, title: "  "))

        let url = Self.resolver().searchURL(for: entry)

        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value)
        #expect(query.count == 200)
        #expect(query.hasPrefix("Banerjee, A. V. (1992). A simple model of herd behavior. Quarterly Journal"))
        #expect(url.host == "scholar.google.com")
        #expect(url.path == "/scholar")
    }

    @Test func anEmptyEntryStillGivesAScholarAddress() {
        let url = Self.resolver().searchURL(for: BibEntry(id: 0, rawText: "", parsed: ParsedReference()))
        #expect(url.absoluteString == "https://scholar.google.com/scholar?q=")
    }
}
