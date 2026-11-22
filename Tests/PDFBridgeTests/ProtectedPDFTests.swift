import Foundation
import PDFKit
import Testing
import RefereeCore
import PDFBridge
import TestSupport

/// WP2 row "protected PDFs" (plan.md sections 7.2 and 11.4). The protected files are temporary copies written with
/// `PDFDocument.write(to:withOptions:)`, the one call of that kind section 4.6 allows, into a folder of the test's own.
///
/// The copy is made from `num_links`. Writing a document re-encodes its fonts, and on this OS the "ff" and "ffi"
/// ligatures of the other fixtures then come back from `page.string` as "!" and "\"" (with or without a password), so
/// their page text is not the original's; `num_links` has no such ligature on page 1.
@Suite struct ProtectedPDFTests {
    /// Low- and high-quality printing and accessibility, nothing else: copying and changes are disabled.
    /// (`PDFAccessPermissions` is a plain enum in Swift, so the flags are given as a number.)
    private static let printingOnly = NSNumber(value: UInt(1 << 0 | 1 << 1 | 1 << 5))

    private static func writeCopy(of fixture: String, to url: URL, options: [PDFDocumentWriteOption: Any]) throws {
        let source = try fixtureDocument(fixture)
        try #require(source.write(to: url, withOptions: options), "the protected copy could not be written")
    }

    @Test func anOwnerPasswordWithCopyingDisabledLoadsAsEncryptedWithTheOriginalText() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let url = folder.url.appendingPathComponent("owner-protected.pdf")
        try Self.writeCopy(of: "num_links", to: url, options: [.ownerPasswordOption: "owner-password", .accessPermissionsOption: Self.printingOnly])

        // The copy really is what the row describes: it opens without a password, encrypted, and copying is disabled.
        let check = try #require(PDFDocument(data: try Data(contentsOf: url)))
        #expect(check.isEncrypted && !check.isLocked && !check.allowsCopying && check.allowsPrinting)

        let paper = try await PDFPaperService(builder: IdentityTextBuilder()).load(url: url)
        #expect(paper.isEncrypted)
        #expect(paper.ref.pageCount == 4)
        let original = try Fixtures.rawDocument("num_links")
        #expect(paper.text.pages.first?.string == original.pages.first?.string)
        #expect(paper.text.hasTextLayer)
    }

    @Test func aUserPasswordIsRefused() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let url = folder.url.appendingPathComponent("user-protected.pdf")
        // PDFKit encrypts only when an owner password is given; a user password alone writes a plain file.
        try Self.writeCopy(of: "num_links", to: url, options: [.userPasswordOption: "user-password", .ownerPasswordOption: "owner-password"])
        #expect(try #require(PDFDocument(data: try Data(contentsOf: url))).isLocked)

        let service = PDFPaperService(builder: IdentityTextBuilder())
        await #expect(throws: PaperError.encrypted) { _ = try await service.load(url: url) }
        await #expect(throws: PaperError.encrypted) { _ = try await service.load(data: try Data(contentsOf: url), fileName: "user-protected.pdf") }
    }
}
