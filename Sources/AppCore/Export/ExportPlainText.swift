import Foundation

/// The plain text of a report, for pasting into a journal's web form (plan.md section 6.10): a heading becomes its
/// text on a line of its own followed by a blank line; emphasis markers go; numbered lists keep their numbers, bullets
/// become "- ", nested items are indented by three spaces a level; a link keeps its address in brackets after its
/// text; a block quote keeps its "> "; code keeps its characters. One blank line separates blocks (none between the
/// items of a tight list), and the text ends with one line break.
enum ExportPlainText {
    static func render(_ blocks: [ExportBlock]) -> String {
        var lines: [String] = []
        var previous: ExportBlock?
        for block in blocks {
            defer { previous = block }
            let blockLines = render(block)
            guard !blockLines.isEmpty else { continue }
            if !lines.isEmpty {
                var tight = false
                if case .item? = previous, case .item(let item) = block { tight = !item.followsBlankLine }
                if !tight { lines.append("") }
            }
            lines.append(contentsOf: blockLines)
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    private static func render(_ block: ExportBlock) -> [String] {
        switch block {
        case .heading(_, let runs):
            let text = plain(runs).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? [] : textLines(text)
        case .paragraph(let runs):
            return textLines(plain(runs))
        case .item(let item):
            let indent = String(repeating: " ", count: 3 * item.level)
            let hanging = indent + String(repeating: " ", count: item.marker.count + 1)
            var lines: [String] = []
            for (index, paragraph) in item.paragraphs.enumerated() {
                for (offset, line) in textLines(plain(paragraph)).enumerated() {
                    let lead = index == 0 && offset == 0 ? indent + item.marker + " " : hanging
                    lines.append(trimmedEnd(lead + line))
                }
            }
            return lines.isEmpty ? [trimmedEnd(indent + item.marker)] : lines
        case .quote(let paragraphs):
            var lines: [String] = []
            for (index, paragraph) in paragraphs.enumerated() {
                if index > 0 { lines.append(">") }
                lines.append(contentsOf: textLines(plain(paragraph)).map { trimmedEnd("> " + $0) })
            }
            return lines
        case .code(let codeLines):
            return codeLines
        case .rule:
            return []
        }
    }

    private static func plain(_ runs: [ExportRun]) -> String {
        runs.map(\.text).joined()
    }

    private static func textLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { trimmedEnd(String($0)) }
    }

    private static func trimmedEnd(_ line: String) -> String {
        var line = Substring(line)
        while let last = line.last, last == " " || last == "\t" { line = line.dropLast() }
        return String(line)
    }
}
