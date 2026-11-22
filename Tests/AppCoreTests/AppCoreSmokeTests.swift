import Foundation
import Testing
import RefereeCore
import AppCore
import TestSupport

/// Wave 0a smoke tests. They hold for the placeholders and must keep holding for the real models (WP8b) and the
/// real exporter (WP8a): they only look at the state a new model starts in.
@Suite struct AppCoreSmokeTests {
    private func dependencies() -> AppDependencies {
        let paper = LoadedPaper(ref: DocumentRef(sha256: String(repeating: "0", count: 64), fileName: "empty.pdf", byteCount: 0, pageCount: 0),
                                data: Data(), isEncrypted: false, text: PaperText(pages: [], hasTextLayer: false, hasMarginLineNumbers: false))
        let plan = SendPlan(sendsPDF: false, requestCount: 1, estimatedInputTokens: 0, destination: "this Mac", isLocal: true)
        return AppDependencies(paperService: FakePaperService(paper: paper), matcherFactory: { FakeQuoteMatcher(paper: $0) },
                               citationIndexer: FakeCitationIndexer(), engine: ScriptedReviewEngine(plan: plan), resolver: FakeResolver(),
                               sessions: InMemorySessionStore(), settings: InMemorySettingsStore(), providers: ProviderRegistry([]),
                               secrets: InMemorySecretStore())
    }

    @Test @MainActor func aNewReviewModelIsEmptyAndIdle() {
        let settings = DefaultSettings.make()
        let model = ReviewSessionModel(dependencies: dependencies(), settings: settings)
        #expect(model.phase == .empty)
        #expect(model.paper == nil)
        #expect(model.session == nil)
        #expect(model.runState == .idle)
        #expect(model.settings == settings)
        #expect(model.filter == .all)
        #expect(model.sidebarTab == .comments)
        #expect(model.visibleComments.isEmpty)
        #expect(!model.canStartReview)
    }

    @Test @MainActor func aNewSettingsModelHoldsTheSettingsItWasGiven() {
        let settings = DefaultSettings.make()
        let model = SettingsModel(dependencies: dependencies(), settings: settings)
        #expect(model.settings == settings)
        #expect(model.providers.isEmpty)
    }

    @Test @MainActor func markdownExportIsTheTextItself() throws {
        let markdown = "## Summary assessment\n\nShort and direct.\n"
        #expect(try ReportExporter.data(markdown: markdown, format: .markdown) == Data(markdown.utf8))
    }
}
