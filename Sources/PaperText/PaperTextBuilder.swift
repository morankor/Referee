import Foundation
import RefereeCore

// Wave 0 placeholder (plan.md section 11.4, WP0a). WP1 replaces the body of `build` with the cleaning of section 7.2.

public struct PaperTextBuilder: PaperTextBuilding {
    private let stripMarginLineNumbers: @Sendable () -> Bool

    public init(stripMarginLineNumbers: @escaping @Sendable () -> Bool = { true }) {
        self.stripMarginLineNumbers = stripMarginLineNumbers
    }

    /// Placeholder: every raw line becomes a `.body` line with `contentRange == range`. Nothing is classified and no
    /// margin number is removed, so `stripMarginLineNumbers` is not consulted yet.
    public func build(from raw: RawDocument) -> PaperText {
        let pages = raw.pages.map { page in
            PageText(index: page.index, label: page.label, size: page.size, string: page.string,
                     lines: page.lines.map { line in
                         TextLine(pageIndex: page.index, range: line.range, contentRange: line.range, text: line.text, kind: .body,
                                  bounds: line.bounds)
                     })
        }
        return PaperText(pages: pages, hasTextLayer: Self.hasAtLeast200Letters(raw), hasMarginLineNumbers: false)
    }

    /// Plan section 7.2, step 7: a document with fewer than 200 letters has no text layer (a scanned PDF).
    private static func hasAtLeast200Letters(_ raw: RawDocument) -> Bool {
        var letters = 0
        for page in raw.pages {
            for character in page.string where character.isLetter {
                letters += 1
                if letters >= 200 { return true }
            }
        }
        return false
    }
}
