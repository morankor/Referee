import Foundation

/// A marker line of the block format (plan.md section 6.5): `@@COMMENT`, `@@END`, … with any leading Markdown
/// decoration (`### @@COMMENT 1`, `**@@COMMENT**`, `> @@END`).
enum BlockMark: String, CaseIterable {
    case comment = "COMMENT", end = "END", done = "DONE", notes = "NOTES", revised = "REVISED", withdraw = "WITHDRAW"
}

/// The fields a block can set. Synonyms are folded in: type and severity are the kind, pages the page, comment the
/// body, fix and resolution the suggestion.
enum BlockField: Equatable {
    case kind, category, page, quote, title, body, suggestion

    init?(name: String) {
        switch name.lowercased() {
        case "kind", "type", "severity": self = .kind
        case "category": self = .category
        case "page", "pages": self = .page
        case "quote": self = .quote
        case "title": self = .title
        case "body", "comment": self = .body
        case "suggestion", "fix", "resolution": self = .suggestion
        default: return nil
        }
    }

    /// Fields whose value is text that grows line by line, and can therefore be shown while it streams.
    var isText: Bool {
        switch self {
        case .quote, .title, .body, .suggestion: return true
        case .kind, .category, .page: return false
        }
    }

    static let allNames = ["kind", "type", "severity", "category", "page", "pages", "quote", "title", "body", "comment", "suggestion", "fix", "resolution"]
    static let suggestionNames = ["suggestion", "fix", "resolution"]
}

/// Classifies one line. All patterns are case-insensitive and tolerate leading Markdown decoration:
///
///     MARK(x)  = ^\s*[>#*`\-\s]*@@\s*x\b.*$
///     FIELD    = ^\s*(?:[-*•]\s+|\d+[.)]\s+)?[*_`]{0,3}(kind|type|…|resolution)[*_`]{0,3}\s*[:：][*_`]{0,3}\s*(.*)$
///
/// Only the first 256 characters of a line are matched (a field name and its colon always lie there), so a line of
/// several megabytes costs no more than a short one.
enum LineSyntax {
    private static let prefixLength = 256

    private static let markPattern: NSRegularExpression = {
        let names = BlockMark.allCases.map(\.rawValue).joined(separator: "|")
        // A regex literal: a failure here is a programmer error.
        return try! NSRegularExpression(pattern: #"^\s*[>#*`\-\s]*@@\s*("# + names + #")\b"#, options: [.caseInsensitive])
    }()

    private static let fieldPattern: NSRegularExpression = {
        let names = BlockField.allNames.joined(separator: "|")
        return try! NSRegularExpression(pattern: #"^\s*(?:[-*•]\s+|\d+[.)]\s+)?[*_`]{0,3}("# + names + #")[*_`]{0,3}\s*[:：][*_`]{0,3}\s*"#,
                                        options: [.caseInsensitive])
    }()

    static func mark(in line: String) -> BlockMark? {
        let head = String(line.prefix(prefixLength))
        let nsHead = head as NSString
        guard let match = markPattern.firstMatch(in: head, range: NSRange(location: 0, length: nsHead.length)) else { return nil }
        return BlockMark(rawValue: nsHead.substring(with: match.range(at: 1)).uppercased())
    }

    /// The field a line sets and the value after its colon (trailing whitespace removed), or nil for any other line.
    static func field(in line: String) -> (field: BlockField, value: String)? {
        let head = String(line.prefix(prefixLength))
        let nsHead = head as NSString
        guard let match = fieldPattern.firstMatch(in: head, range: NSRange(location: 0, length: nsHead.length)),
              let field = BlockField(name: nsHead.substring(with: match.range(at: 1))) else { return nil }
        let valueStart = String.Index(utf16Offset: match.range.upperBound, in: line)
        var value = String(line[valueStart...])
        while let last = value.last, last.isWhitespace { value.removeLast() }
        return (field, value)
    }

    /// Whether an unfinished line could still turn out to be a marker, or a field line for one of `fieldNames`, once the
    /// rest of it arrives. Such a line is not shown in a streaming draft: shown as text, it would vanish again when the
    /// line completes, and a draft must only grow. A line for which this is false can never become either.
    static func couldBecomeStructural(_ partial: String, fieldNames: [String]) -> Bool {
        couldBecomeMark(Substring(partial)) || couldBecomeField(Substring(partial), names: fieldNames)
    }

    private static func couldBecomeMark(_ line: Substring) -> Bool {
        var rest = line.drop { $0.isWhitespace || ">#*`-".contains($0) }
        if rest.isEmpty { return true }
        guard rest.first == "@" else { return false }
        rest = rest.dropFirst()
        if rest.isEmpty { return true }
        guard rest.first == "@" else { return false }
        rest = rest.dropFirst().drop { $0.isWhitespace }
        if rest.isEmpty { return true }
        let word = rest.uppercased()
        for name in BlockMark.allCases.map(\.rawValue) {
            if name.hasPrefix(word) { return true }               // "@@COMM": the name may still complete
            if word.hasPrefix(name) {                              // "@@END " or "@@END": already a marker
                let after = word.dropFirst(name.count).first
                if after == nil || !(after!.isLetter || after!.isNumber || after! == "_") { return true }
            }
        }
        return false
    }

    private static func couldBecomeField(_ line: Substring, names: [String]) -> Bool {
        var rest = line.drop { $0.isWhitespace }
        if rest.isEmpty { return true }
        // An optional list marker: "- ", "* ", "• ", "12. ", "3) ".
        if let first = rest.first, "-*•".contains(first) {
            let after = rest.dropFirst()
            if after.isEmpty { return true }
            if after.first!.isWhitespace {
                rest = after.drop { $0.isWhitespace }
                if rest.isEmpty { return true }
            } else if first != "*" {
                return false                                       // "-x" or "•x": neither a marker nor emphasis
            }
        } else if let first = rest.first, first.isASCII, first.isNumber {
            let afterDigits = rest.drop { $0.isASCII && $0.isNumber }
            if afterDigits.isEmpty { return true }
            if afterDigits.first == "." || afterDigits.first == ")" {
                let afterPunctuation = afterDigits.dropFirst()
                if afterPunctuation.isEmpty { return true }
                guard afterPunctuation.first!.isWhitespace else { return false }
                rest = afterPunctuation.drop { $0.isWhitespace }
                if rest.isEmpty { return true }
            } else {
                return false
            }
        }
        // Up to three emphasis characters, the name, up to three more, spaces, then the colon.
        rest = dropEmphasis(rest)
        if rest.isEmpty { return true }
        let word = rest.prefix { $0.isLetter }.lowercased()
        let afterWord = rest.drop { $0.isLetter }
        if afterWord.isEmpty { return names.contains { $0.hasPrefix(word) } }
        guard names.contains(word) else { return false }
        let beforeColon = dropEmphasis(afterWord).drop { $0.isWhitespace }
        if beforeColon.isEmpty { return true }
        return beforeColon.first == ":" || beforeColon.first == "："
    }

    private static func dropEmphasis(_ text: Substring) -> Substring {
        var rest = text
        var dropped = 0
        while dropped < 3, let first = rest.first, "*_`".contains(first) {
            rest = rest.dropFirst()
            dropped += 1
        }
        return rest
    }
}
