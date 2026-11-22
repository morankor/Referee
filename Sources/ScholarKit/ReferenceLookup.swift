import Foundation
import RefereeCore

/// Steps 1 to 4 of plan.md section 8.7, after the cache: a printed arXiv id (no request), a printed DOI (OpenAlex),
/// else a Crossref bibliographic search whose validated DOI then goes to OpenAlex, else `notFound`. Holds no state
/// and runs outside the resolver's actor.
///
/// `source` says how the work was identified: `.entryText` when the identifier is in the entry (confidence 1),
/// `.crossref` when Crossref's search found it (confidence 0.5 + 0.5 × the title share). A lookup that could not be
/// completed is `.failed`, keeps the identifiers already known (DOI, landing page) and is never cached.
struct ReferenceLookup: Sendable {
    struct Outcome: Sendable {
        var reference: ResolvedReference
        var cacheable: Bool              // resolved or notFound, and learnt from a request
        var via: String                  // for the log: "arxiv", "doi", "crossref", "none"
    }

    let client: ServiceClient
    let clock: any ResolverClock

    func run(_ entry: BibEntry, contact: String?) async -> Outcome {
        if let arxivID = ReferenceText.arxivID(entry.parsed.arxivID) {
            let reference = ResolvedReference(entryID: entry.id, status: .resolved, title: ReferenceText.nonEmpty(entry.parsed.title),
                                              authors: entry.parsed.authorSurnames, year: entry.parsed.year,
                                              doi: ReferenceText.doi(entry.parsed.doi), arxivID: arxivID,
                                              landingURL: "https://arxiv.org/abs/\(arxivID)", openAccessPDFURL: "https://arxiv.org/pdf/\(arxivID)",
                                              source: .entryText, confidence: 1.0, resolvedAt: stamp())
            return Outcome(reference: reference, cacheable: false, via: "arxiv")
        }
        if let doi = ReferenceText.doi(entry.parsed.doi) {
            return await lookUpPrintedDOI(doi, entry: entry)
        }
        return await searchCrossref(entry, contact: contact)
    }

    // ---- step 2: a DOI printed in the entry ----

    private func lookUpPrintedDOI(_ doi: String, entry: BibEntry) async -> Outcome {
        switch await openAlex(doi) {
        case .found(let work):
            let reference = ResolvedReference(entryID: entry.id, status: .resolved,
                                              title: work.title ?? ReferenceText.nonEmpty(entry.parsed.title),
                                              authors: work.authors.isEmpty ? entry.parsed.authorSurnames : work.authors,
                                              year: work.year ?? entry.parsed.year, venue: work.venue, doi: doi,
                                              landingURL: Self.landingURL(doi), openAccessPDFURL: work.pdfURL,
                                              source: .entryText, confidence: 1.0, resolvedAt: stamp())
            return Outcome(reference: reference, cacheable: true, via: "doi")
        case .missing:
            // OpenAlex does not know the DOI: keep it, with what the entry itself says.
            let reference = ResolvedReference(entryID: entry.id, status: .resolved, title: ReferenceText.nonEmpty(entry.parsed.title),
                                              authors: entry.parsed.authorSurnames, year: entry.parsed.year, doi: doi,
                                              landingURL: Self.landingURL(doi), source: .entryText, confidence: 1.0, resolvedAt: stamp())
            return Outcome(reference: reference, cacheable: true, via: "doi")
        case .failed:
            return Outcome(reference: failed(entry, doi: doi), cacheable: false, via: "doi")
        }
    }

    // ---- step 3: Crossref, then OpenAlex for the open-access data ----

    private func searchCrossref(_ entry: BibEntry, contact: String?) async -> Outcome {
        // Without a first surname no candidate can pass validation: the reference text is not sent at all.
        guard let surname = entry.parsed.authorSurnames.first, !ReferenceText.fold(surname).isEmpty,
              let request = ServiceRequests.crossref(rawText: entry.rawText, contact: contact) else {
            return Outcome(reference: notFound(entry), cacheable: false, via: "none")
        }
        let candidates: [CrossrefCandidate]
        switch await client.get(request, host: .crossref, policy: .crossref(polite: contact != nil)) {
        case .ok(let body):
            guard let parsed = CrossrefCandidate.candidates(from: body) else {
                return Outcome(reference: failed(entry, doi: nil), cacheable: false, via: "crossref")
            }
            candidates = parsed
        case .notFound, .failed:
            return Outcome(reference: failed(entry, doi: nil), cacheable: false, via: "crossref")
        }
        guard let (candidate, verdict) = CandidateValidator.choose(from: candidates, for: entry) else {
            return Outcome(reference: notFound(entry), cacheable: true, via: "crossref")       // step 4
        }
        let work: OpenAlexWork?
        switch await openAlex(candidate.doi) {
        case .found(let found): work = found
        case .missing: work = nil
        case .failed: return Outcome(reference: failed(entry, doi: candidate.doi), cacheable: false, via: "crossref")
        }
        let crossrefAuthors = candidate.authors.compactMap(\.displayName)
        let reference = ResolvedReference(entryID: entry.id, status: .resolved, title: work?.title ?? candidate.title,
                                          authors: (work?.authors).flatMap { $0.isEmpty ? nil : $0 } ?? crossrefAuthors,
                                          year: work?.year ?? candidate.year, venue: work?.venue ?? candidate.venue, doi: candidate.doi,
                                          landingURL: Self.landingURL(candidate.doi), openAccessPDFURL: work?.pdfURL,
                                          source: .crossref, confidence: verdict.confidence, resolvedAt: stamp())
        return Outcome(reference: reference, cacheable: true, via: "crossref")
    }

    // ---- OpenAlex ----

    private enum OpenAlexAnswer {
        case found(OpenAlexWork)
        case missing                     // 404
        case failed
    }

    private func openAlex(_ doi: String) async -> OpenAlexAnswer {
        guard let request = ServiceRequests.openAlex(doi: doi) else { return .missing }
        switch await client.get(request, host: .openAlex, policy: .openAlex) {
        case .ok(let body):
            guard let work = OpenAlexWork.work(from: body) else { return .failed }
            return .found(work)
        case .notFound:
            return .missing
        case .failed:
            return .failed
        }
    }

    // ---- results ----

    private func notFound(_ entry: BibEntry) -> ResolvedReference {
        ResolvedReference(entryID: entry.id, status: .notFound, confidence: 0, resolvedAt: stamp())
    }

    private func failed(_ entry: BibEntry, doi: String?) -> ResolvedReference {
        ResolvedReference(entryID: entry.id, status: .failed, doi: doi, landingURL: doi.map(Self.landingURL), confidence: 0, resolvedAt: stamp())
    }

    static func landingURL(_ doi: String) -> String {
        "https://doi.org/" + (doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi)
    }

    /// Now, in whole seconds: what the cache file stores (ISO 8601) is then exactly what was returned.
    private func stamp() -> Date {
        Date(timeIntervalSince1970: clock.now().timeIntervalSince1970.rounded(.down))
    }
}
