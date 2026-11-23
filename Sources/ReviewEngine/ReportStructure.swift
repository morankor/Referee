import Foundation
import RefereeCore

/// The headings, sections and paragraphs of a report's Markdown, with UTF-16 ranges (the coordinates of `LintFinding`).
///
/// A heading is a Markdown heading line (`## Major concerns`), or a line that is only bold text naming one of the six
/// template sections (`**Major concerns**`), which models drifting from the template write. A section runs from its
/// heading to the next heading. A paragraph is a run of non-empty lines that are not headings.
struct ReportStructure {
    /// The six headings of the default template (Appendix B.4), lower-cased.
    static let templateSections = ["summary assessment", "recommendation", "publication probability", "major concerns", "minor concerns",
                                   "questions for the authors"]
    /// The six headings of the conference template (Appendix B.4): "chance of acceptance" for "publication probability".
    static let conferenceSections = ["summary assessment", "recommendation", "chance of acceptance", "major concerns", "minor concerns",
                                     "questions for the authors"]

    /// The template headings of a report written for a venue of this kind.
    static func sections(for kind: VenueKind) -> [String] {
        kind == .conference ? conferenceSections : templateSections
    }

    struct Line {
        let range: NSRange           // without the line break
        let text: String
    }

    struct Heading {
        let line: Int                // index into `lines`
        let name: String             // normalised: lower-cased, emphasis and a trailing colon removed, spaces collapsed
    }

    let text: NSString
    let lines: [Line]
    let headings: [Heading]

