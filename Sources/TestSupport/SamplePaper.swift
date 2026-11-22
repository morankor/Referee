import Foundation
import CryptoKit
import RefereeCore

/// Every raw line becomes a .body line with contentRange == range. Clean for every fixture except ay_nolinks and s1_ruler.
///
/// Nothing is classified and nothing is removed: line numbers, page numbers and watermarks stay in the body text, which
/// is why the two journal-stamped fixtures are not clean. `hasTextLayer` follows the 200-letter rule of plan section 7.2,
/// `hasMarginLineNumbers` is false and there is no title guess.
public func identityPaperText(from raw: RawDocument) -> PaperText {
    let pages = raw.pages.map { page in
        PageText(index: page.index, label: page.label, size: page.size, string: page.string,
                 lines: page.lines.map { line in
                     TextLine(pageIndex: page.index, range: line.range, contentRange: line.range, text: line.text, kind: .body,
                              bounds: line.bounds)
                 })
    }
    var letters = 0
    for page in raw.pages where letters < 200 {
        for character in page.string where character.isLetter {
            letters += 1
            if letters >= 200 { break }
        }
    }
    return PaperText(pages: pages, hasTextLayer: letters >= 200, hasMarginLineNumbers: false)
}

/// A LoadedPaper built from a raw dump with identityPaperText (no PDFKit); data = the fixture file's bytes.
///
/// `fixture` is a name without extension: Fixtures/raw/<fixture>.raw.json and Fixtures/pdf/<fixture>.pdf. The reference
/// carries the real SHA-256 and size of the PDF, so it equals the one PDFPaperService gives for the same file, except
/// that `lastKnownPath` is nil.
public func makeSamplePaper(fixture: String = "ay_round_nolinks") throws -> LoadedPaper {
    let raw = try Fixtures.rawDocument(fixture)
    let data = try Fixtures.read("pdf/\(fixture).pdf")
    let ref = DocumentRef(sha256: sha256Hex(of: data), fileName: "\(fixture).pdf", byteCount: data.count, pageCount: raw.pages.count)
    return LoadedPaper(ref: ref, data: data, isEncrypted: false, text: identityPaperText(from: raw), links: raw.links, outline: raw.outline)
}

/// Lowercase hexadecimal SHA-256, the form `DocumentRef.sha256` uses.
func sha256Hex(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
