import Foundation
import RefereeCore

/// The line-driven state machine of plan.md section 6.5, fed with text deltas as they arrive.
///
/// Nothing depends on where the deltas are cut: text is split into lines on U+000A (a trailing CR is dropped), and a
/// closed block depends only on complete lines. The unfinished last line only feeds the live draft, and only when it
/// can no longer turn into a marker or a field line, so a draft shown while streaming only grows.
///
/// Bounded on any input: a line is matched on its first 256 characters, a line longer than a million characters is cut,
/// a field keeps at most 20,000 characters per line and a block 100,000 in all, and an unfinished line longer than
/// 8 KB no longer updates the draft. Random bytes or a 5 MB line cannot make it crash or stall.
struct CommentStreamParser {
    enum Output: Equatable {
        case draftStarted(UUID)
        case draftUpdated(DraftComment)
        case blockClosed(DraftComment)
        case notes(String)
        case done
    }

    /// `.review` reads `@@COMMENT` blocks and `@@NOTES`; `.revision` reads the one `@@REVISED` block of a discussion
    /// reply (a `@@COMMENT` line opens it too), where a missing kind or title stays missing instead of being defaulted.
    enum Mode { case review, revision }

    private(set) var sawAnyBlock = false
    private(set) var sawDone = false
    private(set) var sawNotes = false
    /// Everything received, for the fallbacks and the debug transcript.
    private(set) var rawText = ""
    var hasOpenBlock: Bool { block != nil }

    private enum Section { case outside, notes, fields, body, suggestion }

    private struct Block {
        let id: UUID
        var values: [BlockField: [String]] = [:]
        var preamble: [String] = []
        var last: BlockField?
        var size = 0
    }

    private let mode: Mode
    private let categories: CategoryTable?
    private var section: Section = .outside
    private var block: Block?
    private var pending = ""
    private var pendingCount = 0
    private var lastDraft: DraftComment?
    private var notesLines: [String] = []
    private var notesSize = 0
    private var finished = false

    static let maxLineLength = 1_000_000
    static let maxStoredLineLength = 20_000
    static let maxBlockSize = 100_000
    static let maxNotesSize = 50_000
    static let maxLiveLineBytes = 8_192

    /// `categories`: the rubric the prompt listed; nil keeps the model's category as a slug.
    init(mode: Mode = .review, categories: CategoryTable? = nil) {
        self.mode = mode
        self.categories = categories
    }

    /// Any chunking; emits a draft update for the unfinished last line too.
    mutating func feed(_ delta: String) -> [Output] {
        guard !finished, !delta.isEmpty else { return [] }
        rawText.append(delta)
        var outputs: [Output] = []
        let scalars = delta.unicodeScalars
        var start = scalars.startIndex
        while let newline = scalars[start...].firstIndex(of: "\n") {
            appendPending(scalars[start..<newline])
            let line = pending
            pending = ""
            pendingCount = 0
            outputs += process(line)
            start = scalars.index(after: newline)
        }
        appendPending(scalars[start...])
        if let update = liveUpdate() { outputs.append(update) }
        return outputs
    }

    /// End of stream: the unfinished line counts as a line, then an open block is closed and open notes are emitted.
    mutating func finish() -> [Output] {
        guard !finished else { return [] }
        var outputs: [Output] = []
        if !pending.isEmpty {
            let line = pending
            pending = ""
            pendingCount = 0
            outputs += process(line)
        }
        if block != nil { outputs += closeBlock() }
        if section == .notes { outputs += notesOutput() }
        section = .outside
        finished = true
        return outputs
    }

    // ---- lines ----

    private mutating func appendPending(_ scalars: Substring.UnicodeScalarView) {
        guard pendingCount < Self.maxLineLength, !scalars.isEmpty else { return }
        let room = Self.maxLineLength - pendingCount
        var taken = 0
        for scalar in scalars {
            if taken == room { break }
            pending.unicodeScalars.append(scalar)
            taken += 1
        }
        pendingCount += taken
    }

    private mutating func process(_ rawLine: String) -> [Output] {
        var line = rawLine
        if line.unicodeScalars.last == "\r" { line.unicodeScalars.removeLast() }
        let mark = recognisedMark(in: line)
        switch section {
        case .outside, .notes:
            if let mark { return markOutside(mark) }
            if section == .notes { appendNote(line) }
            return []
        case .fields, .body, .suggestion:
            if let mark { return markInBlock(mark) }
            blockLine(line)
            return []
        }
    }

