import Foundation

/// One item of a numbered or bulleted list.
struct ExportListItem: Equatable, Sendable {
    var ordered: Bool
    var marker: String                    // as written for a numbered item ("1.", "2)"); "-" for every bullet
    var level: Int                        // 0 = top level
    var paragraphs: [[ExportRun]]         // at least one
    var followsBlankLine: Bool            // a blank line separates it from the item before it
}

/// The blocks of a Markdown report.
enum ExportBlock: Equatable, Sendable {
    case heading(level: Int, runs: [ExportRun])
    case paragraph([ExportRun])
    case item(ExportListItem)
    case quote([[ExportRun]])             // its paragraphs
    case code([String])                   // the lines of a fenced code block, verbatim
    case rule
}

/// Markdown blocks, as far as a referee report needs them (plan.md section 6.10): ATX and setext headings,
/// paragraphs (soft line breaks become spaces), numbered and bulleted lists nested by indentation, block quotes,
/// fenced code and thematic breaks. Total: any text is some sequence of these blocks, and each line is read once.
enum ExportMarkdown {
    static func parse(_ markdown: String) -> [ExportBlock] {
        var parser = BlockParser()
        let normalised = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for line in normalised.split(separator: "\n", omittingEmptySubsequences: false) {
            parser.consume(String(line))
        }
        return parser.finish()
    }

    /// Joins the lines of a paragraph for the inline parser: a line that ends in two spaces or a backslash ends with
    /// a hard break ("\n"); any other line end is a space. Leading and trailing spaces of the lines go.
    static func joinParagraph(_ lines: [String]) -> String {
        var result = ""
        for (index, line) in lines.enumerated() {
            let isLast = index == lines.count - 1
            var text = Substring(line)
            while let first = text.first, first == " " || first == "\t" { text = text.dropFirst() }
            let trailingSpaces = text.reversed().prefix { $0 == " " }.count
            text = text.dropLast(trailingSpaces)
            var hardBreak = false
            if !isLast {
                if trailingSpaces >= 2 {
                    hardBreak = true
                } else if text.last == "\\" {
                    text = text.dropLast()
                    hardBreak = true
                }
            }
            result += text
            if !isLast { result += hardBreak ? "\n" : " " }
        }
        return result
    }
}

private struct BlockParser {
    private struct OpenItem {
        var ordered: Bool
        var marker: String
        var level: Int
        var paragraphs: [[String]]
        var followsBlankLine: Bool
    }

    private struct OpenFence {
        var character: Character
        var length: Int
        var indent: Int
        var lines: [String] = []
    }

    private var blocks: [ExportBlock] = []
    private var paragraph: [String] = []
    private var item: OpenItem?
    private var listIndents: [Int] = []       // the marker columns of the open list levels
    private var quote: [String]?              // the lines of an open block quote; "" separates its paragraphs
    private var fence: OpenFence?
    private var previousWasBlank = false

    mutating func consume(_ rawLine: String) {
        let line = Self.expandingTabs(rawLine)
        if let open = fence {
            if Self.closesFence(line, open) {
                blocks.append(.code(open.lines))
                fence = nil
            } else {
                fence?.lines.append(Self.droppingIndent(line, upTo: open.indent))
            }
            return
        }

        let indent = line.prefix { $0 == " " }.count
        let content = String(line.dropFirst(indent))
        if content.trimmingCharacters(in: .whitespaces).isEmpty {
            closeParagraph()
            if quote != nil { quote?.append("") }
            previousWasBlank = true
            return
        }
        let wasBlank = previousWasBlank
        previousWasBlank = false

        if indent <= 3, let opening = Self.fenceOpening(content) {
            closeAll()
            fence = OpenFence(character: opening.character, length: opening.length, indent: indent)
            return
        }
        if indent <= 3, let heading = Self.atxHeading(content) {
            closeAll()
            blocks.append(.heading(level: heading.level, runs: ExportInline.parse(heading.text)))
            return
        }
        if indent <= 3, item == nil, quote == nil, !paragraph.isEmpty, let level = Self.setextLevel(content) {
            let text = ExportMarkdown.joinParagraph(paragraph)
            paragraph = []
            blocks.append(.heading(level: level, runs: ExportInline.parse(text)))
            return
        }
        if indent <= 3, Self.isThematicBreak(content) {
            closeAll()
            blocks.append(.rule)
            return
        }
        if indent <= 3, content.hasPrefix(">") {
            closeParagraph()
            closeItem()
            listIndents = []
            var rest = content.dropFirst()
            if rest.first == " " { rest = rest.dropFirst() }
            if quote == nil { quote = [] }
            quote?.append(String(rest))
            return
        }
        if quote != nil {
            if !wasBlank, quote?.last?.isEmpty == false {
                quote?.append(content)              // a lazy continuation of the quote's paragraph
                return
            }
            closeQuote()
        }
        if let marker = Self.listMarker(content), startsItem(marker, after: wasBlank) {
            let followsBlankLine = item != nil && wasBlank
            closeParagraph()
            closeItem()
            let level = enterLevel(indent: indent)
            item = OpenItem(ordered: marker.ordered, marker: marker.text, level: level, paragraphs: [[marker.rest]],
                            followsBlankLine: followsBlankLine)
            return
        }
        if var open = item {
            if !wasBlank {
                open.paragraphs[open.paragraphs.count - 1].append(content)    // a lazy continuation
                item = open
                return
            }
            if indent >= 2 {
                open.paragraphs.append([content])          // a further paragraph of the same item
                item = open
                return
            }
            closeItem()
            listIndents = []
        }
        paragraph.append(content)
    }

    mutating func finish() -> [ExportBlock] {
        if let open = fence {
            blocks.append(.code(open.lines))           // an unclosed fence runs to the end
            fence = nil
        }
        closeAll()
        return blocks
    }

