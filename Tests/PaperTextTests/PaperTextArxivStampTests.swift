import Foundation
import Testing
import RefereeCore
import PaperText

/// Gate 1: the stamp arXiv prints up the left margin of page 1 is boilerplate (plan.md section 7.2, step 2). Found on
/// the real papers of Fixtures/private: rotated, the stamp has the tallest bounds of the page and was the title guess.
@Suite struct PaperTextArxivStampTests {
    @Test(arguments: ["arXiv:1409.0473v7 [cs.CL] 19 May 2016", "arXiv:1803.09015v4  [econ.EM]  1 Dec 2020",
                      "arXiv:hep-th/9901001v1 [hep-th] 4 Jan 1999", "arXiv:1706.03762 [cs.CL] 2 Aug 2023"])
    func theStampIsBoilerplate(stamp: String) {
        var page = PaperTextSample.rawPage(index: 0, lines: [stamp, "A Title Set Large", "Anonymous", "Abstract", "The text of the paper."])
        page.lines[0].bounds = PageRect(pageIndex: 0, x: 20, y: 200, width: 12, height: 360)           // rotated: tall and narrow
        page.lines[1].bounds?.height = 17
        let paper = PaperTextBuilder().build(from: RawDocument(pages: [page]))
        #expect(paper.pages[0].lines[0].kind == .watermark)
        #expect(paper.titleGuess == "A Title Set Large")
    }

    @Test(arguments: ["See arXiv:1409.0473v7 for the proofs.", "arXiv:1409.0473v7", "arXiv:1409.0473 [cs.CL]",
                      "Smith (2020), arXiv:1409.0473 [cs.CL] 19 May 2016, p. 3"])
    func aReferenceToArXivInTheTextIsNot(line: String) {
        let paper = PaperTextBuilder().build(from: RawDocument(pages: [PaperTextSample.rawPage(index: 0, lines: [line, "More text."])]))
        #expect(paper.pages[0].lines[0].kind == .body)
    }
}
