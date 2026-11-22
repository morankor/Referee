import Foundation

/// The folding of plan section 6.7. One Unicode scalar folds to zero or more *units*: its compatibility decomposition
/// (NFKD), of which only letters and digits are kept, lower-cased. So the ligatures ﬀ ﬁ ﬂ ﬃ ﬄ expand, µ becomes μ, and
/// superscript digits, full-width forms and the mathematical alphanumerics of Word-made PDFs become plain letters and
/// digits. Combining marks, whitespace, hyphens and dashes, quotation marks, punctuation, symbols, soft hyphens and
/// zero-width characters fold to nothing.
///
/// Decision (the plan is silent): modifier letters (general category Lm, such as U+02C6 "ˆ" or U+02BC "ʼ") fold to
/// nothing as well. PDF text often carries accents and apostrophes as these spacing characters, and a quote written
/// with the composed letter or a plain apostrophe must still match.
enum Folding {
    /// Appends the units of `scalar` to `units` and returns how many were appended. The folding of a non-ASCII scalar
    /// is remembered in `cache`.
    static func append(_ scalar: Unicode.Scalar, to units: inout [UInt32], cache: inout [UInt32: [UInt32]]) -> Int {
        let value = scalar.value
        if value < 0x80 { return appendASCII(value, to: &units) }
        if let known = cache[value] {
            units.append(contentsOf: known)
            return known.count
        }
        let folded = foldNonASCII(scalar)
        cache[value] = folded
        units.append(contentsOf: folded)
        return folded.count
    }

    /// The same, reading `cache` without adding to it.
    static func append(_ scalar: Unicode.Scalar, to units: inout [UInt32], lookingUpIn cache: [UInt32: [UInt32]]) -> Int {
        let value = scalar.value
        if value < 0x80 { return appendASCII(value, to: &units) }
        let folded = cache[value] ?? foldNonASCII(scalar)
        units.append(contentsOf: folded)
        return folded.count
    }

    /// The units of a whole string.
    static func fold(_ text: String) -> [UInt32] {
        var units: [UInt32] = []
        var cache: [UInt32: [UInt32]] = [:]
        for scalar in text.unicodeScalars { _ = append(scalar, to: &units, cache: &cache) }
        return units
    }

    @inline(__always)
    private static func appendASCII(_ value: UInt32, to units: inout [UInt32]) -> Int {
        switch value {
        case 0x30...0x39, 0x61...0x7A:
            units.append(value)
            return 1
        case 0x41...0x5A:
            units.append(value + 0x20)
            return 1
        default:
            return 0
        }
    }

    private static func foldNonASCII(_ scalar: Unicode.Scalar) -> [UInt32] {
        var result: [UInt32] = []
        for part in String(Character(scalar)).decomposedStringWithCompatibilityMapping.unicodeScalars where isLetterOrDigit(part) {
            if part.value < 0x80 {
                _ = appendASCII(part.value, to: &result)
                continue
            }
            for lower in part.properties.lowercaseMapping.unicodeScalars where isLetterOrDigit(lower) {
                result.append(lower.value)
            }
        }
        return result
    }

    /// Letters (except modifier letters, see the type's comment) and numbers of every kind.
    static func isLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .otherLetter, .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    /// Whether a scalar that folds to nothing ends a token (section 6.7, "tokens": maximal runs of folded letters and
    /// digits). Decision: combining marks, format characters (soft hyphen, zero-width joiners), modifier letters and
    /// modifier symbols do not, so that "re\u{301}sume\u{301}" or "caf´e" stay one token, as their folding is one run.
    static func separatesTokens(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value < 0x80 { return true }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .format, .modifierLetter, .modifierSymbol:
            return false
        default:
            return true
        }
    }

    /// The characters that hyphenate a word at the end of a line.
    static func isHyphen(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2D, 0x2010, 0x2011, 0xAD: return true
        default: return false
        }
    }

    @inline(__always)
    static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value < 0x80 { return value == 0x20 || (value >= 0x09 && value <= 0x0D) }
        return scalar.properties.isWhitespace
    }
}

