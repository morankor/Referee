import Foundation
import PDFKit
import Testing
import RefereeCore
import PaperText
import TestSupport

/// The second half of the row "no false positives" (plan.md section 11.4, WP1): no margin numbers are found in any
/// real paper directly inside `Fixtures/private` (git-ignored; the public papers of scripts/fetch-optional-fixtures.sh).
/// A file there is a PDF, dumped here the way `RawExtractor` dumps it, or a raw dump (`*.raw.json`, from
/// `referee-cli dump-raw`). Skipped when there is none. Journal-system PDFs, which do have line numbers, belong in a
/// subfolder, which this test does not read. Files are named by their position only, so no file name reaches the log.
@Suite struct PaperTextPrivateFixtureTests {
    static let files: [URL] = {
        let folder = Fixtures.url("private")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.filter { $0.hasSuffix(".pdf") || $0.hasSuffix(".raw.json") }.sorted().map { folder.appendingPathComponent($0) }
    }()

    @Test(.enabled(if: !files.isEmpty, "Fixtures/private holds no PDF and no raw dump"), arguments: files.indices)
    func noMarginNumbersInARealPaper(file: Int) throws {
        let raw = try #require(Self.rawDocument(at: Self.files[file]), "file \(file) could not be read")
        #expect(!PaperTextBuilder().build(from: raw).hasMarginLineNumbers, "file \(file)")
    }

    /// The dump made here equals the committed one, so a private PDF is read as `RawExtractor` would read it.
    @Test func theDumpOfAFixturePDFEqualsItsCommittedDump() throws {
        let made = try #require(Self.rawDocument(at: Fixtures.url("pdf/ay_links.pdf")))
        #expect(made.pages == (try Fixtures.rawDocument("ay_links")).pages)
    }

    static func rawDocument(at url: URL) -> RawDocument? {
        if url.lastPathComponent.hasSuffix(".raw.json") {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(RawDocument.self, from: data)
        }
        guard let document = PDFDocument(url: url) else { return nil }
        return RawDocument(pages: (0..<document.pageCount).compactMap { index in document.page(at: index).map { page(of: $0, index: index) } })
    }

    /// Plan section 7.2, "Raw extraction": one line per line selection of the whole page, its range without trailing
    /// line breaks, the text at that range and the selection's bounds.
    private static func page(of page: PDFPage, index: Int) -> RawPage {
        let string = page.string ?? ""
        let text = string as NSString
        var lines: [RawLine] = []
        if text.length > 0, let whole = page.selection(for: NSRange(location: 0, length: text.length)) {
            for selection in whole.selectionsByLine() where selection.numberOfTextRanges(on: page) > 0 {
                var range = selection.range(at: 0, on: page)
                guard range.location != NSNotFound, range.location >= 0, NSMaxRange(range) <= text.length else { continue }
                while range.length > 0, [0x0A, 0x0D, 0x2028, 0x2029].contains(text.character(at: NSMaxRange(range) - 1)) { range.length -= 1 }
                let bounds = selection.bounds(for: page)
                lines.append(RawLine(range: TextRange(range), text: text.substring(with: range),
                                     bounds: PageRect(pageIndex: index, x: Double(bounds.origin.x), y: Double(bounds.origin.y),
                                                      width: Double(bounds.size.width), height: Double(bounds.size.height))))
            }
        }
        let size = page.bounds(for: .mediaBox).size
        return RawPage(index: index, label: page.label, size: PageSize(width: Double(size.width), height: Double(size.height)),
                       string: string, lines: lines)
    }
}