    /// The markers that mean something in this mode; any other "@@" line is ordinary text.
    private func recognisedMark(in line: String) -> BlockMark? {
        guard line.contains("@@"), let mark = LineSyntax.mark(in: line) else { return nil }
        switch (mode, mark) {
        case (.review, .comment), (.review, .end), (.review, .done), (.review, .notes): return mark
        case (.revision, .revised), (.revision, .comment), (.revision, .end), (.revision, .done), (.revision, .withdraw): return mark
        default: return nil
        }
    }

    private mutating func markOutside(_ mark: BlockMark) -> [Output] {
        switch mark {
        case .comment, .revised:
            var outputs = section == .notes ? notesOutput() : []
            outputs.append(openBlock())
            return outputs
        case .done:
            var outputs = section == .notes ? notesOutput() : []
            section = .outside
            sawDone = true
            outputs.append(.done)
            return outputs
        case .notes:
            section = .notes
            sawNotes = true
            return []
        case .end, .withdraw:
            return []
        }
    }

    private mutating func markInBlock(_ mark: BlockMark) -> [Output] {
        var outputs = closeBlock()
        switch mark {
        case .comment, .revised:
            outputs.append(openBlock())
        case .done:
            sawDone = true
            outputs.append(.done)
        case .notes:
            section = .notes
            sawNotes = true
        case .end, .withdraw:
            break
        }
        return outputs
    }

    private mutating func openBlock() -> Output {
        let id = UUID()
        block = Block(id: id)
        section = .fields
        sawAnyBlock = true
        lastDraft = DraftComment(id: id, body: "")
        return .draftStarted(id)
    }

    /// Rules 2 and 3: before the body a field line sets its field and any other line continues the field set last;
    /// once the body (or the suggestion) has started, only a suggestion field or a marker ends it.
    private mutating func blockLine(_ line: String) {
        guard var current = block else { return }
        defer { block = current }
        guard current.size < Self.maxBlockSize else { return }
        let stored = String(line.prefix(Self.maxStoredLineLength))
        current.size += stored.count
        switch section {
        case .fields:
            if let (field, value) = LineSyntax.field(in: stored) {
                switch field {
                case .body:
                    current.values[.body] = value.isEmpty ? [] : [value]
                    section = .body
                case .suggestion:
                    current.values[.suggestion] = value.isEmpty ? [] : [value]
                    section = .suggestion
                default:
                    current.values[field] = [value]
                }
                current.last = field
            } else {
                let trimmed = stored.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                if let last = current.last {
                    current.values[last, default: []].append(trimmed)
                } else {
                    current.preamble.append(stored)
                }
            }
        case .body:
            if let (field, value) = LineSyntax.field(in: stored), field == .suggestion {
                current.values[.suggestion] = value.isEmpty ? [] : [value]
                current.last = .suggestion
                section = .suggestion
            } else {
                current.values[.body, default: []].append(trimmingTrailingWhitespace(stored))
            }
        case .suggestion:
            if let (field, value) = LineSyntax.field(in: stored), field == .suggestion {
                if !value.isEmpty { current.values[.suggestion, default: []].append(value) }
            } else {
                current.values[.suggestion, default: []].append(trimmingTrailingWhitespace(stored))
            }
        case .outside, .notes:
            break
        }
    }

    private mutating func appendNote(_ line: String) {
        guard notesSize < Self.maxNotesSize else { return }
        let stored = String(line.prefix(Self.maxStoredLineLength))
        notesSize += stored.count + 1
        notesLines.append(stored)
    }

