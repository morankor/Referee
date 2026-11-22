import AppKit

/// The report as an attributed string for Word and PDF (plan.md section 6.10): headings as bold, larger runs;
/// paragraphs; numbered and bulleted items with a hanging indent; emphasis as italic, strong emphasis as bold, code
/// in a fixed-pitch face. Times New Roman 12 pt, which Word has on every system, in black, so that a page printed or
/// exported in dark mode is still black on white.
@MainActor
enum ExportRichText {
    static let bodySize: CGFloat = 12
    private static let indentPerLevel: CGFloat = 18
    private static let markerWidth: CGFloat = 22

    static func attributedString(for blocks: [ExportBlock]) -> NSAttributedString {
        let visible = blocks.filter { $0 != .rule }
        let result = NSMutableAttributedString()
        for (index, block) in visible.enumerated() {
            let isFirst = index == 0
            let nextIsItem: Bool
            if index + 1 < visible.count, case .item = visible[index + 1] { nextIsItem = true } else { nextIsItem = false }
            switch block {
            case .heading(let level, let runs):
                let size: CGFloat = level == 1 ? 16 : level == 2 ? 14 : bodySize
                let style = paragraphStyle(before: isFirst ? 0 : 14, after: 6)
                append(runs, to: result, base: bold(textFont(size: size)), style: style)
            case .paragraph(let runs):
                append(runs, to: result, base: textFont(size: bodySize), style: paragraphStyle(before: 0, after: 8))
            case .item(let item):
                let start = indentPerLevel * CGFloat(item.level)
                let after: CGFloat = nextIsItem ? 4 : 8
                let before: CGFloat = item.followsBlankLine ? 4 : 0
                for (offset, paragraph) in item.paragraphs.enumerated() {
                    let style = paragraphStyle(before: offset == 0 ? before : 2, after: offset == item.paragraphs.count - 1 ? after : 2,
                                               firstLine: offset == 0 ? start : start + markerWidth, head: start + markerWidth,
                                               tab: start + markerWidth)
                    let marker = offset == 0 ? (item.ordered ? item.marker : "\u{2022}") + "\t" : ""
                    let runs = [ExportRun(text: marker)] + paragraph
                    append(runs, to: result, base: textFont(size: bodySize), style: style)
                }
            case .quote(let paragraphs):
                for (offset, paragraph) in paragraphs.enumerated() {
                    let style = paragraphStyle(before: 0, after: offset == paragraphs.count - 1 ? 8 : 4,
                                               firstLine: markerWidth, head: markerWidth, tail: -markerWidth)
                    append(paragraph, to: result, base: textFont(size: bodySize), style: style)
                }
            case .code(let lines):
                for (offset, line) in lines.enumerated() {
                    let style = paragraphStyle(before: 0, after: offset == lines.count - 1 ? 8 : 0, firstLine: markerWidth,
                                               head: markerWidth, lineHeight: 1)
                    append([ExportRun(text: line, code: true)], to: result, base: textFont(size: bodySize), style: style)
                }
            case .rule:
                break
            }
        }
        // Every paragraph was appended with its terminator; the last one needs none.
        if result.length > 0, result.string.hasSuffix("\n") {
            result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
        }
        return result
    }

    /// Appends one paragraph: its runs and a line feed, all carrying the paragraph's style. A hard line break inside
    /// the paragraph becomes U+2028, a line break that does not end the paragraph.
    private static func append(_ runs: [ExportRun], to result: NSMutableAttributedString, base: NSFont, style: NSParagraphStyle) {
        for run in runs where !run.text.isEmpty {
            var font = run.code ? codeFont(size: base.pointSize - 1) : base
            if run.strong { font = bold(font) }
            if run.emphasis { font = italic(font) }
            let text = run.text.replacingOccurrences(of: "\n", with: "\u{2028}")
            result.append(NSAttributedString(string: text, attributes: attributes(font, style)))
        }
        result.append(NSAttributedString(string: "\n", attributes: attributes(base, style)))
    }

    private static func attributes(_ font: NSFont, _ style: NSParagraphStyle) -> [NSAttributedString.Key: Any] {
        [.font: font, .paragraphStyle: style, .foregroundColor: NSColor.black]
    }

    private static func paragraphStyle(before: CGFloat, after: CGFloat, firstLine: CGFloat = 0, head: CGFloat = 0,
                                       tail: CGFloat = 0, tab: CGFloat? = nil, lineHeight: CGFloat = 1.15) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.firstLineHeadIndent = firstLine
        style.headIndent = head
        style.tailIndent = tail
        style.lineHeightMultiple = lineHeight
        style.tabStops = tab.map { [NSTextTab(textAlignment: .left, location: $0)] } ?? []
        style.defaultTabInterval = markerWidth
        return style
    }

    static func textFont(size: CGFloat) -> NSFont {
        NSFont(name: "Times New Roman", size: size) ?? NSFont(name: "Times", size: size) ?? NSFont.systemFont(ofSize: size)
    }

    private static func codeFont(size: CGFloat) -> NSFont {
        NSFont(name: "Courier New", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static func bold(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    private static func italic(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }
}
