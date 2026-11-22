import Foundation
import Testing
import RefereeCore
import TestSupport
@testable import AppCore

/// WP8a acceptance row "export, text" (plan.md section 11.4): Markdown is the text itself; plain text has headings on
/// a line of their own followed by a blank line, no emphasis markers, and the numbered lists kept.
@Suite struct ExportPlainTextTests {
    @Test @MainActor func markdownIsTheTextAsItIs() throws {
        let markdown = "## Summary assessment\n\nShort \u{2014} and \u{201C}quoted\u{201D}: M\u{00FC}ller (2019), 10\u{2013}20%, \u{2713}"
        #expect(try ReportExporter.data(markdown: markdown, format: .markdown) == Data(markdown.utf8))
        #expect(try ReportExporter.data(markdown: "", format: .markdown).isEmpty)
    }

    @Test @MainActor func theSampleReportLosesOnlyItsHeadingMarks() throws {
        let sample = try Fixtures.text("llm/report_sample.txt")
        let plain = ReportExporter.plainText(fromMarkdown: sample)
        // The sample's headings are "## …" lines followed by a blank line, its paragraphs single lines, its lists
        // numbered and without emphasis: its plain text is the sample without the heading marks.
        #expect(plain == sample.replacingOccurrences(of: "## ", with: ""))
        #expect(plain.contains("\nMajor concerns\n\n1. The interval includes one (p. 1)."))
        #expect(plain.contains("\n2. Rollout timing (p. 1)."))
        #expect(try ReportExporter.data(markdown: sample, format: .plainText) == Data(plain.utf8))
    }

    @Test @MainActor func emphasisMarkersAreRemoved() {
        let markdown = """
            ## Summary assessment
            The paper is *careful* but the **main claim** does not hold; the _identifying assumption_ is __never__ defended, \
            and ***nothing*** in Table 2 supports it.

            ## Recommendation

            **Major revision.** The concerns below go to the *main result*.
            """
        #expect(ReportExporter.plainText(fromMarkdown: markdown) == """
            Summary assessment

            The paper is careful but the main claim does not hold; the identifying assumption is never defended, \
            and nothing in Table 2 supports it.

            Recommendation

            Major revision. The concerns below go to the main result.

            """)
    }

    @Test @MainActor func asterisksAndUnderscoresThatAreNotEmphasisStay() {
        let markdown = "The estimator uses x_i and y_j, the file data_v2_final.csv, the product 2 * 3 * 4, a ** b, "
            + "and p < 0.05* as the threshold; snake_case_name stays, as does 5*3, and so does `__init__` in code."
        #expect(ReportExporter.plainText(fromMarkdown: markdown) == markdown.replacingOccurrences(of: "`", with: "") + "\n")
    }

    @Test @MainActor func everyKindOfHeadingBecomesALineFollowedByABlankLine() {
        let markdown = "# Report\n### Detail ###\nTitle\n=====\nSubtitle\n--------\nText right after.\n#hashtag is text\n####### seven is text"
        #expect(ReportExporter.plainText(fromMarkdown: markdown) == """
            Report

            Detail

            Title

            Subtitle

            Text right after. #hashtag is text ####### seven is text

            """)
    }

    @Test @MainActor func listsKeepTheirNumbersAndNesting() {
        let markdown = """
            ## Major concerns

            1. First concern
               continues here.
            2) Second concern
               - a sub-point
               * another
                 + deeper
            3. Third

            4. Fourth, after a blank line

               with a second paragraph.

            - a bullet
            """
        #expect(ReportExporter.plainText(fromMarkdown: markdown) == """
            Major concerns

