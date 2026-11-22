import AppKit
import Foundation
import Testing
@testable import AppCore

/// `PaperSize.current` (plan.md section 11.3) and the attributed text that Word and PDF export share.
@Suite struct ExportPaperSizeTests {
    @Test func letterInTheUnitedStatesCanadaAndMexicoA4Elsewhere() {
        for region in ["US", "CA", "MX", "us"] { #expect(PaperSize.forRegion(region) == .letter, "\(region)") }
        for region in ["GB", "DE", "FR", "IL", "JP", "BR", "AU", "001"] { #expect(PaperSize.forRegion(region) == .a4, "\(region)") }
        #expect(PaperSize.forRegion(nil) == .a4)
        #expect(PaperSize.current == PaperSize.forRegion(Locale.current.region?.identifier))
    }

    @Test func theSheetsInPoints() {
        #expect(PaperSize.letter.points == NSSize(width: 612, height: 792))
        #expect(PaperSize.a4.points == NSSize(width: 595, height: 842))
    }

    /// Black on white whatever the appearance, so that a report exported in dark mode is readable on paper.
    @Test @MainActor func theRichTextIsBlackAndBuiltFromTheBlocks() throws {
        let sample = """
            ## Major concerns

            1. First, with *emphasis*.
               - a sub-point
            > A quote.

            ```
            code
            ```
            """
        let text = ExportRichText.attributedString(for: ExportMarkdown.parse(sample))
        #expect(text.string == "Major concerns\n1.\tFirst, with emphasis.\n\u{2022}\ta sub-point\nA quote.\ncode")
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            #expect(attributes[.foregroundColor] as? NSColor == NSColor.black, "\(range)")
            #expect(attributes[.font] is NSFont, "\(range)")
            #expect(attributes[.paragraphStyle] is NSParagraphStyle, "\(range)")
        }
        let nested = try #require(text.attribute(.paragraphStyle, at: (text.string as NSString).range(of: "a sub-point").location,
                                                 effectiveRange: nil) as? NSParagraphStyle)
        let top = try #require(text.attribute(.paragraphStyle, at: (text.string as NSString).range(of: "First").location,
                                              effectiveRange: nil) as? NSParagraphStyle)
        #expect(nested.headIndent > top.headIndent)
        #expect(top.headIndent > 0 && top.firstLineHeadIndent == 0)
    }
}