    private func notesOutput() -> [Output] {
        [.notes(notesLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))]
    }

    // ---- closing a block ----

    private mutating func closeBlock() -> [Output] {
        guard let closing = block else { return [] }
        block = nil
        section = .outside
        lastDraft = nil
        guard let draft = closedDraft(closing) else { return [] }
        return [.blockClosed(draft)]
    }

    /// Rule 5. A review block with neither title nor body is dropped; a revision block is kept if it sets anything.
    private func closedDraft(_ closing: Block) -> DraftComment? {
        func joined(_ field: BlockField, _ separator: String) -> String? {
            closing.values[field].map { $0.joined(separator: separator) }
        }
        var body = CommentValues.body(from: joined(.body, "\n") ?? "")
        if body.isEmpty, closing.values[.body] == nil, !closing.preamble.isEmpty {
            body = CommentValues.body(from: closing.preamble.joined(separator: "\n"))   // a block written as prose
        }
        var title = CommentValues.title(from: joined(.title, " ") ?? "")
        let kind = joined(.kind, " ").flatMap(CommentValues.kind(from:))
        let quote = CommentValues.quote(from: joined(.quote, " ") ?? "")
        let page = joined(.page, " ").flatMap(CommentValues.page(from:))
        let suggestion = joined(.suggestion, "\n").flatMap(CommentValues.suggestion(from:))
        let categoryValue = joined(.category, " ") ?? ""
        let category = categories.map { $0.resolve(categoryValue) } ?? CategoryTable.slug(categoryValue)

        switch mode {
        case .review:
            guard !title.isEmpty || !body.isEmpty else { return nil }
            if title.isEmpty { title = CommentValues.title(fromBody: body) }
            return DraftComment(id: closing.id, kind: kind ?? .minor, category: category, page: page, quote: quote.isEmpty ? nil : quote,
                                title: title, body: body, suggestion: suggestion)
        case .revision:
            guard kind != nil || !title.isEmpty || !body.isEmpty || suggestion != nil else { return nil }
            return DraftComment(id: closing.id, kind: kind, category: nil, page: page, quote: quote.isEmpty ? nil : quote,
                                title: title.isEmpty ? nil : title, body: body, suggestion: suggestion)
        }
    }

    // ---- the live draft ----

    private mutating func liveUpdate() -> Output? {
        guard let current = block else { return nil }
        let draft = liveDraft(current)
        guard draft != lastDraft else { return nil }
        lastDraft = draft
        return .draftUpdated(draft)
    }

    /// The draft as the lines so far give it, plus the unfinished line where that is safe. Kind, category and page are
    /// read from complete lines only; quote, title, body and suggestion are shown as written.
    private func liveDraft(_ current: Block) -> DraftComment {
        var values = current.values
        if let tentative = tentativeLine(current) {
            switch tentative {
            case .set(let field, let value): values[field] = [value]
            case .append(let field, let text): values[field, default: []].append(text)
            }
        }
        func text(_ field: BlockField, _ separator: String) -> String? {
            guard let lines = values[field] else { return nil }
            let pieces = separator == " " ? lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } : lines
            let value = trimmingTrailingWhitespace(pieces.joined(separator: separator).drop { $0 == "\n" }.description)
            return value.isEmpty ? nil : value
        }
        let kind = current.values[.kind].flatMap { CommentValues.kind(from: $0.joined(separator: " ")) }
        let page = current.values[.page].flatMap { CommentValues.page(from: $0.joined(separator: " ")) }
        let category = current.values[.category].flatMap { lines -> String? in
            let value = lines.joined(separator: " ")
            guard !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return categories.map { $0.resolve(value) } ?? CategoryTable.slug(value)
        }
        let body = text(.body, "\n").map { String($0.drop { $0.isWhitespace }) } ?? ""
        return DraftComment(id: current.id, kind: kind, category: category, page: page, quote: text(.quote, " "), title: text(.title, " "),
                            body: body, suggestion: text(.suggestion, "\n"))
    }

    private enum Tentative {
        case set(BlockField, String)
        case append(BlockField, String)
    }

    /// What the unfinished line would add to the draft, or nil when it is empty, too long, or could still become a
    /// marker or a field line that changes the reading.
    private func tentativeLine(_ current: Block) -> Tentative? {
        guard !pending.isEmpty, pending.utf8.count <= Self.maxLiveLineBytes, current.size < Self.maxBlockSize else { return nil }
        var line = pending
        if line.unicodeScalars.last == "\r" { line.unicodeScalars.removeLast() }
        guard !line.isEmpty else { return nil }
        let field = LineSyntax.field(in: line)
        switch section {
        case .fields:
            if let (name, value) = field {
                guard name.isText, !value.isEmpty else { return nil }
                return .set(name, value)
            }
            guard !LineSyntax.couldBecomeStructural(line, fieldNames: BlockField.allNames),
                  let last = current.last, last.isText else { return nil }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : .append(last, trimmed)
        case .body:
            if let (name, value) = field, name == .suggestion { return value.isEmpty ? nil : .set(.suggestion, value) }
            guard !LineSyntax.couldBecomeStructural(line, fieldNames: BlockField.suggestionNames) else { return nil }
            return .append(.body, line)
        case .suggestion:
            if let (name, value) = field, name == .suggestion { return value.isEmpty ? nil : .append(.suggestion, value) }
            guard !LineSyntax.couldBecomeStructural(line, fieldNames: BlockField.suggestionNames) else { return nil }
            return .append(.suggestion, line)
        case .outside, .notes:
            return nil
        }
    }

    private func trimmingTrailingWhitespace(_ text: String) -> String {
        var result = text
        while let last = result.last, last.isWhitespace { result.removeLast() }
        return result
    }
}
