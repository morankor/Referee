import AppKit
import PDFKit
import Testing
import TestSupport
@testable import RefereeUI

/// The reference viewer's model (plan.md section 7.7) and the list of the Reader's scenes (section 10.1).
@Suite struct ReaderViewerAndScenesTests {
    @Test @MainActor func theViewerShowsTheFileFromItsBytes() async {
        let viewer = ReaderViewerModel(fileURL: Fixtures.url("pdf/num_twocol_links.pdf"), title: "A cited paper")
        #expect(viewer.state == .loading)
        #expect(viewer.pageCountText == nil)                        // the toolbar shows no count before the file is read
        await viewer.load()
        #expect(viewer.state == .ready)
        #expect(viewer.pageCount == 2)
        #expect(viewer.pageCountText == "2 pages")
        #expect(viewer.pdfView.document?.pageCount == 2)
        #expect(viewer.pdfView.document?.documentURL == nil)       // made from the bytes: the viewer cannot write the file
        await viewer.load()                                         // once only
        #expect(viewer.state == .ready)
        viewer.zoom(.zoomIn)
        #expect(!viewer.pdfView.autoScales)
        viewer.zoom(.fitWidth)
        #expect(viewer.pdfView.autoScales)
    }

    @Test @MainActor func aFileThatIsNoPDFIsSaidSo() async {
        let viewer = ReaderViewerModel(fileURL: Fixtures.url("llm/review_clean.txt"), title: "Not a paper")
        await viewer.load()
        #expect(viewer.state == .failed("This file could not be opened."))
        let missing = ReaderViewerModel(fileURL: Fixtures.url("pdf/no_such_paper.pdf"), title: "Missing")
        await missing.load()
        #expect(missing.state == .failed("This file could not be opened."))
        #expect(missing.pdfView.document == nil)
    }

    @Test @MainActor func theSevenScenesOfSection101() {
        let scenes = ReaderScenes.all
        #expect(scenes.map(\.name).filter { !$0.hasPrefix("design-") } == ["reader-highlights", "reader-selection", "reader-citation", "reader-find", "reader-references",
                                       "reader-ruler", "reference-viewer"])
        let byName = Dictionary(uniqueKeysWithValues: scenes.map { ($0.name, $0) })
        #expect(byName["reader-highlights"]?.fixturePDF == "ay_nolinks.pdf")
        #expect(byName["reader-highlights"]?.fixtureSession == "sample.json")
        #expect(byName["reader-selection"]?.fixturePDF == "ay_nolinks.pdf")
        #expect(byName["reader-citation"]?.fixturePDF == "ay_links.pdf")
        #expect(byName["reader-ruler"]?.fixturePDF == "s1_ruler.pdf")
        #expect(byName["reader-ruler"]?.fixtureSession == "sample.json")
        #expect(byName["reference-viewer"]?.kind == .referenceViewer)
        #expect(byName["reference-viewer"]?.fixturePDF == "num_twocol_links.pdf")
        #expect(scenes.filter { $0.name != "reference-viewer" }.allSatisfy { $0.kind == .review })
        #expect(scenes.filter { $0.name != "reference-viewer" }.allSatisfy { $0.verify != nil })
    }

    /// The design scenes of the Reader (docs/design-review.md, steps 4 and 5), each checking its state in `verify`.
    @Test @MainActor func theDesignScenesOfTheReader() {
        let scenes = ReaderScenes.all.filter { $0.name.hasPrefix("design-") }
        #expect(scenes.map(\.name) == ["design-citation-states", "design-find-no-matches", "design-selection-asked", "design-selection-copied",
                                       "design-references-filter", "design-find-with-comments"])
        #expect(scenes.allSatisfy { $0.kind == .review && $0.verify != nil })
        let byName = Dictionary(uniqueKeysWithValues: scenes.map { ($0.name, $0) })
        #expect(byName["design-selection-asked"]?.fixturePDF == "ay_nolinks.pdf")
        #expect(byName["design-selection-copied"]?.fixturePDF == "ay_nolinks.pdf")
        #expect(byName["design-references-filter"]?.fixturePDF == "ay_links.pdf")
        #expect(byName["design-find-with-comments"]?.fixturePDF == "ay_nolinks.pdf")
        #expect(byName["design-find-with-comments"]?.fixtureSession == "sample.json")
        // Captured inside Copy's feedback time, so that the picture shows "Copied".
        #expect((byName["design-selection-copied"]?.settleSeconds ?? 9) < Theme.feedbackDuration / .seconds(1))
    }
}
