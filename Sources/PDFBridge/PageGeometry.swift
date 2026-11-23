import Foundation
import PDFKit
import RefereeCore

/// Rectangles of text on a page, from the PDFKit calls that plan section 7.2 lists as consistent with `PDFPage.string`:
/// `page.selection(for: NSRange)` and `PDFSelection.bounds(for:)`.
///
/// The bounds of a selection are the union of the boxes PDFKit gives its characters, and some of those boxes are wrong.
/// On a page whose line numbers PDFKit glues to the end of the text lines (the `lineno` case, `Fixtures/pdf/ay_nolinks.pdf`),
/// the digits and the character just before them have boxes that reach back across the page: in "…which is difficult to14"
/// every character has its own exact box except "o", whose box runs from x = 296.6 to 493.5 (the "o" itself starts at
/// 493.6), "1" (−2.2 to 296.7) and "4" (100.9 to 197.0). A range that merely ends at "o" therefore gets bounds that begin
/// in the middle of the line. A single glyph is never more than about one em wide, and its box is about one em high, so a
/// box more than twice as wide as it is high is not taken as that character's box.
///
/// `bounds(of:on:in:)` takes the bounds of a range between its outermost non-blank characters whose boxes are plausible:
/// exact for ordinary text, the true left edge for a range that ends at such a character, and at worst one character short
/// at the right. Blank characters at either end are ignored, as their boxes span whatever gap they stand for.
///
/// With `completingTheLastGlyph` (highlights and selections, `PDFPaperService.rects`; Wave 3) a range whose last
/// non-blank character has no plausible box is widened by one glyph: that character is the one before glued margin
/// digits, its glyph starts where the measured part ends (its wrong box ends there too: 493.5 against 493.6 above), and its
/// width is taken as the mean width of the last plausible glyphs of the range. The line bounds that the text cleaning
/// reads are measured without it, so extraction and rendering do not change.
enum PageGeometry {
    /// A box wider than this many times its height is not a single glyph.
    static let maximumGlyphAspect: CGFloat = 2

    /// Slack, in points, when comparing the edges of PDFKit's bounds with those of the outermost characters.
    private static let tolerance: CGFloat = 0.5

    /// How many plausible glyphs, counted back from the last one, give the width of a glyph that has no box of its own.
    private static let widthSamples = 8

    /// The bounds on `page` of the characters of `range`, a range in `string` (the page's `PDFPage.string`).
    /// nil when the range is empty, lies outside the string, holds only blank characters, or no character in it has a
    /// plausible box.
    static func bounds(of range: NSRange, on page: PDFPage, in string: NSString, completingTheLastGlyph: Bool = false) -> CGRect? {
        guard let range = clamped(range, toLength: string.length) else { return nil }

        // The first and the last non-blank characters, from the outside in, whose own boxes are plausible.
        var head: (range: NSRange, box: CGRect)?
        var index = range.location
        while index < NSMaxRange(range), head == nil {
            let piece = character(at: index, within: range, in: string)
            index = NSMaxRange(piece)
            if !isBlank(piece, in: string), let box = glyphBox(of: piece, on: page) { head = (piece, box) }
        }
        guard let head else { return nil }
        var tail = head
        var lastGlyphHasNoBox = false
        var end = NSMaxRange(range)
        while end > NSMaxRange(head.range) {
            let piece = character(at: end - 1, within: range, in: string)
            end = piece.location
            guard !isBlank(piece, in: string) else { continue }
            if let box = glyphBox(of: piece, on: page) {
                tail = (piece, box)
                break
            }
            lastGlyphHasNoBox = true
        }

        // PDFKit's bounds of everything from the one to the other are right unless a character in between has a box that
        // reaches beyond both of them; then the plausible boxes are united one by one.
        let inner = NSRange(location: head.range.location, length: NSMaxRange(tail.range) - head.range.location)
        var measured: CGRect
        if let whole = finite(page.selection(for: inner)?.bounds(for: page)), !whole.isEmpty,
           whole.minX >= min(head.box.minX, tail.box.minX) - tolerance, whole.maxX <= max(head.box.maxX, tail.box.maxX) + tolerance {
            measured = whole
        } else {
            var union = CGRect.null
            index = inner.location
            while index < NSMaxRange(inner) {
                let piece = character(at: index, within: inner, in: string)
                index = NSMaxRange(piece)
                if !isBlank(piece, in: string), let box = glyphBox(of: piece, on: page) { union = union.union(box) }
            }
            guard !union.isNull else { return nil }
            measured = union
        }
        if completingTheLastGlyph, lastGlyphHasNoBox, let width = meanGlyphWidth(endingAt: tail, from: head.range.location, on: page, in: string) {
            measured.size.width += width
        }
        return measured
    }

