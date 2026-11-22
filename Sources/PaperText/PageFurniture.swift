import Foundation
import RefereeCore

/// Section 7.2, steps 2–4: what a journal system or a page layout puts on every page and is not the paper's text.
/// Each step looks only at the lines that are still `.body`.
enum PageFurniture {
    /// Steps 2, 3 and 4, in that order.
    static func classify(_ pages: inout [PageText]) {
        markBoilerplate(&pages)
        markPageNumbers(&pages)
        markRepeatedLines(&pages)
    }

    // MARK: - Step 2: journal-system boilerplate

    /// Lines matching `^(for peer review( only)?|confidential|manuscript (id|number)\b.*|click here to
    /// (download|view|access).*|powered by editorial manager.*|.*scholarone.*|electronic copy available at.*)$`,
    /// case-insensitive, become `.watermark`. Runs of whitespace count as one space. So does the stamp arXiv prints
    /// up the left margin of page 1, "arXiv:1409.0473v7 [cs.CL] 19 May 2016" (Gate 1: rotated, it was the tallest line
    /// of the page and became the title guess of every arXiv paper).
    static func markBoilerplate(_ pages: inout [PageText]) {
        for position in pages.indices {
            for index in pages[position].lines.indices where pages[position].lines[index].kind == .body {
                if isBoilerplate(pages[position].lines[index].text) { pages[position].lines[index].kind = .watermark }
            }
        }
    }

    static func isBoilerplate(_ text: String) -> Bool {
        let line = collapsingWhitespace(text).lowercased()
        if line == "for peer review" || line == "for peer review only" || line == "confidential" { return true }
        for prefix in ["manuscript id", "manuscript number"] where line.hasPrefix(prefix) {
            let rest = line.unicodeScalars.dropFirst(prefix.unicodeScalars.count)
            guard let next = rest.first else { return true }
            if !(Folding.isLetterOrDigit(next) || next == "_") { return true }
        }
        for prefix in ["click here to download", "click here to view", "click here to access", "powered by editorial manager",
                       "electronic copy available at"] where line.hasPrefix(prefix) {
            return true
        }
        if line.contains("scholarone") { return true }
        return line.range(of: arxivStamp, options: .regularExpression) != nil
    }

    /// "arxiv:1409.0473v7 [cs.cl] 19 may 2016", and the old form "arxiv:hep-th/9901001v1 [hep-th] 4 jan 1999".
    static let arxivStamp = #"^arxiv:\s?(\d{4}\.\d{4,5}|[a-z-]+(\.[a-z-]+)?/\d{7})(v\d+)?\s?\[[a-z.-]+\]\s\d{1,2}\s[a-z]{3,9}\s\d{4}$"#

    // MARK: - Step 3: page numbers

    /// The first or last remaining body line of a page that is only a number ("12", "Page 12", "12 of 30",
    /// "– 12 –") becomes `.pageNumber` when its number goes up by one from page to page; so does any line that is
    /// exactly "Page N of M".
    ///
    /// Decision: "goes up by one from the previous page" is read over the whole document, so that one page without a
    /// number, or one stray number, does not stop the rest: each candidate has an offset (its number minus its page
    /// position), and the candidates with the most common offset are page numbers (on a tie, the offset nearest to
    /// page 1 being numbered 1).
    static func markPageNumbers(_ pages: inout [PageText]) {
        var candidates: [(position: Int, line: Int, offset: Int)] = []
        for position in pages.indices {
            let body = pages[position].lines.indices.filter { pages[position].lines[$0].kind == .body }
            guard let first = body.first, let last = body.last else { continue }
            for index in Set([first, last]).sorted() {
                if let number = pageNumber(in: pages[position].lines[index].text) {
                    candidates.append((position, index, number - position))
                }
            }
        }
        var pagesPerOffset: [Int: Set<Int>] = [:]
        for candidate in candidates { pagesPerOffset[candidate.offset, default: []].insert(candidate.position) }
        let chosen = pagesPerOffset.max { a, b in
            if a.value.count != b.value.count { return a.value.count < b.value.count }
            if abs(a.key - 1) != abs(b.key - 1) { return abs(a.key - 1) > abs(b.key - 1) }
            return a.key > b.key
        }?.key
        for candidate in candidates where candidate.offset == chosen {
            pages[candidate.position].lines[candidate.line].kind = .pageNumber
        }
        for position in pages.indices {
            for index in pages[position].lines.indices where pages[position].lines[index].kind == .body {
                if isPageNOfM(pages[position].lines[index].text) { pages[position].lines[index].kind = .pageNumber }
            }
        }
    }

    /// The number of a line that is only a page number: `^(page\s+)?(\d{1,4})(\s+of\s+\d{1,4})?$` or `^[-–—]\s*(\d{1,4})\s*[-–—]$`.
    static func pageNumber(in text: String) -> Int? {
        var scanner = WordScanner(text)
        if scanner.dash() {
            scanner.spaces()
            guard let number = scanner.number() else { return nil }
            scanner.spaces()
            return scanner.dash() && scanner.atEnd ? number : nil
        }
        if scanner.word("page") {
            guard scanner.spaces() else { return nil }
        }
        guard let number = scanner.number() else { return nil }
        if scanner.atEnd { return number }
        guard scanner.spaces(), scanner.word("of"), scanner.spaces(), scanner.number() != nil, scanner.atEnd else { return nil }
        return number
    }