    // ---- closing ----

    private mutating func closeParagraph() {
        guard !paragraph.isEmpty else { return }
        blocks.append(.paragraph(ExportInline.parse(ExportMarkdown.joinParagraph(paragraph))))
        paragraph = []
    }

    private mutating func closeItem() {
        guard let open = item else { return }
        let paragraphs = open.paragraphs.map { ExportInline.parse(ExportMarkdown.joinParagraph($0)) }
        blocks.append(.item(ExportListItem(ordered: open.ordered, marker: open.marker, level: open.level,
                                           paragraphs: paragraphs, followsBlankLine: open.followsBlankLine)))
        item = nil
    }

    private mutating func closeQuote() {
        guard let lines = quote else { return }
        var paragraphs: [[String]] = [[]]
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if paragraphs[paragraphs.count - 1].isEmpty == false { paragraphs.append([]) }
            } else {
                paragraphs[paragraphs.count - 1].append(line)
            }
        }
        let parsed = paragraphs.filter { !$0.isEmpty }.map { ExportInline.parse(ExportMarkdown.joinParagraph($0)) }
        if !parsed.isEmpty { blocks.append(.quote(parsed)) }
        quote = nil
    }

    private mutating func closeAll() {
        closeParagraph()
        closeItem()
        closeQuote()
        listIndents = []
    }

    // ---- lists ----

    /// Inside a list any marker starts an item. Outside one, a marker after a blank line (or at the start) does; one
    /// that would interrupt a paragraph must be a bullet with text or a numbered item that starts at 1 (CommonMark),
    /// so that "…was introduced in\n2019. Since then…" stays a paragraph.
    private func startsItem(_ marker: ListMarker, after blank: Bool) -> Bool {
        if item != nil || paragraph.isEmpty || blank { return true }
        if marker.rest.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return !marker.ordered || marker.number == 1
    }

    /// The nesting level for a marker at `indent`: deeper than the open level by two columns or more opens a level,
    /// less deep closes levels.
    private mutating func enterLevel(indent: Int) -> Int {
        while let last = listIndents.last, indent < last { listIndents.removeLast() }
        if let last = listIndents.last {
            if indent >= last + 2 { listIndents.append(indent) }
        } else {
            listIndents.append(indent)
        }
        return max(0, listIndents.count - 1)
    }

    private struct ListMarker {
        var ordered: Bool
        var number: Int
        var text: String
        var rest: String
    }

    private static func listMarker(_ content: String) -> ListMarker? {
        let characters = Array(content)
        guard let first = characters.first else { return nil }
        // What follows the marker, without the spaces that separate it (trailing spaces stay: they can be a hard break).
        func rest(after count: Int) -> String { String(characters.dropFirst(count).drop { $0 == " " }) }
        if first == "-" || first == "*" || first == "+" {
            guard characters.count == 1 || characters[1] == " " else { return nil }
            return ListMarker(ordered: false, number: 0, text: "-", rest: rest(after: 1))
        }
        var digits = 0
        while digits < characters.count, digits < 10, characters[digits].isASCII, characters[digits].isNumber { digits += 1 }
        guard (1...9).contains(digits), digits < characters.count, characters[digits] == "." || characters[digits] == ")" else { return nil }
        guard digits + 1 == characters.count || characters[digits + 1] == " " else { return nil }
        let number = Int(String(characters[0..<digits])) ?? 0
        return ListMarker(ordered: true, number: number, text: String(characters[0...digits]), rest: rest(after: digits + 1))
    }

    // ---- other blocks ----

    private static func atxHeading(_ content: String) -> (level: Int, text: String)? {
        let hashes = content.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = content.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // A closing sequence of #s, preceded by a space (or making up the whole text), is not part of the heading.
        let closing = text.reversed().prefix { $0 == "#" }.count
        if closing > 0 {
            let remaining = text.dropLast(closing)
            if remaining.isEmpty || remaining.last == " " { text = remaining.trimmingCharacters(in: .whitespaces) }
        }
        return (hashes, text)
    }

    private static func setextLevel(_ content: String) -> Int? {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first == "=" || first == "-", trimmed.allSatisfy({ $0 == first }) else { return nil }
        return first == "=" ? 1 : 2
    }

    private static func isThematicBreak(_ content: String) -> Bool {
        let marks = content.filter { $0 != " " }
        guard let first = marks.first, first == "-" || first == "*" || first == "_" else { return false }
        return marks.count >= 3 && marks.allSatisfy { $0 == first }
    }

    private static func fenceOpening(_ content: String) -> (character: Character, length: Int)? {
        guard let first = content.first, first == "`" || first == "~" else { return nil }
        let length = content.prefix { $0 == first }.count
        guard length >= 3 else { return nil }
        if first == "`", content.dropFirst(length).contains("`") { return nil }   // that is inline code
        return (first, length)
    }

    private static func closesFence(_ line: String, _ fence: OpenFence) -> Bool {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return false }
        let content = line.dropFirst(indent)
        let length = content.prefix { $0 == fence.character }.count
        return length >= fence.length && content.dropFirst(length).allSatisfy { $0 == " " }
    }

    private static func droppingIndent(_ line: String, upTo count: Int) -> String {
        let indent = min(count, line.prefix { $0 == " " }.count)
        return String(line.dropFirst(indent))
    }

    /// Tabs to spaces, with stops every four columns.
    private static func expandingTabs(_ line: String) -> String {
        guard line.contains("\t") else { return line }
        var result = ""
        var column = 0
        for character in line {
            if character == "\t" {
                let spaces = 4 - column % 4
                result += String(repeating: " ", count: spaces)
                column += spaces
            } else {
                result.append(character)
                column += 1
            }
        }
        return result
    }
}
