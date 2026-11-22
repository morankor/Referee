import Foundation
import RefereeCore
import AppCore

// The words and addresses of the citation card and the References list (plan.md sections 7.6, 8.6 and 9.9). Pure.
//
// Decisions (also in docs/contract-notes/wp9-reader.md):
// - A mention's text runs from where the author key begins to the end of the year (section 8.4: "Acemoglu et al.
//   [2011", "Avery and Zem- sky, 1998"). The card's header shows it readable: a word broken at a line end is joined
//   and an opened bracket is closed ("Acemoglu et al. [2011]", "Avery and Zemsky, 1998"). Only the display changes.
// - A card opened from the References list is headed by the entry's authors and year ("Acemoglu et al. (2011)"), or
//   "Reference 3" when the entry has none.
// - "Open in Browser" goes to the resolved landing page, else https://doi.org/<doi>, else the entry's own URL; only
//   http and https addresses count. The DOI to copy is the record's, else the entry's.

enum ReaderCitationText {
    /// The mention's text as the card's header shows it.
    static func displayMention(_ text: String) -> String {
        var result = joinedBrokenWords(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var open: [Character] = []
        for character in result {
            switch character {
            case "(", "[": open.append(character)
            case ")": if open.last == "(" { open.removeLast() }
            case "]": if open.last == "[" { open.removeLast() }
            default: break
            }
        }
        for character in open.reversed() { result.append(character == "(" ? ")" : "]") }
        return result
    }

    /// "Zem- sky" -> "Zemsky": a hyphen after a letter, one space, then a lower-case letter is a word broken at a line end.
    static func joinedBrokenWords(_ text: String) -> String {
        var characters = Array(text)
        var index = 1
        while index + 2 < characters.count {
            if characters[index] == "-", characters[index + 1] == " ", characters[index - 1].isLetter, characters[index + 2].isLowercase {
                characters.removeSubrange(index...(index + 1))
            } else {
                index += 1
            }
        }
        return String(characters)
    }

    /// The header of a card opened from the References list: "Banerjee (1992)", "Avery and Zemsky (1998)",
    /// "Acemoglu et al. (2011)", "[13]" for a numbered list without surnames, else "Reference <position>".
    static func entryHeading(_ entry: BibEntry) -> String {
        let names = entry.parsed.authorSurnames
        let year = entry.parsed.year.map { " (\($0)\(entry.parsed.yearSuffix ?? ""))" } ?? ""
        switch names.count {
        case 0: return entry.label.map { "[\($0)]" } ?? "Reference \(entry.id + 1)"
        case 1: return names[0] + year
        case 2: return names[0] + " and " + names[1] + year
        default: return names[0] + " et al." + year
        }
    }

    /// "year differs: the list says 2019, this record 2022" when both years are known and differ (section 8.6).
    static func yearNote(listYear: Int?, recordYear: Int?) -> String? {
        guard let listYear, let recordYear, listYear != recordYear else { return nil }
        return "year differs: the list says \(listYear), this record \(recordYear)"
    }

    /// Year and venue of a resolved record, "2011 · Econometrica"; nil when neither is known.
    static func recordDetails(_ reference: ResolvedReference) -> String? {
        let parts = [reference.year.map(String.init), reference.venue?.trimmingCharacters(in: .whitespacesAndNewlines)]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Acemoglu, Dahleh, Lobel, Ozdaglar"; nil when the record names nobody.
    static func authorsLine(_ authors: [String]) -> String? {
        let names = authors.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    /// Where "Open in Browser" goes: the landing page, else the DOI's address, else the entry's URL.
    static func browserURL(reference: ResolvedReference?, entry: BibEntry) -> URL? {
        if let landing = reference?.landingURL.flatMap(webURL) { return landing }
        if let doi = doi(reference: reference, entry: entry), let url = webURL("https://doi.org/" + doi) { return url }
        return entry.parsed.url.flatMap(webURL)
    }

    /// The DOI "Copy DOI" puts on the pasteboard: the record's, else the entry's.
    static func doi(reference: ResolvedReference?, entry: BibEntry) -> String? {
        for candidate in [reference?.doi, entry.parsed.doi] {
            if let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return value }
        }
        return nil
    }

    /// The title the reference viewer's window gets for a downloaded paper.
    static func viewerTitle(reference: ResolvedReference?, entry: BibEntry) -> String {
        for candidate in [reference?.title, entry.parsed.title] {
            if let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return value }
        }
        return entryHeading(entry)
    }

    /// A stand-in entry for a mention that has no candidate entries, so that "Search Google Scholar" can still search
    /// for its text (`model.searchURL(for:)` takes an entry).
    static func searchEntry(forMention text: String) -> BibEntry {
        BibEntry(id: -1, rawText: displayMention(text), parsed: ParsedReference())
    }

    /// The line a failed lookup shows (sections 8.6, 9.9).
    static func failureLine(_ reference: ResolvedReference) -> String {
        let reason = reference.failureReason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return reason.isEmpty ? "Lookup failed." : "Lookup failed: " + reason
    }

    private static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil else { return nil }
        return url
    }
}

