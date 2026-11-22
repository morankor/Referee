import Foundation

/// A stretch of a paragraph's text with the inline styles Markdown gave it. A hard line break is a run "\n".
struct ExportRun: Equatable, Sendable {
    var text: String
    var strong = false
    var emphasis = false
    var code = false

    func hasSameStyle(as other: ExportRun) -> Bool {
        strong == other.strong && emphasis == other.emphasis && code == other.code
    }
}

/// The inline Markdown of one paragraph, as far as a referee report needs it: emphasis and strong emphasis with `*`
/// and `_` under CommonMark's flanking rules (so `x_i`, `snake_case` and `2 * 3` keep their characters), code spans,
/// links and images (written as "text (url)"), autolinks, backslash escapes, a few character references, and hard
/// line breaks. Anything else stays as it was written. Total and bounded: every character is looked at a fixed number
/// of times, and link texts are parsed at most four levels deep.
enum ExportInline {
    /// `text` is one paragraph whose soft line breaks are already spaces; "\n" in it is a hard line break.
    static func parse(_ text: String) -> [ExportRun] {
        parse(Array(text), depth: 0)
    }

    private static let maximumDepth = 4

    private enum Style { case strong, emphasis }

    private struct Delimiter {
        let character: Character
        let originalCount: Int
        var count: Int
        let canOpen: Bool
        let canClose: Bool
        var closes: [Style] = []          // styles that end before the characters left over
        var opens: [Style] = []           // styles that begin after them
        var active = true                 // still on the delimiter stack (may match)
    }

    private enum Node {
        case text(String)
        case code(String)
        case delimiter(Int)
        case link([ExportRun], url: String?)
        case lineBreak
    }

    private struct DelimiterKey: Hashable {
        let character: Character
        let closerCanOpen: Bool
        let lengthModulo3: Int
    }

    private static func parse(_ chars: [Character], depth: Int) -> [ExportRun] {
        var nodes: [Node] = []
        var delimiters: [Delimiter] = []
        var buffer = ""
        func flush() {
            if !buffer.isEmpty { nodes.append(.text(buffer)); buffer = "" }
        }

        let backtickRuns = BacktickRuns(chars)
        let brackets = depth < maximumDepth ? matchingBrackets(chars) : [:]
        let count = chars.count
        var index = 0
        while index < count {
            let character = chars[index]
            switch character {
            case "\\":
                if index + 1 < count, chars[index + 1].isASCIIPunctuation {
                    buffer.append(chars[index + 1])
                    index += 2
                } else {
                    buffer.append(character)
                    index += 1
                }
            case "`":
                var end = index
                while end < count, chars[end] == "`" { end += 1 }
                let length = end - index
                if let closing = backtickRuns.next(length: length, after: end - 1) {
                    flush()
                    nodes.append(.code(codeSpanContent(chars[end..<closing])))
                    index = closing + length
                } else {
                    buffer.append(String(repeating: "`", count: length))
                    index = end
                }
            case "*", "_":
                var end = index
                while end < count, chars[end] == character { end += 1 }
                let before: Character? = index > 0 ? chars[index - 1] : nil
                let after: Character? = end < count ? chars[end] : nil
                let leftFlanking = !isWhitespace(after) && (!isPunctuation(after) || isWhitespace(before) || isPunctuation(before))
                let rightFlanking = !isWhitespace(before) && (!isPunctuation(before) || isWhitespace(after) || isPunctuation(after))
                let canOpen: Bool
                let canClose: Bool
                if character == "*" {
                    canOpen = leftFlanking
                    canClose = rightFlanking
                } else {
                    canOpen = leftFlanking && (!rightFlanking || isPunctuation(before))
                    canClose = rightFlanking && (!leftFlanking || isPunctuation(after))
                }
                flush()
                delimiters.append(Delimiter(character: character, originalCount: end - index, count: end - index,
                                            canOpen: canOpen, canClose: canClose))
                nodes.append(.delimiter(delimiters.count - 1))
                index = end
            case "[", "!":
                let open = character == "!" ? index + 1 : index
                if open < count, chars[open] == "[", let close = brackets[open], let link = linkTail(chars, after: close) {
                    flush()
                    let label = parse(Array(chars[(open + 1)..<close]), depth: depth + 1)
                    nodes.append(.link(label, url: character == "!" ? nil : link.url))
                    index = link.end
                } else {
                    buffer.append(character)
                    index += 1
                }
            case "<":
                if let autolink = autolink(chars, at: index) {
                    flush()
                    nodes.append(.text(autolink.text))
                    index = autolink.end
                } else {
                    buffer.append(character)
                    index += 1
                }
            case "&":
                if let reference = characterReference(chars, at: index) {
                    buffer.append(reference.text)
                    index = reference.end
                } else {
                    buffer.append(character)
                    index += 1
                }
            case "\n":
                flush()
                nodes.append(.lineBreak)
                index += 1
            default:
                buffer.append(character)
                index += 1
            }
        }
        flush()
        processEmphasis(&delimiters)
        return flatten(nodes, delimiters)
    }

