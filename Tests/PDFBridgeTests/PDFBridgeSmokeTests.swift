import Foundation
import PDFKit
import Testing
import RefereeCore
import PDFBridge
import TestSupport

/// Wave 0a smoke tests. They hold for the placeholders and must keep holding for the real implementation (WP0b, WP2).
@Suite struct PDFBridgeSmokeTests {
    private struct IdentityBuilder: PaperTextBuilding {
        func build(from raw: RawDocument) -> PaperText { identityPaperText(from: raw) }
    }

    @Test func bytesThatAreNotAPDFAreRejected() async {
        let service = PDFPaperService(builder: IdentityBuilder())
        await #expect(throws: PaperError.self) {
            _ = try await service.load(data: Data("plain text, not a PDF".utf8), fileName: "note.txt")
        }
    }

    @Test func anEmptyDocumentHasNoPages() {
        #expect(RawExtractor.extract(from: PDFDocument()).pages.isEmpty)
    }
}
