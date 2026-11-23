import Foundation
import RefereeCore
import AppCore

/// What the Report tab says about the report and the comments it is built from (plan.md sections 6.10 and 9.8). Pure.
enum SidebarReportFacts {
    /// Lint rule `recommendation-mismatch` of Appendix B.7, shown under the recommendation picker.
    static let mismatchMessage = "The recommendation does not match the concerns listed."

    /// The comments a report is generated from: approved and included in the report (section 6.10).
    static func reportComments(_ comments: [ReviewComment]) -> [ReviewComment] {
        comments.filter { $0.status == .approved && $0.includeInReport }
    }

    /// "8 approved comments (3 major, 4 minor, 1 question)"; kinds in the order major, minor, question, strength,
    /// those with none left out. "No approved comments yet" when there is none.
    static func approvedSummary(of comments: [ReviewComment]) -> String {
        let parts = approvedSummaryParts(of: comments)
        return parts.kinds.map { parts.count + " " + $0 } ?? parts.count
    }

    /// The summary in its two parts, so that a narrow row can break between them: "8 approved comments" and "(3 major,
    /// 4 minor, 1 question)"; no kinds when nothing is approved.
    static func approvedSummaryParts(of comments: [ReviewComment]) -> (count: String, kinds: String?) {
        let approved = reportComments(comments)
        guard !approved.isEmpty else { return ("No approved comments yet", nil) }
        let parts = CommentKind.allCases.compactMap { kind -> String? in
            let count = approved.filter { $0.kind == kind }.count
            guard count > 0 else { return nil }
            switch kind {
            case .major: return "\(count) major"
            case .minor: return "\(count) minor"
            case .question: return count == 1 ? "1 question" : "\(count) questions"
            case .strength: return count == 1 ? "1 strength" : "\(count) strengths"
            }
        }
        let noun = approved.count == 1 ? "approved comment" : "approved comments"
        return ("\(approved.count) \(noun)", "(\(parts.joined(separator: ", ")))")
    }

    /// The numbered items under the heading "Major concerns", up to the next heading of the same or a higher level.
    static func majorConcernCount(in markdown: String) -> Int {
        let lines = markdown.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { line in
            guard let heading = SidebarMarkdown.heading(line.trimmingCharacters(in: .whitespaces)) else { return false }
            return heading.text.lowercased().hasPrefix("major concerns")
        }), let level = SidebarMarkdown.heading(lines[start].trimmingCharacters(in: .whitespaces))?.level else { return 0 }
        var count = 0
        for line in lines[(start + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let heading = SidebarMarkdown.heading(trimmed), heading.level <= level { break }
            if SidebarMarkdown.numberedItem(trimmed) != nil { count += 1 }
        }
        return count
    }

    /// The consistency check of section 9.8 (rule `recommendation-mismatch` of Appendix B.7), for the recommendation the
    /// picker shows: accept or minor revision with at least one major concern, or reject or major revision with none.
    static func recommendationMismatch(_ recommendation: Recommendation?, markdown: String) -> Bool {
        guard let recommendation else { return false }
        let majors = majorConcernCount(in: markdown)
        switch recommendation {
        case .accept, .minorRevision: return majors > 0
        case .majorRevision, .reject: return majors == 0
        }
    }

    /// The same check on any venue's scale (step 5, G.9): a label of the more favourable half with a major concern, or
    /// of the less favourable half without one; the middle label of an odd scale, and no label, never disagree
    /// (`VenueProfile.recommendationMismatch(label:majorConcerns:)`, which the style check uses too).
    static func recommendationMismatch(label: String?, venue: VenueProfile, markdown: String) -> Bool {
        guard let label else { return false }
        return venue.recommendationMismatch(label: label, majorConcerns: majorConcernCount(in: markdown))
    }

    /// The venue as the Report tab names it: "Journal of Economic Theory (JET)" over "Journal"; an unspecified venue
    /// over "Journal, no venue named" (step 5, G.9). `typedName` is the paper's `meta.targetVenue`: on an unspecified
    /// venue, a target journal typed before venues (or a deleted venue's name), which the prompts still name, so the
    /// tab says so: "Journal, named “JET” in the prompts".
    static func venueLines(_ venue: VenueProfile, typedName: String? = nil) -> (name: String, kind: String) {
        let name = venue.displayName.isEmpty ? "Untitled venue" : venue.displayName
        let kind = venue.kind == .journal ? "Journal" : "Conference"
        guard venue.isUnspecified else { return (name, kind) }
        let typed = typedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (name, typed.isEmpty ? kind + ", no venue named" : kind + ", named “\(typed)” in the prompts")
    }

    /// The venue's short name ("JET", "EC", "Journal"), else its full name, for the folded "Venue and notes".
    static func venueShortName(_ venue: VenueProfile) -> String {
        let short = venue.shortName.trimmingCharacters(in: .whitespacesAndNewlines)
        return short.isEmpty ? venueLines(venue).name : short
    }

    /// The Export menu's copy for the confidential box: the editor's for a journal, the program committee's for a
    /// conference (step 5, G.9).
    static func confidentialCopyTitle(_ kind: VenueKind) -> String {
        kind == .journal ? "Copy Confidential Comments to the Editor" : "Copy Confidential Comments to the Program Committee"
    }

