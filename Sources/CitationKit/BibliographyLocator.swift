import Foundation
import RefereeCore

/// The reference list as found among the body lines (plan.md section 8.2). Line numbers are indices into
/// `BodyText.lines`.
struct ReferenceList {
    struct Entry {
        var lines: Range<Int>
        var label: Int?             // numeric lists: the entry's number
    }

    var style: CitationStyle        // .numeric or .authorYear
    var heading: Int
    var end: Int                    // the first line after the list
    var hanging: Bool
    var entries: [Entry]

    /// Every line from the one after the heading to the end of the list.
    var lines: Range<Int> { (heading + 1)..<end }
}

/// Finds the heading of the reference list, decides its style, splits it into entries and decides where it ends
/// (plan.md section 8.2). Ending too early loses every later entry, so the list ends only on positive evidence of a
/// line that is not a reference.
enum BibliographyLocator {
    static func locate(in body: BodyText) -> ReferenceList? {
        guard let heading = body.lines.lastIndex(where: isHeading), heading + 1 < body.lines.count else { return nil }
        return Walk(lines: body.lines, heading: heading).run()
    }

    /// §8.2 step 1, on a body line.
    static func isHeading(_ line: BodyLine) -> Bool {
        line.trimmedLength <= 64 && Patterns.heading.matches(line.text)
    }

    /// The number of a line that starts like a numbered entry ("[12] …", "12. …"), if it does.
    static func numberLabel(_ text: String) -> Int? {
        let ns = text as NSString
        guard let match = Patterns.numberLabel.first(in: ns) else { return nil }
        return (match.group(1, in: ns) ?? match.group(2, in: ns)).flatMap { Int($0) }
    }

    /// The median of the heights seen so far, kept in a sorted array.
    struct RunningMedian {
        private var sorted: [Double] = []

        mutating func insert(_ value: Double) {
            var low = 0
            var high = sorted.count
            while low < high {
                let mid = (low + high) / 2
                if sorted[mid] < value { low = mid + 1 } else { high = mid }
            }
            sorted.insert(value, at: low)
        }

        var median: Double? {
            guard !sorted.isEmpty else { return nil }
            let n = sorted.count
            return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
        }
    }

    /// One pass over the lines after the heading: style, left edge, entry starts and the end of the list.
    private final class Walk {
        let lines: [BodyLine]
        let heading: Int
        let first: Int
        let numeric: Bool
        private var leftEdge: [Int: Double] = [:]
        private(set) var hanging = false
        private var entryLikeCache: [Int: Bool] = [:]

        init(lines: [BodyLine], heading: Int) {
            self.lines = lines
            self.heading = heading
            self.first = heading + 1
            // Step 2: numeric if the first line after the heading is numbered, or at least three of the first ten.
            let firstTen = first..<min(first + 10, lines.count)
            let numbered = firstTen.filter { BibliographyLocator.numberLabel(lines[$0].text) != nil }.count
            self.numeric = BibliographyLocator.numberLabel(lines[first].text) != nil || numbered >= 3
            // Step 3: the left edge per page is the 10th percentile of x over the lines after the heading on that page.
            var xs: [Int: [Double]] = [:]
            for i in first..<lines.count {
                if let b = lines[i].bounds { xs[lines[i].pageIndex, default: []].append(b.x) }
            }
            for (page, values) in xs {
                let sorted = values.sorted()
                leftEdge[page] = sorted[Int(0.1 * Double(sorted.count - 1))]
            }
            let probe = first..<min(first + 40, lines.count)
            let indented = probe.filter { lines[$0].bounds != nil && !isAtLeftEdge($0) }.count
            hanging = Double(indented) >= 0.2 * Double(probe.count)
        }

        func isAtLeftEdge(_ i: Int) -> Bool {
            guard let b = lines[i].bounds, let x0 = leftEdge[lines[i].pageIndex] else { return false }
            return b.x <= x0 + 2
        }

