import Foundation
import Testing
import RefereeCore
@testable import AppCore
import TestSupport

/// A provider whose status the test changes (an Ollama started later) and which counts its calls.
private final class LocalDefaultProvider: LLMProvider, @unchecked Sendable {
    let descriptor: ProviderDescriptor
    private let lock = NSLock()
    private var status: ProviderAvailability
    private let models: [ModelInfo]
    private var statusCalls = 0
    private var listCalls = 0

    init(id: ProviderID, isLocal: Bool, status: ProviderAvailability, models: [ModelInfo] = [ModelInfo(id: "gemma4:e4b", displayName: "gemma4:e4b")]) {
        descriptor = ProviderDescriptor(id: id, displayName: id, vendor: "Test", authMode: isLocal ? .local : .apiKey, isLocal: isLocal,
                                        destination: isLocal ? "127.0.0.1:11434" : "\(id).example.org", supportsNativePDF: false,
                                        streaming: .token, retentionNote: "A test provider.", isExperimental: false)
        self.status = status
        self.models = models
    }

    var availabilityCalls: Int { lock.withLock { statusCalls } }
    var listModelsCalls: Int { lock.withLock { listCalls } }
    func setStatus(_ new: ProviderAvailability) { lock.withLock { status = new } }

    func availability() async -> ProviderAvailability {
        lock.withLock {
            statusCalls += 1
            return status
        }
    }

    func listModels() async throws -> [ModelInfo] {
        lock.withLock { listCalls += 1 }
        return models
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: LLMError.notConfigured("a test provider that only reports a status")) }
    }
}

/// Step 5c, the coordinator's decision on the Shell's contract problem 3 of step 5b: Ollama ships switched on with no
/// review default, so D5's "switching it on makes it the default" never runs for it when it was not running at the first
/// launch. Whenever no review default is set and a local provider that is switched on reports ready, it becomes the
/// review default, once, when a window opens or the app becomes active. Never a remote provider.
@Suite struct SettingsModelLocalDefaultTests {
    static let notRunning = ProviderAvailability.needsSetup(reason: "Ollama is not running", hint: "Start the Ollama app or run `ollama serve`.")

    /// The default settings (Ollama on, no review default) with `remote` switched on as well.
    static func settings(remote: ProviderID = "remote") -> AppSettings {
        var settings = DefaultSettings.make()
        settings.providers[remote] = ProviderSettings(enabled: true, model: "example-large", inputMode: .auto)
        return settings
    }

    @Test @MainActor func anOllamaStartedAfterTheFirstLaunchBecomesTheDefaultOnce() async throws {
        let ollama = LocalDefaultProvider(id: "ollama", isLocal: true, status: Self.notRunning)
        let remote = LocalDefaultProvider(id: "remote", isLocal: false, status: .ready(detail: "Key set"))
        let parts = try SettingsModelTests.make(settings: Self.settings(), providers: [remote, ollama])
        let model = parts.model
        #expect(model.settings.providers["ollama"]?.enabled == true)
        #expect(model.settings.defaults.review == nil)

        // The first launch: Ollama is not running. Nothing is chosen, and the remote provider is not even asked.
        await model.adoptReadyLocalProviderIfNeeded()
        #expect(model.settings.defaults.review == nil)
        #expect(ollama.availabilityCalls == 1)
        #expect(model.availability["ollama"] == Self.notRunning)

        // Later the referee starts Ollama and comes back to the app: it becomes the review default, with the first model
        // it lists (none was chosen), which Settings now keeps.
        ollama.setStatus(.ready(detail: "Ollama 0.40.17"))
        let counter = SettingsNotificationCounter(for: model)
        defer { counter.stop() }
        await model.adoptReadyLocalProviderIfNeeded()
        #expect(model.settings.defaults.review == ProviderRef(providerID: "ollama", model: "gemma4:e4b"))
        #expect(model.settings.providers["ollama"]?.model == "gemma4:e4b")
        #expect(model.settings.providers["ollama"]?.cachedModels.map(\.id) == ["gemma4:e4b"])
        #expect(model.settings.defaults.chat == nil)
        #expect(model.settings.defaults.report == nil)
        #expect(counter.count == 1)                                         // the windows hear of it
        #expect(remote.availabilityCalls == 0)
        #expect(remote.listModelsCalls == 0)

        // Once: the referee then chooses None; opening a window or coming back does not override that in this run.
        model.update { $0.defaults.review = nil }
        await model.adoptReadyLocalProviderIfNeeded()
        #expect(model.settings.defaults.review == nil)
        #expect(ollama.availabilityCalls == 2)
    }

    @Test @MainActor func aChosenModelIsKeptAndAnExistingDefaultIsNeverReplaced() async throws {
        let local = LocalDefaultProvider(id: "ollama", isLocal: true, status: .ready(detail: "Ollama 0.40.17"))
        var settings = Self.settings()
        settings.providers["ollama"]?.model = "phi4"
        let parts = try SettingsModelTests.make(settings: settings, providers: [local])
        await parts.model.adoptReadyLocalProviderIfNeeded()
        #expect(parts.model.settings.defaults.review == ProviderRef(providerID: "ollama", model: "phi4"))
        #expect(local.listModelsCalls == 0)                                  // a model was chosen: nothing to list

        var chosen = Self.settings()
        chosen.defaults.review = ProviderRef(providerID: "remote", model: "example-large")
        let other = LocalDefaultProvider(id: "ollama", isLocal: true, status: .ready(detail: "Ollama 0.40.17"))
        let kept = try SettingsModelTests.make(settings: chosen, providers: [other])
        await kept.model.adoptReadyLocalProviderIfNeeded()
        #expect(kept.model.settings == chosen)
        #expect(other.availabilityCalls == 0)                                // nothing to decide: nobody asked
    }

    @Test @MainActor func neitherARemoteProviderNorALocalOneThatIsOffIsChosen() async throws {
        let remote = LocalDefaultProvider(id: "remote", isLocal: false, status: .ready(detail: "Key set"))
        let parts = try SettingsModelTests.make(settings: Self.settings(), providers: [remote])
        await parts.model.adoptReadyLocalProviderIfNeeded()
        #expect(parts.model.settings.defaults.review == nil)
        #expect(remote.availabilityCalls == 0)

        var off = Self.settings()
        off.providers["ollama"]?.enabled = false
        let ollama = LocalDefaultProvider(id: "ollama", isLocal: true, status: .ready(detail: "Ollama 0.40.17"))
        let quiet = try SettingsModelTests.make(settings: off, providers: [ollama])
        await quiet.model.adoptReadyLocalProviderIfNeeded()
        #expect(quiet.model.settings.defaults.review == nil)
        #expect(ollama.availabilityCalls == 0)

        // A ready local provider that lists no model cannot become the default.
        let empty = LocalDefaultProvider(id: "ollama", isLocal: true, status: .ready(detail: "Ollama 0.40.17"), models: [])
        let none = try SettingsModelTests.make(settings: Self.settings(), providers: [empty])
        await none.model.adoptReadyLocalProviderIfNeeded()
        #expect(none.model.settings.defaults.review == nil)
    }
}
