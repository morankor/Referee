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
        let approved = reportComments(comments)
        guard !approved.isEmpty else { return "No approved comments yet" }
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
        return "\(approved.count) \(noun) (\(parts.joined(separator: ", ")))"
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
}
