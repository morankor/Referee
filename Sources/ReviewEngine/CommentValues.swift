import Foundation
import RefereeCore

/// The value clean-up of plan.md section 6.5, rule 5, applied when a block closes (and to the JSON fallback).
enum CommentValues {
    static let maxTitleLength = 120

    /// The first of "major", "minor", "question", "strength" that the lower-cased value contains, in that order; then the
    /// synonyms "critical" (major), "query" (question), "praise" and "positive" (strength). Nil when none occurs; the
    /// caller decides the default (minor for a review comment).
    static func kind(from value: String) -> CommentKind? {
        let lowered = value.lowercased()
        let keywords: [(String, CommentKind)] = [
            ("major", .major), ("minor", .minor), ("question", .question), ("strength", .strength),
            ("critical", .major), ("query", .question), ("praise", .strength), ("positive", .strength),
        ]
        return keywords.first { lowered.contains($0.0) }?.1
    }

    /// The first run of ASCII digits in the value, as an integer ("p. 12" -> 12, "3-4" -> 3). Nil when there is none or
    /// it is absurdly long.
    static func page(from value: String) -> Int? {
        var digits = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            if scalar.value >= 0x30 && scalar.value <= 0x39 {
                digits.append(scalar)
                if digits.count > 9 { return nil }
            } else if !digits.isEmpty {
                break
            }
        }
        return digits.isEmpty ? nil : Int(String(digits))
    }

    /// Characters stripped from both ends of a quote: straight and curly quotation marks, guillemets, backticks, and the
    /// emphasis markers a model drifting into Markdown puts around a quoted passage.
    private static let quoteWrapping: Set<Character> = ["\"", "'", "“", "”", "„", "‟", "‘", "’", "‚", "‛", "«", "»", "‹", "›", "`", "*", "_"]

    /// Trimmed, with surrounding quotation marks and backticks removed. The text in between is kept as written.
    static func quote(from value: String) -> String {
        var text = Substring(value)
        while let first = text.first, first.isWhitespace || quoteWrapping.contains(first) { text = text.dropFirst() }
        while let last = text.last, last.isWhitespace || quoteWrapping.contains(last) { text = text.dropLast() }
        return String(text)
    }

    /// One line, Markdown emphasis and heading marks stripped, whitespace collapsed, at most 120 characters (cut at a word
    /// boundary, with an ellipsis).
    static func title(from value: String) -> String {
        var text = stripEmphasis(value)
        while text.first == "#" { text.removeFirst() }
        return truncated(collapsingWhitespace(text), to: maxTitleLength)
    }

    /// The first ten words of the body, as a title.
    static func title(fromBody body: String) -> String {
        let words = body.split(whereSeparator: { $0.isWhitespace }).prefix(10)
        return title(from: words.joined(separator: " "))
    }

    static func body(from value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Nil when the folded value is empty or one of "na", "none", "nosuggestion", "nothing" (small models write "N/A" and
    /// "No suggestion." although the format asks them to leave the field out).
    static func suggestion(from value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = Folding.fold(text)
        let empty: Set<String> = ["", "na", "none", "nosuggestion", "nothing"]
        return empty.contains(folded) ? nil : text
    }

    // ---- text helpers ----

    static func stripEmphasis(_ value: String) -> String {
        var text = value.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        text.removeAll { $0 == "*" || $0 == "`" }
        // A single underscore is emphasis only at the edge of a word ("_robust_"), not inside one ("snake_case").
        var result = ""
        let characters = Array(text)
        for (position, character) in characters.enumerated() {
            if character == "_" {
                let before = position > 0 ? characters[position - 1] : " "
                let after = position + 1 < characters.count ? characters[position + 1] : " "
                if !(before.isLetter || before.isNumber) || !(after.isLetter || after.isNumber) { continue }
            }
            result.append(character)
        }
        return result
    }

    static func collapsingWhitespace(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// At most `limit` characters; a longer text is cut at the last space of its first `limit - 1` characters (when that
    /// keeps at least half of them) and ends with "…".
    static func truncated(_ value: String, to limit: Int) -> String {
        guard value.count > limit else { return value }
        var cut = String(value.prefix(limit - 1))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) >= limit / 2 {
            cut = String(cut[..<space])
        }
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// The rubric ids a model may write in `category:`, for rule 5 ("lower-cased slug, unknown → other").
///
/// A value is matched, after folding, against each enabled category's id and name, then by its first word; so "claims",
/// "Claims.", "Claims vs. evidence" and "claims (the abstract)" all give "claims". Anything else is "other", which is
/// always allowed.
struct CategoryTable: Sendable, Equatable {
    static let fallback = "other"
    private let byFoldedKey: [String: String]

    init(rubric: [RubricCategory]) {
        var keys: [String: String] = [Folding.fold(Self.fallback): Self.fallback]
        for category in rubric where category.enabled {
            let id = category.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !id.isEmpty else { continue }
            let foldedName = Folding.fold(category.name)
            if !foldedName.isEmpty, keys[foldedName] == nil { keys[foldedName] = id }
            keys[Folding.fold(id)] = id
        }
        byFoldedKey = keys
    }

    func resolve(_ value: String) -> String {
        let text = CommentValues.stripEmphasis(value).trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = byFoldedKey[Folding.fold(text)] { return id }
        let firstWord = text.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }).first.map(String.init) ?? ""
        if let id = byFoldedKey[Folding.fold(firstWord)] { return id }
        return Self.fallback
    }

    /// Without a rubric: the value as a lower-cased slug ("Claims vs. evidence" -> "claims-vs-evidence"), "other" when empty.
    static func slug(_ value: String) -> String {
        let words = CommentValues.stripEmphasis(value).lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") })
        return words.isEmpty ? fallback : words.joined(separator: "-")
    }
}
