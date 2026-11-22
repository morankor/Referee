import Foundation
import PDFKit
import Testing
import RefereeCore
import PDFBridge
import TestSupport

/// WP2 rows "load", "failures", "file untouched" and "off-main" (plan.md section 11.4), and how loads are counted.
@Suite struct PaperServiceLoadTests {
    // MARK: - Load

    @Test(arguments: [("ay_nolinks", 4), ("ay_round_nolinks", 4), ("ay_links", 4), ("s1_ruler", 4), ("num_links", 4),
                      ("num_twocol_links", 2), ("scanned", 1), ("ay_long", 16)])
    func loadGivesThePagesTheHashOfTheFileAndNoEncryption(name: String, pages: Int) async throws {
        let url = Fixtures.url("pdf/\(name).pdf")
        let paper = try await PDFPaperService(builder: IdentityTextBuilder()).load(url: url)
        #expect(paper.ref.pageCount == pages)
        #expect(paper.text.pages.map(\.index) == Array(0..<pages))
        #expect(paper.ref.sha256 == (try shasum256(of: url)))
        #expect(paper.ref.byteCount == (try Data(contentsOf: url)).count)
        #expect(!paper.isEncrypted)
    }

    @Test(arguments: allFixtures)
    func twoLoadsGiveEqualText(name: String) async throws {
        let url = Fixtures.url("pdf/\(name).pdf")
        let service = PDFPaperService(builder: TrailingDigitsBuilder())       // with recomputed bounds, not only raw ones
        let first = try await service.load(url: url)
        let second = try await service.load(url: url)
        let elsewhere = try await PDFPaperService(builder: TrailingDigitsBuilder()).load(data: try Data(contentsOf: url), fileName: "copy.pdf")
        #expect(first.text == second.text)
        #expect(first.text == elsewhere.text)
        #expect(first.ref == second.ref)
        #expect(first.ref.sha256 == elsewhere.ref.sha256)
        #expect(first.links == elsewhere.links && first.outline == elsewhere.outline)
    }

    // MARK: - Failures

