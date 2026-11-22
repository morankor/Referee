import AppKit
import PDFKit
import Testing
import RefereeCore
import AppCore
import TestSupport
import RefereeUI

/// `ReaderController.attach()` as section 11.3 defines it: it loads the display document as soon as the model has a
/// paper, and calling it again changes nothing. Written against the surface only, so it holds for the Wave 0
/// placeholder and must keep holding for the real controller (WP9).
@Suite struct ReaderAttachTests {
    @MainActor private func makeModel() throws -> (model: ReviewSessionModel, paper: LoadedPaper) {
        let paper = try makeSamplePaper()
        let plan = SendPlan(sendsPDF: false, requestCount: 1, estimatedInputTokens: 0, destination: "this Mac", isLocal: true)
        let dependencies = AppDependencies(paperService: FakePaperService(paper: paper), matcherFactory: { FakeQuoteMatcher(paper: $0) },
                                           citationIndexer: FakeCitationIndexer(), engine: ScriptedReviewEngine(plan: plan), resolver: FakeResolver(),
                                           sessions: InMemorySessionStore(), settings: InMemorySettingsStore(), providers: ProviderRegistry([]),
                                           secrets: InMemorySecretStore())
        return (ReviewSessionModel(dependencies: dependencies, settings: DefaultSettings.make()), paper)
    }

    /// Lets the main actor run what the controller scheduled, until the condition holds or ten seconds have passed.
    @MainActor private func wait(until condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while !condition(), clock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test @MainActor func attachLoadsTheDocumentOfAPaperThatIsAlreadyOpen() async throws {
        let (model, _) = try makeModel()
        await model.open(url: Fixtures.url("pdf/ay_round_nolinks.pdf"))
        let reader = ReaderController(model: model)
        #expect(!reader.isDocumentLoaded)
        reader.attach()
        await wait { reader.isDocumentLoaded }
        #expect(reader.isDocumentLoaded)
        #expect(reader.pdfView.document?.pageCount == 4)
        #expect(reader.pdfView.document?.documentURL == nil)        // made from the bytes: nothing can write it back to the file
    }

    @Test @MainActor func attachLoadsTheDocumentWhenThePaperArrivesLater() async throws {
        let (model, _) = try makeModel()
        let reader = ReaderController(model: model)
        reader.attach()
        #expect(!reader.isDocumentLoaded)
        await model.open(url: Fixtures.url("pdf/ay_round_nolinks.pdf"))
        await wait { reader.isDocumentLoaded }
        #expect(reader.pdfView.document?.pageCount == 4)
    }

    @Test @MainActor func attachIsIdempotent() async throws {
        let (model, _) = try makeModel()
        await model.open(url: Fixtures.url("pdf/ay_round_nolinks.pdf"))
        let reader = ReaderController(model: model)
        reader.attach()
        await wait { reader.isDocumentLoaded }
        let document = reader.pdfView.document
        reader.attach()
        reader.attach()
        try await Task.sleep(for: .milliseconds(50))
        #expect(reader.pdfView.document === document)               // not loaded a second time
    }
}
