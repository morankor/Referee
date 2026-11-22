import Foundation

/// JSON bodies of the two services. The first two are Appendix D.10 of plan.md as recorded on 2026-11-22; the
/// next two are the hand-written fixtures that D.10 asks for. They are Swift literals rather than files under
/// Fixtures/: the package declares no resources, and a JSON file in a test target's folder makes SwiftPM warn.
enum Bodies {
    /// Crossref `/works?query.bibliographic=Hochreiter+Schmidhuber+Long+short-term+memory+Neural+computation+1997&rows=2&select=…`
    static let crossrefHochreiter = #"""
    {"status":"ok","message-type":"work-list","message":{"total-results":5104456,"items":[{"DOI":"10.1162/neco.1997.9.8.1735","title":["Long Short-Term Memory"],"author":[{"given":"Sepp","family":"Hochreiter","sequence":"first"},{"given":"Jürgen","family":"Schmidhuber","sequence":"additional"}],"issued":{"date-parts":[[1997,11,1]]},"container-title":["Neural Computation"],"score":77.511246,"type":"journal-article"},{"DOI":"10.1162/neco.1997.9.1.1","title":["Flat Minima"],"author":[{"given":"Sepp","family":"Hochreiter","sequence":"first"},{"given":"Jürgen","family":"Schmidhuber","sequence":"additional"}],"issued":{"date-parts":[[1997,1,1]]},"container-title":["Neural Computation"],"score":53.478394,"type":"journal-article"}]}}
    """#

    /// OpenAlex `/works/doi:10.1162/neco.1997.9.8.1735?select=…`, without a key: closed access.
    static let openAlexHochreiter = #"""
    {"id":"https://openalex.org/W2064675550","doi":"https://doi.org/10.1162/neco.1997.9.8.1735","title":"Long Short-Term Memory","publication_year":1997,"open_access":{"is_oa":false,"oa_status":"closed","oa_url":null,"any_repository_has_fulltext":false},"best_oa_location":null,"authorships":[{"author_position":"first","author":{"display_name":"Sepp Hochreiter"}},{"author_position":"last","author":{"display_name":"Jürgen Schmidhuber"}}],"primary_location":{"landing_page_url":"https://doi.org/10.1162/neco.1997.9.8.1735","pdf_url":null,"is_oa":false,"source":{"display_name":"Neural Computation"}}}
    """#

    /// D.10's open-access case: the recorded record with `open_access` and `best_oa_location` written by hand.
    static let openAlexOpenAccess = #"""
    {"id":"https://openalex.org/W2064675550","doi":"https://doi.org/10.1162/neco.1997.9.8.1735","title":"Long Short-Term Memory","publication_year":1997,"open_access":{"is_oa":true,"oa_status":"green","oa_url":"https://example.org/paper.pdf"},"best_oa_location":{"is_oa":true,"landing_page_url":"https://example.org/abs","pdf_url":"https://example.org/paper.pdf","license":"cc-by","version":"submittedVersion"},"authorships":[{"author_position":"first","author":{"display_name":"Sepp Hochreiter"}},{"author_position":"last","author":{"display_name":"Jürgen Schmidhuber"}}],"primary_location":{"landing_page_url":"https://doi.org/10.1162/neco.1997.9.8.1735","pdf_url":null,"is_oa":false,"source":{"display_name":"Neural Computation"}}}
    """#

    /// D.10's year case: the recorded Crossref item, issued in 2001, for an entry dated 1997.
    static let crossrefHochreiter2001 = #"""
    {"status":"ok","message-type":"work-list","message":{"total-results":1,"items":[{"DOI":"10.1162/neco.1997.9.8.1735","title":["Long Short-Term Memory"],"author":[{"given":"Sepp","family":"Hochreiter","sequence":"first"},{"given":"Jürgen","family":"Schmidhuber","sequence":"additional"}],"issued":{"date-parts":[[2001,1,1]]},"container-title":["Neural Computation"],"score":77.511246,"type":"journal-article"}]}}
    """#

    /// A Crossref work list with no items.
    static let crossrefEmpty = #"{"status":"ok","message-type":"work-list","message":{"total-results":0,"items":[]}}"#

    // ---- variants built in the tests ----

    struct CrossrefItem {
        var doi: String
        var title: String
        var authors: [(given: String, family: String)]
        var year: Int?
        var venue = "Neural Computation"
    }

    /// A Crossref work list holding these items, in this order.
    static func crossref(_ items: [CrossrefItem]) -> String {
        let list: [[String: Any]] = items.map { item in
            var fields: [String: Any] = [
                "DOI": item.doi, "title": [item.title], "container-title": [item.venue], "type": "journal-article", "score": 50.0,
                "author": item.authors.enumerated().map { index, author in
                    ["given": author.given, "family": author.family, "sequence": index == 0 ? "first" : "additional"]
                },
            ]
            if let year = item.year { fields["issued"] = ["date-parts": [[year, 1, 1]]] }
            return fields
        }
        return serialized(["status": "ok", "message-type": "work-list", "message": ["total-results": items.count, "items": list]])
    }

    /// The recorded OpenAlex record with some top-level fields replaced (`NSNull()` writes a JSON null).
    static func openAlex(replacing fields: [String: Any]) -> String {
        guard let data = openAlexHochreiter.data(using: .utf8),
              var record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return openAlexHochreiter }
        record.merge(fields) { _, new in new }
        return serialized(record)
    }

    private static func serialized(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