            1. First concern continues here.
            2) Second concern
               - a sub-point
               - another
                  - deeper
            3. Third

            4. Fourth, after a blank line
               with a second paragraph.

            - a bullet

            """)
    }

    @Test @MainActor func aNumberThatStartsALineInsideAParagraphIsNotAList() {
        let markdown = "The rule was introduced in\n2019. Since then it has been applied twice.\n\nThree points:\n1. one\n2. two"
        #expect(ReportExporter.plainText(fromMarkdown: markdown) == """
            The rule was introduced in 2019. Since then it has been applied twice.

            Three points:

            1. one
            2. two

            """)
    }

    @Test @MainActor func softLineBreaksJoinAndHardOnesStay() {
        let markdown = "The first line\ncontinues here.\n\nA hard break follows  \nthis line, and another\\\nthis one."
        #expect(ReportExporter.plainText(fromMarkdown: markdown) == """
            The first line continues here.

            A hard break follows
            this line, and another
            this one.

            """)
    }

    @Test @MainActor func linksCodeEscapesAndCharacterReferences() {
        let markdown = "See [the replication files](https://example.org/files \"Files\") and <https://doi.org/10.1000/xyz123>, "
            + "write to <editor@example.org>, run `x*y_z`, keep \\*stars\\* and \\_underscores\\_, AT&T &amp; co. &#8211; done. "
            + "![Figure 2](fig2.png) [plain](plain) [not a link] (either)"
        #expect(ReportExporter.plainText(fromMarkdown: markdown) == "See the replication files (https://example.org/files) and "
            + "https://doi.org/10.1000/xyz123, write to editor@example.org, run x*y_z, keep *stars* and _underscores_, "
            + "AT&T & co. \u{2013} done. Figure 2 plain [not a link] (either)\n")
    }

    @Test @MainActor func quotesKeepTheirMarkAndCodeKeepsItsCharacters() {
        let markdown = """
            > The authors write that the effect is *robust*.
            > It is not.
            >
            > Second paragraph.

            ```text
            let x = a * b * c   // **not** bold
            ```
            After the code.
            """
        #expect(ReportExporter.plainText(fromMarkdown: markdown) == """
            > The authors write that the effect is robust. It is not.
            >
            > Second paragraph.

            let x = a * b * c   // **not** bold

            After the code.

            """)
    }

    @Test @MainActor func lineEndingsAndEmptyInput() {
        let unix = "## Summary assessment\n\nShort.\n\n1. One\n2. Two\n"
        #expect(ReportExporter.plainText(fromMarkdown: unix.replacingOccurrences(of: "\n", with: "\r\n"))
                == ReportExporter.plainText(fromMarkdown: unix))
        #expect(ReportExporter.plainText(fromMarkdown: unix.replacingOccurrences(of: "\n", with: "\r"))
                == ReportExporter.plainText(fromMarkdown: unix))
        #expect(ReportExporter.plainText(fromMarkdown: "") == "")
        #expect(ReportExporter.plainText(fromMarkdown: " \n\n\t\n") == "")
        #expect(ReportExporter.plainText(fromMarkdown: "---\n***") == "")
    }

    /// The report is model output and user edits: no input may crash the converter or make it loop.
    @Test(.timeLimit(.minutes(1))) @MainActor func garbageAndPathologicalInputEnd() {
        var generator = ExportSeededGenerator(seed: 0x5EED)
        let alphabet = Array("*_`[]()!<>&#;:\\-+=~ \n\n  1.)abc\u{00E9}\u{2014}\u{1F600}\t>|")
        for _ in 0..<300 {
            let length = Int.random(in: 0..<400, using: &generator)
            let text = String((0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] })
            _ = ReportExporter.plainText(fromMarkdown: text)
        }
        let pathological = [
            String(repeating: "*", count: 20_000),
            String(repeating: "*a", count: 10_000),
            String(repeating: "_a ", count: 10_000),
            String(repeating: "[", count: 10_000) + String(repeating: "](x)", count: 10_000),
            String(repeating: "[a](", count: 5_000),
            String(repeating: "`", count: 5_000) + "x" + String(repeating: "``", count: 2_000),
            String(repeating: "<", count: 10_000),
            String(repeating: "&#", count: 10_000),
            String(repeating: "  - ", count: 5_000),
            String(repeating: "> ", count: 5_000),
            String(repeating: "1. a\n   ", count: 3_000),
            String(repeating: "```\n", count: 3_001),
        ]
        for text in pathological {
            let plain = ReportExporter.plainText(fromMarkdown: text)
            #expect(plain.count <= text.count + text.count / 2 + 2)
        }
    }
}

/// A small deterministic generator (SplitMix64) so that the garbage is the same on every run.
struct ExportSeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
