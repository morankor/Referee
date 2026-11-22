import Foundation
import RefereeCore

/// Section 6.7, step 4: fuzzy matching on tokens.
///
/// At least 6 quote tokens. The five quote tokens rarest in the document (length ≥ 4, not all digits, present in the
/// document) give at most 200 candidate alignments; each is scored on the window of document tokens that would hold
/// the whole quote, with a slack of 3 tokens before and 3 + n/4 after: score = LCS(quote tokens, window) / n. The best
/// score of at least 0.75 with at least 5 matched tokens wins; among scores within 0.05 of the best, a candidate on the
/// hinted page is preferred. The match is trimmed to the first and last matched tokens.
extension QuoteIndex {
    struct FuzzyMatch {
        var units: Range<Int>
        var score: Double
    }

    /// `quoteTokens` are document token ids, -1 for a token the document does not have.
    func fuzzyMatch(quoteTokens: [Int], hint: Int?) -> FuzzyMatch? {
        let n = quoteTokens.count
        guard n >= 6, !tokens.isEmpty else { return nil }

        // The five rarest usable quote tokens, each with its first position in the quote.
        var seen = Set<Int>()
        var usable: [(id: Int, position: Int)] = []
        for (position, id) in quoteTokens.enumerated() where id >= 0 && seen.insert(id).inserted {
            if idLength[id] >= 4 && !idIsNumber[id] { usable.append((id, position)) }
        }
        usable.sort { a, b in
            if postings[a.id].count != postings[b.id].count { return postings[a.id].count < postings[b.id].count }
            if idLength[a.id] != idLength[b.id] { return idLength[a.id] > idLength[b.id] }
            return a.position < b.position
        }
        let rarest = usable.prefix(5)
        guard !rarest.isEmpty else { return nil }

        // Candidate alignments: the document token where the quote would start, and the page of the occurrence.
        var alignments: [(start: Int, page: Int)] = []
        var tried = Set<Int>()
        candidates: for token in rarest {
            for occurrence in postings[token.id] {
                let start = occurrence - token.position
                guard tried.insert(start).inserted else { continue }
                alignments.append((start, page(ofUnit: tokenFirstUnit[occurrence])))
                if alignments.count == 200 { break candidates }
            }
        }

        // A window can match at most as many tokens as it has tokens of the quote: a window that cannot reach the
        // threshold is not scored (the result is the same, and most windows are such).
        let needed = max(5, Int((0.75 * Double(n)).rounded(.up)))
        var inQuote = [Bool](repeating: false, count: postings.count)
        for id in quoteTokens where id >= 0 { inQuote[id] = true }
        let after = 3 + n / 4
        var scored: [(window: Range<Int>, matched: Int, page: Int)] = []
        for alignment in alignments {
            let window = max(0, alignment.start - 3)..<min(tokens.count, alignment.start + n + after)
            guard window.count >= needed else { continue }
            var bound = 0
            for position in window where inQuote[tokens[position]] { bound += 1 }
            guard bound >= needed else { continue }
            let matched = Self.lcsLength(quoteTokens, tokens[window])
            if matched >= 5 && Double(matched) >= 0.75 * Double(n) {
                scored.append((window, matched, alignment.page))
            }
        }
        guard let best = scored.max(by: { $0.matched < $1.matched }) else { return nil }
        var chosen = scored.first { $0.matched == best.matched } ?? best
        if let hint {
            let close = scored.filter { $0.page == hint && Double(best.matched - $0.matched) <= 0.05 * Double(n) }
            if let onHint = close.max(by: { $0.matched < $1.matched }) {
                chosen = close.first { $0.matched == onHint.matched } ?? onHint
            }
        }

        // Trim to the first and last matched tokens: the shortest end that keeps the whole common subsequence, then the
        // latest start that does.
        let window = Array(tokens[chosen.window])
        let forward = Self.lcsPrefixLengths(quoteTokens, window[...])
        guard let endCount = forward.firstIndex(of: chosen.matched), endCount > 0 else { return nil }
        let backward = Self.lcsPrefixLengths(Array(quoteTokens.reversed()), Array(window[0..<endCount].reversed())[...])
        guard let startCount = backward.firstIndex(of: chosen.matched) else { return nil }
        let firstToken = chosen.window.lowerBound + endCount - startCount
        let lastToken = chosen.window.lowerBound + endCount - 1
        return FuzzyMatch(units: tokenFirstUnit[firstToken]..<tokenEndUnit[lastToken],
                          score: Double(chosen.matched) / Double(n))
    }

    /// The length of a longest common subsequence of `a` and `b`.
    static func lcsLength(_ a: [Int], _ b: ArraySlice<Int>) -> Int {
        lcsPrefixLengths(a, b).last ?? 0
    }

    /// result[j] = LCS(a, the first j elements of b), for j in 0...b.count.
    static func lcsPrefixLengths(_ a: [Int], _ b: ArraySlice<Int>) -> [Int] {
        let n = a.count
        var result = [Int](repeating: 0, count: b.count + 1)
        guard n > 0 else { return result }
        var column = [Int](repeating: 0, count: n + 1)
        a.withUnsafeBufferPointer { a in
            column.withUnsafeMutableBufferPointer { column in
                var j = 1
                for element in b {
                    var diagonal = 0          // the value of column[i - 1] before this element
                    for i in 1...n {
                        let above = column[i]
                        if a[i - 1] == element {
                            column[i] = diagonal + 1
                        } else if column[i - 1] > above {
                            column[i] = column[i - 1]
                        }
                        diagonal = above
                    }
                    result[j] = column[n]
                    j += 1
                }
            }
        }
        return result
    }
}
