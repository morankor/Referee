import Foundation
import RefereeCore

/// One `.body` line of the paper that has text. Its UTF-16 offsets are those of its own `text`; `location` turns them
/// into offsets in the page string.
struct BodyLine {
    let pageIndex: Int
    let text: String              // TextLine.text, the page string over contentRange
    let length: Int               // UTF-16 length of `text`
    let location: Int             // contentRange.location
    let bounds: PageRect?
    let trimmed: String           // `text` without leading and trailing white space
    let trimmedOffset: Int        // UTF-16 offset of `trimmed` in `text`
    let trimmedLength: Int

    /// The line's text without surrounding white space, in page-string coordinates.
    var span: TextSpan {
        TextSpan(pageIndex: pageIndex, range: TextRange(location: location + trimmedOffset, length: trimmedLength))
    }
}

/// The body lines of a paper in document order: pages in order, lines in `PageText.lines` order (PDFKit's order).
/// Lines of every other kind, and lines that are empty or only white space, are left out.
struct BodyText {
    let lines: [BodyLine]
    /// For each page index, the indices in `lines` of that page's lines, in order.
    let linesByPage: [Int: [Int]]

    init(paper: PaperText) {
        var lines: [BodyLine] = []
        var byPage: [Int: [Int]] = [:]
        for page in paper.pages {
            for line in page.lines where line.kind == .body {
                let ns = line.text as NSString
                var start = 0
                var end = ns.length
                while start < end, BodyText.isSpace(ns.character(at: start)) { start += 1 }
                while end > start, BodyText.isSpace(ns.character(at: end - 1)) { end -= 1 }
                guard end > start else { continue }
                byPage[page.index, default: []].append(lines.count)
                lines.append(BodyLine(pageIndex: page.index, text: line.text, length: ns.length, location: line.contentRange.location,
                                      bounds: line.bounds, trimmed: ns.substring(with: NSRange(location: start, length: end - start)),
                                      trimmedOffset: start, trimmedLength: end - start))
            }
        }
        self.lines = lines
        self.linesByPage = byPage
    }

    static func isSpace(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// An estimate of the page-string offset under a point of a page, for ordering mentions that have only a rectangle:
    /// the line nearest to the point (vertically first, then horizontally), and the position along it in proportion.
    func estimatedOffset(pageIndex: Int, x: Double, y: Double) -> Int? {
        guard let indices = linesByPage[pageIndex] else { return nil }
        var best: (vertical: Double, horizontal: Double, line: Int)?
        for i in indices {
            guard let b = lines[i].bounds else { continue }
            let vertical = max(0, abs(y - (b.y + b.height / 2)) - b.height / 2)
            let horizontal = max(0, b.x - x, x - (b.x + b.width))
            if let current = best, (current.vertical, current.horizontal) <= (vertical, horizontal) { continue }
            best = (vertical, horizontal, i)
        }
        guard let chosen = best else { return nil }
        let line = lines[chosen.line]
        guard let b = line.bounds, b.width > 0 else { return line.location }
        let fraction = (x - b.x) / b.width
        guard fraction.isFinite else { return line.location }
        return line.location + Int((min(1, max(0, fraction)) * Double(line.length)).rounded(.down))
    }
}

/// Body lines joined into one character sequence with a line break between lines, and the way back from a position in
/// it to a page and an offset in that page's string (§8.4).
struct FlowText {
    let string: NSString
    let lines: [BodyLine]
    private let starts: [Int]       // position of each line's first unit in `string`

    init(lines: [BodyLine]) {
        let joined = NSMutableString()
        var starts: [Int] = []
        starts.reserveCapacity(lines.count)
        for (i, line) in lines.enumerated() {
            if i > 0 { joined.append("\n") }
            starts.append(joined.length)
            joined.append(line.text)
        }
        self.string = joined
        self.lines = lines
        self.starts = starts
    }

    /// The line that holds `position`; for a line break, the line before it.
    func lineIndex(at position: Int) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= position { low = mid } else { high = mid - 1 }
        }
        return low
    }

    func pageIndex(at position: Int) -> Int { lines[lineIndex(at: position)].pageIndex }

    /// One span per line touched by [start, end), from its first to its last character on that line.
    func spans(from start: Int, to end: Int) -> [TextSpan] {
        guard end > start, !lines.isEmpty else { return [] }
        var result: [TextSpan] = []
        var i = lineIndex(at: start)
        while i < lines.count, starts[i] < end {
            let lineStart = starts[i]
            let lower = max(start, lineStart)
            let upper = min(end, lineStart + lines[i].length)
            if upper > lower {
                result.append(TextSpan(pageIndex: lines[i].pageIndex,
                                       range: TextRange(location: lines[i].location + lower - lineStart, length: upper - lower)))
            }
            i += 1
        }
        return result
    }

    /// The characters of [start, end), line breaks as spaces.
    func text(from start: Int, to end: Int) -> String {
        string.substring(with: NSRange(location: start, length: end - start)).replacingOccurrences(of: "\n", with: " ")
    }
}
