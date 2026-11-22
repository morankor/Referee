import Foundation
import RefereeCore

/// Writes the output lines of section 6.2: keeps the open run, joins lines into it (rules 3 and 4), and places page
/// markers (rule 5).
struct RunWriter {
    private var output: [String] = []
    private var run: [Unicode.Scalar] = []
    private var isOpen = false
    /// Page breaks inside the open run: where the next page's text joined it, and that page's marker.
    private var breaks: [(join: Int, marker: String)] = []
    private var lastLineWasFull = false

    mutating func add(_ page: RenderPage, lexicon: () -> HyphenationLexicon) {
        let continues = isOpen && lastLineWasFull && !page.lines.isEmpty
        if !continues {
            flush()
            output.append(page.marker)
        }
        var previous: RenderPage.Line?
        for (index, line) in page.lines.enumerated() {
            if isOpen {
                let joins = lastLineWasFull && (previous.map { page.atNormalPitch($0, line) } ?? true)
                if !joins { flush() }
            }
            append(line.text, marker: index == 0 && continues ? page.marker : nil, lexicon: lexicon)
            lastLineWasFull = line.isFull
            previous = line
        }
    }

    /// All lines, each ended by "\n"; "" when there are none.
    mutating func finish() -> String {
        flush()
        return output.isEmpty ? "" : output.joined(separator: "\n") + "\n"
    }

    private mutating func append(_ text: [Unicode.Scalar], marker: String?, lexicon: () -> HyphenationLexicon) {
        guard isOpen else {
            run = text
            isOpen = true
            breaks = []
            return
        }
        let join: Int
        if run.count >= 2, Folding.isHyphen(run[run.count - 1]), RunWriter.isLetter(run[run.count - 2]),
           let first = text.first, RunWriter.isLetter(first), first.properties.isLowercase {
            let left = RunWriter.wordFragment(before: run.count - 1, in: run)
            let right = RunWriter.wordFragment(startingAt: 0, in: text)
            if !lexicon().keepsHyphen(left: left, right: right) { run.removeLast() }
            join = run.count
        } else {
            join = run.count
            run.append(" ")
        }
        run.append(contentsOf: text)
        if let marker { breaks.append((join, marker)) }
    }

    /// Ends the open run: its text up to each page break's sentence end, then that page's marker; markers without a
    /// sentence end follow the whole run.
    private mutating func flush() {
        guard isOpen else { return }
        var cursor = 0
        var deferred: [String] = []
        for pageBreak in breaks {
            if deferred.isEmpty, let cut = RunWriter.sentenceEnd(in: run, from: cursor, join: pageBreak.join) {
                emit(run[cursor..<cut.end])
                output.append(pageBreak.marker)
                cursor = cut.next
            } else {
                deferred.append(pageBreak.marker)
            }
        }
        emit(run[cursor...])
        output.append(contentsOf: deferred)
        run = []
        breaks = []
        isOpen = false
    }

    private mutating func emit(_ text: ArraySlice<Unicode.Scalar>) {
        var slice = text
        while let first = slice.first, Folding.isSpace(first) { slice.removeFirst() }
        while let last = slice.last, Folding.isSpace(last) { slice.removeLast() }
        guard !slice.isEmpty else { return }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: slice)
        output.append(String(scalars))
    }

    /// The first sentence end after a page break: ".", "?" or "!", optional closing quotes or brackets, whitespace,
    /// then an upper-case letter or an opening bracket, with the terminator at most 400 characters after the break.
    /// The whitespace must lie at or after the join, so that the cut never moves text of the earlier page after the
    /// marker; a sentence that ends exactly at the break counts. `end` is where the sentence's text ends, `next` where
    /// the rest of the run starts.
    static func sentenceEnd(in run: [Unicode.Scalar], from cursor: Int, join: Int) -> (end: Int, next: Int)? {
        var position = max(cursor, join - 4, 0)
        let limit = min(run.count, join + 400)
        while position < limit {
            defer { position += 1 }
            guard isTerminator(run[position]) else { continue }
            var end = position + 1
            while end < run.count && isCloser(run[end]) { end += 1 }
            guard end >= join, end < run.count, Folding.isSpace(run[end]) else { continue }
            var next = end
            while next < run.count && Folding.isSpace(run[next]) { next += 1 }
            guard next < run.count else { continue }
            let opener = run[next]
            if opener.properties.isUppercase || opener == "[" || opener == "(" { return (end, next) }
        }
        return nil
    }

    private static func isTerminator(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "." || scalar == "?" || scalar == "!"
    }

    private static func isCloser(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "\"", "'", ")", "]", "\u{201D}", "\u{2019}": return true
        default: return false
        }
    }

    static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    /// The letters and digits that end just before `end`, lower-cased.
    static func wordFragment(before end: Int, in scalars: [Unicode.Scalar]) -> String {
        var start = end
        while start > 0 && HyphenationLexicon.isWordScalar(scalars[start - 1]) { start -= 1 }
        return HyphenationLexicon.lowercased(scalars[start..<end])
    }

    /// The letters and digits from `start` on, lower-cased.
    static func wordFragment(startingAt start: Int, in scalars: [Unicode.Scalar]) -> String {
        var end = start
        while end < scalars.count && HyphenationLexicon.isWordScalar(scalars[end]) { end += 1 }
        return HyphenationLexicon.lowercased(scalars[start..<end])
    }
}

/// The words of a document, for rule 4: every word of the body text, and every pair of words joined by a single hyphen
/// inside a line ("office-specific", "state-of", "of-the", "the-art"). Lower-cased.
struct HyphenationLexicon {
    private var words = Set<String>()
    private var compounds = Set<String>()

    init(paper: PaperText) {
        for page in paper.pages {
            for line in page.lines where line.kind == .body { add(line.text) }
        }
    }

    /// True when "left-right" occurs unbroken in the document and "leftright" does not.
    func keepsHyphen(left: String, right: String) -> Bool {
        guard !left.isEmpty, !right.isEmpty else { return false }
        return compounds.contains(left + "-" + right) && !words.contains(left + right)
    }

    private mutating func add(_ text: String) {
        var current: [Unicode.Scalar] = []
        var left: String?                  // the word just before a hyphen that may join it to the next one
        func finishWord() -> String? {
            guard !current.isEmpty else { return nil }
            let word = HyphenationLexicon.lowercased(current[...])
            current = []
            words.insert(word)
            if let left { compounds.insert(left + "-" + word) }
            return word
        }
        for scalar in text.unicodeScalars {
            if HyphenationLexicon.isWordScalar(scalar) {
                current.append(scalar)
                continue
            }
            let word = finishWord()
            left = word != nil && (scalar == "-" || scalar == "\u{2010}" || scalar == "\u{2011}") ? word : nil
        }
        _ = finishWord()
    }

    /// Letters, digits and combining marks.
    static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value < 0x80 {
            let value = scalar.value
            return (value >= 0x30 && value <= 0x39) || (value >= 0x41 && value <= 0x5A) || (value >= 0x61 && value <= 0x7A)
        }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber, .letterNumber,
             .otherNumber, .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return false
        }
    }

    static func lowercased(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view).lowercased()
    }
}
