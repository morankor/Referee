import Foundation
import RefereeCore

// Wave 0a placeholder (see Placeholder.swift).

/// Every raw line becomes a .body line with contentRange == range. Clean for every fixture except ay_nolinks and s1_ruler.
/// Placeholder: an empty paper.
public func identityPaperText(from raw: RawDocument) -> PaperText {
    PaperText(pages: [], hasTextLayer: false, hasMarginLineNumbers: false)
}

/// A LoadedPaper built from a raw dump with identityPaperText (no PDFKit); data = the fixture file's bytes.
/// Placeholder: always throws.
public func makeSamplePaper(fixture: String = "ay_round_nolinks") throws -> LoadedPaper {
    throw NotImplementedYet(what: "makeSamplePaper")
}
