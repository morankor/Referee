import Foundation
import Testing
import RefereeCore
import ReviewEngine
import TestSupport

/// Wave 0a smoke test. It holds for the placeholder and must keep holding for the real implementation (WP6).
@Suite struct ReviewEngineSmokeTests {
    /// The engine needs a PaperRendering. The real one is in PaperText, which this test target does not depend on,
    /// and TestSupport has no stand-in for it, so the test brings its own.
    private struct PageMarkerRenderer: PaperRendering {
        func render(_ paper: PaperText, pages: Range<Int>?) -> String {
            paper.pages.map { "[[page \($0.index + 1)]]\n" }.joined()
        }
        func chunkPageRanges(_ paper: PaperText, maxCharacters: Int) -> [Range<Int>] {
            paper.pages.isEmpty ? [] : [0..<paper.pages.count]
        }
    }

    @Test func aReviewForAnUnknownProviderEndsWithAFailedRun() async throws {
        let paper = LoadedPaper(ref: DocumentRef(sha256: String(repeating: "0", count: 64), fileName: "empty.pdf", byteCount: 0, pageCount: 0),
                                data: Data(), isEncrypted: false, text: PaperText(pages: [], hasTextLayer: false, hasMarginLineNumbers: false))
        let engine = ReviewEngine(providers: ProviderRegistry([]), paperService: FakePaperService(paper: paper),
                                  matcherFactory: { FakeQuoteMatcher(paper: $0) }, renderer: PageMarkerRenderer())
        let context = EngineContext(provider: ProviderRef(providerID: "no-such-provider", model: nil),
                                    providerSettings: ProviderSettings(enabled: true, inputMode: .auto),
                                    prompts: DefaultSettings.make().prompts, meta: ManuscriptMeta(reviewerNotes: ""))

        var last: ReviewEvent?
        for try await event in engine.review(paper: paper, existing: [], context: context) { last = event }

        guard case .finished(let run)? = last, case .failed = run.status else {
            Issue.record("expected the last event to be .finished with a failed run, got \(String(describing: last))")
            return
        }
        #expect(run.kind == .review)
        #expect(run.provider.providerID == "no-such-provider")
    }
}
