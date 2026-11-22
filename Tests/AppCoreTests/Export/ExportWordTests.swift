import AppKit
import Foundation
import Testing
import RefereeCore
import TestSupport
@testable import AppCore

/// WP8a acceptance row "export, Word" (plan.md section 11.4). AppKit, hence the main actor.
@Suite struct ExportWordTests {
    @MainActor private func readBack(_ data: Data) throws -> (text: NSAttributedString, attributes: [String: Any]) {
        var attributes: NSDictionary?
        let text = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                                          documentAttributes: &attributes)
        return (text, attributes as? [String: Any] ?? [:])
    }

    @Test @MainActor func wordStartsWithPKAndReadsBackWithTheSixHeadingsInBold() throws {
        let sample = try Fixtures.text("llm/report_sample.txt")
        let data = try ReportExporter.data(markdown: sample, format: .docx, paper: .letter)
        #expect(data.prefix(2) == Data("PK".utf8))

        let text = try readBack(data).text
        for heading in ExportSamples.templateHeadings {
            #expect(ExportFontCheck.every(heading, in: text, ExportFontCheck.isBold), "\(heading) is bold")
        }
        // Only the headings: paragraphs and items are not bold, and no Markdown mark is left.
        #expect(ExportFontCheck.every("The paper studies how sequential traders", in: text) { !ExportFontCheck.isBold($0) })
        #expect(ExportFontCheck.every("The interval includes one (p. 1).", in: text) { !ExportFontCheck.isBold($0) })
        #expect(text.string.contains("1.\tThe interval includes one (p. 1)."))
        #expect(text.string.contains("2.\tRollout timing (p. 1)."))
        #expect(text.string.contains("1.\tDoes Proposition 1 require bounded signals?"))
        #expect(!text.string.contains("##"))
        // Headings are larger than the text.
        let headingFont = text.attribute(.font, at: (text.string as NSString).range(of: "Major concerns").location, effectiveRange: nil) as? NSFont
        let bodyFont = text.attribute(.font, at: (text.string as NSString).range(of: "Rollout timing").location, effectiveRange: nil) as? NSFont
        #expect((headingFont?.pointSize ?? 0) > (bodyFont?.pointSize ?? 0))
    }

    @Test @MainActor func emphasisSurvivesInWord() throws {
        let markdown = "## Recommendation\n\n**Major revision.** The *main result* does not hold, and `x_1` is never defined.\n"
        let text = try readBack(try ReportExporter.data(markdown: markdown, format: .docx, paper: .a4)).text
        #expect(text.string.hasPrefix("Recommendation\n"))
        #expect(ExportFontCheck.every("Major revision.", in: text, ExportFontCheck.isBold))
        #expect(ExportFontCheck.every("main result", in: text) { ExportFontCheck.isItalic($0) && !ExportFontCheck.isBold($0) })
        #expect(ExportFontCheck.every("does not hold", in: text) { !ExportFontCheck.isItalic($0) && !ExportFontCheck.isBold($0) })
        #expect(ExportFontCheck.every("x_1", in: text) { $0?.isFixedPitch == true })
        #expect(!text.string.contains("*") && !text.string.contains("`"))
    }

    @Test(arguments: [PaperSize.letter, .a4]) @MainActor func theWordPageMatchesThePaper(_ paper: PaperSize) throws {
        let attributes = try readBack(try ReportExporter.data(markdown: "Text.", format: .docx, paper: paper)).attributes
        let size = (attributes[NSAttributedString.DocumentAttributeKey.paperSize.rawValue] as? NSValue)?.sizeValue
        #expect(size == (paper == .letter ? NSSize(width: 612, height: 792) : NSSize(width: 595, height: 842)))
        for key in [NSAttributedString.DocumentAttributeKey.leftMargin, .rightMargin, .topMargin, .bottomMargin] {
            #expect((attributes[key.rawValue] as? NSNumber)?.doubleValue == 72, "\(key.rawValue)")
        }
    }

    /// Referee reports are anonymous: the file must not carry the name of the account that wrote it.
    @Test @MainActor func theWordFileNamesNobody() throws {
        let attributes = try readBack(try ReportExporter.data(markdown: "## Summary assessment\n\nText.", format: .docx, paper: .a4)).attributes
        for key in [NSAttributedString.DocumentAttributeKey.author, .company, .editor, .copyright, .comment] {
            #expect(attributes[key.rawValue] == nil, "\(key.rawValue)")
        }
    }

    @Test @MainActor func anEmptyReportIsStillADocument() throws {
        let data = try ReportExporter.data(markdown: "", format: .docx, paper: .a4)
        #expect(data.prefix(2) == Data("PK".utf8))
        #expect(try readBack(data).text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
