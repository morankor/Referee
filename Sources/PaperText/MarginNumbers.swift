import Foundation
import RefereeCore

/// Section 7.2, step 1: margin line numbers, whether glued to the text lines (`lineno`, Editorial Manager) or standing
/// on lines of their own (a ScholarOne ruler). PDFKit turns both into digits at one end of a line, or a line that is
/// only a number, so one rule set finds both.
///
/// For each page and each of two modes, every non-empty line gives candidates. *Trailing*: every suffix of length 1–4
/// of the run of digits ending the line that does not start with 0 ("…199213" can give 13). *Leading*: a run of 1–4
/// digits starting the line, followed by whitespace, a letter or the end of the line (not "." or ")", which mark a
/// list or a reference number). The longest chain v−1 → v over later and later lines, one value per line, is the page's
/// chain; the page qualifies if it has at least max(5, 40% of its non-empty lines) members. The document has margin
/// numbers in a mode if at least half of its pages with ten or more non-empty lines qualify; with both modes, the one
/// with more chained lines (trailing on a tie).
enum MarginNumbers {
    enum Mode { case trailing, leading }

    /// A chained line: its number, and the scalar range of its text once the digits and the whitespace next to them are
    /// removed.
    struct ChainedLine: Equatable {
        var value: Int
        var content: Range<Int>
    }

    /// For each page (by position), the chained lines by line index; nil when the document has no margin numbers.
    /// `pages[p][l]` is the text of line `l` of page `p` as scalars.
    static func detect(in pages: [[[Unicode.Scalar]]]) -> [[Int: ChainedLine]]? {
        var results: [(chains: [[Int: ChainedLine]], total: Int)] = []
        for mode in [Mode.trailing, .leading] {
            var chains: [[Int: ChainedLine]] = []
            var eligible = 0
            var qualifyingEligible = 0
            var total = 0
            for lines in pages {
                let page = chain(of: lines, mode: mode)
                if page.nonEmpty >= 10 {
                    eligible += 1
                    if page.qualifies { qualifyingEligible += 1 }
                }
                chains.append(page.qualifies ? page.lines : [:])
                if page.qualifies { total += page.lines.count }
            }
            if eligible > 0 && 2 * qualifyingEligible >= eligible {
                results.append((chains, total))
            }
        }
        // `max` keeps the first of equal elements: trailing wins a tie.
        return results.max { $0.total < $1.total }?.chains
    }

    private struct PageChain {
        var lines: [Int: ChainedLine]
        var nonEmpty: Int
        var qualifies: Bool
    }

    private static func chain(of lines: [[Unicode.Scalar]], mode: Mode) -> PageChain {
        struct Node {
            var value: Int
            var line: Int
            var digits: Int
            var length: Int
            var previous: Int       // index in `nodes`, -1 for none
        }
        var nodes: [Node] = []
        var best: [Int: Int] = [:]  // value -> the node ending the longest chain at that value (the earliest of equals)
        var nonEmpty = 0
        for (index, scalars) in lines.enumerated() {
            guard scalars.contains(where: { !Folding.isSpace($0) }) else { continue }
            nonEmpty += 1
            var updates: [(value: Int, node: Int)] = []
            for candidate in candidates(in: scalars, mode: mode) {
                let previous = best[candidate.value - 1] ?? -1
                let length = previous >= 0 ? nodes[previous].length + 1 : 1
                if let existing = best[candidate.value], nodes[existing].length >= length { continue }
                nodes.append(Node(value: candidate.value, line: index, digits: candidate.digits, length: length, previous: previous))
                updates.append((candidate.value, nodes.count - 1))
            }
            for update in updates { best[update.value] = update.node }
        }
        let longest = best.values.max { a, b in
            nodes[a].length != nodes[b].length ? nodes[a].length < nodes[b].length : a > b
        }
        guard let end = longest, Double(nodes[end].length) >= max(5, 0.4 * Double(nonEmpty)) else {
            return PageChain(lines: [:], nonEmpty: nonEmpty, qualifies: false)
        }
        var chained: [Int: ChainedLine] = [:]
        var node = end
        while node >= 0 {
            let member = nodes[node]
            chained[member.line] = ChainedLine(value: member.value,
                                               content: content(of: lines[member.line], digits: member.digits, mode: mode))
            node = member.previous
        }
        return PageChain(lines: chained, nonEmpty: nonEmpty, qualifies: true)
    }

