import Foundation
import RefereeCore
import TestSupport
import PaperText
import PDFBridge
import CitationKit
import LLMKit
import CLIProviders
import ReviewEngine
import ScholarKit
import Persistence

/// The settings in force, readable from any thread. Updated whenever settings are loaded or saved.
final class CurrentSettings: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AppSettings
    init(_ value: AppSettings) { self.value = value }
    func get() -> AppSettings { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: AppSettings) { lock.lock(); value = newValue; lock.unlock() }
}
/// AppDependencies.settings: the file store, plus keeping CurrentSettings up to date so that edits apply without a restart.
struct TrackingSettingsStore: SettingsStoring {
    let base: any SettingsStoring
    let current: CurrentSettings
    func load() async -> AppSettings { let s = await base.load(); current.set(s); return s }
    func save(_ settings: AppSettings) async throws { try await base.save(settings); current.set(settings) }
}
/// REFEREE_KEY_<KEY in upper case, non-alphanumerics as _> wins over the wrapped store; writes go to the wrapped store.
struct EnvironmentSecretStore: SecretStoring {
    let environment: [String: String]
    let base: any SecretStoring
    func secret(for key: String) throws -> String? {
        let name = "REFEREE_KEY_" + String(key.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" })
        if let v = environment[name], !v.isEmpty { return v }
        return try base.secret(for: key)
    }
    func setSecret(_ value: String?, for key: String) throws { try base.setSecret(value, for: key) }
}

public enum LiveDependencies {
    public static func make(environment: [String: String] = ProcessInfo.processInfo.environment) async -> AppDependencies {
        let data = AppPaths.dataDirectory(environment: environment)
        let caches = AppPaths.cacheDirectory(environment: environment)
        let snapshot = environment["REFEREE_SNAPSHOT"] == "1"      // snapshot mode: no process, no connection, no Keychain

        let fileStore = FileSettingsStore(fileURL: data.appendingPathComponent("settings.json"))
        let current = CurrentSettings(await fileStore.load())
        let settings = TrackingSettingsStore(base: fileStore, current: current)
        let stored: any SecretStoring = (snapshot || environment["REFEREE_NO_KEYCHAIN"] == "1") ? InMemorySecretStore() : KeychainSecretStore()
        let secrets = EnvironmentSecretStore(environment: environment, base: stored)
        let session = makeURLSession()
        let defaults = DefaultSettings.make()
        let providerEnvironment = ProviderEnvironment(
            settings: { id in current.get().providers[id] ?? defaults.providers[id] ?? ProviderSettings(enabled: false, inputMode: .auto) },
            secrets: secrets, urlSession: session, processEnvironment: environment)

        var providers: [any LLMProvider]
        if snapshot {
            providers = SnapshotSupport.providers()
        } else {
            providers = LLMKitFactory.makeProviders(environment: providerEnvironment) + CLIProviderFactory.makeProviders(environment: providerEnvironment)
            if environment["REFEREE_ENABLE_MOCK"] == "1" { providers.append(MockLLMProvider()) }
        }
        let registry = ProviderRegistry(providers)

        let paperService = PDFPaperService(builder: PaperTextBuilder(stripMarginLineNumbers: { current.get().ui.stripMarginLineNumbers }))
        let matcherFactory: @Sendable (PaperText) -> any QuoteMatching = { QuoteMatcher(paper: $0) }
        let engine = ReviewEngine(providers: registry, paperService: paperService, matcherFactory: matcherFactory, renderer: PaperRenderer())
        let resolver: any ReferenceResolving = snapshot
            ? FakeResolver()
            : ReferenceResolver(settings: { current.get().references }, urlSession: session, dataDirectory: data, cacheDirectory: caches)
        return AppDependencies(paperService: paperService, matcherFactory: matcherFactory, citationIndexer: CitationIndexer(), engine: engine,
                               resolver: resolver, sessions: FileSessionStore(directory: data.appendingPathComponent("sessions")),
                               settings: settings, providers: registry, secrets: secrets)
    }

    /// The one URLSession for providers and reference lookups (section 5.3).
    public static func makeURLSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 600          // longest tolerated silence between bytes
        c.timeoutIntervalForResource = 3600
        c.waitsForConnectivity = false
        c.httpCookieStorage = nil
        c.urlCache = nil
        c.httpShouldSetCookies = false
        return URLSession(configuration: c)
    }
}
