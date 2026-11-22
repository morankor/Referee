import Foundation
import Testing
import RefereeCore
import ScholarKit
import TestSupport

/// Acceptance row "live" (plan.md section 11.4, WP7): only with REFEREE_LIVE_NET=1 (section 10.6). Two requests, one
/// to api.crossref.org and one to api.openalex.org, carrying the public reference of a fixture and nothing else:
/// no contact address, `User-Agent: Referee/0.1.0`.
@Suite struct ScholarKitLiveTests {
    static let enabled = ProcessInfo.processInfo.environment["REFEREE_LIVE_NET"] == "1"

    @Test(.enabled(if: enabled, "calls api.crossref.org and api.openalex.org; set REFEREE_LIVE_NET=1 to run it"))
    func theHochreiterEntryResolvesAgainstTheRealServices() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("referee-scholarkit-live-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let configuration = URLSessionConfiguration.ephemeral     // as LiveDependencies.makeURLSession: no cookies, no cache
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let resolver = ReferenceResolver(settings: { ReferenceSettings(crossrefMailto: "", pdfCacheLimitMB: 500) }, urlSession: session,
                                         dataDirectory: home, cacheDirectory: home.appendingPathComponent("Caches", isDirectory: true))
        let entry = try Entries.hochreiter()
        let document = String(repeating: "0", count: 64)

        let reference = await resolver.resolve(entry, documentSHA256: document)

        #expect(reference.status == .resolved)
        #expect(reference.doi == "10.1162/neco.1997.9.8.1735")
        #expect(reference.source == .crossref)
        #expect(reference.title?.lowercased() == "long short-term memory")
        #expect(reference.year == 1997)
        #expect(reference.authors.first?.contains("Hochreiter") == true)
        #expect(reference.landingURL == "https://doi.org/10.1162/neco.1997.9.8.1735")
        #expect(reference.confidence >= 0.9)
        let file = home.appendingPathComponent("sessions/\(document)/references.json")
        #expect(FileManager.default.fileExists(atPath: file.path))
        print("live lookup: status=\(reference.status.rawValue) doi=\(reference.doi ?? "-") source=\(reference.source?.rawValue ?? "-") "
              + "confidence=\(reference.confidence) year=\(reference.year.map(String.init) ?? "-") pdf=\(reference.openAccessPDFURL ?? "none")")
    }
}
