import Foundation
import RefereeCore

/// Every entry resolves at once: status .resolved, title "Resolved: " + first 30 characters, an example.org open-access URL.
///
/// The rest of a result is as fixed as its title: authors, year, DOI and arXiv id are the entry's own parsed values,
/// the landing page is https://example.org/reference/<id>, the PDF is that address with ".pdf", the source is
/// `.entryText`, the confidence 1 and the date always the same. No request is ever made.
///
/// `init(answers:)` (step 5c) lets chosen entries come back as the real resolver gives a lookup that found nothing
/// (`.notFound`, no record) or one that failed (`.failed`, with its reason): what the snapshot mode needs to show those
/// cards through the model (`SnapshotSupport.resolver(lookups:)`).
///
/// `fetchPDF` hands back a fixture, Fixtures/pdf/num_twocol_links.pdf, as the downloaded paper; it throws
/// `.noOpenAccessPDF` for a reference without a PDF address and when the fixtures cannot be found.
public final class FakeResolver: ReferenceResolving, @unchecked Sendable {
    /// What the fake answers for one entry.
    public enum Answer: Sendable, Equatable {
        case resolved                       // the record described above
        case notFound                       // status .notFound, no record, confidence 0
        case failed(reason: String)         // status .failed with this failureReason, confidence 0
    }

    private let lock = NSLock()
    private var forgotten: [String] = []
    private let answer: @Sendable (BibEntry) -> Answer
    private static let date = Date(timeIntervalSince1970: 1_800_000_000)

    public init() { answer = { _ in .resolved } }

    /// The answer for each entry from `answers`; the rest of a result as described above.
    public init(answers: @escaping @Sendable (BibEntry) -> Answer) { answer = answers }

    /// The documents `forget` was called for, in order. Not part of `ReferenceResolving`: a test of "delete review data"
    /// has to see that the resolver was told to forget (plan.md section 11.4, WP8b), and the protocol offers no way to ask.
    public var forgottenDocuments: [String] {
        lock.withLock { forgotten }
    }

    public func resolve(_ entry: BibEntry, documentSHA256: String) async -> ResolvedReference {
        switch answer(entry) {
        case .resolved:
            return ResolvedReference(entryID: entry.id, status: .resolved, title: "Resolved: " + String(entry.rawText.prefix(30)),
                                     authors: entry.parsed.authorSurnames, year: entry.parsed.year, doi: entry.parsed.doi,
                                     arxivID: entry.parsed.arxivID, landingURL: "https://example.org/reference/\(entry.id)",
                                     openAccessPDFURL: "https://example.org/reference/\(entry.id).pdf",
                                     source: .entryText, confidence: 1.0, resolvedAt: Self.date)
        case .notFound:
            return ResolvedReference(entryID: entry.id, status: .notFound, confidence: 0, resolvedAt: Self.date)
        case .failed(let reason):
            return ResolvedReference(entryID: entry.id, status: .failed, failureReason: reason, confidence: 0, resolvedAt: Self.date)
        }
    }

    public func forget(documentSHA256: String) async {
        lock.withLock { forgotten.append(documentSHA256) }
    }

    public func fetchPDF(for reference: ResolvedReference) async throws -> URL {
        let paper = Fixtures.url("pdf/num_twocol_links.pdf")
        guard reference.openAccessPDFURL != nil, FileManager.default.fileExists(atPath: paper.path) else {
            throw ResolverError.noOpenAccessPDF
        }
        return paper
    }

    /// A Google Scholar query for the entry's text.
    public func searchURL(for entry: BibEntry) -> URL {
        let base = URL(string: "https://scholar.google.com/scholar")!     // a literal: cannot fail
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "q", value: entry.rawText)]
        return components?.url ?? base
    }
}
