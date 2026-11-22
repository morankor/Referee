import Foundation
import Testing
@testable import RefereeUI

/// The report preview's Markdown conversion (plan.md section 9.8; WP10).
@Suite struct SidebarMarkdownTests {
    private func plain(_ blocks: [SidebarMarkdownBlock]) -> [String] {
        blocks.map { String($0.text.characters) }
    }

    @Test func aReportBecomesHeadingsParagraphsAndNumberedItems() {
        let markdown = """
        ## Summary assessment

        The paper studies sequential traders.
        I do not think the main claim holds.

        ## Recommendation

        Major revision.

        ## Major concerns

        1. The interval includes one (p. 1).
        2. Rollout timing (p. 1). Nothing shows that
           it is unrelated to outcomes.

        ## Questions for the authors

        1) Does Proposition 1 require bounded signals?
        """
        let blocks = SidebarMarkdown.blocks(from: markdown)
        #expect(blocks.map(\.kind) == [
            .heading(level: 2), .paragraph, .heading(level: 2), .paragraph, .heading(level: 2),
            .numberedItem(marker: "1."), .numberedItem(marker: "2."), .heading(level: 2), .numberedItem(marker: "1)"),
        ])
        #expect(plain(blocks) == [
            "Summary assessment", "The paper studies sequential traders. I do not think the main claim holds.", "Recommendation",
            "Major revision.", "Major concerns", "The interval includes one (p. 1).",
            "Rollout timing (p. 1). Nothing shows that it is unrelated to outcomes.", "Questions for the authors",
            "Does Proposition 1 require bounded signals?",
        ])
        #expect(blocks.map(\.id) == Array(0..<9))
    }

    @Test func inlineEmphasisIsAppliedAndItsMarkersRemoved() {
        let blocks = SidebarMarkdown.blocks(from: "The effect is *small* and **not robust**.")
        #expect(plain(blocks) == ["The effect is small and not robust."])
        let intents = blocks[0].text.runs.compactMap { $0.inlinePresentationIntent }
        #expect(intents.contains(.emphasized))
        #expect(intents.contains(.stronglyEmphasized))
    }

    @Test func headingLevelsAndWhatIsNotAHeading() {
        let blocks = SidebarMarkdown.blocks(from: "# One\n### Three ###\n####### Seven\n#hashtag\n######")
        #expect(blocks.map(\.kind) == [.heading(level: 1), .heading(level: 3), .paragraph, .heading(level: 6)])
        #expect(plain(blocks) == ["One", "Three", "####### Seven #hashtag", ""])
        #expect(SidebarMarkdown.heading("## C# is a language")?.text == "C# is a language")
    }

    @Test func bulletsRulesAndBlankLines() {
        let blocks = SidebarMarkdown.blocks(from: "- first\n* second\n+ third\n\n---\n\nAfter the rule.\n**Bold** start")
        #expect(blocks.map(\.kind) == [.bulletItem, .bulletItem, .bulletItem, .rule, .paragraph])
        #expect(plain(blocks) == ["first", "second", "third", "", "After the rule. Bold start"])
    }

    @Test func numbersThatAreNotListMarkers() {
        #expect(SidebarMarkdown.numberedItem("10–20% at a top field journal.") == nil)
        #expect(SidebarMarkdown.numberedItem("2.4 points") == nil)
        #expect(SidebarMarkdown.numberedItem("12. Twelfth")?.marker == "12.")
        #expect(SidebarMarkdown.blocks(from: "10–20% at a top field journal.").map(\.kind) == [.paragraph])
    }

    @Test func emptyTextHasNoBlocks() {
        #expect(SidebarMarkdown.blocks(from: "").isEmpty)
        #expect(SidebarMarkdown.blocks(from: "\n\n  \n").isEmpty)
    }

    @Test func textThatIsNotMarkdownStaysAsItIs() {
        #expect(String(SidebarMarkdown.inline("[unclosed link").characters) == "[unclosed link")
        #expect(String(SidebarMarkdown.inline("Em dash — kept").characters) == "Em dash — kept")
    }
}
