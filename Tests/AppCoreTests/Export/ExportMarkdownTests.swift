import Foundation
import Testing
@testable import AppCore

/// The Markdown reading behind plain text, Word and PDF export (plan.md section 6.10), checked on its own.
@Suite struct ExportMarkdownTests {
    private func runs(_ text: String) -> [ExportRun] { ExportInline.parse(text) }
    private func plain(_ text: String) -> ExportRun { ExportRun(text: text) }
    private func em(_ text: String) -> ExportRun { ExportRun(text: text, emphasis: true) }
    private func strong(_ text: String) -> ExportRun { ExportRun(text: text, strong: true) }
    private func both(_ text: String) -> ExportRun { ExportRun(text: text, strong: true, emphasis: true) }
    private func code(_ text: String) -> ExportRun { ExportRun(text: text, code: true) }

    @Test func emphasisFollowsCommonMark() {
        #expect(runs("*foo**bar**baz*") == [em("foo"), both("bar"), em("baz")])
        #expect(runs("**foo*bar*baz**") == [strong("foo"), both("bar"), strong("baz")])
        #expect(runs("***strong emph***") == [both("strong emph")])
        #expect(runs("*foo*bar") == [em("foo"), plain("bar")])
        #expect(runs("foo*bar*") == [plain("foo"), em("bar")])
        #expect(runs("_foo_bar") == [plain("_foo_bar")])                 // no emphasis inside a word with "_"
        #expect(runs("__foo__bar") == [plain("__foo__bar")])
        #expect(runs("**foo bar **") == [plain("**foo bar **")])          // the closer follows a space
        #expect(runs("** not emphasis **") == [plain("** not emphasis **")])
        #expect(runs("****x") == [plain("****x")])
        #expect(runs("**x") == [plain("**x")])
        #expect(runs("*(x)*") == [em("(x)")])
        #expect(runs("a*\"b\"*") == [plain("a*\"b\"*")])                  // CommonMark example 352
    }

    @Test func codeSpansLinksAndEscapes() {
        #expect(runs("a `code *with* stars` b") == [plain("a "), code("code *with* stars"), plain(" b")])
        #expect(runs("``a ` b``") == [code("a ` b")])
        #expect(runs("` padded `") == [code("padded")])
        #expect(runs("`unclosed") == [plain("`unclosed")])
        #expect(runs("[link *text*](https://example.org)") == [plain("link "), em("text"), plain(" (https://example.org)")])
        #expect(runs("[x](<a b>)") == [plain("x (a b)")])
        #expect(runs("[](https://example.org)") == [plain("https://example.org")])
        #expect(runs("[a](b(c)d)") == [plain("a (b(c)d)")])
        #expect(runs("\\*x\\* \\_y\\_ \\q") == [plain("*x* _y_ \\q")])
        #expect(runs("**bold** `code` *em*") == [strong("bold"), plain(" "), code("code"), plain(" "), em("em")])
        #expect(runs("one\ntwo") == [plain("one\ntwo")])
    }

    @Test func blocks() {
        let blocks = ExportMarkdown.parse("""
            # Title
            Intro line one
            line two.

            - one
            - two

            - three
              1. nested
            > quoted
            ***
            ```
            raw *text*
            ```
            """)
        #expect(blocks == [
            .heading(level: 1, runs: [plain("Title")]),
            .paragraph([plain("Intro line one line two.")]),
            .item(ExportListItem(ordered: false, marker: "-", level: 0, paragraphs: [[plain("one")]], followsBlankLine: false)),
            .item(ExportListItem(ordered: false, marker: "-", level: 0, paragraphs: [[plain("two")]], followsBlankLine: false)),
            .item(ExportListItem(ordered: false, marker: "-", level: 0, paragraphs: [[plain("three")]], followsBlankLine: true)),
            .item(ExportListItem(ordered: true, marker: "1.", level: 1, paragraphs: [[plain("nested")]], followsBlankLine: false)),
            .quote([[plain("quoted")]]),
            .rule,
            .code(["raw *text*"]),
        ])
    }

    @Test func setextHeadingsThematicBreaksAndFences() {
        #expect(ExportMarkdown.parse("Text\n---") == [.heading(level: 2, runs: [plain("Text")])])
        #expect(ExportMarkdown.parse("Text\n===") == [.heading(level: 1, runs: [plain("Text")])])
        #expect(ExportMarkdown.parse("Text\n\n---") == [.paragraph([plain("Text")]), .rule])
        #expect(ExportMarkdown.parse("- - -") == [.rule])
        #expect(ExportMarkdown.parse("~~~\nnot closed\n``` (not the same fence)") == [.code(["not closed", "``` (not the same fence)"])])
        #expect(ExportMarkdown.parse("``` inline ` code") == [.paragraph([plain("``` inline ` code")])])
        #expect(ExportMarkdown.parse("\ttabbed text") == [.paragraph([plain("tabbed text")])])
    }

    @Test func listMarkersThatAreNotLists() {
        #expect(ExportMarkdown.parse("-not a bullet") == [.paragraph([plain("-not a bullet")])])
        #expect(ExportMarkdown.parse("1.5 percent") == [.paragraph([plain("1.5 percent")])])
        #expect(ExportMarkdown.parse("1234567890. too long") == [.paragraph([plain("1234567890. too long")])])
        #expect(ExportMarkdown.parse("Text\n-\nmore") == [.heading(level: 2, runs: [plain("Text")]), .paragraph([plain("more")])])
        #expect(ExportMarkdown.parse("Text\n2. two") == [.paragraph([plain("Text 2. two")])])
        #expect(ExportMarkdown.parse("Text\n- bullet") == [
            .paragraph([plain("Text")]),
            .item(ExportListItem(ordered: false, marker: "-", level: 0, paragraphs: [[plain("bullet")]], followsBlankLine: false)),
        ])
    }
}
