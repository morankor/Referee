import Foundation
import CryptoKit

/// Pure text helpers of the resolver: the folding of plan.md section 6.7, identifiers in the form of section 8.3,
/// the title words that the validation of section 8.7 counts, and the SHA-256 that names cache keys and cached PDFs.
enum ReferenceText {
    // ---- folding ----

    /// Section 6.7: compatibility decomposition, lower case, then only letters and digits. "Short-Term" and
    /// "short term" fold alike, and so do a precomposed and a decomposed "ü".
    static func fold(_ text: String) -> String {
        var folded = String.UnicodeScalarView()
        for scalar in text.decomposedStringWithCompatibilityMapping.lowercased().unicodeScalars where isLetterOrDigit(scalar) {
            folded.append(scalar)
        }
        return String(folded)
    }

    private static func isLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber: return true
        default: return false
        }
    }

    /// The folded words of a title. Markup and the common HTML entities are removed first; the title is split where
    /// a character is a space, punctuation or a symbol ("Short-Term" gives "short" and "term").
    static func titleWords(_ title: String) -> [String] {
        var words: [String] = []
        var current = ""
        for character in plainText(title) {
            if character.isWhitespace || character.isPunctuation || character.isSymbol {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.map(fold).filter { !$0.isEmpty }
    }

    // ---- display text ----

    /// Service titles sometimes carry markup (`<i>…</i>`, MathML) and entities (`&amp;`): both removed, spaces collapsed.
    static func plainText(_ text: String) -> String {
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "<", let close = tagEnd(in: text, from: index) {
                out.append(" ")
                index = text.index(after: close)
                continue
            }
            out.append(text[index])
            index = text.index(after: index)
        }
        for (entity, replacement) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&")] {
            out = out.replacingOccurrences(of: entity, with: replacement)
        }
        return collapsingWhitespace(out)
    }

    /// The index of the `>` that closes a tag opened at `start`: a letter, `/` or `!` after the `<`, at most 200
    /// characters, no `<` in between. nil when `<` is just a character.
    private static func tagEnd(in text: String, from start: String.Index) -> String.Index? {
        let next = text.index(after: start)
        guard next < text.endIndex, text[next].isLetter || text[next] == "/" || text[next] == "!" else { return nil }
        var index = next
        var length = 0
        while index < text.endIndex, length < 200 {
            if text[index] == ">" { return index }
            if text[index] == "<" { return nil }
            index = text.index(after: index)
            length += 1
        }
        return nil
    }

    /// Runs of white space and control characters become one space; ends trimmed.
    static func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { character in
            character.isWhitespace || character.unicodeScalars.contains { $0.properties.generalCategory == .control }
        }).joined(separator: " ")
    }

    /// Nothing but non-empty text, or nil.
    static func nonEmpty(_ text: String?) -> String? {
        guard let text else { return nil }
        let plain = plainText(text)
        return plain.isEmpty ? nil : plain
    }

    // ---- identifiers ----

    /// A DOI as section 8.3 stores it: bare and lower-cased. A `doi:` or doi.org prefix, trailing `.`, `,`, `;` and
    /// an unbalanced trailing `)` are removed. nil unless the result reads `10.<4 to 9 digits>/<suffix>` without
    /// spaces.
    static func doi(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var text = removingPrefix(from: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                                  ["https://doi.org/", "http://doi.org/", "https://dx.doi.org/", "http://dx.doi.org/", "doi.org/", "doi:"])
        while let last = text.last, ".,;".contains(last) || (last == ")" && text.occurrences(of: ")") > text.occurrences(of: "(")) {
            text.removeLast()
        }
        text = text.lowercased()
        guard text.hasPrefix("10.") else { return nil }
        let rest = text.dropFirst(3)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let registrant = rest[..<slash]
        let suffix = rest[rest.index(after: slash)...]
        guard (4...9).contains(registrant.count), registrant.allSatisfy({ $0.isASCII && $0.isNumber }), !suffix.isEmpty,
              !text.contains(where: { $0.isWhitespace || $0.unicodeScalars.contains { $0.properties.generalCategory == .control } })
        else { return nil }
        return text
    }

    /// An arXiv identifier: new style `1810.04805` (with an optional version) or old style `hep-th/9901001`. An
    /// `arXiv:` or arxiv.org prefix, a `.pdf` suffix and trailing punctuation are removed. nil for anything else.
    static func arxivID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var text = removingPrefix(from: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                                  ["https://arxiv.org/abs/", "http://arxiv.org/abs/", "https://arxiv.org/pdf/", "http://arxiv.org/pdf/",
                                   "arxiv.org/abs/", "arxiv.org/pdf/", "arxiv:"])
        while let last = text.last, ".,;)".contains(last) { text.removeLast() }
        if text.lowercased().hasSuffix(".pdf") { text.removeLast(4) }
        return isNewStyleArxivID(text) || isOldStyleArxivID(text) ? text : nil
    }

    /// `dddd.dddd` or `dddd.ddddd`, then optionally `v` and a version number.
    private static func isNewStyleArxivID(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 4, isDigits(parts[0]) else { return false }
        let (number, version) = splitVersion(parts[1])
        return (4...5).contains(number.count) && isDigits(number) && version
    }

    /// `archive[.XX]/ddddddd`, then optionally `v` and a version number: `hep-th/9901001`, `math.GT/0309136`.
    private static func isOldStyleArxivID(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let archive = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard let name = archive.first, !name.isEmpty, name.first?.isLetter == true,
              name.allSatisfy({ ($0.isASCII && $0.isLowercase) || $0 == "-" }) else { return false }
        if archive.count == 2 {
            guard archive[1].count == 2, archive[1].allSatisfy({ $0.isASCII && $0.isUppercase }) else { return false }
        } else if archive.count != 1 {
            return false
        }
        let (number, version) = splitVersion(parts[1])
        return number.count == 7 && isDigits(number) && version
    }

    /// "04805v2" -> ("04805", true); "04805" -> ("04805", true); "04805vx" -> (…, false).
    private static func splitVersion(_ text: Substring) -> (number: Substring, versionIsValid: Bool) {
        guard let v = text.firstIndex(of: "v") else { return (text, true) }
        let version = text[text.index(after: v)...]
        return (text[..<v], !version.isEmpty && version.count <= 3 && isDigits(version))
    }

    private static func isDigits(_ text: Substring) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func removingPrefix(from text: String, _ prefixes: [String]) -> String {
        let lower = text.lowercased()
        for prefix in prefixes where lower.hasPrefix(prefix) {
            return String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    // ---- hashing ----

    /// Lower-case hex of the SHA-256 of the UTF-8 bytes.
    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private extension String {
    func occurrences(of character: Character) -> Int {
        reduce(0) { $1 == character ? $0 + 1 : $0 }
    }
}
