import Foundation
import RefereeCore

/// In-text citations found in the body text outside the reference list (plan.md section 8.4). Mentions come back with
/// spans and no rectangles, source `.textPattern`, in text order, with provisional ids.
enum TextMentionFinder {
    /// What the author–year search needs to know of an entry.
    struct Candidate {
        var id: Int
        var year: Int
        var suffix: String?
        var keys: [[UInt32]]        // longest first
    }

    /// The left context is at most this many folded characters (§8.4 step 3).
    static let contextLimit = 120

    // MARK: Numeric

    /// One mention per number or range inside each bracket ("[1, 5, 3]" gives three, "[3–5]" one with three entries).
    /// A bracket is ignored unless every number in it is between 1 and the number of entries.
    static func numericMentions(in flow: FlowText, entryIDsByLabel: [Int: Int]) -> [CitationMention] {
        let count = entryIDsByLabel.count
        var mentions: [CitationMention] = []
        for bracket in Patterns.numericCitation.all(in: flow.string) {
            let inner = bracket.range(at: 1)
            var items: [(range: NSRange, from: Int, to: Int)] = []
            var valid = true
            for item in Patterns.numericItem.all(in: flow.string, range: inner) {
                guard let from = item.group(1, in: flow.string).flatMap({ Int($0) }) else { valid = false; break }
                let to = item.group(2, in: flow.string).flatMap { Int($0) } ?? from
                if from < 1 || to < from || to > count { valid = false; break }
                items.append((item.range, from, to))
            }
            guard valid, !items.isEmpty else { continue }
            for item in items {
                let start = item.range.location
                let end = item.range.upperBound
                let ids = (item.from...item.to).compactMap { entryIDsByLabel[$0] }
                mentions.append(CitationMention(id: mentions.count, pageIndex: flow.pageIndex(at: start), text: flow.text(from: start, to: end),
                                                spans: flow.spans(from: start, to: end), entryIDs: ids, source: .textPattern))
            }
        }
        return mentions
    }

    // MARK: Author–year

    /// A citation is a year that an entry has, preceded by that entry's authors; nothing is assumed about the words
    /// before the authors ("In Banerjee (1992)", "The Avery and Zemsky (1998) model").
    static func authorYearMentions(in flow: FlowText, candidates: [Candidate]) -> [CitationMention] {
        var byYear: [Int: [Candidate]] = [:]
        for candidate in candidates { byYear[candidate.year, default: []].append(candidate) }
        guard !byYear.isEmpty else { return [] }

        let string = flow.string
        var mentions: [CitationMention] = []
        for match in Patterns.year.all(in: string) {
            guard let year = match.group(1, in: string).flatMap({ Int($0) }), var entries = byYear[year] else { continue }
            if let suffix = match.group(2, in: string), entries.contains(where: { $0.suffix != nil }) {
                entries = entries.filter { $0.suffix == suffix }
                if entries.isEmpty { continue }
            }
            let yearStart = match.range.location
            var context = leftContext(of: flow.units, before: yearStart)
            stripTrailingYears(&context.units)
            var lengths = [context.units.count]
            if endsInPossessive(flow.units, before: yearStart), context.units.last == 0x73 { lengths.append(context.units.count - 1) }   // "s"

            var hits: [(length: Int, start: Int, id: Int)] = []
            for entry in entries {
                for key in entry.keys {
                    for length in lengths where hasSuffix(context.units, end: length, key) {
                        let start = context.positions[length - key.count]
                        if beginsName(in: string, at: start) { hits.append((key.count, start, entry.id)) }
                        break
                    }
                }
            }
            guard let best = hits.map(\.length).max() else { continue }
            let winners = hits.filter { $0.length == best }
            let start = winners.map(\.start).min() ?? yearStart
            let end = match.range.upperBound
            let ids = Array(Set(winners.map(\.id))).sorted()
            mentions.append(CitationMention(id: mentions.count, pageIndex: flow.pageIndex(at: start), text: flow.text(from: start, to: end),
                                            spans: flow.spans(from: start, to: end), entryIDs: ids, source: .textPattern))
        }
        return mentions
    }

