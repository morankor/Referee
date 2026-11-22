import Foundation
import RefereeCore
import PaperText
import TestSupport

/// Shared by the PaperText test suites: fixture papers, line lookup, and synthetic documents.
enum PaperTextSample {
    /// The fixtures whose raw dumps the tests read (Fixtures/raw/<name>.raw.json).
    static let journalStamped = ["ay_nolinks", "s1_ruler"]
    static let unnumbered = ["ay_links", "ay_round_nolinks", "num_links", "num_twocol_links"]

    static func raw(_ name: String) throws -> RawDocument {
        try Fixtures.rawDocument(name)
    }

    /// The fixture cleaned by the real builder.
    static func paper(_ name: String, strip: Bool = true) throws -> PaperText {
        PaperTextBuilder(stripMarginLineNumbers: { strip }).build(from: try raw(name))
    }

    /// The first line (any kind) of the page at `position` whose text, trimmed, starts with `prefix`.
    static func line(_ paper: PaperText, page position: Int, startingWith prefix: String) -> TextLine? {
        guard paper.pages.indices.contains(position) else { return nil }
        return paper.pages[position].lines.first { trimmed($0.text).hasPrefix(prefix) }
    }

    /// The first line anywhere whose text, trimmed, starts with `prefix`.
    static func line(_ paper: PaperText, startingWith prefix: String) -> TextLine? {
        for page in paper.pages {
            if let line = page.lines.first(where: { trimmed($0.text).hasPrefix(prefix) }) { return line }
        }
        return nil
    }

    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The text of a span: the page string at its UTF-16 range.
    static func text(of span: TextSpan, in paper: PaperText) -> String? {
        guard let page = paper.pages.first(where: { $0.index == span.pageIndex }) else { return nil }
        let string = page.string as NSString
        guard span.range.location >= 0, span.range.upperBound <= string.length else { return nil }
        return string.substring(with: span.range.nsRange)
    }

    /// A rough folding for test expectations on ASCII-like text: lower-case letters and digits only.
    static func letters(_ text: String) -> String {
        String(String.UnicodeScalarView(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    /// For each span, the body lines whose content range holds it entirely.
    static func bodyLines(holding span: TextSpan, in paper: PaperText) -> [TextLine] {
        guard let page = paper.pages.first(where: { $0.index == span.pageIndex }) else { return [] }
        return page.lines.filter { line in
            line.kind == .body && line.contentRange.location <= span.range.location
                && span.range.upperBound <= line.contentRange.upperBound
        }
    }

    // MARK: - Synthetic documents

    /// A raw page whose lines are the given texts, one per line of the page string, with bounds `pitch` points apart
    /// from the top (none when `pitch` is nil).
    static func rawPage(index: Int, lines texts: [String], pitch: Double? = 14, height: Double = 10, top: Double = 700) -> RawPage {
        var lines: [RawLine] = []
        var location = 0
        for (number, text) in texts.enumerated() {
            let length = text.utf16.count
            let bounds = pitch.map { PageRect(pageIndex: index, x: 72, y: top - Double(number) * $0, width: 400, height: height) }
            lines.append(RawLine(range: TextRange(location: location, length: length), text: text, bounds: bounds))
            location += length + 1
        }
        return RawPage(index: index, size: PageSize(width: 612, height: 792), string: texts.joined(separator: "\n"), lines: lines)
    }

    /// A clean paper (every line `.body`, `contentRange == range`) from pages of line texts.
    static func plainPaper(_ pages: [[String]], pitch: Double? = 14) -> PaperText {
        identityPaperText(from: RawDocument(pages: pages.enumerated().map { rawPage(index: $0.offset, lines: $0.element, pitch: pitch) }))
    }
}

/// A seeded generator, so that "random" test documents are the same on every run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
