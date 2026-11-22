import Foundation
import RefereeCore

/// The text sent to a model in text mode (plan section 6.2): prose joined into paragraph-like lines, headings, table
/// rows and equation fragments on lines of their own, words joined again where a line break hyphenated them, and one
/// "[[page N]]" marker line per page (N = the page's index + 1), never in the middle of a sentence.
///
/// Rules (text and vertical positions only):
/// 1. Only `.body` lines, pages in order, lines in `PageText.lines` order.
/// 2. A line is *full* if its length is at least 0.75 × the median length of the page's body lines of 25 or more
///    characters (a page with fewer than five such lines has no full lines).
/// 3. A line joins the line before it, with one space, iff that line is full and the two are at normal pitch: both
///    have bounds and the vertical distance between them is positive and at most 1.3 × the page's median distance
///    between consecutive body lines (without bounds the pitch test is skipped; across a page break it does not apply).
/// 4. Joining "predeces-" and "sors" gives "predecessors", unless the hyphenated word occurs unbroken elsewhere in the
///    document and the joined word does not.
/// 5. A run still open at a page break continues; it is cut after the first sentence end within 400 characters after
///    the break, the marker follows, and the rest of the run starts a new line. With no sentence end, the marker goes
///    after the whole run.
public struct PaperRenderer: PaperRendering {
    public init() {}

    /// `pages` is a range of positions in `paper.pages` (nil = all), cut to the paper. Every line ends with "\n"; no
    /// pages give "".
    public func render(_ paper: PaperText, pages: Range<Int>?) -> String {
        RenderSession(paper: paper).render(pages ?? paper.pages.indices)
    }

    /// Consecutive ranges of whole pages that cover the paper, each rendering to at most `maxCharacters` characters
    /// unless it is a single page. Greedy: a range grows while it fits.
    public func chunkPageRanges(_ paper: PaperText, maxCharacters: Int) -> [Range<Int>] {
        let session = RenderSession(paper: paper)
        let count = paper.pages.count
        guard count > 0 else { return [] }
        let single = (0..<count).map { session.render($0..<($0 + 1)).count }
        var ranges: [Range<Int>] = []
        var start = 0
        while start < count {
            var end = start + 1
            var size = single[start]
            while end < count {
                // Rendering two ranges together is never longer than rendering them apart (a join at the page break
                // only replaces a line break by a space or drops a hyphen), so the sum is a safe first test.
                let bound = size + single[end]
                if bound <= maxCharacters {
                    size = bound
                    end += 1
                    continue
                }
                let actual = session.render(start..<(end + 1)).count
                guard actual <= maxCharacters else { break }
                size = actual
                end += 1
            }
            // The guarantee does not rest on the argument above: a range that does not fit loses pages from its end.
            while end - start > 1 && session.render(start..<end).count > maxCharacters { end -= 1 }
            ranges.append(start..<end)
            start = end
        }
        return ranges
    }
}

/// One rendering job over one paper: the pages prepared once, and the document's words for rule 4, built when first
/// needed.
final class RenderSession {
    private let paper: PaperText
    private var prepared: [Int: RenderPage] = [:]
    private var lexicon: HyphenationLexicon?

    init(paper: PaperText) {
        self.paper = paper
    }

    func render(_ positions: Range<Int>) -> String {
        let selected = positions.clamped(to: paper.pages.indices)
        var writer = RunWriter()
        for position in selected {
            writer.add(page(at: position)) { self.hyphenationLexicon() }
        }
        return writer.finish()
    }

    private func page(at position: Int) -> RenderPage {
        if let known = prepared[position] { return known }
        let page = RenderPage(paper.pages[position])
        prepared[position] = page
        return page
    }

    private func hyphenationLexicon() -> HyphenationLexicon {
        if let lexicon { return lexicon }
        let built = HyphenationLexicon(paper: paper)
        lexicon = built
        return built
    }
}

/// A page as the rules see it: its marker, its non-empty body lines (trimmed, line breaks inside a line as spaces),
/// which of them are full, and the page's median pitch.
struct RenderPage {
    struct Line {
        var text: [Unicode.Scalar]
        var bounds: PageRect?
        var isFull: Bool
    }

    let marker: String
    let lines: [Line]
    let pitch: Double?

    init(_ page: PageText) {
        marker = "[[page \(page.index + 1)]]"
        var lines: [Line] = []
        for line in page.lines where line.kind == .body {
            let text = RenderPage.cleaned(line.text)
            if !text.isEmpty { lines.append(Line(text: text, bounds: line.bounds, isFull: false)) }
        }
        let long = lines.map(\.text.count).filter { $0 >= 25 }.map(Double.init)
        if long.count >= 5, let median = Statistics.median(long) {
            for index in lines.indices { lines[index].isFull = Double(lines[index].text.count) >= 0.75 * median }
        }
        var distances: [Double] = []
        for (above, below) in zip(lines, lines.dropFirst()) {
            if let a = above.bounds, let b = below.bounds, a.y - b.y > 0 { distances.append(a.y - b.y) }
        }
        self.lines = lines
        self.pitch = Statistics.median(distances)
    }

    /// Rule 3's pitch test between consecutive lines of this page.
    func atNormalPitch(_ above: Line, _ below: Line) -> Bool {
        guard let a = above.bounds, let b = below.bounds, let pitch else { return true }
        let distance = a.y - b.y
        return distance > 0 && distance <= 1.3 * pitch
    }

    /// The text without whitespace at either end, line breaks inside it as spaces.
    static func cleaned(_ text: String) -> [Unicode.Scalar] {
        var scalars = text.unicodeScalars.map { scalar -> Unicode.Scalar in
            switch scalar.value {
            case 0x0A, 0x0D, 0x0B, 0x0C, 0x85, 0x2028, 0x2029: return " "
            default: return scalar
            }
        }
        while let last = scalars.last, Folding.isSpace(last) { scalars.removeLast() }
        let leading = scalars.prefix { Folding.isSpace($0) }.count
        if leading > 0 { scalars.removeFirst(leading) }
        return scalars
    }
}
