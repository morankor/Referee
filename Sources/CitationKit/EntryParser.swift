import Foundation
import RefereeCore

/// An entry's parsed fields, and whether the list printed "et al." instead of every author (which the author keys of
/// §8.4 need to know and `ParsedReference` has no field for).
struct ParsedEntry: Equatable {
    var reference: ParsedReference
    var authorsTruncated: Bool
}

/// Parses the text of one reference entry (plan.md section 8.3). Heuristic and deliberately modest: it only has to
/// support matching citations to entries and looking entries up.
enum EntryParser {
    static let particles: Set<String> = ["van", "von", "de", "del", "della", "di", "da", "la", "le", "ten", "ter", "der", "den"]
    private static let generationalSuffixes: Set<String> = ["jr", "sr", "ii", "iii", "iv"]
    private static let authorSeparator = Pattern(#",|;|\s+and\s+|\s*&\s*"#)

    /// `linkURLs`: the URLs of link annotations that lie inside the entry's lines.
    static func parse(_ text: String, style: CitationStyle, linkURLs: [String] = []) -> ParsedEntry {
        let full = text as NSString
        let body: NSString
        if let label = Patterns.leadingLabel.first(in: full) {
            body = full.substring(from: label.range.upperBound) as NSString
        } else {
            body = full
        }
        let doi = firstDOI(in: full) ?? linkURLs.lazy.compactMap(doi(fromURL:)).first
        let arxiv = arxivID(in: full) ?? linkURLs.lazy.compactMap { arxivID(in: $0 as NSString) }.first
        let url = firstURL(in: full) ?? linkURLs.first

        let years = candidateYears(in: body)
        let year = style == .numeric ? years.last : years.first

        let authorText: String
        let afterAuthors: Int
        if style != .numeric, let first = years.first {
            authorText = trimEnd(body.substring(to: first.range.location), of: " (,.[")
            afterAuthors = first.range.upperBound
        } else {
            let end = authorEnd(in: body)
            authorText = body.substring(to: end)
            afterAuthors = end
        }
        let authors = surnames(in: authorText)
        let reference = ParsedReference(authorSurnames: authors.names, year: year?.value, yearSuffix: year?.suffix,
                                        title: title(in: body, from: afterAuthors), doi: doi, arxivID: arxiv, url: url)
        return ParsedEntry(reference: reference, authorsTruncated: authors.truncated)
    }

    // MARK: Identifiers

    static func firstDOI(in text: NSString) -> String? {
        guard let match = Patterns.doi.first(in: text) else { return nil }
        return cleanDOI(text.substring(with: match.range))
    }

    /// The DOI of a doi.org URL ("https://doi.org/10.3115/v1/D14-1179" -> "10.3115/v1/d14-1179").
    static func doi(fromURL url: String) -> String? {
        guard let marker = url.range(of: "doi.org/", options: .caseInsensitive) else { return nil }
        let tail = String(url[marker.upperBound...])
        let decoded = (tail.removingPercentEncoding ?? tail) as NSString
        guard let match = Patterns.doi.first(in: decoded), match.range.location == 0 else { return nil }
        return cleanDOI(decoded.substring(with: match.range))
    }

    private static func cleanDOI(_ raw: String) -> String? {
        var doi = raw
        while let last = doi.last, ".,;)".contains(last) { doi.removeLast() }
        return doi.isEmpty ? nil : doi.lowercased()
    }

    static func arxivID(in text: NSString) -> String? {
        if let match = Patterns.arxivColon.first(in: text), let id = match.group(1, in: text) { return id }
        guard let match = Patterns.arxivURL.first(in: text), var id = match.group(1, in: text) else { return nil }
        while let last = id.last, "./".contains(last) { id.removeLast() }
        if let version = id.range(of: "v[0-9]+$", options: .regularExpression) { id.removeSubrange(version) }
        return id.isEmpty ? nil : id
    }

    static func firstURL(in text: NSString) -> String? {
        guard let match = Patterns.url.first(in: text) else { return nil }
        var url = text.substring(with: match.range)
        while let last = url.last {
            if ".,;:".contains(last) { url.removeLast(); continue }
            if last == ")", url.filter({ $0 == "(" }).count < url.filter({ $0 == ")" }).count { url.removeLast(); continue }
            if last == "]", url.filter({ $0 == "[" }).count < url.filter({ $0 == "]" }).count { url.removeLast(); continue }
            break
        }
        return url
    }

    // MARK: Year

    struct YearHit {
        var range: NSRange
        var value: Int
        var suffix: String?
    }

    /// Years of the entry in order, after blanking out URLs, DOIs and arXiv ids ("arXiv:1810.04805" is not the year
    /// 1810), without year-like numbers that touch a page range ("pp. 1998–2004") or are followed by "(" (a volume).
    static func candidateYears(in body: NSString) -> [YearHit] {
        let masked = NSMutableString(string: body as String)
        for match in Patterns.identifier.all(in: body) {
            masked.replaceCharacters(in: match.range, with: String(repeating: " ", count: match.range.length))
        }
        var hits: [YearHit] = []
        for match in Patterns.year.all(in: masked) {
            let range = match.range
            if dashAndDigit(in: masked, before: range.location) || followsVolumeOrRange(in: masked, after: range.upperBound) { continue }
            guard let value = match.group(1, in: masked).flatMap({ Int($0) }) else { continue }
            hits.append(YearHit(range: range, value: value, suffix: match.group(2, in: masked)))
        }
        return hits
    }

    private static func isDash(_ unit: unichar) -> Bool {
        unit == 0x2D || unit == 0x2010 || unit == 0x2011 || unit == 0x2013 || unit == 0x2014 || unit == 0x2212
    }

    private static func isDigit(_ unit: unichar) -> Bool { unit >= 0x30 && unit <= 0x39 }

    /// "12–" just before `position`.
    private static func dashAndDigit(in text: NSString, before position: Int) -> Bool {
        var i = position - 1
        while i >= 0, BodyText.isSpace(text.character(at: i)) { i -= 1 }
        guard i >= 0, isDash(text.character(at: i)) else { return false }
        i -= 1
        while i >= 0, BodyText.isSpace(text.character(at: i)) { i -= 1 }
        return i >= 0 && isDigit(text.character(at: i))
    }

    /// "(" just after `position`, or "–12".
    private static func followsVolumeOrRange(in text: NSString, after position: Int) -> Bool {
        let n = text.length
        if position < n, text.character(at: position) == 0x28 { return true }
        var i = position
        while i < n, BodyText.isSpace(text.character(at: i)) { i += 1 }
        guard i < n, isDash(text.character(at: i)) else { return false }
        i += 1
        while i < n, BodyText.isSpace(text.character(at: i)) { i += 1 }
        return i < n && isDigit(text.character(at: i))
    }

    // MARK: Authors

    /// Where the authors end when there is no year to end them (numeric lists): at the first period that follows a
    /// lower-case letter or a closing quotation mark and is followed by white space, or earlier at an opening quotation
    /// mark (IEEE: `J. Smith, “Title,” …`) or an opening parenthesis (`J. Smith (2001). Title.`).
    static func authorEnd(in text: NSString) -> Int {
        let n = text.length
        var i = 0
        while i < n {
            let unit = text.character(at: i)
            if unit == 0x201C || unit == 0x22 || unit == 0x28 { return i }
            if unit == 0x2E, i > 0, i + 1 == n || BodyText.isSpace(text.character(at: i + 1)) {
                let before = text.character(at: i - 1)
                let lowercase = Unicode.Scalar(before).map { $0.properties.generalCategory == .lowercaseLetter } ?? false
                if lowercase || before == 0x201D || before == 0x22 || before == 0x2019 { return i }
            }
            i += 1
        }
        return n
    }

    /// The authors' surnames in printed order (§8.3): "et al." and what follows removed; split on , ; "and" "&"; each
    /// piece either dropped (initials only, "Jr."), or the word of a Springer-style "Dekel E" / "DekelE", or its last
    /// word with any particles before it ("van der Berg").
    ///
    /// One addition to the plan's rules: a piece of written-out given names that follows a comma right after a
    /// one-word surname is that author's given names ("Avery, Christopher, and Peter Zemsky"; "Banerjee, Abhijit V.").
    static func surnames(in authorText: String) -> (names: [String], truncated: Bool) {
        var text = authorText as NSString
        var truncated = false
        if let etAl = Patterns.etAl.first(in: text) {
            text = text.substring(to: etAl.range.location) as NSString
            truncated = true
        }
        var names: [String] = []
        var afterOneWordSurname = false
        for piece in splitAuthors(text) {
            let p = clean(piece.text)
            if p.isEmpty || Patterns.initialsOnly.matches(p) || generationalSuffixes.contains(p.lowercased()) {
                afterOneWordSurname = false
                continue
            }
            if afterOneWordSurname, piece.afterComma, Patterns.givenNames.matches(p) {
                afterOneWordSurname = false
                continue
            }
            if let word = springerSurname(p) {
                names.append(word)
                afterOneWordSurname = false
                continue
            }
            let surname = lastWordWithParticles(p)
            guard surname.contains(where: \.isLetter) else {
                afterOneWordSurname = false
                continue
            }
            names.append(surname)
            afterOneWordSurname = isOneWordSurname(p)
        }
        return (names, truncated)
    }

    private static func splitAuthors(_ text: NSString) -> [(text: String, afterComma: Bool)] {
        var pieces: [(text: String, afterComma: Bool)] = []
        var start = 0
        var afterComma = false
        for separator in authorSeparator.all(in: text) {
            pieces.append((text.substring(with: NSRange(location: start, length: separator.range.location - start)), afterComma))
            let mark = text.substring(with: separator.range)
            afterComma = mark == "," || mark == ";"
            start = separator.range.upperBound
        }
        pieces.append((text.substring(from: start), afterComma))
        return pieces
    }

    private static func clean(_ piece: String) -> String {
        piece.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Dekel E", "Lee J", "DekelE", "van der Berg JH" -> the word before the capitals.
    private static func springerSurname(_ piece: String) -> String? {
        let ns = piece as NSString
        guard let match = Patterns.springer.first(in: ns), let word = match.group(1, in: ns) else { return nil }
        if Patterns.capitalisedWordInside.matches(word) { return nil }
        return word.trimmingCharacters(in: .whitespaces)
    }

    private static func lastWordWithParticles(_ piece: String) -> String {
        let words = piece.split(whereSeparator: \.isWhitespace).map(String.init)
        guard var k = words.indices.last else { return "" }
        var result = words[k].trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
        while k > 0, particles.contains(words[k - 1].lowercased()) {
            k -= 1
            result = words[k] + " " + result
        }
        return result
    }

    /// A piece that is only a surname: one capitalised word, possibly after particles ("Avery", "van der Berg").
    private static func isOneWordSurname(_ piece: String) -> Bool {
        let words = piece.split(whereSeparator: \.isWhitespace)
        guard let last = words.last, last.first?.isUppercase == true else { return false }
        return words.dropLast().allSatisfy { particles.contains($0.lowercased()) }
    }

    // MARK: Title

    /// Author–year: the sentence after the year; numeric: the sentence after the authors. A title in quotation marks is
    /// the quoted text. Quotation marks and trailing punctuation are removed.
    static func title(in text: NSString, from position: Int) -> String? {
        let n = text.length
        var i = position
        func skipPunctuation() {
            while i < n, let scalar = Unicode.Scalar(text.character(at: i)),
                  ".,:;)]".unicodeScalars.contains(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar) {
                i += 1
            }
        }
        skipPunctuation()
        if i < n, text.character(at: i) == 0x28 {                       // "(2001)." after numeric authors
            var j = i + 1
            while j < n, j < i + 40, text.character(at: j) != 0x29 { j += 1 }
            if j < n, text.character(at: j) == 0x29 { i = j + 1 }
            skipPunctuation()
        }
        guard i < n else { return nil }
        let opening: Set<unichar> = [0x201C, 0x22, 0x2018, 0x27, 0xAB]
        let closing: Set<unichar> = [0x201D, 0x22, 0x2019, 0x27, 0xBB]
        var end = n
        if opening.contains(text.character(at: i)) {
            var j = i + 1
            while j < n, !closing.contains(text.character(at: j)) { j += 1 }
            end = j
        } else {
            var j = i
            while j < n {
                let unit = text.character(at: j)
                let atBoundary = j + 1 == n || BodyText.isSpace(text.character(at: j + 1))
                if atBoundary, unit == 0x3F || unit == 0x21 { end = j + 1; break }   // ? !
                if atBoundary, unit == 0x2E, !isInitial(in: text, before: j) { end = j; break }
                j += 1
            }
        }
        let quotes = CharacterSet(charactersIn: "“”\"‘’'«»")
        var title = text.substring(with: NSRange(location: i, length: end - i))
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(quotes))
        while let last = title.last, ",.;:".contains(last) {
            title.removeLast()
            title = title.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(quotes))
        }
        return title.isEmpty ? nil : title
    }

    /// A period after a single letter ("U.S.", "e.g.") does not end a sentence.
    private static func isInitial(in text: NSString, before period: Int) -> Bool {
        guard period >= 1, let letter = Unicode.Scalar(text.character(at: period - 1)), Folding.isLetter(letter) else { return false }
        guard period >= 2, let previous = Unicode.Scalar(text.character(at: period - 2)) else { return true }
        return !Folding.isLetter(previous)
    }

    static func trimEnd(_ text: String, of characters: String) -> String {
        var result = text
        while let last = result.last, characters.contains(last) { result.removeLast() }
        return result
    }
}