    private static let atxHeading = try! NSRegularExpression(pattern: #"^\s{0,3}#{1,6}\s+(.*?)\s*#*\s*$"#)
    private static let boldLine = try! NSRegularExpression(pattern: #"^\s*(?:\*\*|__)(.+?)(?:\*\*|__)\s*:?\s*$"#)

    /// `sections`: the template headings a line of bold text may name (those of the report's venue kind).
    init(_ markdown: String, sections: [String] = templateSections) {
        text = markdown as NSString
        var lines: [Line] = []
        var start = 0
        let length = text.length
        while start <= length {
            let rest = NSRange(location: start, length: length - start)
            let newline = text.range(of: "\n", options: [], range: rest)
            let end = newline.location == NSNotFound ? length : newline.location
            var lineRange = NSRange(location: start, length: end - start)
            if lineRange.length > 0, text.character(at: lineRange.upperBound - 1) == 0x0D { lineRange.length -= 1 }
            lines.append(Line(range: lineRange, text: text.substring(with: lineRange)))
            if newline.location == NSNotFound { break }
            start = end + 1
        }
        self.lines = lines
        var headings: [Heading] = []
        for (position, line) in lines.enumerated() {
            if let name = Self.headingName(line.text, sections: sections) { headings.append(Heading(line: position, name: name)) }
        }
        self.headings = headings
    }

    static func headingName(_ line: String, sections: [String] = templateSections) -> String? {
        let ns = line as NSString
        let whole = NSRange(location: 0, length: ns.length)
        if let match = atxHeading.firstMatch(in: line, range: whole) {
            return normalised(ns.substring(with: match.range(at: 1)))
        }
        if let match = boldLine.firstMatch(in: line, range: whole) {
            let name = normalised(ns.substring(with: match.range(at: 1)))
            if sections.contains(where: { name == $0 || name.hasPrefix($0 + ":") }) { return name }
        }
        return nil
    }

    static func normalised(_ heading: String) -> String {
        var name = CommentValues.collapsingWhitespace(CommentValues.stripEmphasis(heading)).lowercased()
        while name.hasSuffix(":") { name.removeLast() }
        return name.trimmingCharacters(in: .whitespaces)
    }

    func isHeading(_ line: Int) -> Bool { headings.contains { $0.line == line } }

    /// The section whose heading is `name` (or starts with it and a colon, "Recommendation: Reject"), as the lines after
    /// the heading up to the next one.
    func section(named name: String) -> (heading: Heading, lines: Range<Int>)? {
        guard let position = headings.firstIndex(where: { $0.name == name || $0.name.hasPrefix(name + ":") }) else { return nil }
        let heading = headings[position]
        let end = position + 1 < headings.count ? headings[position + 1].line : lines.count
        return (heading, (heading.line + 1)..<end)
    }

    /// Runs of non-empty, non-heading lines within `lineRange`, as ranges of line indices.
    func paragraphs(in lineRange: Range<Int>? = nil) -> [Range<Int>] {
        let range = lineRange ?? 0..<lines.count
        var result: [Range<Int>] = []
        var start: Int?
        for position in range {
            let blank = lines[position].text.trimmingCharacters(in: .whitespaces).isEmpty || isHeading(position)
            if blank {
                if let open = start { result.append(open..<position) }
                start = nil
            } else if start == nil {
                start = position
            }
        }
        if let open = start { result.append(open..<range.upperBound) }
        return result
    }

    /// The UTF-16 range from the first line's start to the last line's end.
    func range(of lineRange: Range<Int>) -> NSRange {
        guard let first = lineRange.first, let last = lineRange.last else { return NSRange(location: 0, length: 0) }
        return NSRange(location: lines[first].range.location, length: lines[last].range.upperBound - lines[first].range.location)
    }

    func string(of lineRange: Range<Int>) -> String { text.substring(with: range(of: lineRange)) }

    // ---- the recommendation (section 6.10) ----

    /// Parsed from the text under the "Recommendation" heading: the first of "reject", "major revision",
    /// "minor revision", "accept" (case-insensitive) in its first sentence, else in the whole section. Nil without the
    /// heading or a match.
    static func recommendation(in markdown: String) -> Recommendation? {
        ReportStructure(markdown).recommendation()
    }

    func recommendation() -> Recommendation? {
        guard let (heading, body) = section(named: "recommendation") else { return nil }
        let inHeading = String(heading.name.dropFirst("recommendation".count))
        let sectionText = inHeading + "\n" + string(of: body)
        let firstLine = sectionText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        let firstSentence = firstLine.split(whereSeparator: { ".?!".contains($0) }).first.map(String.init) ?? firstLine
        return Self.recommendation(matching: firstSentence) ?? Self.recommendation(matching: sectionText)
    }

    private static func recommendation(matching text: String) -> Recommendation? {
        let lowered = text.lowercased()
        let order: [(String, Recommendation)] = [("reject", .reject), ("major revision", .majorRevision), ("minor revision", .minorRevision),
                                                 ("accept", .accept)]
        return order.first { lowered.contains($0.0) }?.1
    }

    /// A conference's recommendation (Appendix G.9), parsed the same way: the label of the venue's scale named in the
    /// first sentence under the "Recommendation" heading, else in the whole section (`VenueProfile.scaleLabel(in:)`).
    /// Nil without the heading, or when the text names no label of the scale.
    static func recommendationLabel(in markdown: String, venue: VenueProfile) -> String? {
        ReportStructure(markdown, sections: sections(for: venue.kind)).recommendationLabel(on: venue)
    }

    func recommendationLabel(on venue: VenueProfile) -> String? {
        guard let (heading, body) = section(named: "recommendation") else { return nil }
        let inHeading = String(heading.name.dropFirst("recommendation".count))
        let sectionText = inHeading + "\n" + string(of: body)
        let firstLine = sectionText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        let firstSentence = firstLine.split(whereSeparator: { ".?!".contains($0) }).first.map(String.init) ?? firstLine
        return venue.scaleLabel(in: firstSentence) ?? venue.scaleLabel(in: sectionText)
    }

    /// List items (numbered or bulleted) under the "Major concerns" heading.
    func majorConcernItems() -> Int {
        guard let (_, body) = section(named: "major concerns") else { return 0 }
        return body.filter { position in
            let line = lines[position].text
            return line.range(of: #"^\s*(?:\*\*)?(?:\d+[.)]|[-*•])\s+\S"#, options: .regularExpression) != nil
        }.count
    }
}