/// The folded units of a sequence of lines, with, for each unit, the UTF-16 range in its page string of the scalar it
/// came from and the line it belongs to (lines are numbered in the order they are added); the page of each line; and
/// where each token starts.
///
/// Tokens are maximal runs of units within a line (section 6.7); a token that ends a line whose last non-space
/// character is a hyphen continues with the first token of the next line ("iden-" + "tification").
struct FoldedText {
    private(set) var units: [UInt32] = []
    private(set) var starts: [Int] = []
    private(set) var ends: [Int] = []
    private(set) var lines: [Int] = []
    private(set) var linePages: [Int] = []
    /// The unit at which each token starts, in order.
    private(set) var tokenStarts: [Int] = []
    private(set) var cache: [UInt32: [UInt32]]
    private let extendsCache: Bool
    private var mergeWithNextLine = false

    /// `extendsCache == false` reads `cache` without adding to it (a quote folded against a document's table).
    init(cache: [UInt32: [UInt32]] = [:], extendsCache: Bool = true) {
        self.cache = cache
        self.extendsCache = extendsCache
    }

    mutating func reserveCapacity(_ count: Int) {
        units.reserveCapacity(count)
        starts.reserveCapacity(count)
        ends.reserveCapacity(count)
        lines.reserveCapacity(count)
    }

    /// The page of the unit at `index`.
    func page(ofUnit index: Int) -> Int {
        linePages[lines[index]]
    }

    /// Folds one line; `location` is the UTF-16 offset of the line's first character in its page string.
    mutating func appendLine(_ text: String, page: Int, location: Int) {
        let line = linePages.count
        linePages.append(page)
        if appendASCIILine(text, location: location, line: line) { return }
        var offset = location
        var producedOnLine = false
        var tokenStartsNext = !mergeWithNextLine
        var previousNonSpaceProduced = false
        var endsWithHyphen = false
        for scalar in text.unicodeScalars {
            let width = scalar.utf16.count
            let first = units.count
            let count = extendsCache
                ? Folding.append(scalar, to: &units, cache: &cache)
                : Folding.append(scalar, to: &units, lookingUpIn: cache)
            if count > 0 {
                if tokenStartsNext { tokenStarts.append(first) }
                tokenStartsNext = false
                for _ in 0..<count {
                    starts.append(offset)
                    ends.append(offset + width)
                    lines.append(line)
                }
                producedOnLine = true
            } else if Folding.separatesTokens(scalar), producedOnLine || !mergeWithNextLine {
                tokenStartsNext = true
            }
            if !Folding.isSpace(scalar) {
                endsWithHyphen = Folding.isHyphen(scalar) && previousNonSpaceProduced
                previousNonSpaceProduced = count > 0
            }
            offset += width
        }
        mergeWithNextLine = producedOnLine && endsWithHyphen
    }

    /// The same for a line that is all ASCII, read byte by byte; false (and nothing done) for any other line.
    private mutating func appendASCIILine(_ text: String, location: Int, line: Int) -> Bool {
        let done = text.utf8.withContiguousStorageIfAvailable { bytes -> Bool in
            for byte in bytes where byte >= 0x80 { return false }
            var offset = location
            var producedOnLine = false
            var tokenStartsNext = !mergeWithNextLine
            var previousNonSpaceProduced = false
            var endsWithHyphen = false
            for byte in bytes {
                let value = UInt32(byte)
                var unit = value
                let produces: Bool
                if (value >= 0x61 && value <= 0x7A) || (value >= 0x30 && value <= 0x39) {
                    produces = true
                } else if value >= 0x41 && value <= 0x5A {
                    unit = value + 0x20
                    produces = true
                } else {
                    produces = false
                }
                if produces {
                    if tokenStartsNext { tokenStarts.append(units.count) }
                    tokenStartsNext = false
                    units.append(unit)
                    starts.append(offset)
                    ends.append(offset + 1)
                    lines.append(line)
                    producedOnLine = true
                } else if producedOnLine || !mergeWithNextLine {
                    tokenStartsNext = true
                }
                if !(value == 0x20 || (value >= 0x09 && value <= 0x0D)) {
                    endsWithHyphen = value == 0x2D && previousNonSpaceProduced
                    previousNonSpaceProduced = produces
                }
                offset += 1
            }
            mergeWithNextLine = producedOnLine && endsWithHyphen
            return true
        }
        return done ?? false
    }

    /// The unit ranges of the tokens, in order.
    func tokenRanges() -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(tokenStarts.count)
        for (number, start) in tokenStarts.enumerated() {
            ranges.append(start..<(number + 1 < tokenStarts.count ? tokenStarts[number + 1] : units.count))
        }
        return ranges
    }
}