    @Test func dataThatDoesNotStartWithTheMarkerIsNotAPDF() async throws {
        let service = PDFPaperService(builder: IdentityTextBuilder())
        let pdf = try Data(contentsOf: Fixtures.url("pdf/ay_round_nolinks.pdf"))
        let samples: [Data] = [
            Data(), Data("%PDF".utf8), Data("%pdf-1.5\n".utf8), Data("plain text, not a PDF".utf8),
            Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),                  // a PNG signature
            Data(repeating: 0x20, count: 1_024) + pdf,                               // the marker starts at byte 1,024
        ]
        for data in samples {
            await #expect(throws: PaperError.notAPDF) { _ = try await service.load(data: data, fileName: "sample.pdf") }
        }
    }

    @Test func theMarkerMayStartAnywhereInTheFirst1024Bytes() async throws {
        let pdf = try Data(contentsOf: Fixtures.url("pdf/ay_round_nolinks.pdf"))
        let padded = Data(repeating: 0x20, count: 1_023) + pdf                       // starts at byte 1,023, the last allowed
        let paper = try await PDFPaperService(builder: IdentityTextBuilder()).load(data: padded, fileName: "padded.pdf")
        #expect(paper.ref.pageCount == 4)
        #expect(paper.data == padded)
    }

    @Test func aScannedPDFLoadsWithoutATextLayer() async throws {
        let paper = try await PDFPaperService(builder: IdentityTextBuilder()).load(url: Fixtures.url("pdf/scanned.pdf"))
        #expect(!paper.text.hasTextLayer)
        #expect(paper.ref.pageCount == 1)
        #expect(paper.text.pages.allSatisfy { $0.lines.isEmpty })
    }

    @Test func dataPDFKitCannotOpenIsUnreadable() async throws {
        let service = PDFPaperService(builder: IdentityTextBuilder())
        let pdf = try Data(contentsOf: Fixtures.url("pdf/ay_round_nolinks.pdf"))
        for data in [Data("%PDF-1.5\nthis is not a document\n".utf8), pdf.prefix(pdf.count / 2)] {
            do {
                _ = try await service.load(data: Data(data), fileName: "damaged.pdf")
                Issue.record("damaged data loaded")
            } catch let error as PaperError {
                guard case .unreadable = error else { Issue.record("expected .unreadable, got \(error)"); continue }
            }
        }
    }

    /// `.empty` cannot be produced with real data on macOS 26: PDFKit (and CoreGraphics) refuse a well-formed PDF whose
    /// page tree is empty, so it comes back `.unreadable`. The service still checks the page count in case PDFKit ever
    /// opens one.
    @Test func aPDFWithoutPagesIsRejected() async throws {
        var body = "%PDF-1.4\n"
        var offsets: [Int] = []
        for object in ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [] /Count 0 >>"] {
            offsets.append(body.utf8.count)
            body += "\(offsets.count) 0 obj\n\(object)\nendobj\n"
        }
        let xref = body.utf8.count
        body += "xref\n0 3\n0000000000 65535 f \n" + offsets.map { String(format: "%010d 00000 n \n", $0) }.joined()
        body += "trailer\n<< /Size 3 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        do {
            _ = try await PDFPaperService(builder: IdentityTextBuilder()).load(data: Data(body.utf8), fileName: "no-pages.pdf")
            Issue.record("a PDF without pages loaded")
        } catch let error as PaperError {
            switch error {
            case .empty, .unreadable: break
            default: Issue.record("expected .empty or .unreadable, got \(error)")
            }
        }
    }

    // MARK: - Loads are counted

    @Test func aDocumentStaysLoadedUntilItsLastLoadIsReleased() async throws {
        let service = PDFPaperService(builder: IdentityTextBuilder())
        let url = Fixtures.url("pdf/ay_round_nolinks.pdf")
        let first = try await service.load(url: url)
        let spans = [TextSpan(pageIndex: 0, range: first.text.pages[0].lines[0].range)]
        #expect(await service.rects(for: spans, in: first.ref).count == 1)

        let second = try await service.load(data: first.data, fileName: "same-bytes.pdf")   // another window, the same file
        await service.unload(second.ref)
        #expect(await service.rects(for: spans, in: first.ref).count == 1)

        await service.unload(first.ref)
        #expect(await service.rects(for: spans, in: first.ref).isEmpty)
        await service.unload(first.ref)                                                     // one unload too many does nothing
        #expect(await service.rects(for: spans, in: first.ref).isEmpty)

        let again = try await service.load(url: url)
        #expect(await service.rects(for: spans, in: again.ref).count == 1)
    }

    @Test func aDocumentThatWasNeverLoadedHasNoRectangles() async throws {
        let paper = try makeSamplePaper()
        let service = PDFPaperService(builder: IdentityTextBuilder())
        #expect(await service.rects(for: contentSpans(of: paper.text), in: paper.ref).isEmpty)
        await service.unload(paper.ref)
    }

    // MARK: - The file is never touched (section 4.6)

    @Test(arguments: allFixtures)
    func theFileIsUnchangedByLoadRectsAndUnload(name: String) async throws {
        let url = Fixtures.url("pdf/\(name).pdf")
        let bytes = try Data(contentsOf: url)
        let modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date

        let service = PDFPaperService(builder: TrailingDigitsBuilder())
        let paper = try await service.load(url: url)
        _ = await service.rects(for: contentSpans(of: paper.text), in: paper.ref)
        await service.unload(paper.ref)

        #expect(paper.data == bytes)
        #expect(try Data(contentsOf: url) == bytes)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == modified)
    }

    // MARK: - Nothing about the manuscript is logged (section 12.2)

    @Test func theLogNamesNeitherTheFileNorItsText() async throws {
        let events = LoggedEvents()
        let sink = Log.addTestSink { name, fields in events.append(name, fields) }
        defer { Log.removeTestSink(sink) }

        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let url = folder.url.appendingPathComponent("confidential-manuscript-4711.pdf")
        try Data(contentsOf: Fixtures.url("pdf/ay_nolinks.pdf")).write(to: url)
        let service = PDFPaperService(builder: TrailingDigitsBuilder())
        let paper = try await service.load(url: url)
        _ = await service.rects(for: contentSpans(of: paper.text), in: paper.ref)
        await service.unload(paper.ref)
        _ = await service.rects(for: contentSpans(of: paper.text), in: paper.ref)            // no longer loaded
        _ = try? await service.load(url: folder.url.appendingPathComponent("missing-manuscript-4711.pdf"))
        _ = try? await service.load(data: Data("not a manuscript".utf8), fileName: "renamed-manuscript-4711.pdf")

        // The sink also sees the events of every other test running now; this holds for all of them.
        let ours = events.all.filter { $0.name.hasPrefix("pdf.") }
        #expect(ours.contains { $0.name == "pdf.load.done" } && ours.contains { $0.name == "pdf.load.failed" })
        #expect(ours.contains { $0.name == "pdf.rects.notLoaded" })
        for event in ours {
            for value in event.fields.values {
                guard case .id(let id) = value else { continue }
                #expect(!id.contains("4711") && !id.contains("manuscript") && !id.contains("Herding"), "\(event.name): \(id)")
            }
        }
    }

    // MARK: - Off the main thread

    @Test func loadAndRectsCompleteFromDetachedTasks() async throws {
        let service = PDFPaperService(builder: TrailingDigitsBuilder())
        let tasks = allFixtures.map { name in
            Task.detached { () -> (pages: Int, rects: Int) in
                let paper = try await service.load(url: Fixtures.url("pdf/\(name).pdf"))
                let rects = await service.rects(for: contentSpans(of: paper.text), in: paper.ref)
                await service.unload(paper.ref)
                return (paper.ref.pageCount, rects.count)
            }
        }
        for (name, task) in zip(allFixtures, tasks) {
            let result = try await task.value
            #expect(result.pages == (try Fixtures.rawDocument(name)).pages.count, "\(name)")
            #expect((result.rects > 0) == (name != "scanned"), "\(name): \(result.rects) rectangles")
        }
    }
}
