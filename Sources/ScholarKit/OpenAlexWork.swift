import Foundation

/// An OpenAlex work as `GET /works/doi:<doi>?select=id,doi,title,publication_year,authorships,primary_location,
/// open_access,best_oa_location` returns it: the metadata for the card and the open-access PDF (plan.md section 8.7).
struct OpenAlexWork: Sendable, Equatable {
    var doi: String?
    var title: String?
    var authors: [String]
    var year: Int?
    var venue: String?
    /// `best_oa_location.pdf_url`, else `open_access.oa_url` when its path ends in `.pdf`; http or https only.
    var pdfURL: String?
}

extension OpenAlexWork {
    /// nil when the body is not a JSON object.
    static func work(from body: Data) -> OpenAlexWork? {
        guard let root = JSONFields.object(body) else { return nil }
        let authors: [String] = (root.array("authorships") ?? []).compactMap { value in
            guard let authorship = value as? JSONObject else { return nil }
            return ReferenceText.nonEmpty(authorship.object("author")?.string("display_name"))
        }
        return OpenAlexWork(doi: ReferenceText.doi(root.string("doi")),
                            title: ReferenceText.nonEmpty(root.string("title")),
                            authors: authors,
                            year: root.int("publication_year"),
                            venue: ReferenceText.nonEmpty(root.object("primary_location")?.object("source")?.string("display_name")),
                            pdfURL: openAccessPDF(in: root))
    }

    private static func openAccessPDF(in root: JSONObject) -> String? {
        if let best = webURL(root.object("best_oa_location")?.string("pdf_url")) {
            return best
        }
        if let fallback = webURL(root.object("open_access")?.string("oa_url")),
           let path = URLComponents(string: fallback)?.path, path.lowercased().hasSuffix(".pdf") {
            return fallback
        }
        return nil
    }

    /// The address when it is an http or https URL with a host, else nil.
    private static func webURL(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty else { return nil }
        return text
    }
}
