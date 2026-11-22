import Foundation

/// One item of a Crossref bibliographic search (`select=DOI,title,author,issued,container-title,score,type`).
/// Crossref is used to identify a work, never for open-access data (plan.md section 8.7).
struct CrossrefCandidate: Sendable, Equatable {
    struct Author: Sendable, Equatable {
        var given: String?
        var family: String?
        var name: String?                // organisations have a name and no family name
        var isFirst: Bool                // "sequence": "first"

        /// What the validation compares with the entry's first surname.
        var surname: String? { family ?? name }

        /// "Sepp Hochreiter", for the card when OpenAlex has no record.
        var displayName: String? {
            if let family {
                return [given, family].compactMap { $0 }.joined(separator: " ")
            }
            return name
        }
    }

    var doi: String
    var title: String?
    var authors: [Author]
    var year: Int?
    var venue: String?

    /// The author marked first, else the first one listed.
    var firstAuthor: Author? { authors.first(where: \.isFirst) ?? authors.first }
}

extension CrossrefCandidate {
    /// The items of a `/works` answer in Crossref's order; items without a usable DOI are skipped. nil when the body
    /// is not a Crossref work list.
    static func candidates(from body: Data) -> [CrossrefCandidate]? {
        guard let root = JSONFields.object(body), let message = root.object("message"), let items = message.array("items") else { return nil }
        return items.compactMap { item in
            guard let fields = item as? JSONObject else { return nil }
            return CrossrefCandidate(fields: fields)
        }
    }

    private init?(fields: JSONObject) {
        guard let doi = ReferenceText.doi(fields.string("DOI")) else { return nil }
        let authors: [Author] = (fields.array("author") ?? []).compactMap { value in
            guard let author = value as? JSONObject else { return nil }
            let parsed = Author(given: ReferenceText.nonEmpty(author.string("given")), family: ReferenceText.nonEmpty(author.string("family")),
                                name: ReferenceText.nonEmpty(author.string("name")), isFirst: author.string("sequence") == "first")
            return parsed.surname == nil ? nil : parsed
        }
        let dateParts = fields.object("issued")?.array("date-parts")?.first as? [Any]
        self.init(doi: doi,
                  title: ReferenceText.nonEmpty(fields.array("title")?.first as? String ?? fields.string("title")),
                  authors: authors,
                  year: JSONFields.int(dateParts?.first),
                  venue: ReferenceText.nonEmpty(fields.array("container-title")?.first as? String ?? fields.string("container-title")))
    }
}
