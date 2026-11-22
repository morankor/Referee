import Foundation
import RefereeCore

/// Small pure rules the review model applies to comments and reports.
enum ModelSupport {
    /// `ReviewComment.previousVersions` keeps at most this many entries (Appendix A.4).
    static let maxPreviousVersions = 20
    /// `ReportDraft.versions` keeps at most this many entries, newest last (Appendix A.4).
    static let maxReportVersions = 10

    /// Pushes the comment's current kind, title, body and suggestion onto its history, dropping the oldest beyond 20.
    static func pushCurrentVersion(of comment: inout ReviewComment) {
        comment.previousVersions.append(CommentRevision(kind: comment.kind, title: comment.title, body: comment.body,
                                                        suggestion: comment.suggestion, withdraw: false))
        if comment.previousVersions.count > maxPreviousVersions {
            comment.previousVersions.removeFirst(comment.previousVersions.count - maxPreviousVersions)
        }
    }

    /// The versions of a report after `draft` is put aside with `note`; an empty draft is not kept.
    static func versions(afterSaving draft: ReportDraft?, note: String, at date: Date) -> [ReportVersion] {
        guard let draft else { return [] }
        var versions = draft.versions
        if !draft.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            versions.append(ReportVersion(markdown: draft.markdown, savedAt: date, note: note))
        }
        if versions.count > maxReportVersions { versions.removeFirst(versions.count - maxReportVersions) }
        return versions
    }

    /// The recommendation written under the "Recommendation" heading (plan section 6.10): of "reject", "major
    /// revision", "minor revision" and "accept", the one that occurs first in that section, ignoring case.
    /// The section runs from the heading to the next heading of the same or a higher level.
    static func recommendation(in markdown: String) -> Recommendation? {
        let lines = markdown.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { headingLevel($0) != nil && headingTitle($0).lowercased().hasPrefix("recommendation") }),
              let level = headingLevel(lines[start]) else { return nil }
        var section: [String] = []
        for line in lines[(start + 1)...] {
            if let other = headingLevel(line), other <= level { break }
            section.append(line)
        }
        let text = section.joined(separator: " ").lowercased()
        let candidates: [(String, Recommendation)] = [("reject", .reject), ("major revision", .majorRevision),
                                                      ("minor revision", .minorRevision), ("accept", .accept)]
        let found = candidates.compactMap { phrase, value in text.range(of: phrase).map { (position: $0.lowerBound, value: value) } }
        return found.min { $0.position < $1.position }?.value
    }

    private static func headingLevel(_ line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard hashes > 0, hashes <= 6, trimmed.dropFirst(hashes).first?.isWhitespace == true else { return nil }
        return hashes
    }

    private static func headingTitle(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespaces).drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
    }

    /// A title for a comment made from a chat answer: the first ten words of the text, on one line, at most 120
    /// characters (the parser's rule for a block without a title, plan section 6.5).
    static func title(fromBody body: String) -> String {
        let words = body.split(whereSeparator: { $0.isWhitespace }).prefix(10).joined(separator: " ")
        return words.count > 120 ? String(words.prefix(120)) : words
    }

    /// nil for a suggestion that is empty once white space is removed.
    static func cleanedSuggestion(_ suggestion: String?) -> String? {
        guard let suggestion, !suggestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return suggestion
    }
}
