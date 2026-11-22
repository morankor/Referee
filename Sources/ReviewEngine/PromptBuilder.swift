import Foundation
import RefereeCore

/// Prompt assembly (plan.md section 6.3). The editable texts come from `EngineContext.prompts`; the format
/// specifications and task texts are the constants of `FormatSpec`, filled in by the rules of its doc comment.
///
/// No prompt carries the document's file name (section 12.2): a PDF part is always named "manuscript.pdf".
enum PromptBuilder {
    static let manuscriptFileName = "manuscript.pdf"

    // ---- system prompts ----

    /// `reviewSystem` + rubric block + `FORMAT_REVIEW`.
    static func reviewSystem(_ context: EngineContext) -> String {
        [context.prompts.reviewSystem.trimmingCharacters(in: .whitespacesAndNewlines), rubricBlock(context.rubric), FormatSpec.review]
            .joined(separator: "\n\n")
    }

    /// The enabled categories as `- <id>: <name>. <guidance>`, under the header that tells the model to use those ids.
    /// "other" is listed when the rubric has nothing enabled, so the format's "one of the category ids listed above"
    /// always has something to point at.
    static func rubricBlock(_ rubric: [RubricCategory]) -> String {
        var lines = [#"Categories (use the id in the "category" field):"#]
        for category in rubric where category.enabled {
            let id = category.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            var line = "- \(id): " + category.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.hasSuffix(".") { line += "." }
            let guidance = category.guidance.trimmingCharacters(in: .whitespacesAndNewlines)
            if !guidance.isEmpty { line += " " + guidance }
            lines.append(line)
        }
        if lines.count == 1 { lines.append("- \(CategoryTable.fallback): Other.") }
        return lines.joined(separator: "\n")
    }

    /// `discussionSystem` + `FORMAT_REVISION`.
    static func discussionSystem(_ context: EngineContext) -> String {
        [context.prompts.discussionSystem.trimmingCharacters(in: .whitespacesAndNewlines), FormatSpec.revision].joined(separator: "\n\n")
    }

    // ---- review tasks ----

    /// `TASK_REVIEW`, text mode, split at the line `{paper text}`: the introduction with the rendered paper (before the
    /// cache boundary) and the task (after it).
    static func textModeReview(paper rendered: String, meta: ManuscriptMeta, existingTitles: [String]) -> (paper: String, task: String) {
        (textIntroduction + trimmingTrailingNewlines(rendered), optionalLines(textModeTask, meta: meta, titles: existingTitles))
    }

    /// `TASK_REVIEW`, PDF mode: what follows the `.pdf` part and the cache boundary.
    static func pdfModeReviewTask(meta: ManuscriptMeta, existingTitles: [String]) -> String {
        optionalLines(FormatSpec.taskReviewPDF, meta: meta, titles: existingTitles)
    }

    /// `TASK_PART`: one text with the part inside it. For the first part the notes lines go (FormatSpec's rule for
    /// `{if i > 1:}`); later parts with no notes say "(none)".
    static func partTask(part: Int, of count: Int, firstPage: Int, lastPage: Int, notes: String, text: String) -> String {
        var lines = FormatSpec.taskPart.components(separatedBy: "\n")
        if let marker = lines.firstIndex(of: "{if i > 1:}") {
            if part == 1 {
                // The marker, the two lines after it and the empty line that follows them.
                var end = min(lines.count, marker + 3)
                if end < lines.count, lines[end].isEmpty { end += 1 }
                lines.removeSubrange(marker..<end)
            } else {
                lines.remove(at: marker)
            }
        }
        return fill(lines.joined(separator: "\n"), [
            "i": String(part), "n": String(count), "a": String(firstPage), "b": String(lastPage),
            "notes": notes.isEmpty ? "(none)" : notes, "text of the part": trimmingTrailingNewlines(text),
        ])
    }

    /// `TASK_WHOLE`.
    static func wholeTask(notes: String, titles: [String]) -> String {
        fill(FormatSpec.taskWhole, ["notes": notes.isEmpty ? "(none)" : notes, "titles": titleList(titles) ?? "none"])
    }

    /// `TASK_CONTINUE`.
    static func continueTask(titles: [String]) -> String {
        fill(FormatSpec.taskContinue, ["titles": titleList(titles) ?? "none"])
    }

    // ---- paper context for replies and the report (section 6.3) ----

    /// The first line of the PDF-mode task, which says how to count pages; it opens the task of a reply that carries the PDF.
    static var pdfIntroduction: String {
        FormatSpec.taskReviewPDF.components(separatedBy: "\n").first ?? ""
    }

    /// The text-mode introduction followed by the whole rendered paper.
    static func fullTextContext(_ rendered: String) -> String {
        textIntroduction + trimmingTrailingNewlines(rendered)
    }

    /// The digest (when there is one) and the rendered pages around the passage.
    static func excerptContext(digest: String?, pages rendered: String, firstPage: Int, lastPage: Int) -> String {
        var text = "The manuscript is too long to include in full."
        if let digest, !digest.isEmpty {
            text += " These notes on the whole manuscript were written while reading it in parts:\n\n" + digest + "\n\n"
        } else {
            text += " "
        }
        let pages = firstPage == lastPage ? "Page \(firstPage)" : "Pages \(firstPage) to \(lastPage)"
        text += "\(pages) follow, as text extracted from a PDF. Lines of the form [[page N]] mark where PDF page N begins; words run together, "
            + "odd hyphenation and broken equations or tables are artefacts of extraction.\n\n" + trimmingTrailingNewlines(rendered)
        return text
    }

    // ---- discussion, question, report, voice revision ----

    static func discussionTask(comment: ReviewComment, message: String) -> String {
        let location = comment.anchor.locationLabel.isEmpty ? "" : " (location: \(comment.anchor.locationLabel))"
        var lines = ["The comment under discussion\(location):", "kind: \(comment.kind.rawValue) | category: \(comment.category)"]
        if !comment.anchor.quote.isEmpty { lines.append("quote: \(comment.anchor.quote)") }
        lines.append("title: \(comment.title)")
        lines.append("body: \(comment.body)")
        if let suggestion = comment.suggestion, !suggestion.isEmpty { lines.append("suggestion: \(suggestion)") }
        var text = lines.joined(separator: "\n")
        let transcript = transcriptLines(comment.thread, droppingTrailing: message)
        if !transcript.isEmpty { text += "\n\nDiscussion so far:\n" + transcript.joined(separator: "\n") }
        return text + "\n\nReferee: " + message
    }

    static func questionTask(conversation: Conversation, question: String) -> String {
        var sections: [String] = []
        if let anchor = conversation.anchor, !anchor.quote.isEmpty {
            let location = anchor.locationLabel.isEmpty ? "" : " (\(anchor.locationLabel))"
            sections.append("Selected passage\(location): «\(anchor.quote)»")
        }
        let transcript = transcriptLines(conversation.messages, droppingTrailing: question)
        if !transcript.isEmpty { sections.append("Conversation so far:\n" + transcript.joined(separator: "\n")) }
        sections.append("Referee: " + question)
        return sections.joined(separator: "\n\n")
    }

    /// The report's user turn (Appendix B.4), with the approved comments already in order.
    static func reportTask(comments: [ReviewComment], meta: ManuscriptMeta, template: String) -> String {
        let venue = meta.targetVenue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let notes = meta.reviewerNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        var counters: [CommentKind: Int] = [:]
        let blocks = comments.map { comment -> String in
            counters[comment.kind, default: 0] += 1
            var header = "[\(reportPrefix(comment.kind))\(counters[comment.kind]!)] \(comment.kind.rawValue) | \(comment.category)"
            if !comment.anchor.locationLabel.isEmpty { header += " | \(comment.anchor.locationLabel)" }
            var lines = [header]
            if !comment.anchor.quote.isEmpty { lines.append("quote: \(comment.anchor.quote)") }
            lines.append("title: \(comment.title)")
            lines.append("body: \(comment.body)")
            if let suggestion = comment.suggestion, !suggestion.isEmpty { lines.append("suggestion: \(suggestion)") }
            return lines.joined(separator: "\n")
        }
        return "Target journal: \(venue.isEmpty ? "not specified" : venue)\nReviewer's notes: \(notes.isEmpty ? "none" : notes)\n\n"
            + "Approved comments:\n" + blocks.joined(separator: "\n\n") + "\n\nTemplate:\n" + template
    }

    /// M, m, Q, S (section 6.10).
    static func reportPrefix(_ kind: CommentKind) -> String {
        switch kind {
        case .major: return "M"
        case .minor: return "m"
        case .question: return "Q"
        case .strength: return "S"
        }
    }

    /// The voice revision's user turn: the report, then the passages the style check flagged.
    static func voiceRevisionTask(reportMarkdown: String, findings: [LintFinding]) -> String {
        let report = reportMarkdown as NSString
        let flagged = findings.map { finding -> String in
            var line = "- [\(finding.rule)]"
            let range = finding.range.nsRange
            if range.length > 0, range.location >= 0, range.upperBound <= report.length {
                let passage = CommentValues.collapsingWhitespace(report.substring(with: range))
                line += " “\(CommentValues.truncated(passage, to: 200))”"
            }
            return line + " " + finding.message
        }
        return "The report:\n\n" + reportMarkdown.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\nFlagged:\n"
            + (flagged.isEmpty ? "(nothing)" : flagged.joined(separator: "\n"))
    }

    // ---- FormatSpec placeholders ----

    private static var textModeParts: (introduction: String, task: String) {
        let template = FormatSpec.taskReviewText
        guard let marker = template.range(of: "{paper text}") else { return ("", template) }
        var task = template[marker.upperBound...]
        if task.first == "\n" { task = task.dropFirst() }
        return (String(template[..<marker.lowerBound]), String(task))
    }

    /// What stands before `{paper text}` in `TASK_REVIEW` (the paragraph about page markers and extraction artefacts).
    static var textIntroduction: String { textModeParts.introduction }
    private static var textModeTask: String { textModeParts.task }

    /// The three optional lines of the review tasks: each becomes its text with the value after the first colon, or
    /// goes, with its line break, when there is nothing to say.
    static func optionalLines(_ template: String, meta: ManuscriptMeta, titles: [String]) -> String {
        let notes = meta.reviewerNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let venue = meta.targetVenue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let values: [String: String?] = [
            "Reviewer's notes": notes.isEmpty ? nil : notes,
            "Target journal": venue.isEmpty ? nil : venue,
            "Comments already made, do not repeat them": titleList(titles),
        ]
        var lines: [String] = []
        for line in template.components(separatedBy: "\n") {
            guard line.hasPrefix("{"), line.hasSuffix("}"), let colon = line.firstIndex(of: ":") else {
                lines.append(line)
                continue
            }
            let key = String(line[line.index(after: line.startIndex)..<colon])
            guard let value = values[key] else {
                lines.append(line)                // not an optional line of ours: kept as it is
                continue
            }
            if let value { lines.append("\(key): \(value)") }
        }
        return lines.joined(separator: "\n")
    }

    /// Replaces each `{name}` of `values` in one pass, so that a value which itself contains braces (notes copied by a
    /// model, a title) is never filled in again.
    static func fill(_ template: String, _ values: [String: String]) -> String {
        var result = ""
        var rest = template[...]
        while let open = rest.firstIndex(of: "{") {
            guard let close = rest[open...].firstIndex(of: "}") else { break }
            result += rest[..<open]
            let name = String(rest[rest.index(after: open)..<close])
            if let value = values[name] {
                result += value
            } else {
                result += rest[open...close]
            }
            rest = rest[rest.index(after: close)...]
        }
        result += rest
        return result
    }

    static func titleList(_ titles: [String]) -> String? {
        let cleaned = titles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return cleaned.isEmpty ? nil : cleaned.joined(separator: "; ")
    }

    /// "Referee: …" and "Assistant: …" lines. A last referee message equal to the new one is left out: the caller may
    /// already have added it to the thread.
    private static func transcriptLines(_ messages: [ThreadMessage], droppingTrailing message: String) -> [String] {
        var thread = messages
        if let last = thread.last, last.role == .user,
           last.text.trimmingCharacters(in: .whitespacesAndNewlines) == message.trimmingCharacters(in: .whitespacesAndNewlines) {
            thread.removeLast()
        }
        return thread.map { ($0.role == .user ? "Referee: " : "Assistant: ") + $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func trimmingTrailingNewlines(_ text: String) -> String {
        var result = text
        while let last = result.last, last.isNewline { result.removeLast() }
        return result
    }
}
