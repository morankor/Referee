import Foundation
import RefereeCore

/// Splits a discussion reply (plan.md section 6.8) into the visible reply and the proposal that may end it: one
/// `@@REVISED … @@END` block, parsed by the same line rules as a review block, or a line `@@WITHDRAW`. Everything
/// before the marker line is the visible reply.
///
/// `feed` returns the text that may be shown now. A line is held back only while it could still become a marker line
/// (once it cannot, the rest of it is shown as it arrives), so the marker never reaches the screen and what was shown
/// is always a prefix of the final reply. With `parsesProposal == false` (questions about a selection) all text is
/// visible. Every scalar is looked at once, so a reply of any length costs linear time.
struct ReplyParser {
    private enum State { case visible, block, withdrawn, ignoring }

    let parsesProposal: Bool
    private var state: State = .visible
    private var held = ""                       // the current line, not yet shown, while it could still be a marker line
    private var heldBytes = 0
    private var lineIsText = false              // the current line can no longer be a marker line
    private(set) var visibleText = ""
    private(set) var rawText = ""
    private var blockParser = CommentStreamParser(mode: .revision)
    private(set) var revision: DraftComment?
    private(set) var withdraw = false
    /// True once the revision block was closed by `@@END` (or another marker line), not only by the end of the stream.
    private(set) var revisionTerminated = false

    init(parsesProposal: Bool) { self.parsesProposal = parsesProposal }

    /// The visible reply, trimmed.
    var reply: String { visibleText.trimmingCharacters(in: .whitespacesAndNewlines) }

    mutating func feed(_ delta: String) -> String {
        guard !delta.isEmpty else { return "" }
        rawText.append(delta)
        guard parsesProposal else {
            visibleText.append(delta)
            return delta
        }
        var shown = ""
        let scalars = delta.unicodeScalars
        var start = scalars.startIndex
        while start < scalars.endIndex, state == .visible {
            let newline = scalars[start...].firstIndex(of: "\n")
            let segment = String(String.UnicodeScalarView(scalars[start..<(newline ?? scalars.endIndex)]))
            if lineIsText {
                shown += segment
            } else {
                held += segment
                heldBytes += segment.utf8.count
            }
            if let newline {
                shown += completeLine()
                start = scalars.index(after: newline)
                if state == .block, start < scalars.endIndex {
                    absorb(blockParser.feed(String(String.UnicodeScalarView(scalars[start...]))), terminated: true)
                }
            } else {
                start = scalars.endIndex
                if !lineIsText, heldBytes > CommentStreamParser.maxLiveLineBytes || !LineSyntax.couldBecomeStructural(held, fieldNames: []) {
                    shown += held
                    held = ""
                    heldBytes = 0
                    lineIsText = true
                }
            }
        }
        if state == .block, start == scalars.startIndex {
            absorb(blockParser.feed(delta), terminated: true)
        }
        visibleText += shown
        return shown
    }

    /// End of stream; returns the last visible text, if any.
    mutating func finish() -> String {
        guard parsesProposal else { return "" }
        var shown = ""
        if state == .visible, !held.isEmpty || lineIsText {
            shown = completeLine(addNewline: false)
        }
        if state == .block {
            absorb(blockParser.finish(), terminated: false)
            state = .ignoring
        }
        visibleText += shown
        return shown
    }

    /// The proposal for `comment`: a withdrawal, or the revised fields, with what the block leaves out taken from the
    /// comment as it stands (the suggestion excepted: a revision without one proposes none).
    func proposal(for comment: ReviewComment) -> CommentRevision? {
        if withdraw {
            return CommentRevision(kind: comment.kind, title: comment.title, body: comment.body, suggestion: comment.suggestion, withdraw: true)
        }
        guard let revision else { return nil }
        return CommentRevision(kind: revision.kind ?? comment.kind, title: revision.title ?? comment.title,
                               body: revision.body.isEmpty ? comment.body : revision.body, suggestion: revision.suggestion, withdraw: false)
    }

    /// A complete line: a held line that is a marker switches state; anything else is shown with its line break.
    private mutating func completeLine(addNewline: Bool = true) -> String {
        defer {
            held = ""
            heldBytes = 0
            lineIsText = false
        }
        if lineIsText { return addNewline ? "\n" : "" }
        var line = held
        if line.unicodeScalars.last == "\r" { line.unicodeScalars.removeLast() }
        if line.contains("@@"), let mark = LineSyntax.mark(in: line) {
            switch mark {
            case .revised, .comment:
                state = .block
                absorb(blockParser.feed(line + "\n"), terminated: true)
                return ""
            case .withdraw:
                withdraw = true
                state = .withdrawn
                return ""
            case .end, .done, .notes:
                break
            }
        }
        return addNewline ? line + "\n" : line
    }

    private mutating func absorb(_ outputs: [CommentStreamParser.Output], terminated: Bool) {
        for output in outputs {
            if case .blockClosed(let draft) = output, revision == nil {
                revision = draft
                revisionTerminated = terminated
                state = .ignoring
            }
        }
    }
}