        /// Step 4: the first 240 characters of the line and its next two contain a year or a publication status.
        func isEntryLike(_ i: Int) -> Bool {
            if let known = entryLikeCache[i] { return known }
            var text = lines[i].trimmed
            for next in (i + 1)..<min(i + 3, lines.count) { text += " " + lines[next].trimmed }
            let window = String(text.prefix(240))
            let result = Patterns.year.matches(window) || Patterns.status.matches(window)
            entryLikeCache[i] = result
            return result
        }

        /// A keyword line (step 5 a): it matches KEY and contains no year and no comma.
        func isKeywordLine(_ text: String) -> Bool {
            Patterns.keyword.matches(text) && !Patterns.year.matches(text) && !text.contains(",")
        }

        /// An author–year entry that does not hang begins with an upper-case letter, or with name particles before one
        /// ("van der Berg, J. (2005)").
        func beginsLikeAName(_ text: String) -> Bool {
            var words = text.split(separator: " ", omittingEmptySubsequences: true)[...]
            while let word = words.first, words.count > 1, EntryParser.particles.contains(String(word)) { words = words.dropFirst() }
            return words.first?.unicodeScalars.first.map(Folding.isUppercase) ?? false
        }

        /// The line before an author–year entry that does not hang ends in ".", ")", a digit or a URL.
        func endsAnEntry(_ text: String) -> Bool {
            guard let last = text.unicodeScalars.last else { return false }
            if last == "." || last == ")" || ("0"..."9").contains(last) { return true }
            return Patterns.urlAtEnd.matches(text)
        }

        func run() -> ReferenceList? {
            var starts: [(line: Int, label: Int?)] = []
            var end = lines.count
            var nextNumber = 1
            var heights = RunningMedian()
            var leftmost: [Int: Double] = [:]          // leftmost x of the list's lines so far, per page

            for k in first..<lines.count {
                let line = lines[k]
                let text = line.trimmed
                let started = starts.count >= 3

                // (b) Back to an earlier column.
                if started, let b = line.bounds, let minX = leftmost[line.pageIndex], b.x < minX - 40 { end = k; break }

                var isStart = false
                var label: Int?
                if numeric {
                    if let n = BibliographyLocator.numberLabel(line.text), n == nextNumber { isStart = true; label = n }
                } else if hanging {
                    isStart = isAtLeftEdge(k)
                } else {
                    let follows = k == first || endsAnEntry(lines[k - 1].trimmed)
                    isStart = follows && beginsLikeAName(text) && isEntryLike(k)
                }

                if started {
                    // (a) A heading: a short line that is not the next numbered entry.
                    if text.unicodeScalars.count <= 60, !(numeric && isStart) {
                        let height = line.bounds?.height
                        let median = heights.median
                        let taller = height != nil && median != nil && height! >= 1.15 * median!
                        let keyword = isKeywordLine(text)
                        if taller && (!isEntryLike(k) || keyword || Patterns.letteredHeading.matches(text)) { end = k; break }
                        if keyword && (isAtLeftEdge(k) || !hanging || height == nil || median == nil) { end = k; break }
                    }
                    // (c) Ordinary text: two lines at the left edge in a row that are not entries (hanging lists only).
                    if hanging, isAtLeftEdge(k), !(numeric ? isStart : isEntryLike(k)), k + 1 < lines.count, isAtLeftEdge(k + 1) {
                        let nextIsEntry = numeric ? BibliographyLocator.numberLabel(lines[k + 1].text) == nextNumber : isEntryLike(k + 1)
                        if !nextIsEntry { end = k; break }
                    }
                }

                if isStart {
                    starts.append((k, label))
                    if numeric { nextNumber += 1 }
                }
                if let b = line.bounds {
                    heights.insert(b.height)
                    leftmost[line.pageIndex] = min(leftmost[line.pageIndex] ?? b.x, b.x)
                }
            }

            // Step 6: fewer than three entries is not a reference list.
            guard starts.count >= 3 else { return nil }
            var entries: [ReferenceList.Entry] = []
            for (i, start) in starts.enumerated() {
                let upper = i + 1 < starts.count ? starts[i + 1].line : end
                entries.append(ReferenceList.Entry(lines: start.line..<upper, label: start.label))
            }
            return ReferenceList(style: numeric ? .numeric : .authorYear, heading: heading, end: end, hanging: hanging, entries: entries)
        }
    }
}
