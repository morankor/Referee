import Foundation
import RefereeCore

/// What the engine does with an answer that contains no block (plan.md section 6.5, "Fallbacks").
enum ParserFallbacks {
    static let unstructuredTitle = "Unstructured model output"
    static let unstructuredNotice = "The model ignored the output format; its answer is shown as a single comment."
    static let unstructuredBodyLength = 6_000

    /// Fallback 1. Code fences are stripped, then the first balanced `[…]` or `{…}` that `JSONSerialization` reads as an
    /// object, an array of objects, or an object with one array of objects is taken; each object's keys are matched
    /// case-insensitively with the synonyms of the block format, and its values cleaned up as a block's are. Empty when
    /// nothing usable is found. Bounded: at most 2 MB of text and eight candidate brackets are examined.
    static func jsonComments(in raw: String, categories: CategoryTable?) -> [DraftComment] {
        let text = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !(trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~"))
            }
            .joined(separator: "\n")
        let units = Array(text.utf16.prefix(2_000_000))
        var searchFrom = 0
        for _ in 0..<8 {
            guard let open = units[searchFrom...].firstIndex(where: { $0 == 0x5B || $0 == 0x7B }) else { break }
            searchFrom = open + 1
            guard let close = matchingBracket(in: units, from: open) else { continue }
            let candidate = Data(String(decoding: units[open...close], as: UTF16.self).utf8)
            guard let json = try? JSONSerialization.jsonObject(with: candidate, options: [.fragmentsAllowed]) else { continue }
            let drafts = objects(in: json).compactMap { draft(from: $0, categories: categories) }
            if !drafts.isEmpty { return drafts }
        }
        return []
    }

    /// Fallback 2: one comment carrying the answer itself (its first 6,000 characters).
    static func unstructuredDraft(from raw: String) -> DraftComment {
        let body = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(unstructuredBodyLength))
        return DraftComment(id: UUID(), kind: .minor, category: CategoryTable.fallback, title: unstructuredTitle, body: body)
    }

    // ---- JSON ----

    /// The position of the bracket that closes the one at `open`, skipping brackets inside JSON strings.
    private static func matchingBracket(in units: [UInt16], from open: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        var position = open
        while position < units.count {
            let unit = units[position]
            if inString {
                if escaped { escaped = false } else if unit == 0x5C { escaped = true } else if unit == 0x22 { inString = false }
            } else {
                switch unit {
                case 0x22: inString = true
                case 0x5B, 0x7B: depth += 1
                case 0x5D, 0x7D:
                    depth -= 1
                    if depth == 0 { return position }
                    if depth < 0 { return nil }
                default: break
                }
            }
            position += 1
        }
        return nil
    }

    private static func objects(in json: Any) -> [[String: Any]] {
        if let array = json as? [Any] { return array.compactMap { $0 as? [String: Any] } }
        if let object = json as? [String: Any] {
            let arrays = object.values.compactMap { $0 as? [Any] }.filter { $0.contains { $0 is [String: Any] } }
            if arrays.count == 1 { return arrays[0].compactMap { $0 as? [String: Any] } }
            return [object]
        }
        return []
    }

    private static func draft(from object: [String: Any], categories: CategoryTable?) -> DraftComment? {
        var values: [BlockField: String] = [:]
        for (key, value) in object {
            guard let field = BlockField(name: key.trimmingCharacters(in: .whitespacesAndNewlines)), values[field] == nil,
                  let text = string(from: value) else { continue }
            values[field] = text
        }
        let body = CommentValues.body(from: values[.body] ?? "")
        var title = CommentValues.title(from: values[.title] ?? "")
        guard !title.isEmpty || !body.isEmpty else { return nil }
        if title.isEmpty { title = CommentValues.title(fromBody: body) }
        let quote = CommentValues.quote(from: values[.quote] ?? "")
        let category = values[.category] ?? ""
        return DraftComment(id: UUID(), kind: values[.kind].flatMap(CommentValues.kind(from:)) ?? .minor,
                            category: categories.map { $0.resolve(category) } ?? CategoryTable.slug(category),
                            page: values[.page].flatMap(CommentValues.page(from:)), quote: quote.isEmpty ? nil : quote, title: title, body: body,
                            suggestion: values[.suggestion].flatMap(CommentValues.suggestion(from:)))
    }

    private static func string(from value: Any) -> String? {
        switch value {
        case let text as String: return text
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? nil : number.stringValue
        case let array as [Any]:
            let parts = array.compactMap { string(from: $0) }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        default: return nil
        }
    }
}
