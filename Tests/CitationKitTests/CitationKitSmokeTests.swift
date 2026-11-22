import Foundation
import Testing
import RefereeCore
import CitationKit

/// Wave 0a smoke test. It holds for the placeholder and must keep holding for the real implementation (WP3).
@Suite struct CitationKitSmokeTests {
    @Test func aPaperWithoutAReferenceListGivesAnEmptyIndex() {
        let paper = PaperText(pages: [], hasTextLayer: false, hasMarginLineNumbers: false)
        let index = CitationIndexer().buildIndex(paper: paper, links: [])
        #expect(index.style == .unknown)
        #expect(index.entries.isEmpty)
        #expect(index.mentions.isEmpty)
    }
}
