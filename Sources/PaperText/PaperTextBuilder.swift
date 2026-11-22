import Foundation
import RefereeCore

/// The cleaning of plan section 7.2: classifies every raw line, finds and strips margin line numbers, and marks page
/// furniture. Pure: the result depends on the raw document (and the setting) only.
///
/// Of a raw line's bounds only `y` and `height` are used: `x` and `width` are wrong for every line with margin digits
/// glued to it. `TextLine.bounds` stays the raw bounds; `PDFPaperService` recomputes them where `contentRange != range`.
public struct PaperTextBuilder: PaperTextBuilding {
    private let stripMarginLineNumbers: @Sendable () -> Bool

    /// `stripMarginLineNumbers` is read once per `build`; false (Settings ▸ Advanced, "Never") skips step 1, so no
    /// line loses characters, no line is `.marginNumberOnly` and `hasMarginLineNumbers` is false.
    public init(stripMarginLineNumbers: @escaping @Sendable () -> Bool = { true }) {
        self.stripMarginLineNumbers = stripMarginLineNumbers
    }

    public func build(from raw: RawDocument) -> PaperText {
        var pages = raw.pages.map { page in
            PageText(index: page.index, label: page.label, size: page.size, string: page.string,
                     lines: page.lines.map { line in
                         TextLine(pageIndex: page.index, range: line.range, contentRange: line.range, text: line.text, kind: .body,
                                  bounds: line.bounds)
                     })
        }

        // Step 1: margin numbers.
        var foundMarginNumbers = false
        if stripMarginLineNumbers() {
            let scalars = raw.pages.map { page in page.lines.map { Array($0.text.unicodeScalars) } }
            if let chains = MarginNumbers.detect(in: scalars) {
                foundMarginNumbers = true
                for (position, chain) in chains.enumerated() {
                    for (index, chained) in chain {
                        Self.strip(&pages[position].lines[index], scalars: scalars[position][index], keeping: chained)
                    }
                }
            }
        }

        // Step 5, first: whitespace-only lines are `.empty` (steps 2–4 would never take them).
        for position in pages.indices {
            for index in pages[position].lines.indices where pages[position].lines[index].kind == .body {
                if !pages[position].lines[index].text.unicodeScalars.contains(where: { !Folding.isSpace($0) }) {
                    pages[position].lines[index].kind = .empty
                }
            }
        }

        // Steps 2–4: boilerplate, page numbers, repeated lines. What is still `.body` after them is the text (step 5).
        PageFurniture.classify(&pages)

        // Step 6: a number for body lines that have none.
        MarginNumbers.assignNearestNumbers(&pages)

        // Step 7.
        return PaperText(pages: pages, hasTextLayer: Self.hasTextLayer(raw), hasMarginLineNumbers: foundMarginNumbers,
                         titleGuess: Self.titleGuess(pages))
    }

    /// A chained line keeps the text around its number; a line left empty is `.marginNumberOnly`.
    private static func strip(_ line: inout TextLine, scalars: [Unicode.Scalar], keeping chained: MarginNumbers.ChainedLine) {
        var utf16Offset = 0
        var startOffset = 0
        var endOffset = 0
        for (position, scalar) in scalars.enumerated() {
            if position == chained.content.lowerBound { startOffset = utf16Offset }
            if position == chained.content.upperBound { endOffset = utf16Offset }
            utf16Offset += scalar.utf16.count
        }
        if chained.content.lowerBound >= scalars.count { startOffset = utf16Offset }
        if chained.content.upperBound >= scalars.count { endOffset = utf16Offset }
        line.contentRange = TextRange(location: line.range.location + startOffset, length: max(0, endOffset - startOffset))
        var text = String.UnicodeScalarView()
        text.append(contentsOf: scalars[chained.content])
        line.text = String(text)
        line.marginNumber = chained.value
        if chained.content.isEmpty { line.kind = .marginNumberOnly }
    }

    /// Step 7: a text layer has at least 200 letters in the whole document.
    static func hasTextLayer(_ raw: RawDocument) -> Bool {
        var letters = 0
        for page in raw.pages {
            for character in page.string where character.isLetter {
                letters += 1
                if letters >= 200 { return true }
            }
        }
        return false
    }

    /// Step 7: among the first 15 body lines of page 1, the consecutive lines with the tallest bounds, joined with a
    /// space; nil when no line has bounds. Heights within max(0.5 pt, 2%) of the tallest count as the tallest.
    static func titleGuess(_ pages: [PageText]) -> String? {
        guard let page = pages.first else { return nil }
        let lines = page.lines.filter { $0.kind == .body }.prefix(15)
        guard let tallest = lines.compactMap({ $0.bounds?.height }).max(), tallest > 0 else { return nil }
        let tolerance = max(0.5, 0.02 * tallest)
        var parts: [String] = []
        for line in lines {
            if let height = line.bounds?.height, height >= tallest - tolerance {
                parts.append(PageFurniture.collapsingWhitespace(line.text))
            } else if !parts.isEmpty {
                break
            }
        }
        let title = parts.filter { !$0.isEmpty }.joined(separator: " ")
        return title.isEmpty ? nil : title
    }
}