    private static func candidates(in scalars: [Unicode.Scalar], mode: Mode) -> [(value: Int, digits: Int)] {
        switch mode {
        case .trailing:
            var end = scalars.count
            while end > 0 && Folding.isSpace(scalars[end - 1]) { end -= 1 }
            var start = end
            while start > 0 && isDigit(scalars[start - 1]) { start -= 1 }
            guard start < end else { return [] }
            var result: [(value: Int, digits: Int)] = []
            for digits in 1...min(4, end - start) where scalars[end - digits] != "0" {
                result.append((number(scalars[(end - digits)..<end]), digits))
            }
            return result
        case .leading:
            var start = 0
            while start < scalars.count && Folding.isSpace(scalars[start]) { start += 1 }
            var end = start
            while end < scalars.count && isDigit(scalars[end]) { end += 1 }
            let digits = end - start
            guard digits >= 1, digits <= 4, scalars[start] != "0" else { return [] }
            if end < scalars.count {
                let next = scalars[end]
                guard Folding.isSpace(next) || isLetter(next) else { return [] }
            }
            return [(number(scalars[start..<end]), digits)]
        }
    }

    /// The text that remains: without the digits and the whitespace next to them.
    private static func content(of scalars: [Unicode.Scalar], digits: Int, mode: Mode) -> Range<Int> {
        switch mode {
        case .trailing:
            var end = scalars.count
            while end > 0 && Folding.isSpace(scalars[end - 1]) { end -= 1 }
            var cut = end - digits
            while cut > 0 && Folding.isSpace(scalars[cut - 1]) { cut -= 1 }
            return 0..<cut
        case .leading:
            var start = 0
            while start < scalars.count && Folding.isSpace(scalars[start]) { start += 1 }
            var cut = start + digits
            while cut < scalars.count && Folding.isSpace(scalars[cut]) { cut += 1 }
            return cut..<scalars.count
        }
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x30 && scalar.value <= 0x39
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    private static func number(_ digits: ArraySlice<Unicode.Scalar>) -> Int {
        digits.reduce(0) { $0 * 10 + Int($1.value - 0x30) }
    }

    // MARK: - Step 6

    /// Section 7.2, step 6: on each page that has `.marginNumberOnly` lines with bounds, a `.body` line without a number
    /// takes the number of the number-only line whose vertical centre is nearest to its own, if the distance is at most
    /// max(0.75 × its height, 0.55 × the median step between the number-only lines when there are at least three).
    static func assignNearestNumbers(_ pages: inout [PageText]) {
        for position in pages.indices {
            let numbers = pages[position].lines.compactMap { line -> (centre: Double, value: Int)? in
                guard line.kind == .marginNumberOnly, let bounds = line.bounds, let value = line.marginNumber else { return nil }
                return (bounds.y + bounds.height / 2, value)
            }
            guard !numbers.isEmpty else { continue }
            let centres = numbers.map(\.centre).sorted()
            let step = centres.count >= 3 ? Statistics.median(zip(centres, centres.dropFirst()).map { $1 - $0 }) : nil
            for index in pages[position].lines.indices {
                let line = pages[position].lines[index]
                guard line.kind == .body, line.marginNumber == nil, let bounds = line.bounds else { continue }
                let centre = bounds.y + bounds.height / 2
                var nearest = numbers[0]
                for number in numbers.dropFirst() where abs(number.centre - centre) < abs(nearest.centre - centre) {
                    nearest = number
                }
                let tolerance = max(0.75 * bounds.height, 0.55 * (step ?? 0))
                if abs(nearest.centre - centre) <= tolerance {
                    pages[position].lines[index].marginNumber = nearest.value
                }
            }
        }
    }
}

enum Statistics {
    /// The median; the mean of the two middle values for an even count; nil for no values.
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}
