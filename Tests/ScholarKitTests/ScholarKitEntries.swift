import Foundation
import RefereeCore
import TestSupport

/// Reference-list entries of the numeric fixture `num_links.pdf`, as `CitationKit` builds them: the entry's lines of
/// `Fixtures/raw/num_links.raw.json` joined by a space, with the parsed fields of plan.md section 8.3.
enum Entries {
    struct MissingFixtureLine: Error, CustomStringConvertible {
        let prefix: String
        var description: String { "no line of Fixtures/raw/num_links.raw.json starts with \"\(prefix)\"" }
    }

    /// "[4] Sepp Hochreiter and Jürgen Schmidhuber. Long short-term memory. Neural Computation, 9(8):1735–1780, 1997."
    /// No identifier is printed, so it is searched on Crossref (Appendix D.10 holds the answers).
    static func hochreiter(id: Int = 3) throws -> BibEntry {
        BibEntry(id: id, label: "4", rawText: try fixtureText(startingWith: "[4] Sepp Hochreiter", lines: 2),
                 parsed: ParsedReference(authorSurnames: ["Hochreiter", "Schmidhuber"], year: 1997, title: "Long short-term memory"))
    }

    /// Entry [3]: BERT, with the arXiv id 1810.04805 printed.
    static func devlin(id: Int = 2) throws -> BibEntry {
        BibEntry(id: id, label: "3", rawText: try fixtureText(startingWith: "[3] Jacob Devlin", lines: 3),
                 parsed: ParsedReference(authorSurnames: ["Devlin", "Chang", "Lee", "Toutanova"], year: 2019,
                                         title: "BERT: Pre-training of deep bidirectional transformers for language understanding",
                                         arxivID: "1810.04805"))
    }

    /// Entry [2]: the encoder–decoder paper, with the DOI 10.3115/v1/D14-1179 printed (broken across two lines).
    static func cho(id: Int = 1) throws -> BibEntry {
        BibEntry(id: id, label: "2", rawText: try fixtureText(startingWith: "[2] Kyunghyun Cho", lines: 5),
                 parsed: ParsedReference(authorSurnames: ["Cho", "van Merrienboer", "Gulcehre", "Bahdanau", "Bougares", "Schwenk", "Bengio"],
                                         year: 2014,
                                         title: "Learning phrase representations using RNN encoder-decoder for statistical machine translation",
                                         doi: "10.3115/v1/d14-1179", url: "https://doi.org/10.3115/v1/D14-1179"))
    }

    /// An entry whose parsing found no surname: nothing can validate a candidate, so nothing is sent.
    static let withoutSurname = BibEntry(id: 9, rawText: "Anonymous working paper on herding, 2020.", parsed: ParsedReference(year: 2020))

    /// `count` consecutive lines of the fixture, the first starting with `prefix`, joined as section 8.1 joins them:
    /// by a space, except after a hyphen that follows a letter when the next line starts in lower case (the hyphen
    /// goes), and after a DOI or URL that ends in a slash.
    private static func fixtureText(startingWith prefix: String, lines count: Int) throws -> String {
        let lines = try Fixtures.rawDocument("num_links").pages.flatMap(\.lines).map(\.text)
        guard let first = lines.firstIndex(where: { $0.hasPrefix(prefix) }), first + count <= lines.count else {
            throw MissingFixtureLine(prefix: prefix)
        }
        var text = ""
        for line in lines[first..<(first + count)] {
            if text.isEmpty {
                text = line
            } else if text.hasSuffix("-"), text.dropLast().last?.isLetter == true, line.first?.isLowercase == true {
                text = String(text.dropLast()) + line
            } else if text.hasSuffix("/") {
                text += line
            } else {
                text += " " + line
            }
        }
        return text
    }
}
