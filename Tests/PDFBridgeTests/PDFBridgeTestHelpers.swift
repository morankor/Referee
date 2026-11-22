import Foundation
import PDFKit
import Testing
import RefereeCore
import PDFBridge
import TestSupport

// Shared by the WP2 tests. This target cannot import PaperText, so the two builders below stand in for the real one.

/// The seven committed fixtures (Fixtures/pdf and Fixtures/raw).
let allFixtures = ["ay_nolinks", "s1_ruler", "ay_round_nolinks", "ay_links", "num_links", "num_twocol_links", "scanned"]

/// Every raw line as a `.body` line with `contentRange == range` (TestSupport's `identityPaperText`).
struct IdentityTextBuilder: PaperTextBuilding {
    func build(from raw: RawDocument) -> PaperText { identityPaperText(from: raw) }
}

/// Marks the trailing digits of every line as its margin number: at most two, since `ay_nolinks` numbers its lines 1–54
/// (so the Springer line "J Polit Econ 108(1):34–55" with 46 glued to it keeps its "55"). A line of nothing else becomes
/// `.marginNumberOnly`, page numbers included, which is good enough for geometry. Bounds stay the raw ones, as the
/// `PaperTextBuilding` contract requires.
struct TrailingDigitsBuilder: PaperTextBuilding {
    func build(from raw: RawDocument) -> PaperText {
        let pages = raw.pages.map { page in
            PageText(index: page.index, label: page.label, size: page.size, string: page.string, lines: page.lines.map { line in
                let units = Array(line.text.utf16)
                var digits = 0
                while digits < 2, digits < units.count, (0x30...0x39).contains(units[units.count - 1 - digits]) { digits += 1 }
                let content = TextRange(location: line.range.location, length: line.range.length - digits)
                return TextLine(pageIndex: page.index, range: line.range, contentRange: content,
                                text: String(decoding: units.dropLast(digits), as: UTF16.self),
                                kind: content.length == 0 ? .marginNumberOnly : .body,
                                marginNumber: digits > 0 ? Int(String(decoding: units.suffix(digits), as: UTF16.self)) : nil,
                                bounds: line.bounds)
            })
        }
        return PaperText(pages: pages, hasTextLayer: true, hasMarginLineNumbers: true)
    }
}

/// A fixture as a `PDFDocument` made from its bytes, the way the service makes its own (no `documentURL`).
func fixtureDocument(_ name: String) throws -> PDFDocument {
    try #require(PDFDocument(data: try Data(contentsOf: Fixtures.url("pdf/\(name).pdf"))), "Fixtures/pdf/\(name).pdf does not open")
}

/// The box PDFKit gives the one character at `index` of the page string.
func characterBox(on page: PDFPage, at index: Int) -> CGRect? {
    page.selection(for: NSRange(location: index, length: 1))?.bounds(for: page)
}

/// The spans of every line's content on every page, as a highlight of the whole text would ask for.
func contentSpans(of text: PaperText) -> [TextSpan] {
    text.pages.flatMap { page in page.lines.map { TextSpan(pageIndex: page.index, range: $0.contentRange) } }
}

/// `shasum -a 256` of a file, run as the command itself.
func shasum256(of url: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
    process.arguments = ["-a", "256", url.path]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let hash = String(decoding: data, as: UTF8.self).split(separator: " ").first.map(String.init)
    return try #require(process.terminationStatus == 0 ? hash : nil, "shasum failed")
}

/// A folder of its own in the temporary directory, for the files a test writes. Fixtures are never written.
struct TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("referee-pdfbridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