    /// CommonMark's "process emphasis", over a linked list so that each search skips what is already removed, with
    /// the lowest possible opener remembered per kind of closer, so that no delimiter is searched twice in vain.
    private static func processEmphasis(_ delimiters: inout [Delimiter]) {
        let total = delimiters.count
        guard total > 1 else { return }
        var previous = Array(-1..<(total - 1))
        var next = Array(1...total)
        func unlink(_ position: Int) {
            delimiters[position].active = false
            if previous[position] >= 0 { next[previous[position]] = next[position] }
            if next[position] < total { previous[next[position]] = previous[position] }
        }

        var lowest: [DelimiterKey: Int] = [:]
        var closer = 0
        while closer < total {
            let candidate = delimiters[closer]
            guard candidate.active, candidate.canClose, candidate.count > 0 else {
                closer = next[closer]
                continue
            }
            let key = DelimiterKey(character: candidate.character, closerCanOpen: candidate.canOpen,
                                   lengthModulo3: candidate.originalCount % 3)
            let floor = lowest[key] ?? 0
            var opener = previous[closer]
            var found: Int?
            while opener >= floor, opener >= 0 {
                let other = delimiters[opener]
                if other.active, other.character == candidate.character, other.canOpen, other.count > 0 {
                    let sum = other.originalCount + candidate.originalCount
                    let ruleOfThree = (other.canClose || candidate.canOpen) && sum % 3 == 0
                        && !(other.originalCount % 3 == 0 && candidate.originalCount % 3 == 0)
                    if !ruleOfThree { found = opener; break }
                }
                opener = previous[opener]
            }
            guard let found else {
                lowest[key] = closer
                let following = next[closer]
                if !candidate.canOpen { unlink(closer) }
                closer = following
                continue
            }
            let used = delimiters[found].count >= 2 && candidate.count >= 2 ? 2 : 1
            let style: Style = used == 2 ? .strong : .emphasis
            delimiters[found].count -= used
            delimiters[found].opens.insert(style, at: 0)
            delimiters[closer].count -= used
            delimiters[closer].closes.append(style)
            var between = next[found]
            while between != closer, between < total {
                let following = next[between]
                unlink(between)
                between = following
            }
            if delimiters[found].count == 0 { unlink(found) }
            if delimiters[closer].count == 0 {
                let following = next[closer]
                unlink(closer)
                closer = following
            }
        }
    }

    private static func flatten(_ nodes: [Node], _ delimiters: [Delimiter]) -> [ExportRun] {
        var runs: [ExportRun] = []
        var strongDepth = 0
        var emphasisDepth = 0
        func emit(_ text: String, strong: Bool = false, emphasis: Bool = false, code: Bool = false) {
            guard !text.isEmpty else { return }
            let run = ExportRun(text: text, strong: strong || strongDepth > 0, emphasis: emphasis || emphasisDepth > 0, code: code)
            if let last = runs.last, last.hasSameStyle(as: run) {
                runs[runs.count - 1].text += text
            } else {
                runs.append(run)
            }
        }
        for node in nodes {
            switch node {
            case .text(let text):
                emit(text)
            case .code(let text):
                emit(text, code: true)
            case .lineBreak:
                emit("\n")
            case .delimiter(let position):
                let delimiter = delimiters[position]
                for style in delimiter.closes {
                    if style == .strong { strongDepth = max(0, strongDepth - 1) } else { emphasisDepth = max(0, emphasisDepth - 1) }
                }
                emit(String(repeating: delimiter.character, count: delimiter.count))
                for style in delimiter.opens {
                    if style == .strong { strongDepth += 1 } else { emphasisDepth += 1 }
                }
            case .link(let label, let url):
                let labelText = label.map(\.text).joined()
                for run in label { emit(run.text, strong: run.strong, emphasis: run.emphasis, code: run.code) }
                if let url, !url.isEmpty, url != labelText {
                    emit(labelText.isEmpty ? url : " (\(url))")
                }
            }
        }
        return runs
    }

    // ---- pieces ----

    private static func isWhitespace(_ character: Character?) -> Bool {
        guard let character else { return true }
        return character.isWhitespace
    }

    /// Unicode punctuation as CommonMark counts it: the P and S categories.
    private static func isPunctuation(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isPunctuation || character.isSymbol
    }

