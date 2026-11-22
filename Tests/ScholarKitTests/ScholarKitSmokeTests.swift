import Foundation
import Testing
import RefereeCore
import ScholarKit
import TestSupport

/// Wave 0a smoke test. It holds for the placeholder and must keep holding for the real implementation (WP7).
/// No request can leave the machine: the session only talks to StubURLProtocol, and nothing is resolved.
@Suite struct ScholarKitSmokeTests {
    @Test func theSearchFallbackIsAGoogleScholarQuery() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("referee-scholarkit-smoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let resolver = ReferenceResolver(settings: { ReferenceSettings(crossrefMailto: "", pdfCacheLimitMB: 500) },
                                         urlSession: StubURLProtocol.session(), dataDirectory: home,
                                         cacheDirectory: home.appendingPathComponent("Caches", isDirectory: true))
        let entry = BibEntry(id: 0, rawText: "Banerjee, A. V. (1992). A simple model of herd behavior. Quarterly Journal of Economics.",
                             parsed: ParsedReference(authorSurnames: ["Banerjee"], year: 1992))
        let url = resolver.searchURL(for: entry)
        #expect(url.scheme == "https")
        #expect(url.host == "scholar.google.com")
    }
}
