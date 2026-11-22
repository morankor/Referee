import Foundation
import RefereeCore

/// Anchors a quote to the clean text of a paper (plan section 6.7). Built once per paper; pure.
///
/// The index is the folded text of every `.body` line, pages in order and lines in `PageText.lines` order, so line
/// breaks, page breaks and every line of another kind (margin numbers, page numbers, running heads, watermarks)
/// contribute nothing, and a quote that crosses a page is still one contiguous run. `locate` tries, first success wins:
/// an exact match of the folded quote, then the head and tail of a long or elided quote, then a fuzzy match on tokens.
public struct QuoteMatcher: QuoteMatching {
    private let index: QuoteIndex

    public init(paper: PaperText) {
        index = QuoteIndex(paper: paper)
    }

    public func locate(quote: String, pageHint: Int?) -> AnchorMatch? {
        index.locate(quote: quote, pageHint: pageHint)
    }

    public func locationLabel(for spans: [TextSpan]) -> String {
        index.locationLabel(for: spans)
    }
}

/// The index of section 6.7: the folded `stream` with parallel arrays, and the tokens with their positions.
struct QuoteIndex: Sendable {
    /// The paper's pages, for location labels; and the position in `pages` of each page index.
    let pages: [PageText]
    let positionOfPage: [Int: Int]
    /// The folding of every non-ASCII scalar of the paper, reused for quotes.
    let foldCache: [UInt32: [UInt32]]

    /// The stream: one folded unit each, with the UTF-16 range of its scalar in the page string and the number of its
    /// body line (counted over the whole paper); and the page index of each body line.
    let units: [UInt32]
    let unitStart: [Int]
    let unitEnd: [Int]
    let unitLine: [Int]
    let linePage: [Int]

    /// The tokens of the stream, in order: an id per token, and the stream range of each.
    let tokens: [Int]
    let tokenFirstUnit: [Int]
    let tokenEndUnit: [Int]
    /// Token text -> id; for each id its positions in `tokens`, its length in units and whether it is all digits.
    let vocabulary: [ArraySlice<UInt32>: Int]
    let postings: [[Int]]
    let idLength: [Int]
    let idIsNumber: [Bool]

    init(paper: PaperText) {
        var folded = FoldedText()
        folded.reserveCapacity(paper.pages.reduce(0) { $0 + $1.string.utf16.count })
        var positions: [Int: Int] = [:]
        for (position, page) in paper.pages.enumerated() {
            if positions[page.index] == nil { positions[page.index] = position }
            for line in page.lines where line.kind == .body {
                folded.appendLine(line.text, page: page.index, location: line.contentRange.location)
            }
        }

        let units = folded.units
        var vocabulary: [ArraySlice<UInt32>: Int] = [:]
        var tokens: [Int] = []
        var tokenFirstUnit: [Int] = []
        var tokenEndUnit: [Int] = []
        var postings: [[Int]] = []
        var idLength: [Int] = []
        var idIsNumber: [Bool] = []
        let ranges = folded.tokenRanges()
        tokens.reserveCapacity(ranges.count)
        tokenFirstUnit.reserveCapacity(ranges.count)
        tokenEndUnit.reserveCapacity(ranges.count)
        for range in ranges {
            let key = units[range]
            let id: Int
            if let known = vocabulary[key] {
                id = known
            } else {
                id = postings.count
                vocabulary[key] = id
                postings.append([])
                idLength.append(key.count)
                idIsNumber.append(key.allSatisfy(QuoteIndex.isNumeric))
            }
            postings[id].append(tokens.count)
            tokens.append(id)
            tokenFirstUnit.append(range.lowerBound)
            tokenEndUnit.append(range.upperBound)
        }

        self.pages = paper.pages
        self.positionOfPage = positions
        self.foldCache = folded.cache
        self.units = units
        self.unitStart = folded.starts
        self.unitEnd = folded.ends
        self.unitLine = folded.lines
        self.linePage = folded.linePages
        self.tokens = tokens
        self.tokenFirstUnit = tokenFirstUnit
        self.tokenEndUnit = tokenEndUnit
        self.vocabulary = vocabulary
        self.postings = postings
        self.idLength = idLength
        self.idIsNumber = idIsNumber
    }

