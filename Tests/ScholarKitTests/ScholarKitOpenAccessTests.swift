import Foundation
import Testing
import RefereeCore
@testable import ScholarKit
import TestSupport

/// Acceptance row "open access" (plan.md section 11.4, WP7): `best_oa_location.pdf_url` is preferred; `oa_url` is
/// used only when it ends in `.pdf`; none gives `openAccessPDFURL == nil`.
@Suite struct ScholarKitOpenAccessTests {
    /// The PDF address the resolver reports for an entry with a printed DOI, given OpenAlex's answer.
    private func pdfAddress(openAlex body: String) async throws -> String? {
        StubURLProtocol.setHandler { _ in Stub.json(body) }
        let harness = ResolverHarness()
        defer { harness.cleanUp() }
        var entry = try Entries.hochreiter()
        entry.parsed.doi = "10.1162/neco.1997.9.8.1735"
        let reference = await harness.resolver.resolve(entry, documentSHA256: Documents.first)
        #expect(reference.status == .resolved)
        #expect(StubURLProtocol.recordedRequests.count == 1)
        return reference.openAccessPDFURL
    }

    @Test func theHandWrittenOpenAccessRecordGivesItsPDF() async throws {
        #expect(try await pdfAddress(openAlex: Bodies.openAlexOpenAccess) == "https://example.org/paper.pdf")
    }

    @Test func theBestLocationsPDFIsPreferredToTheOpenAccessURL() async throws {
        let body = Bodies.openAlex(replacing: [
            "open_access": ["is_oa": true, "oa_status": "green", "oa_url": "https://example.org/other.pdf"],
            "best_oa_location": ["is_oa": true, "landing_page_url": "https://example.org/abs", "pdf_url": "https://example.org/best.pdf"],
        ])
        #expect(try await pdfAddress(openAlex: body) == "https://example.org/best.pdf")
    }

    @Test(arguments: [("https://example.org/paper.pdf", true), ("https://example.org/files/Paper.PDF?download=1", true),
                      ("https://example.org/abs/1234", false), ("https://example.org/pdf", false), ("https://example.org/a.pdf.html", false)])
    func theOpenAccessURLIsUsedOnlyWhenItEndsInPDF(_ address: String, _ used: Bool) async throws {
        let body = Bodies.openAlex(replacing: [
            "open_access": ["is_oa": true, "oa_status": "green", "oa_url": address],
            "best_oa_location": ["is_oa": true, "landing_page_url": "https://example.org/abs", "pdf_url": NSNull()],
        ])
        #expect(try await pdfAddress(openAlex: body) == (used ? address : nil))
    }

    @Test func anOpenAccessURLAloneIsUsedWhenThereIsNoBestLocation() async throws {
        let body = Bodies.openAlex(replacing: ["open_access": ["is_oa": true, "oa_url": "https://example.org/paper.pdf"], "best_oa_location": NSNull()])
        #expect(try await pdfAddress(openAlex: body) == "https://example.org/paper.pdf")
    }

    @Test func aClosedWorkHasNoPDF() async throws {
        #expect(try await pdfAddress(openAlex: Bodies.openAlexHochreiter) == nil)
    }

    @Test(arguments: ["ftp://example.org/paper.pdf", "not a url", "/relative/paper.pdf"])
    func anAddressThatIsNotAWebAddressIsIgnored(_ address: String) async throws {
        let body = Bodies.openAlex(replacing: ["best_oa_location": ["pdf_url": address], "open_access": ["oa_url": address]])
        #expect(try await pdfAddress(openAlex: body) == nil)
    }

    @Test func aPlainHTTPAddressIsReportedSoThatTheCardCanOfferTheBrowser() async throws {
        let body = Bodies.openAlex(replacing: ["best_oa_location": ["pdf_url": "http://example.org/paper.pdf"]])
        #expect(try await pdfAddress(openAlex: body) == "http://example.org/paper.pdf")
    }
}
