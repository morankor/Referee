import AppKit
import Foundation
import PDFKit
import Testing
import RefereeCore
import TestSupport
@testable import AppCore

/// WP8a acceptance row "export, PDF" (plan.md section 11.4). The PDF is printed with NSPrintOperation, which must run
/// on the main thread. PDFKit is imported here only, to read the result back.
@Suite struct ExportPDFTests {
    private func mediaBox(_ paper: PaperSize) -> (width: Double, height: Double) {
        paper == .letter ? (612, 792) : (595, 842)
    }

    @Test(arguments: [PaperSize.letter, .a4]) @MainActor func aLongReportHasTextOnEveryPage(_ paper: PaperSize) throws {
        let data = try ReportExporter.data(markdown: ExportSamples.longReport(), format: .pdf, paper: paper)
        #expect(data.starts(with: Data("%PDF-".utf8)))
        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount >= 3)

        let expected = mediaBox(paper)
        for index in 0..<document.pageCount {
            let page = try #require(document.page(at: index))
            let box = page.bounds(for: .mediaBox)
            #expect(Double(box.width).rounded() == expected.width && Double(box.height).rounded() == expected.height,
                    "page \(index + 1): \(box.width) x \(box.height)")
            let characters = page.string?.count ?? 0
            #expect(characters > 200, "page \(index + 1) of \(document.pageCount) has \(characters) characters")
        }
        let text = document.string ?? ""
        #expect(text.contains("Remarks on the appendix"))           // the last heading
        for heading in ExportSamples.longHeadings { #expect(text.contains(heading), "\(heading)") }
        #expect(text.contains("Item 1-1:") && text.contains("Item 4-14:"))   // the first and the last item
        #expect(!text.contains("##"))
    }

    @Test @MainActor func theSampleReportFitsOnePage() throws {
        let sample = try Fixtures.text("llm/report_sample.txt")
        let document = try #require(PDFDocument(data: try ReportExporter.data(markdown: sample, format: .pdf, paper: .a4)))
        #expect(document.pageCount == 1)
        let text = document.string ?? ""
        for heading in ExportSamples.templateHeadings { #expect(text.contains(heading), "\(heading)") }
        #expect(text.contains("Does Proposition 1 require bounded signals?"))
    }

    @Test @MainActor func anEmptyReportIsStillAPDF() throws {
        let data = try ReportExporter.data(markdown: "", format: .pdf, paper: .letter)
        #expect(data.starts(with: Data("%PDF-".utf8)))
        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount == 1)
    }

    /// Referee reports are anonymous: no author in the PDF, and a neutral title.
    @Test @MainActor func thePDFNamesNobody() throws {
        let data = try ReportExporter.data(markdown: "## Summary assessment\n\nText.", format: .pdf, paper: .a4)
        let attributes = try #require(PDFDocument(data: data)).documentAttributes ?? [:]
        #expect(attributes[PDFDocumentAttribute.authorAttribute] == nil)
        #expect(attributes[PDFDocumentAttribute.titleAttribute] as? String == "Referee report")
        let fullName = NSFullUserName()
        if fullName.count >= 3 {
            for (key, value) in attributes {
                if let value = value as? String { #expect(!value.contains(fullName), "\(key)") }
            }
        }
    }

    @Test @MainActor func printingLeavesNoTemporaryFile() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("referee-export-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let text = ExportRichText.attributedString(for: ExportMarkdown.parse("## Summary assessment\n\nText."))
        let data = try ExportPrinter.pdf(text, paper: .a4, scratch: scratch)
        #expect(data.starts(with: Data("%PDF-".utf8)))
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
    }
}
