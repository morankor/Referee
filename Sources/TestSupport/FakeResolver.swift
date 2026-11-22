import Foundation
import RefereeCore

// Wave 0a placeholder (see Placeholder.swift).

/// Every entry resolves at once: status .resolved, title "Resolved: " + first 30 characters, an example.org open-access URL.
/// Placeholder: every entry is "not found" and there is never a PDF.
public final class FakeResolver: ReferenceResolving, @unchecked Sendable {
    public init() {}

    public func resolve(_ entry: BibEntry, documentSHA256: String) async -> ResolvedReference {
        ResolvedReference(entryID: entry.id, status: .notFound, confidence: 0, resolvedAt: Date())
    }

    public func forget(documentSHA256: String) async {}

    public func fetchPDF(for reference: ResolvedReference) async throws -> URL { throw ResolverError.noOpenAccessPDF }

    public func searchURL(for entry: BibEntry) -> URL {
        URL(string: "https://scholar.google.com/scholar")!     // a literal: cannot fail
    }
}
