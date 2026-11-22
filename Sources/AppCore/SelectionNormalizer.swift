import Foundation
import RefereeCore

// Selection normalisation (plan.md section 7.4). The PDF view reports a selection exactly as PDFKit gives it: one span
// per line, including the margin line numbers glued to a line, watermark lines, number-only lines, running headers and
// page numbers that lie between the selected lines. This file turns it into what the rest of the app uses.
//
// Where the plan leaves a choice, this file decides (also listed in docs/contract-notes/wp8b-models.md):
// - Each clipped piece is also trimmed of white space at both ends, and its span with it, so a selection that starts
//   on the space before a word starts at the word ("As shown by…", not " As shown by…").
// - Two spans that touch the same line give one span for that line (their union inside the line's contentRange).
// - Spans come back in text order: by page index, then by position in the page string.
// - Hyphens for the rule of section 6.2 are "-", U+2010 and the soft hyphen U+00AD; "the hyphenated word occurs
//   unbroken elsewhere" is checked, ignoring case, as a whole word inside the text of a single .body line.

public enum SelectionNormalizer {
    /// Clips every span to the contentRange of the .body lines it touches, drops what lies on other lines, and rebuilds
    /// `text` from the clipped pieces. `rects` come back empty (the model fills them with PaperService.rects). nil when nothing is left.
    public static func normalize(_ selection: SelectionInfo, in text: PaperText) -> SelectionInfo? {
        let pieces = clippedPieces(of: selection.spans, in: text)
        guard !pieces.isEmpty else { return nil }
        return SelectionInfo(text: join(pieces.map(\.text), in: text), spans: pieces.map(\.span), rects: [])
    }

    // ---- clipping ----

    struct Piece: Equatable {
        var span: TextSpan
        var text: String
    }

    private struct LineKey: Hashable {
        var page: Int
        var line: Int           // position in PageText.lines
    }

    /// One piece per .body line touched: the union of the parts of the spans that fall inside the line's contentRange,
    /// trimmed of white space, in text order.
    static func clippedPieces(of spans: [TextSpan], in text: PaperText) -> [Piece] {
        var pages: [Int: PageText] = [:]
        for page in text.pages where pages[page.index] == nil { pages[page.index] = page }

        var clipped: [LineKey: (lower: Int, upper: Int)] = [:]
        for span in spans where span.range.length > 0 {
            guard let page = pages[span.pageIndex] else { continue }
            for (position, line) in page.lines.enumerated() where line.kind == .body {
                let lower = max(span.range.location, line.contentRange.location)
                let upper = min(span.range.upperBound, line.contentRange.upperBound)
                guard lower < upper else { continue }
                let key = LineKey(page: span.pageIndex, line: position)
                if let known = clipped[key] {
                    clipped[key] = (min(known.lower, lower), max(known.upper, upper))
                } else {
                    clipped[key] = (lower, upper)
                }
            }
        }

        let ordered = clipped.sorted { left, right in
            (left.key.page, left.value.lower, left.key.line) < (right.key.page, right.value.lower, right.key.line)
        }
        return ordered.compactMap { key, range in
            pages[key.page].flatMap { trimmedPiece(of: $0, lower: range.lower, upper: range.upper) }
        }
    }

    /// The text of the page string between two UTF-16 offsets, without white space at either end; nil when nothing is left.
    private static func trimmedPiece(of page: PageText, lower: Int, upper: Int) -> Piece? {
        let string = page.string as NSString
        let start = max(0, min(lower, string.length))
        let end = max(start, min(upper, string.length))
        guard start < end else { return nil }
        let raw = string.substring(with: NSRange(location: start, length: end - start))
        var leading = 0
        for scalar in raw.unicodeScalars {
            guard CharacterSet.whitespacesAndNewlines.contains(scalar) else { break }
            leading += scalar.utf16.count
        }
        var trailing = 0
        for scalar in raw.unicodeScalars.reversed() {
            guard CharacterSet.whitespacesAndNewlines.contains(scalar) else { break }
            trailing += scalar.utf16.count
        }
        let length = (end - start) - leading - trailing
        guard length > 0 else { return nil }
        let range = TextRange(location: start + leading, length: length)
        return Piece(span: TextSpan(pageIndex: page.index, range: range), text: string.substring(with: range.nsRange))
    }

    // ---- joining ----

    private static let hyphens: Set<Character> = ["-", "\u{2010}", "\u{00AD}"]

    /// The pieces joined by one space, except across a hyphenated line break (section 6.2, rule 4): when the text so far
    /// ends in a hyphen preceded by a letter and the next piece starts with a lower-case letter, the hyphen is dropped and
    /// no space is added ("iden-" + "tification" -> "identification"), unless the hyphenated word occurs unbroken
    /// elsewhere in the document and the joined word does not ("office-" + "specific" -> "office-specific" when the
    /// document also writes "office-specific" on one line and never "officespecific").
    static func join(_ pieces: [String], in document: PaperText) -> String {
        var result = ""
        var lexicon: Lexicon?
        for piece in pieces where !piece.isEmpty {
            guard let last = result.last else {
                result = piece
                continue
            }
            let beforeHyphen = result.dropLast()
            if hyphens.contains(last), beforeHyphen.last?.isLetter == true, piece.first?.isLowercase == true {
                let head = String(beforeHyphen.reversed().prefix { $0.isLetter }.reversed())
                let tail = String(piece.prefix { $0.isLetter })
                if lexicon == nil { lexicon = Lexicon(document) }
                if lexicon?.keepsHyphen(head: head, tail: tail) == true {
                    result += piece
                } else {
                    result = String(beforeHyphen) + piece
                }
            } else {
                result += " " + piece
            }
        }
        return result
    }

    /// The lower-cased text of every .body line, to look a word up as it is printed on one line.
    private struct Lexicon {
        let lines: [String]

        init(_ document: PaperText) {
            lines = document.pages.flatMap { page in page.lines.filter { $0.kind == .body }.map { $0.text.lowercased() } }
        }

        func keepsHyphen(head: String, tail: String) -> Bool {
            occursAsWord((head + "-" + tail).lowercased()) && !occursAsWord((head + tail).lowercased())
        }

        /// True when `word` stands in some line with no letter directly before or after it.
        private func occursAsWord(_ word: String) -> Bool {
            guard !word.isEmpty else { return false }
            for line in lines {
                var searchStart = line.startIndex
                while searchStart < line.endIndex, let found = line.range(of: word, range: searchStart..<line.endIndex) {
                    let letterBefore = found.lowerBound > line.startIndex && line[line.index(before: found.lowerBound)].isLetter
                    let letterAfter = found.upperBound < line.endIndex && line[found.upperBound].isLetter
                    if !letterBefore && !letterAfter { return true }
                    searchStart = line.index(after: found.lowerBound)
                }
            }
            return false
        }
    }
}