    /// "Accept", "Minor revision", "Major revision", "Reject".
    static func title(of recommendation: Recommendation) -> String {
        switch recommendation {
        case .accept: return "Accept"
        case .minorRevision: return "Minor revision"
        case .majorRevision: return "Major revision"
        case .reject: return "Reject"
        }
    }

    /// The text a lint finding points at, on one line and at most `limit` characters (with "…" when cut); nil when
    /// the range lies outside the text or holds only white space.
    static func excerpt(of finding: LintFinding, in markdown: String, limit: Int = 48) -> String? {
        let text = markdown as NSString
        guard finding.range.location >= 0, finding.range.length > 0, finding.range.upperBound <= text.length else { return nil }
        let words = text.substring(with: finding.range.nsRange).split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let joined = words.joined(separator: " ")
        guard !joined.isEmpty else { return nil }
        return joined.count > limit ? String(joined.prefix(max(1, limit - 1))) + "…" : joined
    }

    /// The range of a lint finding, clamped to the text (the text may have changed since the lint ran).
    static func clampedRange(of finding: LintFinding, in markdown: String) -> NSRange {
        let length = (markdown as NSString).length
        let location = min(max(0, finding.range.location), length)
        return NSRange(location: location, length: min(max(0, finding.range.length), length - location))
    }

    // ---- the style check's titles (D8) ----

    /// What a lint rule of Appendix B.7 is called in the style check, instead of its id.
    static let ruleTitles: [String: String] = [
        "banned-word": "Machine-sounding word",
        "check-word": "Word to check",
        "em-dash": "Em dash",
        "not-only": "“Not only … but also”",
        "copula": "“Serves as”",
        "gerund-tail": "Trailing -ing clause",
        "third-person": "Third person",
        "hedge-stack": "Stacked hedge",
        "flattering-opener": "Opening praise",
        "optimistic-closer": "Optimistic ending",
        "template-heading": "Template heading",
        "missing-section": "Missing section",
        "opens-with-summary": "Opens with a summary",
        "recommendation-mismatch": "Recommendation mismatch",
    ]

    /// "Em dash" for `em-dash`; a rule without a title of its own reads as its id with hyphens as spaces, the first
    /// letter capitalised ("new-rule" → "New rule").
    static func ruleTitle(_ rule: String) -> String {
        if let title = ruleTitles[rule] { return title }
        let words = rule.replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    // ---- the journal's two boxes (D33) ----

    /// The sections that go to the editor alone: the confidential box of a journal system. A conference's report has
    /// "Chance of acceptance" where a journal's has "Publication probability" (step 5, G.9), and it goes the same way.
    static let editorSections = ["summary assessment", "recommendation", "publication probability", "chance of acceptance"]
    /// The sections that never go to the authors.
    static let confidentialSections = ["recommendation", "publication probability", "chance of acceptance"]

    /// "Copy Comments to the Authors": the report without the sections "Recommendation" and "Publication probability"
    /// (a conference's "Chance of acceptance"), in Markdown. A section is a heading and everything under it up to the next
    /// heading of the same or a higher level (deeper headings included); headings are found with `SidebarMarkdown.heading`
    /// and matched by their text, ignoring case and a closing colon. Text before the first heading stays.
    static func authorsMarkdown(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var dropped = IndexSet()
        for section in headingSections(of: lines) where confidentialSections.contains(normalised(section.title)) {
            dropped.insert(integersIn: section.lines)
        }
        return lines.indices.filter { !dropped.contains($0) }.map { lines[$0] }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Copy Confidential Comments to the Editor": the sections "Summary assessment", "Recommendation" and "Publication
    /// probability" (or "Chance of acceptance"), in Markdown, in the order the report has them.
    static func editorMarkdown(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var taken = IndexSet()
        for section in headingSections(of: lines) where editorSections.contains(normalised(section.title)) {
            taken.insert(integersIn: section.lines)
        }
        return taken.map { lines[$0] }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every heading of the report with the lines of its section: from the heading to the next heading of the same or
    /// a higher level, or to the end.
    private static func headingSections(of lines: [String]) -> [(title: String, lines: Range<Int>)] {
        let headings = lines.indices.compactMap { index -> (index: Int, level: Int, title: String)? in
            SidebarMarkdown.heading(lines[index].trimmingCharacters(in: .whitespaces)).map { (index, $0.level, $0.text) }
        }
        return headings.enumerated().map { position, heading in
            let end = headings[(position + 1)...].first { $0.level <= heading.level }?.index ?? lines.count
            return (heading.title, heading.index..<end)
        }
    }

    /// The plain text for one box: the Markdown of those sections as `ReportExporter` writes plain text.
    @MainActor static func authorsText(_ markdown: String) -> String {
        let part = authorsMarkdown(markdown)
        return part.isEmpty ? "" : ReportExporter.plainText(fromMarkdown: part)
    }

    @MainActor static func editorText(_ markdown: String) -> String {
        let part = editorMarkdown(markdown)
        return part.isEmpty ? "" : ReportExporter.plainText(fromMarkdown: part)
    }

    private static func normalised(_ heading: String) -> String {
        var text = heading.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasSuffix(":") { text.removeLast() }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