    /// The page index of the unit at `index` of the stream.
    func page(ofUnit index: Int) -> Int {
        linePage[unitLine[index]]
    }

    private static func isNumeric(_ unit: UInt32) -> Bool {
        if unit < 0x80 { return unit >= 0x30 && unit <= 0x39 }
        guard let scalar = Unicode.Scalar(unit) else { return false }
        switch scalar.properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }

    // MARK: - locate

    /// Section 6.7, `locate(quote:pageHint:)`. `pageHint` is a 0-based page index.
    func locate(quote: String, pageHint: Int?) -> AnchorMatch? {
        let folded = foldQuote(quote)
        let q = folded.units

        // Step 2: exact. Short quotes only with a page hint, and then only on that page and its neighbours.
        if q.count >= 12 || (pageHint != nil && q.count >= 6) {
            var hits = occurrences(of: q)
            if q.count < 12, let hint = pageHint {
                hits = hits.filter { abs(page(ofUnit: $0) - hint) <= 1 }
            }
            if let start = preferred(hits, hint: pageHint) {
                return AnchorMatch(spans: spans(from: start, to: start + q.count), confidence: .exact)
            }
        }

        // Steps 1 and 3: the head and tail of a long quote, or the first and last pieces of an elided one.
        let pieces = Self.ellipsisPieces(of: quote)
        if q.count > 160 || pieces != nil {
            let head = Array((pieces?.head ?? q).prefix(80))
            let tail = Array((pieces?.tail ?? q).suffix(80))
            if let match = headAndTail(head: head, tail: tail, limit: 3 * q.count, hint: pageHint) {
                return AnchorMatch(spans: spans(from: match.lowerBound, to: match.upperBound), confidence: .fuzzy(score: 0.9))
            }
        }

        // Step 4: fuzzy on tokens.
        let quoteTokens = folded.tokenRanges().map { vocabulary[q[$0]] ?? -1 }
        if let match = fuzzyMatch(quoteTokens: quoteTokens, hint: pageHint) {
            return AnchorMatch(spans: spans(from: match.units.lowerBound, to: match.units.upperBound),
                               confidence: .fuzzy(score: match.score))
        }
        return nil
    }

