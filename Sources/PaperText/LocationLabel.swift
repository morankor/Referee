import Foundation
import RefereeCore

/// Section 6.7, "Label": where a passage is, in the form a referee writes in a report. Pages are 1-based; line numbers
/// are the `marginNumber` of the first and the last line touched; dashes are en dashes.
///
/// | Case | Label |
/// |---|---|
/// | one page, both numbers known, equal | `p. A, line a` |
/// | one page, both known, different | `p. A, lines a–b` |
/// | one page, a number unknown | `p. A` |
/// | two pages, both known | `pp. A–B (p. A line a to p. B line b)` |
/// | two pages otherwise | `pp. A–B` |
extension QuoteIndex {
    func locationLabel(for spans: [TextSpan]) -> String {
        let ordered = spans.sorted { ($0.pageIndex, $0.range.location) < ($1.pageIndex, $1.range.location) }
        guard let first = ordered.first, let last = ordered.last else { return "" }
        let pageA = first.pageIndex + 1
        let pageB = last.pageIndex + 1
        let numberA = marginNumber(touchedBy: first, firstLine: true)
        let numberB = marginNumber(touchedBy: last, firstLine: false)
        if pageA == pageB {
            guard let a = numberA, let b = numberB else { return "p. \(pageA)" }
            return a == b ? "p. \(pageA), line \(a)" : "p. \(pageA), lines \(a)–\(b)"
        }
        guard let a = numberA, let b = numberB else { return "pp. \(pageA)–\(pageB)" }
        return "pp. \(pageA)–\(pageB) (p. \(pageA) line \(a) to p. \(pageB) line \(b))"
    }

    /// The margin number of the first (or last) line of the span's page that the span touches: a `.body` line whose
    /// content it meets, else any line whose range it meets.
    private func marginNumber(touchedBy span: TextSpan, firstLine: Bool) -> Int? {
        guard let position = positionOfPage[span.pageIndex] else { return nil }
        let lines = pages[position].lines
        let body = lines.filter { $0.kind == .body && Self.meets(span.range, $0.contentRange) }
        let touched = body.isEmpty ? lines.filter { Self.meets(span.range, $0.range) } : body
        return (firstLine ? touched.first : touched.last)?.marginNumber
    }

    /// (`RefereeCore.` because Foundation on macOS 26 has a `TextRange` of its own.)
    private static func meets(_ span: RefereeCore.TextRange, _ line: RefereeCore.TextRange) -> Bool {
        if span.length <= 0 { return span.location >= line.location && span.location <= line.upperBound }
        return max(span.location, line.location) < min(span.upperBound, line.upperBound)
    }
}
