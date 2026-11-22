import Foundation
import RefereeCore
import TestSupport

/// Hand-built papers whose page strings, line ranges and line kinds are known exactly.
enum SyntheticPaper {
    /// One line of a page: its content, its kind, and the margin digits PDFKit glued to its end (left out of contentRange).
    struct Line {
        var text: String
        var kind: LineKind = .body
        var marginDigits: String?
        init(_ text: String, _ kind: LineKind = .body, digits: String? = nil) {
            self.text = text
            self.kind = kind
            self.marginDigits = digits
        }
    }

    /// The page string is the lines' raw text joined by "\n". A body line's contentRange leaves out its margin digits;
    /// a number-only line's contentRange is empty. Lines are 24 pt apart from the top of a 792 pt page.
    static func page(_ index: Int, _ lines: [Line]) -> PageText {
        var string = ""
        var textLines: [TextLine] = []
        for (position, line) in lines.enumerated() {
            let start = string.utf16.count
            let raw = line.text + (line.marginDigits ?? "")
            string += raw + "\n"
            let range = RefereeCore.TextRange(location: start, length: raw.utf16.count)
            let content: RefereeCore.TextRange
            let text: String
            switch line.kind {
            case .marginNumberOnly:
                content = RefereeCore.TextRange(location: start, length: 0)
                text = ""
            default:
                content = RefereeCore.TextRange(location: start, length: line.text.utf16.count)
                text = line.text
            }
            let bounds = PageRect(pageIndex: index, x: 110, y: 740 - Double(position) * 24, width: 380, height: 12)
            textLines.append(TextLine(pageIndex: index, range: range, contentRange: content, text: text, kind: line.kind,
                                      marginNumber: line.marginDigits.flatMap { Int($0) }, bounds: bounds))
        }
        return PageText(index: index, size: PageSize(width: 612, height: 792), string: string, lines: textLines)
    }

    static func paper(_ pages: [PageText], name: String = "synthetic.pdf") -> LoadedPaper {
        let ref = DocumentRef(sha256: String(repeating: "5a", count: 32), fileName: name, byteCount: 1_000, pageCount: pages.count)
        return LoadedPaper(ref: ref, data: Data("%PDF-1.4 synthetic".utf8), isEncrypted: false,
                           text: PaperText(pages: pages, hasTextLayer: true, hasMarginLineNumbers: true))
    }

    /// A line-numbered page in the manner of ay_nolinks (section 6.7): digits glued to the text lines, a watermark line,
    /// a number-only line and a page number between them; a second page with a running header and the word
    /// "office-specific" printed unbroken on one line and broken across two others.
    static let lineNumbered: LoadedPaper = paper([
        page(0, [
            Line("In Banerjee [1992], agents observe only the actions of their predecessors.", digits: "9"),
            Line("Later work extends the framework to markets. As shown by Acemoglu et al. [2011],", digits: "11"),
            Line("network structure determines whether learning is efficient; see also Lee [2021].", digits: "12"),
            Line("CONFIDENTIAL", .watermark),
            Line("", .marginNumberOnly, digits: "13"),
            Line("We define the office-specific iden-", digits: "14"),
            Line("tification threshold and verify the differentiability of the payoff.", digits: "15"),
            Line("1", .pageNumber),
        ]),
        page(1, [
            Line("Journal of Synthetic Economics", .runningHeader),
            Line("The office-specific threshold is defined in Section 2.", digits: "16"),
            Line("The cost of the office-", digits: "17"),
            Line("specific rule is the same in every period.", digits: "18"),
        ]),
    ], name: "line_numbered.pdf")

    /// The raw range of line `line` of page `page` (margin digits included), or the part of it from `from` for `length`.
    static func rawSpan(_ paper: LoadedPaper, page: Int, line: Int, from offset: Int = 0, length: Int? = nil) -> TextSpan {
        let textLine = paper.text.pages[page].lines[line]
        let start = textLine.range.location + offset
        return TextSpan(pageIndex: page, range: RefereeCore.TextRange(location: start, length: length ?? (textLine.range.upperBound - start)))
    }

    /// The UTF-16 offset of `needle` in the page string.
    static func offset(of needle: String, in paper: LoadedPaper, page: Int) -> Int {
        let string = paper.text.pages[page].string as NSString
        return string.range(of: needle).location
    }

    /// Two pages of ten and five plain body lines, for the display order.
    static let twoPages: LoadedPaper = paper([
        page(0, (0..<10).map { Line("Page one, line \($0 + 1), with some words to make it a full line of text.") }),
        page(1, (0..<5).map { Line("Page two, line \($0 + 1), with some words to make it a full line of text.") }),
    ], name: "two_pages.pdf")

    /// A span inside line `line` of `paper`'s page `page`, starting `offset` characters into it.
    static func span(_ paper: LoadedPaper, page: Int, line: Int, offset: Int = 0, length: Int = 8) -> RefereeCore.TextRange {
        RefereeCore.TextRange(location: paper.text.pages[page].lines[line].range.location + offset, length: length)
    }
}
