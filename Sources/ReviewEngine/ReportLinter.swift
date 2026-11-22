import Foundation
import RefereeCore

/// The deterministic style check of plan.md Appendix B.7. Matching is case-insensitive and on word boundaries except
/// where a pattern starts or ends with punctuation (the em dash, the trailing "-ing" clause). Ranges are UTF-16 ranges
/// in the Markdown. Findings come in document order, numbered from 0.
enum ReportLinter {
    private struct Rule {
        let id: String
        let pattern: NSRegularExpression
        let message: (String) -> String
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Literal patterns: a failure is a programmer error.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static let textRules: [Rule] = [
        Rule(id: "banned-word",
             pattern: regex(#"\b(?:delv(?:e|es|ed|ing)|tapestry|multifaceted|pivotal|testament|underscor(?:e|es|ed|ing)|leverag(?:e|es|ed|ing)|utili[sz](?:e|es|ed|ing)|foster(?:s|ed|ing)?|showcas(?:e|es|ed|ing)|elucidat(?:e|es|ed|ing)|illuminat(?:e|es|ed|ing)|synerg(?:y|ies)|paradigms?|holistic)\b"#),
             message: { "'\($0)' reads as machine-written; use a plain word." }),
        Rule(id: "check-word", pattern: regex(#"\b(?:landscape|navigat(?:e|es|ed|ing)|robust)\b"#),
             message: { "Keep '\($0)' only in its literal sense (for 'robust': a named robustness check)." }),
        Rule(id: "em-dash", pattern: regex("—"), message: { _ in "Em dash: use a comma, parentheses or a new sentence." }),
        Rule(id: "not-only", pattern: regex(#"\bnot only\b[^.?!]{0,120}\bbut also\b"#),
             message: { _ in "'not only … but also': state the point directly." }),
        Rule(id: "copula", pattern: regex(#"\b(?:serves|stands|functions) as\b"#), message: { _ in "Write 'is'." }),
        Rule(id: "gerund-tail",
             pattern: regex(#",\s+(?:highlighting|underscoring|reflecting|emphasi[sz]ing|showcasing|demonstrating|illustrating|underlining)\b[^.?!]*[.?!]"#),
             message: { _ in "Trailing '-ing' clause: make it a sentence with a specific claim, or delete it." }),
        Rule(id: "third-person",
             pattern: regex(#"\b(?:this reviewer|the reviewer (?:believes|feels|notes|thinks)|it is noted that|it should be noted)\b"#),
             message: { _ in "Use the first person." }),
        Rule(id: "hedge-stack", pattern: regex(#"\b(?:(?:could|might|may) (?:potentially|possibly|perhaps)|it could be argued)\b"#),
             message: { _ in "Stacked hedge: take a position or say you cannot judge." }),
    ]

    private static let flatteringOpener = regex(#"\b(?:commendable|valuable contribution|interesting paper|well[- ]written|timely)\b"#)
    private static let optimisticCloser = regex(#"\b(?:promising|exciting|potential to|bright future|future directions)\b"#)
    private static let summaryOpening = regex(#"^[\s*_>]*this (?:paper|manuscript|study|article) (?:presents|proposes|investigates|explores|examines)\b"#)
    private static let strengthsWord = regex(#"\bstrengths?\b"#)
    private static let weaknessesWord = regex(#"\bweakness(?:es)?\b"#)
    private static let sentenceEnd = regex(#"[.?!]+(?=\s|$)"#)

    static func lint(_ markdown: String) -> [LintFinding] {
        let structure = ReportStructure(markdown)
        let text = structure.text
        let whole = NSRange(location: 0, length: text.length)
        var found: [(range: NSRange, order: Int, sequence: Int, rule: String, message: String)] = []
        func add(_ range: NSRange, _ rule: String, _ message: String, order: Int) { found.append((range, order, found.count, rule, message)) }

        for (order, rule) in textRules.enumerated() {
            for match in rule.pattern.matches(in: markdown, range: whole) {
                add(match.range, rule.id, rule.message(text.substring(with: match.range)), order: order)
            }
        }

        let paragraphs = structure.paragraphs()
        // flattering-opener: the first paragraph after the first heading.
        let firstHeadingLine = structure.headings.first?.line ?? -1
        if let opener = paragraphs.first(where: { $0.lowerBound > firstHeadingLine }) {
            let range = structure.range(of: opener)
            if let match = flatteringOpener.firstMatch(in: markdown, range: range) {
                add(match.range, "flattering-opener", "Opening praise without content.", order: 20)
            }
        }
        // optimistic-closer: the last paragraph.
        if let closer = paragraphs.last, let match = optimisticCloser.firstMatch(in: markdown, range: structure.range(of: closer)) {
            add(match.range, "optimistic-closer", "Ends on generic optimism; end with the last question.", order: 21)
        }
        // template-heading: a heading naming strengths and weaknesses.
        for heading in structure.headings {
            let line = structure.lines[heading.line]
            if strengthsWord.firstMatch(in: markdown, range: line.range) != nil, weaknessesWord.firstMatch(in: markdown, range: line.range) != nil {
                add(line.range, "template-heading", "This heading is a common marker of generated reviews.", order: 22)
            }
        }
        // missing-section: the six template headings.
        for name in ReportStructure.templateSections where structure.section(named: name) == nil {
            add(NSRange(location: text.length, length: 0), "missing-section", "Section '\(displayName(name))' is missing.", order: 23)
        }
        // opens-with-summary: a summary that opens by describing the paper and runs to more than four sentences.
        if let (_, body) = structure.section(named: "summary assessment"), let paragraph = structure.paragraphs(in: body).first {
            let range = structure.range(of: paragraph)
            if summaryOpening.firstMatch(in: markdown, range: range) != nil,
               sentenceEnd.numberOfMatches(in: markdown, range: range) > 4 {
                let firstEnd = sentenceEnd.firstMatch(in: markdown, range: range)
                let sentence = firstEnd.map { NSRange(location: range.location, length: $0.range.upperBound - range.location) } ?? range
                add(sentence, "opens-with-summary", "Do not summarise the paper; state the assessment.", order: 24)
            }
        }
        // recommendation-mismatch: the recommendation against the number of major concerns.
        if let recommendation = structure.recommendation(), let (heading, body) = structure.section(named: "recommendation") {
            let items = structure.majorConcernItems()
            let positive = recommendation == .accept || recommendation == .minorRevision
            if (positive && items > 0) || (!positive && items == 0) {
                let range = structure.paragraphs(in: body).first.map { structure.range(of: $0) } ?? structure.lines[heading.line].range
                add(range, "recommendation-mismatch", "The recommendation does not match the concerns listed.", order: 25)
            }
        }

        return found.sorted { ($0.range.location, $0.order, $0.range.length, $0.sequence) < ($1.range.location, $1.order, $1.range.length, $1.sequence) }
            .enumerated()
            .map { LintFinding(id: $0.offset, range: TextRange($0.element.range), rule: $0.element.rule, message: $0.element.message) }
    }

    /// "major concerns" -> "Major concerns".
    private static func displayName(_ name: String) -> String {
        name.prefix(1).uppercased() + name.dropFirst()
    }
}
