import Foundation
import RefereeCore

/// Resolves a cited reference (plan.md section 8.7): the document's lookup cache, then a printed arXiv id, a
/// printed DOI looked up on OpenAlex, or a Crossref bibliographic search validated against the entry and followed
/// by OpenAlex; otherwise `notFound`, for which the card offers a Google Scholar search. Requests go to
/// api.crossref.org and api.openalex.org only, each host through its own token bucket; open-access PDFs come from
/// the host the reference names, only when asked for, into a size-limited cache.
public actor ReferenceResolver: ReferenceResolving {
    private let settings: @Sendable () -> ReferenceSettings
    private let clock: any ResolverClock
    private let lookup: ReferenceLookup
    private let lookupStore: LookupCacheStore
    private let pdfStore: PDFStore
    private let downloader: PDFDownloader

    /// Fresh lookups per document, read from its file on first use.
    private var lookups: [String: [String: ResolvedReference]] = [:]
    /// Bumped by `forget`: a lookup that was under way when its document was forgotten is not written back.
    private var generations: [String: Int] = [:]

    /// dataDirectory = AppPaths.dataDirectory: a document's lookups are cached in <dataDirectory>/sessions/<sha256>/references.json.
    /// cacheDirectory = AppPaths.cacheDirectory: downloaded PDFs go to <cacheDirectory>/papers/.
    public init(settings: @escaping @Sendable () -> ReferenceSettings, urlSession: URLSession, dataDirectory: URL, cacheDirectory: URL) {
        self.init(settings: settings, urlSession: urlSession, dataDirectory: dataDirectory, cacheDirectory: cacheDirectory,
                  clock: SystemResolverClock())
    }

    /// The same, with the clock and the PDF size limit chosen by the caller (tests).
    init(settings: @escaping @Sendable () -> ReferenceSettings, urlSession: URLSession, dataDirectory: URL, cacheDirectory: URL,
         clock: any ResolverClock, maxPDFBytes: Int = PDFDownloader.defaultMaxBytes) {
        self.settings = settings
        self.clock = clock
        let limiter = HostLimiter(clock: clock)
        lookup = ReferenceLookup(client: ServiceClient(session: urlSession, limiter: limiter, clock: clock), clock: clock)
        lookupStore = LookupCacheStore(sessionsDirectory: dataDirectory.appendingPathComponent("sessions", isDirectory: true))
        pdfStore = PDFStore(directory: cacheDirectory.appendingPathComponent("papers", isDirectory: true))
        downloader = PDFDownloader(session: urlSession, maxBytes: maxPDFBytes)
    }

    // ---- ReferenceResolving ----

    public func resolve(_ entry: BibEntry, documentSHA256: String) async -> ResolvedReference {
        let key = LookupCacheStore.key(for: entry)
        let document = LookupCacheStore.isUsableDocumentID(documentSHA256) ? documentSHA256 : nil
        if let document, var hit = cachedLookup(key, in: document) {
            hit.entryID = entry.id
            Log.event("scholar.resolve", ["status": .id(hit.status.rawValue), "via": .id("cache")])
            return hit
        }
        let generation = document.map { generations[$0, default: 0] }
        let contact = ServiceRequests.contactAddress(settings().crossrefMailto)
        let outcome = await lookup.run(entry, contact: contact)
        if outcome.cacheable, let document, generations[document, default: 0] == generation {
            remember(outcome.reference, key: key, in: document)
        }
        Log.event("scholar.resolve", ["status": .id(outcome.reference.status.rawValue), "via": .id(outcome.via)])
        return outcome.reference
    }

    public func forget(documentSHA256: String) async {
        generations[documentSHA256, default: 0] += 1
        lookups[documentSHA256] = nil
        guard LookupCacheStore.isUsableDocumentID(documentSHA256) else { return }
        lookupStore.remove(documentSHA256)
        Log.event("scholar.forget")
    }

    public func fetchPDF(for reference: ResolvedReference) async throws -> URL {
        guard let address = reference.openAccessPDFURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: address), let host = url.host, !host.isEmpty else { throw ResolverError.noOpenAccessPDF }
        guard url.scheme?.lowercased() == "https" else { throw ResolverError.noOpenAccessPDF }   // http: Open in Browser instead
        let file = pdfStore.file(for: url)
        if pdfStore.contains(file) {
            pdfStore.touch(file, at: clock.now())
            Log.event("scholar.pdf", ["cached": .bool(true)])
            return file
        }
        let partial: URL
        do {
            partial = try pdfStore.newPartialFile()
        } catch {
            throw PDFDownloader.resolverError(for: error)
        }
        let size: Int
        do {
            size = try await downloader.download(url, to: partial)
            try pdfStore.install(partial, as: file, at: clock.now())
        } catch {
            pdfStore.discard(partial)
            let failure = PDFDownloader.resolverError(for: error)
            Log.event("scholar.pdf", ["cached": .bool(false), "accepted": .bool(false)])
            throw failure
        }
        let limit = Int64(max(0, settings().pdfCacheLimitMB)) * PDFStore.bytesPerMB
        pdfStore.evict(limitBytes: limit, keeping: file)
        Log.event("scholar.pdf", ["cached": .bool(false), "accepted": .bool(true), "bytes": .int(size)])
        return file
    }

    /// `https://scholar.google.com/scholar?q=<the title, else the first 200 characters of the entry text>`, every
    /// character but the unreserved ones of RFC 3986 percent-encoded.
    public nonisolated func searchURL(for entry: BibEntry) -> URL {
        let title = ReferenceText.collapsingWhitespace(entry.parsed.title ?? "")
        let query = title.isEmpty ? String(ReferenceText.collapsingWhitespace(entry.rawText).prefix(200)) : title
        let base = URL(string: "https://scholar.google.com/scholar")!     // a literal: cannot fail
        return URL(string: "https://scholar.google.com/scholar?q=" + ServiceRequests.queryEncoded(query)) ?? base
    }

    // ---- the per-document cache ----

    private func cachedLookup(_ key: String, in document: String) -> ResolvedReference? {
        let now = clock.now()
        if lookups[document] == nil { lookups[document] = lookupStore.load(document, now: now) }
        guard let hit = lookups[document]?[key] else { return nil }
        guard LookupCacheStore.isFresh(hit, now: now) else {
            lookups[document]?[key] = nil
            return nil
        }
        return hit
    }

    private func remember(_ reference: ResolvedReference, key: String, in document: String) {
        let now = clock.now()
        var entries = (lookups[document] ?? lookupStore.load(document, now: now)).filter { LookupCacheStore.isFresh($0.value, now: now) }
        entries[key] = reference
        lookups[document] = entries
        do {
            try lookupStore.save(entries, for: document)
        } catch {
            Log.event("scholar.cache.unwritable")                    // kept in memory for this run
        }
    }
}