    /// `^page\s+\d{1,4}\s+of\s+\d{1,4}$`, case-insensitive.
    static func isPageNOfM(_ text: String) -> Bool {
        var scanner = WordScanner(text)
        return scanner.word("page") && scanner.spaces() && scanner.number() != nil && scanner.spaces() && scanner.word("of")
            && scanner.spaces() && scanner.number() != nil && scanner.atEnd
    }

    // MARK: - Step 4: repeated lines

    /// In a document of three or more pages, a line found (lower-cased, digits as "#", whitespace collapsed) on at
    /// least max(3, 60% of the pages) is `.runningHeader` with its vertical centre in the top 15% of the page,
    /// `.runningFooter` in the bottom 15%, otherwise `.watermark` (also without bounds).
    ///
    /// Decision: a repeated line without a single letter ("(#)", an equation number; "□") is left in the text unless it
    /// sits in the top or bottom 15%. Watermarks are words; equation numbers on most pages of a mathematical paper are
    /// not furniture.
    static func markRepeatedLines(_ pages: inout [PageText]) {
        guard pages.count >= 3 else { return }
        var pagesWithLine: [String: Int] = [:]
        for page in pages {
            var seen = Set<String>()
            for line in page.lines where line.kind == .body {
                let key = normalized(line.text)
                if !key.isEmpty && seen.insert(key).inserted { pagesWithLine[key, default: 0] += 1 }
            }
        }
        let threshold = max(3, 0.6 * Double(pages.count))
        for position in pages.indices {
            let height = pages[position].size.height
            for index in pages[position].lines.indices where pages[position].lines[index].kind == .body {
                let line = pages[position].lines[index]
                let key = normalized(line.text)
                guard !key.isEmpty, Double(pagesWithLine[key] ?? 0) >= threshold else { continue }
                let hasLetter = key.unicodeScalars.contains { $0.properties.isAlphabetic }
                if let bounds = line.bounds {
                    let centre = bounds.y + bounds.height / 2
                    if centre >= 0.85 * height {
                        pages[position].lines[index].kind = .runningHeader
                    } else if centre <= 0.15 * height {
                        pages[position].lines[index].kind = .runningFooter
                    } else if hasLetter {
                        pages[position].lines[index].kind = .watermark
                    }
                } else if hasLetter {
                    pages[position].lines[index].kind = .watermark
                }
            }
        }
    }

    /// Lower-cased, every decimal digit as "#", whitespace collapsed to single spaces, trimmed.
    static func normalized(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in collapsingWhitespace(text).lowercased().unicodeScalars {
            scalars.append(scalar.properties.generalCategory == .decimalNumber ? "#" : scalar)
        }
        return String(scalars)
    }

    /// Runs of whitespace as one space, and none at either end.
    static func collapsingWhitespace(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if Folding.isSpace(scalar) {
                pendingSpace = !scalars.isEmpty
            } else {
                if pendingSpace { scalars.append(" ") }
                pendingSpace = false
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }
}

/// A small scanner for the page-number shapes: words compared case-insensitively, ASCII digits, whitespace and the
/// three dashes.
private struct WordScanner {
    private let scalars: [Unicode.Scalar]
    private var position = 0

    init(_ text: String) {
        scalars = Array(PageFurniture.collapsingWhitespace(text).unicodeScalars)
    }

    var atEnd: Bool { position == scalars.count }

    /// Consumes whitespace; true if there was any.
    @discardableResult
    mutating func spaces() -> Bool {
        let start = position
        while position < scalars.count && Folding.isSpace(scalars[position]) { position += 1 }
        return position > start
    }

    /// Consumes `word` (lower-case ASCII) if the text continues with it in any case.
    mutating func word(_ word: String) -> Bool {
        let letters = Array(word.unicodeScalars)
        guard position + letters.count <= scalars.count else { return false }
        for (offset, letter) in letters.enumerated() {
            let value = scalars[position + offset].value
            let lower = value >= 0x41 && value <= 0x5A ? value + 0x20 : value
            guard lower == letter.value else { return false }
        }
        position += letters.count
        return true
    }

    /// Consumes 1–4 ASCII digits not followed by a fifth.
    mutating func number() -> Int? {
        var value = 0
        var count = 0
        while position + count < scalars.count {
            let digit = scalars[position + count].value
            guard digit >= 0x30 && digit <= 0x39 else { break }
            value = value * 10 + Int(digit - 0x30)
            count += 1
            if count > 4 { return nil }
        }
        guard count > 0 else { return nil }
        position += count
        return value
    }

    /// Consumes "-", "–" or "—".
    mutating func dash() -> Bool {
        guard position < scalars.count else { return false }
        switch scalars[position].value {
        case 0x2D, 0x2013, 0x2014:
            position += 1
            return true
        default:
            return false
        }
    }
}