    /// One leading and one trailing space are dropped when both are there and the content is not only spaces.
    private static func codeSpanContent(_ slice: ArraySlice<Character>) -> String {
        var text = String(slice).replacingOccurrences(of: "\n", with: " ")
        if text.count >= 2, text.first == " ", text.last == " ", text.contains(where: { $0 != " " }) {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }

    /// The bracket that closes each "[" (not escaped), found in one pass.
    private static func matchingBrackets(_ chars: [Character]) -> [Int: Int] {
        var result: [Int: Int] = [:]
        var open: [Int] = []
        var index = 0
        while index < chars.count {
            switch chars[index] {
            case "\\": index += 1
            case "[": open.append(index)
            case "]": if let start = open.popLast() { result[start] = index }
            default: break
            }
            index += 1
        }
        return result
    }

    /// `(destination "optional title")` right after the closing bracket of a link text. At most 4,096 characters are
    /// read for the two together, which bounds the work for text full of unclosed "[a](".
    private static func linkTail(_ chars: [Character], after close: Int) -> (url: String, end: Int)? {
        let count = min(chars.count, close + 4_096)
        var index = close + 1
        guard index < count, chars[index] == "(" else { return nil }
        index += 1
        func skipSpaces() { while index < count, chars[index] == " " { index += 1 } }
        skipSpaces()
        var url = ""
        if index < count, chars[index] == "<" {
            index += 1
            while index < count, chars[index] != ">", chars[index] != "\n" { url.append(chars[index]); index += 1 }
            guard index < count, chars[index] == ">" else { return nil }
            index += 1
        } else {
            var depth = 0
            while index < count, !chars[index].isWhitespace {
                let character = chars[index]
                if character == "\\", index + 1 < count, chars[index + 1].isASCIIPunctuation {
                    url.append(chars[index + 1])
                    index += 2
                    continue
                }
                if character == "(" { depth += 1 }
                if character == ")" {
                    if depth == 0 { break }
                    depth -= 1
                }
                url.append(character)
                index += 1
            }
        }
        skipSpaces()
        if index < count, chars[index] == "\"" || chars[index] == "'" || chars[index] == "(" {
            let closing: Character = chars[index] == "(" ? ")" : chars[index]
            index += 1
            while index < count, chars[index] != closing {
                index += chars[index] == "\\" ? 2 : 1
            }
            guard index < count else { return nil }
            index += 1
            skipSpaces()
        }
        guard index < count, chars[index] == ")" else { return nil }
        return (url, index + 1)
    }

    /// `<https://example.org/x>` or `<name@example.org>`: the text between the brackets.
    private static func autolink(_ chars: [Character], at start: Int) -> (text: String, end: Int)? {
        var index = start + 1
        var text = ""
        while index < chars.count, index - start <= 2_048 {
            let character = chars[index]
            if character == ">" { break }
            if character == "<" || character.isWhitespace { return nil }
            text.append(character)
            index += 1
        }
        guard index < chars.count, chars[index] == ">", !text.isEmpty else { return nil }
        let isURI = text.wholeMatch(of: #/[A-Za-z][A-Za-z0-9+.\-]{1,31}:[^<>\s]*/#) != nil
        let isEmail = text.wholeMatch(of: #/[A-Za-z0-9.!#$%&'*+\/=?^_`{|}~\-]+@[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?)*/#) != nil
        guard isURI || isEmail else { return nil }
        return (text, index + 1)
    }

    private static let namedReferences: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "ndash": "\u{2013}", "mdash": "\u{2014}", "hellip": "\u{2026}",
    ]

    /// `&amp;`, `&#8211;`, `&#x2013;` and the few names above; anything else is left as written.
    private static func characterReference(_ chars: [Character], at start: Int) -> (text: String, end: Int)? {
        var index = start + 1
        var body = ""
        while index < chars.count, index - start <= 32, chars[index] != ";" {
            body.append(chars[index])
            index += 1
        }
        guard index < chars.count, chars[index] == ";", !body.isEmpty else { return nil }
        if let named = namedReferences[body] { return (named, index + 1) }
        guard body.first == "#" else { return nil }
        let digits = body.dropFirst()
        let value: UInt32?
        if digits.first == "x" || digits.first == "X" {
            value = digits.count > 1 && digits.count <= 7 ? UInt32(digits.dropFirst(), radix: 16) : nil
        } else {
            value = !digits.isEmpty && digits.count <= 8 ? UInt32(digits, radix: 10) : nil
        }
        guard let value, value != 0, let scalar = Unicode.Scalar(value) else { return nil }
        return (String(Character(scalar)), index + 1)
    }
}

/// Where each maximal run of backticks starts, by length, so that the run closing a code span is found without
/// scanning the rest of the paragraph again.
private struct BacktickRuns {
    private var starts: [Int: [Int]] = [:]

    init(_ chars: [Character]) {
        var index = 0
        while index < chars.count {
            guard chars[index] == "`" else { index += 1; continue }
            var end = index
            while end < chars.count, chars[end] == "`" { end += 1 }
            starts[end - index, default: []].append(index)
            index = end
        }
    }

    /// The start of the first run of exactly `length` backticks that begins after `position`.
    func next(length: Int, after position: Int) -> Int? {
        guard let list = starts[length] else { return nil }
        var low = 0
        var high = list.count
        while low < high {
            let middle = (low + high) / 2
            if list[middle] <= position { low = middle + 1 } else { high = middle }
        }
        return low < list.count ? list[low] : nil
    }
}

private extension Character {
    var isASCIIPunctuation: Bool {
        guard let ascii = asciiValue else { return false }
        return (0x21...0x2F).contains(ascii) || (0x3A...0x40).contains(ascii) || (0x5B...0x60).contains(ascii) || (0x7B...0x7E).contains(ascii)
    }
}