    /// The folded characters before `position`, walking left and skipping everything that folds to nothing, at most
    /// `contextLimit` of them, with the position in `string` of the character each came from.
    static func leftContext(of text: [UInt16], before position: Int) -> (units: [UInt32], positions: [Int]) {
        // Filled from the end, so that no reversal is needed; written through buffer pointers because this runs once
        // per year in the text and tests run unoptimised.
        let capacity = contextLimit + 8                     // one scalar folds to a few units at most
        var units = [UInt32](repeating: 0, count: capacity)
        var positions = [Int](repeating: 0, count: capacity)
        var first = capacity
        var buffer: [UInt32] = []
        text.withUnsafeBufferPointer { source in
            units.withUnsafeMutableBufferPointer { out in
                positions.withUnsafeMutableBufferPointer { origin in
                    var cursor = min(position, source.count)
                    while cursor > 0, capacity - first < contextLimit {
                        cursor -= 1
                        let unit = source[cursor]
                        var value = UInt32(unit)
                        if unit < 0x80 {                                   // ASCII: letters and digits, lower-cased
                            if value >= 0x41 && value <= 0x5A {
                                value += 0x20
                            } else if !((value >= 0x61 && value <= 0x7A) || (value >= 0x30 && value <= 0x39)) {
                                continue
                            }
                            first -= 1
                            out[first] = value
                            origin[first] = cursor
                            continue
                        }
                        if UTF16.isTrailSurrogate(unit), cursor > 0, UTF16.isLeadSurrogate(source[cursor - 1]) {
                            cursor -= 1
                            value = 0x10000 + ((UInt32(source[cursor]) - 0xD800) << 10) + (value - 0xDC00)
                        }
                        guard let scalar = Unicode.Scalar(value) else { continue }
                        buffer.removeAll(keepingCapacity: true)
                        Folding.fold(scalar, into: &buffer)
                        for folded in buffer.reversed() where first > 0 {
                            first -= 1
                            out[first] = folded
                            origin[first] = cursor
                        }
                    }
                }
            }
        }
        return (Array(units[first...]), Array(positions[first...]))
    }

    /// Whether `units[..<end]` ends with `key`.
    static func hasSuffix(_ units: [UInt32], end: Int, _ key: [UInt32]) -> Bool {
        let start = end - key.count
        guard !key.isEmpty, start >= 0, end <= units.count else { return false }
        return units.withUnsafeBufferPointer { u in
            key.withUnsafeBufferPointer { k in
                var i = 0
                while i < k.count {
                    if u[start + i] != k[i] { return false }
                    i += 1
                }
                return true
            }
        }
    }

    /// Removes years at the end of a folded context, so that in "Smith (2019, 2021)" the second year has the same
    /// authors as the first.
    static func stripTrailingYears(_ units: inout [UInt32]) {
        func isYear(_ digits: ArraySlice<UInt32>) -> Bool {
            guard digits.count == 4, digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return false }
            let a = digits[digits.startIndex], b = digits[digits.startIndex + 1]
            return (a == 0x31 && (b == 0x38 || b == 0x39)) || (a == 0x32 && b == 0x30)
        }
        while true {
            let n = units.count
            if n >= 5, units[n - 1] >= 0x61, units[n - 1] <= 0x7A, isYear(units[(n - 5)..<(n - 1)]) {
                units.removeLast(5)
            } else if n >= 4, isYear(units[(n - 4)..<n]) {
                units.removeLast(4)
            } else {
                return
            }
        }
    }

    /// The raw text just before the year ends in "'s" or "’s", brackets and spaces aside ("Banerjee's (1992)").
    static func endsInPossessive(_ text: [UInt16], before position: Int) -> Bool {
        var i = min(position, text.count) - 1
        while i >= 0 {
            let unit = text[i]
            if unit == 0x28 || unit == 0x5B || BodyText.isSpace(unit) { i -= 1 } else { break }
        }
        guard i >= 1, text[i] == 0x73 || text[i] == 0x53 else { return false }     // s, S
        return text[i - 1] == 0x27 || text[i - 1] == 0x2019                        // ' ’
    }

    /// A key may begin at an upper-case letter, or after a character that is not a letter. This keeps "employee (2021)"
    /// from citing Lee (2021) while accepting "followsBikhchandanietal.(1992)".
    static func beginsName(in string: NSString, at position: Int) -> Bool {
        if let scalar = Folding.scalar(at: position, in: string), Folding.isUppercase(scalar) { return true }
        guard let previous = Folding.scalar(before: position, in: string) else { return true }
        guard let scalar = previous.scalar else { return true }
        return !Folding.isLetter(scalar)
    }
}
