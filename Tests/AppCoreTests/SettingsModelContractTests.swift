import Foundation
import Testing
import RefereeCore
@testable import AppCore
import TestSupport

/// A provider whose whole model list is longer than the filtered one (OpenAI and Gemini filter theirs, section 5.4).
final class FilteringModelProvider: LLMProvider, @unchecked Sendable {
    let descriptor = ProviderDescriptor(id: "filtering", displayName: "Filtering", vendor: "Test", authMode: .apiKey, isLocal: true,
                                        destination: "this Mac", supportsNativePDF: false, streaming: .token, retentionNote: "A test provider.",
                                        isExperimental: false)
    static let visible = ModelInfo(id: "chat-model", displayName: "Chat model")
    static let hidden = ModelInfo(id: "embedding-model", displayName: "Embedding model")
    func availability() async -> ProviderAvailability { .ready(detail: "Key set") }
    func listModels() async throws -> [ModelInfo] { [Self.visible] }
    func listModels(includeHidden: Bool) async throws -> [ModelInfo] { includeHidden ? [Self.visible, Self.hidden] : [Self.visible] }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: LLMError.notConfigured("a test provider")) }
    }
}

/// The fake resolver, with a PDF cache of a given size.
final class CachingModelResolver: ReferenceResolving, @unchecked Sendable {
    private let base = FakeResolver()
    private let lock = NSLock()
    private var bytes: Int
    init(bytes: Int) { self.bytes = bytes }
    var forgottenDocuments: [String] { base.forgottenDocuments }
    func resolve(_ entry: BibEntry, documentSHA256: String) async -> ResolvedReference { await base.resolve(entry, documentSHA256: documentSHA256) }
    func forget(documentSHA256: String) async { await base.forget(documentSHA256: documentSHA256) }
    func fetchPDF(for reference: ResolvedReference) async throws -> URL { try await base.fetchPDF(for: reference) }
    func searchURL(for entry: BibEntry) -> URL { base.searchURL(for: entry) }
    func cachedPDFBytes() async -> Int { lock.withLock { bytes } }
    func clearPDFCache() async { lock.withLock { bytes = 0 } }
}

/// What Gate 1 added to `SettingsModel` (plan.md Appendix A.9, section 9.6).
@Suite struct SettingsModelContractTests {
    @MainActor static func model(providers: [any LLMProvider] = [], sessions: any SessionStoring = InMemorySessionStore(),
                                 resolver: any ReferenceResolving = FakeResolver(), dataDirectory: URL? = nil) throws -> SettingsModel {
        let paper = try makeSamplePaper()
        let dependencies = AppDependencies(paperService: FakePaperService(paper: paper), matcherFactory: { FakeQuoteMatcher(paper: $0) },
                                           citationIndexer: FakeCitationIndexer(), engine: ScriptedReviewEngine(plan: ModelSample.localPlan),
                                           resolver: resolver, sessions: sessions, settings: InMemorySettingsStore(), providers: ProviderRegistry(providers),
                                           secrets: InMemorySecretStore(), dataDirectory: dataDirectory)
        return SettingsModel(dependencies: dependencies, settings: DefaultSettings.make(), clock: ManualModelClock())
    }

    @Test @MainActor func showAllAsksTheProviderForItsWholeList() async throws {
        let model = try Self.model(providers: [FilteringModelProvider()])
        await model.refreshModels(of: "filtering")
        #expect(model.models["filtering"] == [FilteringModelProvider.visible])
        await model.refreshModels(of: "filtering", includeHidden: true)
        #expect(model.models["filtering"] == [FilteringModelProvider.visible, FilteringModelProvider.hidden])
        #expect(model.settings.providers["filtering"]?.cachedModels == [FilteringModelProvider.visible, FilteringModelProvider.hidden])
    }

    @Test @MainActor func deletingAllReviewDataEmptiesTheStoreAndForgetsEveryDocument() async throws {
        let store = InMemorySessionStore()
        let paper = try makeSamplePaper()
        var other = ModelSample.session(for: paper)
        other.document.sha256 = String(repeating: "b", count: 64)
        try await store.save(ModelSample.session(for: paper))
        try await store.save(other)
        let resolver = FakeResolver()
        let model = try Self.model(sessions: store, resolver: resolver)
        try await model.deleteAllReviewData()
        #expect(await store.listSessions().isEmpty)
        #expect(Set(resolver.forgottenDocuments) == [paper.ref.sha256, other.document.sha256])
    }

    @Test @MainActor func thePDFCacheSizeAndClearGoThroughTheResolver() async throws {
        let model = try Self.model(resolver: CachingModelResolver(bytes: 1_234_567))
        #expect(model.pdfCacheBytes == nil)                               // nothing is measured at init
        await model.refreshPDFCacheSize()
        #expect(model.pdfCacheBytes == 1_234_567)
        await model.clearPDFCache()
        #expect(model.pdfCacheBytes == 0)
        let plain = try Self.model()                                      // a resolver without a cache reports 0 (the default)
        await plain.refreshPDFCacheSize()
        #expect(plain.pdfCacheBytes == 0)
    }

    @Test @MainActor func theDataFolderIsTheOneTheDependenciesName() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("referee-data-folder", isDirectory: true)
        #expect(try Self.model(dataDirectory: folder).dataDirectory == folder)
        #expect(try Self.model().dataDirectory == nil)
    }
}
