import Foundation

public enum CitationStyle: String, Codable, Sendable { case numeric, authorYear, unknown }

public struct ParsedReference: Codable, Sendable, Equatable {
    public var authorSurnames: [String]      // in printed order
    public var year: Int?
    public var yearSuffix: String?           // "a", "b"
    public var title: String?
    public var doi: String?                  // bare, lowercased, no URL prefix
    public var arxivID: String?
    public var url: String?
    public init(authorSurnames: [String] = [], year: Int? = nil, yearSuffix: String? = nil, title: String? = nil, doi: String? = nil, arxivID: String? = nil,
                url: String? = nil) {
        self.authorSurnames = authorSurnames; self.year = year; self.yearSuffix = yearSuffix; self.title = title; self.doi = doi; self.arxivID = arxivID
        self.url = url
    }
}

public struct BibEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: Int                       // 0-based position in the reference list
    public var label: String?                // "13" for numeric lists
    public var rawText: String               // entry lines joined by a space, margin numbers removed
    public var spans: [TextSpan]
    public var firstLineBounds: PageRect?
    public var parsed: ParsedReference
    public init(id: Int, label: String? = nil, rawText: String, spans: [TextSpan] = [], firstLineBounds: PageRect? = nil, parsed: ParsedReference) {
        self.id = id; self.label = label; self.rawText = rawText; self.spans = spans; self.firstLineBounds = firstLineBounds; self.parsed = parsed
    }
}

public enum MentionSource: String, Codable, Sendable { case linkAnnotation, textPattern }

public struct CitationMention: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var pageIndex: Int
    public var text: String                  // "Smith and Jones (2019)", "12"
    public var spans: [TextSpan]             // one per text line touched; empty when only the link rectangle is known
    public var rects: [PageRect]             // click targets
    public var entryIDs: [Int]               // candidate BibEntry ids; empty = unresolved
    public var source: MentionSource
    public init(id: Int, pageIndex: Int, text: String, spans: [TextSpan] = [], rects: [PageRect] = [], entryIDs: [Int] = [], source: MentionSource) {
        self.id = id; self.pageIndex = pageIndex; self.text = text; self.spans = spans; self.rects = rects; self.entryIDs = entryIDs; self.source = source
    }
}

public struct CitationIndex: Codable, Sendable, Equatable {
    public var style: CitationStyle
    public var entries: [BibEntry]
    public var mentions: [CitationMention]
    public var bibliographyHeading: TextSpan?
    public init(style: CitationStyle, entries: [BibEntry] = [], mentions: [CitationMention] = [], bibliographyHeading: TextSpan? = nil) {
        self.style = style; self.entries = entries; self.mentions = mentions; self.bibliographyHeading = bibliographyHeading
    }
}

public protocol CitationIndexing: Sendable {
    /// Pure. Text-pattern mentions come back with `rects == []`; the caller fills them with PaperService.rects(for:in:).
    func buildIndex(paper: PaperText, links: [RawLink]) -> CitationIndex
}

// ---- Resolution ----

public enum ResolutionSource: String, Codable, Sendable { case entryText, linkAnnotation, crossref, openAlex }
public enum ResolutionStatus: String, Codable, Sendable { case resolved, notFound, failed }

public struct ResolvedReference: Codable, Sendable, Equatable {
    public var entryID: Int
    public var status: ResolutionStatus      // .failed = transient (network, rate limit); never cached
    public var title: String?
    public var authors: [String]
    public var year: Int?                    // may differ from the entry's year (working paper vs. published version); the card says so
    public var venue: String?
    public var doi: String?
    public var arxivID: String?
    public var landingURL: String?
    public var openAccessPDFURL: String?
    public var source: ResolutionSource?
    public var confidence: Double            // 1.0 when the identifier was printed in the entry itself
    public var resolvedAt: Date
    public init(entryID: Int, status: ResolutionStatus, title: String? = nil, authors: [String] = [], year: Int? = nil, venue: String? = nil,
                doi: String? = nil, arxivID: String? = nil, landingURL: String? = nil, openAccessPDFURL: String? = nil, source: ResolutionSource? = nil,
                confidence: Double, resolvedAt: Date) {
        self.entryID = entryID; self.status = status; self.title = title; self.authors = authors; self.year = year; self.venue = venue; self.doi = doi
        self.arxivID = arxivID; self.landingURL = landingURL; self.openAccessPDFURL = openAccessPDFURL; self.source = source; self.confidence = confidence
        self.resolvedAt = resolvedAt
    }
}

public enum ResolverError: RefereeError, Equatable {
    case noOpenAccessPDF
    case downloadFailed(String)
    case notAPDF
    case offline
    public var userMessage: String {
        switch self {
        case .noOpenAccessPDF: return "No open-access PDF was found for this reference."
        case .downloadFailed(let why): return "The PDF could not be downloaded (\(why))."
        case .notAPDF: return "The link did not return a PDF."
        case .offline: return "You appear to be offline."
        }
    }
    public var recoverySuggestion: String? { "Open the reference in your browser instead." }
    public var isRetryable: Bool { if case .downloadFailed = self { return true }; return self == .offline }
}

public protocol ReferenceResolving: Sendable {
    /// Never throws; inspect `status`. Reads and writes that document's lookup cache, sessions/<sha256>/references.json.
    func resolve(_ entry: BibEntry, documentSHA256: String) async -> ResolvedReference
    /// Drops every cached lookup made for that document, in memory and on disk. Called when a review is deleted.
    func forget(documentSHA256: String) async
    /// Returns a local file URL in the PDF cache. Throws ResolverError.
    func fetchPDF(for reference: ResolvedReference) async throws -> URL
    /// Manual fallback: a Google Scholar query URL built from the entry text.
    func searchURL(for entry: BibEntry) -> URL
}