    /// The quote folded as the document is, line by line (a line break in a quote is a line break in the text).
    private func foldQuote(_ quote: String) -> FoldedText {
        var folded = FoldedText(cache: foldCache, extendsCache: false)
        for line in quote.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            folded.appendLine(String(line), page: 0, location: 0)
        }
        return folded
    }

    /// The start of every occurrence of `needle` in the stream, in order.
    func occurrences(of needle: [UInt32]) -> [Int] {
        let length = needle.count
        guard length > 0, length <= units.count else { return [] }
        var found: [Int] = []
        units.withUnsafeBufferPointer { stream in
            needle.withUnsafeBufferPointer { pattern in
                let first = pattern[0]
                let last = stream.count - length
                var position = 0
                while position <= last {
                    if stream[position] == first {
                        var offset = 1
                        while offset < length && stream[position + offset] == pattern[offset] { offset += 1 }
                        if offset == length { found.append(position) }
                    }
                    position += 1
                }
            }
        }
        return found
    }

    /// One occurrence: without a hint the first; with one, the first on the hinted page, else the first of those
    /// nearest to it.
    private func preferred(_ starts: [Int], hint: Int?) -> Int? {
        guard let first = starts.first else { return nil }
        guard let hint else { return first }
        var best = first
        var bestDistance = Int.max
        for start in starts {
            let distance = abs(page(ofUnit: start) - hint)
            if distance < bestDistance {
                best = start
                bestDistance = distance
                if distance == 0 { break }
            }
        }
        return best
    }

    /// Step 3: the nearest pair of a head occurrence and a later tail occurrence, at most `limit` units from the start
    /// of the head to the end of the tail. Returns the stream range from head start to tail end.
    private func headAndTail(head: [UInt32], tail: [UInt32], limit: Int, hint: Int?) -> Range<Int>? {
        guard !head.isEmpty, !tail.isEmpty else { return nil }
        let heads = occurrences(of: head)
        guard !heads.isEmpty else { return nil }
        let tails = occurrences(of: tail)
        var best: Range<Int>?
        var next = 0
        for start in heads {
            while next < tails.count && tails[next] < start + head.count { next += 1 }
            guard next < tails.count else { break }
            let match = start..<(tails[next] + tail.count)
            guard match.count <= limit else { continue }
            guard let current = best else {
                best = match
                continue
            }
            if match.count < current.count
                || (match.count == current.count && hint.map { abs(page(ofUnit: start) - $0) < abs(page(ofUnit: current.lowerBound) - $0) } == true) {
                best = match
            }
        }
        return best
    }

    /// Section 6.7, step 1: the first and last pieces of a quote cut at "…", "...", ". . ." or "[...]", folded; nil
    /// unless there are two pieces or more and the first and the last have at least 12 units each.
    static func ellipsisPieces(of quote: String) -> (head: [UInt32], tail: [UInt32])? {
        let characters = Array(quote)
        var pieces: [String] = []
        var current = ""
        var position = 0
        var cut = false
        while position < characters.count {
            if let length = ellipsisLength(in: characters, at: position) {
                pieces.append(current)
                current = ""
                position += length
                cut = true
                continue
            }
            current.append(characters[position])
            position += 1
        }
        pieces.append(current)
        guard cut else { return nil }
        let folded = pieces.map(Folding.fold).filter { !$0.isEmpty }
        guard folded.count >= 2, let head = folded.first, let tail = folded.last, head.count >= 12, tail.count >= 12 else { return nil }
        return (head, tail)
    }

    /// The length of an ellipsis starting at `position`: "…", three or more dots (". . ." included), or either of
    /// those in square brackets.
    private static func ellipsisLength(in characters: [Character], at position: Int) -> Int? {
        let character = characters[position]
        if character == "…" { return 1 }
        if character == "." { return dotsLength(in: characters, at: position) }
        guard character == "[" else { return nil }
        var index = position + 1
        while index < characters.count && characters[index] == " " { index += 1 }
        guard index < characters.count else { return nil }
        if characters[index] == "…" {
            index += 1
        } else if let dots = dotsLength(in: characters, at: index) {
            index += dots
        } else {
            return nil
        }
        while index < characters.count && characters[index] == " " { index += 1 }
        guard index < characters.count, characters[index] == "]" else { return nil }
        return index + 1 - position
    }

    private static func dotsLength(in characters: [Character], at position: Int) -> Int? {
        var index = position
        var dots = 0
        while index < characters.count && characters[index] == "." {
            dots += 1
            index += 1
            if index + 1 < characters.count && characters[index] == " " && characters[index + 1] == "." { index += 1 }
        }
        return dots >= 3 ? index - position : nil
    }

    // MARK: - spans

    /// A stream range as spans: one per line touched, from its first to its last matched character.
    func spans(from start: Int, to end: Int) -> [TextSpan] {
        var result: [TextSpan] = []
        var position = max(0, start)
        let end = min(end, units.count)
        while position < end {
            let line = unitLine[position]
            let lower = unitStart[position]
            var upper = unitEnd[position]
            var next = position + 1
            while next < end && unitLine[next] == line {
                upper = max(upper, unitEnd[next])
                next += 1
            }
            result.append(TextSpan(pageIndex: page(ofUnit: position), range: TextRange(location: lower, length: upper - lower)))
            position = next
        }
        return result
    }
}