/// What the citation card shows for the model's `citationLookup` (section 8.6): its header, the candidate entries and,
/// once they are in, their lookups. Pure.
struct ReaderCardContent: Equatable {
    var target: CitationLookup.Target
    var heading: String
    var mentionText: String?             // the mention's own text, for a search when no entry matches
    var entries: [BibEntry]
    var references: [Int: ResolvedReference]   // entry id → its result; empty while resolving
    var isResolving: Bool

    /// nil while no card is open (`.idle`), or when the mention or entry is not in the index.
    static func make(_ lookup: CitationLookup, citations: CitationIndex?) -> ReaderCardContent? {
        switch lookup {
        case .idle:
            return nil
        case .resolving(let target):
            guard var content = base(for: target, citations: citations) else { return nil }
            content.isResolving = true
            return content
        case .resolved(let target, let entries, let references):
            guard var content = base(for: target, citations: citations) else { return nil }
            content.entries = entries
            content.references = Dictionary(references.map { ($0.entryID, $0) }, uniquingKeysWith: { _, latest in latest })
            return content
        }
    }

    private static func base(for target: CitationLookup.Target, citations: CitationIndex?) -> ReaderCardContent? {
        guard let citations else { return nil }
        switch target {
        case .mention(let id):
            guard let mention = citations.mentions.first(where: { $0.id == id }) else { return nil }
            let entries = mention.entryIDs.compactMap { entryID in citations.entries.first { $0.id == entryID } }
            return ReaderCardContent(target: target, heading: ReaderCitationText.displayMention(mention.text), mentionText: mention.text,
                                     entries: entries, references: [:], isResolving: false)
        case .entry(let id):
            guard let entry = citations.entries.first(where: { $0.id == id }) else { return nil }
            return ReaderCardContent(target: target, heading: ReaderCitationText.entryHeading(entry), mentionText: nil,
                                     entries: [entry], references: [:], isResolving: false)
        }
    }
}

/// The icon of an entry in the References list (section 7.6): none until the entry was looked up.
struct ReaderReferenceStatus: Equatable {
    enum Tint: Equatable { case green, orange, secondary }
    var systemImage: String
    var tint: Tint
    var help: String

    static func of(_ reference: ResolvedReference?) -> ReaderReferenceStatus? {
        guard let reference else { return nil }
        switch reference.status {
        case .resolved:
            return reference.openAccessPDFURL == nil
                ? ReaderReferenceStatus(systemImage: "checkmark.circle", tint: .green, help: "Found")
                : ReaderReferenceStatus(systemImage: "checkmark.circle.fill", tint: .green, help: "Found, with an open-access PDF")
        case .notFound:
            return ReaderReferenceStatus(systemImage: "questionmark.circle", tint: .secondary, help: "No match found")
        case .failed:
            return ReaderReferenceStatus(systemImage: "exclamationmark.triangle.fill", tint: .orange, help: ReaderCitationText.failureLine(reference))
        }
    }
}
