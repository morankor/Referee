import Foundation
import RefereeCore

// Wave 0 placeholder (plan.md section 11.4, WP0a). WP7 replaces every body with the resolver of section 8.7.
// Until then nothing is looked up, nothing is cached and no connection is opened.

public actor ReferenceResolver: ReferenceResolving {
    /// dataDirectory = AppPaths.dataDirectory: a document's lookups are cached in <dataDirectory>/sessions/<sha256>/references.json.
    /// cacheDirectory = AppPaths.cacheDirectory: downloaded PDFs go to <cacheDirectory>/papers/.
    public init(settings: @escaping @Sendable () -> ReferenceSettings, urlSession: URLSession, dataDirectory: URL, cacheDirectory: URL) {}

    /// Placeholder: every entry is "not found".
    public func resolve(_ entry: BibEntry, documentSHA256: String) async -> ResolvedReference {
        ResolvedReference(entryID: entry.id, status: .notFound, confidence: 0, resolvedAt: Date())
    }

    public func forget(documentSHA256: String) async {}

    /// Placeholder: there is never a PDF to fetch.
    public func fetchPDF(for reference: ResolvedReference) async throws -> URL {
        throw ResolverError.noOpenAccessPDF
    }

    /// A Google Scholar query for the entry's text.
    public nonisolated func searchURL(for entry: BibEntry) -> URL {
        let base = URL(string: "https://scholar.google.com/scholar")!     // a literal: cannot fail
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "q", value: entry.rawText)]
        return components?.url ?? base
    }
}