    /// The mean width of the last `widthSamples` non-blank characters with plausible boxes, from `tail` back to `start`.
    private static func meanGlyphWidth(endingAt tail: (range: NSRange, box: CGRect), from start: Int, on page: PDFPage,
                                       in string: NSString) -> CGFloat? {
        var widths: [CGFloat] = [tail.box.width]
        var end = tail.range.location
        while end > start, widths.count < widthSamples {
            let piece = character(at: end - 1, within: NSRange(location: start, length: end - start), in: string)
            end = piece.location
            if !isBlank(piece, in: string), let box = glyphBox(of: piece, on: page) { widths.append(box.width) }
        }
        let mean = widths.reduce(0, +) / CGFloat(widths.count)
        return mean > 0 ? mean : nil
    }

    /// The part of `range` that lies inside a string of `length` UTF-16 units; nil when nothing does.
    static func clamped(_ range: NSRange, toLength length: Int) -> NSRange? {
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        let lower = max(0, range.location)
        let (sum, overflow) = range.location.addingReportingOverflow(range.length)
        let upper = min(length, overflow ? length : sum)
        return upper > lower ? NSRange(location: lower, length: upper - lower) : nil
    }

    /// LF, CR, LINE SEPARATOR and PARAGRAPH SEPARATOR: what ends a line in `PDFPage.string`.
    static func isLineBreak(_ unit: unichar) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029
    }

    /// `rect` as a `PageRect`, or nil when it is null, infinite or not a number (as `CGRect.null` and the bounds of an
    /// empty selection are).
    static func pageRect(_ rect: CGRect?, pageIndex: Int) -> PageRect? {
        guard let rect = finite(rect) else { return nil }
        return PageRect(pageIndex: pageIndex, x: Double(rect.origin.x), y: Double(rect.origin.y),
                        width: Double(rect.size.width), height: Double(rect.size.height))
    }

    // MARK: - Helpers

    private static func finite(_ rect: CGRect?) -> CGRect? {
        guard let rect, !rect.isNull, !rect.isInfinite,
              rect.origin.x.isFinite, rect.origin.y.isFinite, rect.size.width.isFinite, rect.size.height.isFinite else { return nil }
        return rect
    }

    /// The box of one character (one composed character sequence), when it is plausible for a single glyph.
    private static func glyphBox(of piece: NSRange, on page: PDFPage) -> CGRect? {
        guard let box = finite(page.selection(for: piece)?.bounds(for: page)), box.width > 0, box.height > 0,
              box.width <= maximumGlyphAspect * box.height else { return nil }
        return box
    }

    /// The composed character sequence at `index`, cut to `range`, so that a surrogate pair or a letter with its combining
    /// marks is asked for as one piece.
    private static func character(at index: Int, within range: NSRange, in string: NSString) -> NSRange {
        let composed = NSIntersectionRange(string.rangeOfComposedCharacterSequence(at: index), range)
        return composed.length > 0 ? composed : NSRange(location: index, length: 1)
    }

    private static func isBlank(_ piece: NSRange, in string: NSString) -> Bool {
        string.substring(with: piece).unicodeScalars.allSatisfy { blank.contains($0) }
    }

    private static let blank = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
}
