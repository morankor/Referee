import Foundation

/// One block of the report's preview (plan.md section 9.8): a heading, a paragraph or a list item.
struct SidebarMarkdownBlock: Equatable, Identifiable {
    enum Kind: Equatable {
        case heading(level: Int)             // 1 to 6
        case paragraph
        case numberedItem(marker: String)    // "1." or "1)", as written
        case bulletItem
        case rule                            // a thematic break ("---")
    }
    var id: Int                              // position in the document
    var kind: Kind
    var text: AttributedString               // inline Markdown already applied: emphasis, strong, code, links
}

/// The preview's Markdown conversion. Pure.
///
/// `AttributedString(markdown:)` alone is not enough for a preview: SwiftUI's `Text` draws neither headings nor list
/// numbers from it and runs the paragraphs together. So the blocks are found line by line, in the shape a report has
/// (ATX headings, paragraphs, numbered and bulleted items), and only each block's text goes through
/// `AttributedString(markdown:)` with inline syntax. Rules:
/// - `#` to `######` followed by a space starts a heading (closing `#`s are dropped); `#word` is text.
/// - `1.` or `1)` followed by a space starts a numbered item, `-`, `*` or `+` followed by a space a bulleted one;
///   a line of three or more `-`, `*` or `_` alone is a rule.
/// - A blank line ends a paragraph or an item; any other line continues the open one, joined with a space.
enum SidebarMarkdown {
    static func blocks(from markdown: String) -> [SidebarMarkdownBlock] {
        var blocks: [SidebarMarkdownBlock] = []
        var open: (kind: SidebarMarkdownBlock.Kind, lines: [String])?

        func add(_ kind: SidebarMarkdownBlock.Kind, _ text: String) {
            blocks.append(SidebarMarkdownBlock(id: blocks.count, kind: kind, text: inline(text)))
        }
        func close() {
            if let block = open { add(block.kind, block.lines.joined(separator: " ")) }
            open = nil
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                close()
            } else if let heading = heading(line) {
                close()
                add(.heading(level: heading.level), heading.text)
            } else if isRule(line) {
                close()
                blocks.append(SidebarMarkdownBlock(id: blocks.count, kind: .rule, text: AttributedString()))
            } else if let item = numberedItem(line) {
                close()
                open = (.numberedItem(marker: item.marker), [item.text])
            } else if let text = bulletItem(line) {
                close()
                open = (.bulletItem, [text])
            } else if open != nil {
                open?.lines.append(line)
            } else {
                open = (.paragraph, [line])
            }
        }
        close()
        return blocks
    }

    /// The inline Markdown of one block (emphasis, strong, code, links); the text as it is when it does not parse.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    static func heading(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.isEmpty || rest.first?.isWhitespace == true else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // A closing sequence of #s after a space is not part of the heading ("## Title ##").
        let closing = text.reversed().prefix { $0 == "#" }.count
        if closing > 0 {
            let start = text.index(text.endIndex, offsetBy: -closing)
            if start == text.startIndex {
                text = ""
            } else if text[text.index(before: start)].isWhitespace {
                text = text[..<start].trimmingCharacters(in: .whitespaces)
            }
        }
        return (hashes, text)
    }

    static func numberedItem(_ line: String) -> (marker: String, text: String)? {
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard (1...9).contains(digits.count) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let delimiter = rest.first, delimiter == "." || delimiter == ")" else { return nil }
        let afterDelimiter = rest.dropFirst()
        guard afterDelimiter.first?.isWhitespace == true else { return nil }
        return (String(digits) + String(delimiter), afterDelimiter.trimmingCharacters(in: .whitespaces))
    }

    static func bulletItem(_ line: String) -> String? {
        guard let marker = line.first, "-*+".contains(marker) else { return nil }
        let rest = line.dropFirst()
        guard rest.first?.isWhitespace == true else { return nil }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    static func isRule(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }
}
