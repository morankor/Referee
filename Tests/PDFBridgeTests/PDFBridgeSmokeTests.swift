import Foundation
import PDFKit
import Testing
import RefereeCore
import PDFBridge
import TestSupport

/// Wave 0 tests of the two things Wave 0 wrote here in their simplest working form: raw extraction and `load`.
/// They state what the committed fixtures rely on, so they must keep holding when WP2 completes the target.
@Suite struct PDFBridgeSmokeTests {
    private struct IdentityBuilder: PaperTextBuilding {
        func build(from raw: RawDocument) -> PaperText { identityPaperText(from: raw) }
    }

    private static let fixtures = ["ay_nolinks", "s1_ruler", "ay_round_nolinks", "ay_links", "num_links", "num_twocol_links", "scanned"]

    @Test func bytesThatAreNotAPDFAreRejected() async {
        let service = PDFPaperService(builder: IdentityBuilder())
        await #expect(throws: PaperError.notAPDF) {
            _ = try await service.load(data: Data("plain text, not a PDF".utf8), fileName: "note.txt")
        }
        await #expect(throws: PaperError.notAPDF) {
            _ = try await service.load(data: Data(), fileName: "empty.pdf")
        }
        await #expect(throws: PaperError.self) {            // the right first bytes, and nothing a PDF needs after them
            _ = try await service.load(data: Data("%PDF-1.5\nthis is not a document\n".utf8), fileName: "broken.pdf")
        }
    }

    @Test func aFileThatDoesNotExistIsUnreadableAndTheMessageDoesNotNameIt() async {
        let service = PDFPaperService(builder: IdentityBuilder())
        do {
            _ = try await service.load(url: URL(fileURLWithPath: "/nonexistent-folder/secret-manuscript.pdf"))
            Issue.record("loading a missing file should throw")
        } catch let error as PaperError {
            guard case .unreadable = error else {
                Issue.record("expected .unreadable, got \(error)")
                return
            }
            #expect(!error.userMessage.contains("secret-manuscript"))
            #expect(!error.userMessage.contains("nonexistent-folder"))
        } catch {
            Issue.record("expected a PaperError, got \(error)")
        }
    }

    @Test func anEmptyDocumentHasNoPages() {
        #expect(RawExtractor.extract(from: PDFDocument()).pages.isEmpty)
    }

    /// The committed dumps are what the extractor gives for the committed PDFs. If this fails after a change to the
    /// extractor or to the fixtures, run scripts/make-fixtures.sh and look at the difference before committing it.
    @Test(arguments: fixtures)
    func extractionOfAFixtureEqualsItsCommittedDump(name: String) throws {
        let document = try #require(PDFDocument(url: Fixtures.url("pdf/\(name).pdf")))
        #expect(RawExtractor.extract(from: document) == (try Fixtures.rawDocument(name)))
    }

    @Test(arguments: fixtures)
    func loadGivesThePaperOfTheFile(name: String) async throws {
        let url = Fixtures.url("pdf/\(name).pdf")
        let bytes = try Data(contentsOf: url)
        let raw = try Fixtures.rawDocument(name)
        let paper = try await PDFPaperService(builder: IdentityBuilder()).load(url: url)

        // The same reference as the sample paper made without PDFKit, plus where the file was.
        let sample = try makeSamplePaper(fixture: name)
        #expect(paper.ref.sha256 == sample.ref.sha256)
        #expect(paper.ref.fileName == "\(name).pdf")
        #expect(paper.ref.lastKnownPath == url.path)
        #expect(paper.ref.byteCount == bytes.count)
        #expect(paper.ref.pageCount == raw.pages.count)
        #expect(paper.data == bytes)
        #expect(!paper.isEncrypted)
        #expect(paper.text == identityPaperText(from: raw))         // the builder it was given built the text
        #expect(paper.links == raw.links)
        #expect(paper.outline == raw.outline)
        #expect(paper.text.hasTextLayer == (name != "scanned"))

        #expect(try Data(contentsOf: url) == bytes)                 // the file is as it was
    }

    @Test func loadFromDataLeavesThePathEmpty() async throws {
        let bytes = try Data(contentsOf: Fixtures.url("pdf/num_links.pdf"))
        let paper = try await PDFPaperService(builder: IdentityBuilder()).load(data: bytes, fileName: "renamed.pdf")
        #expect(paper.ref.fileName == "renamed.pdf")
        #expect(paper.ref.lastKnownPath == nil)
        #expect(paper.ref.pageCount == 4)
        #expect(paper.links.count == 12)
    }
}
