import Foundation
import Observation
import Testing
import RefereeCore
@testable import AppCore
import TestSupport

/// A provider whose status the test sets and which counts its `availability()` calls; `delay` makes each answer late.
private final class StatusModelProvider: LLMProvider, @unchecked Sendable {
    let descriptor: ProviderDescriptor
    private let delay: Duration
    private let lock = NSLock()
    private var current: ProviderAvailability
    private var calls = 0

    init(id: ProviderID, isLocal: Bool, authMode: AuthMode, status: ProviderAvailability, delay: Duration = .zero) {
        descriptor = ProviderDescriptor(id: id, displayName: id, vendor: "Test", authMode: authMode, isLocal: isLocal,
                                        destination: isLocal ? "this Mac" : "\(id).example.org", supportsNativePDF: false, streaming: .token,
                                        retentionNote: "A test provider.", isExperimental: false)
        current = status
        self.delay = delay
    }

    var availabilityCalls: Int { lock.withLock { calls } }
    func setStatus(_ status: ProviderAvailability) { lock.withLock { current = status } }

    func availability() async -> ProviderAvailability {
        let status = lock.withLock {
            calls += 1
            return current
        }
        if delay > .zero { try? await Task.sleep(for: delay) }
        return status
    }

    func listModels() async throws -> [ModelInfo] { [ModelInfo(id: "m", displayName: "m", contextWindow: 100_000)] }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: LLMError.notConfigured("a test provider that only reports a status")) }
    }
}

/// Set once, from any thread: an observation's onChange.
private final class ModelObservedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// Step 5, design review O1 and O2 (plan.md Appendix A.9, Appendix G.8): where the chat and the report go, and the
/// status of a local active provider.
@Suite struct ReviewSessionModelProviderTests {
    static let notRunning = ProviderAvailability.needsSetup(reason: "Ollama is not running", hint: "Start the Ollama app or run `ollama serve`.")

    /// The snapshot settings with these providers enabled, each with the model "m", and `review` the review default.
    static func settings(_ ids: [ProviderID], review: ProviderID) -> AppSettings {
        ModelSample.settings { settings in
            for id in ids { settings.providers[id] = ProviderSettings(enabled: true, model: "m", inputMode: .auto) }
            settings.defaults.review = ProviderRef(providerID: review, model: "m")
        }
    }

    // ---- O1: chatProvider and reportProvider ----

    @Test @MainActor func theChatAndReportProvidersFollowTheirDefaultsUntilTheDocumentChoosesOne() async throws {
        let settings = ModelSample.settings { $0.defaults.chat = ProviderRef(providerID: "mock-remote", model: "mock") }
        let harness = try await makeModelHarness(settings: settings)
        await harness.open()
        #expect(harness.model.session?.preferredProvider == nil)
        #expect(harness.model.activeProvider?.id == "mock")
        #expect(harness.model.chatProvider?.id == "mock-remote")          // defaults.chat
        #expect(harness.model.reportProvider?.id == "mock")               // no report default: the review's

        var withReport = harness.model.settings
        withReport.defaults.report = ProviderRef(providerID: "mock-remote", model: "mock")
        harness.model.reloadSettings(withReport)
        #expect(harness.model.reportProvider?.id == "mock-remote")
        #expect(harness.model.activeProvider?.id == "mock")

        // The document's own choice (the destination menu) is every job's.
        harness.model.setActiveProvider(ProviderRef(providerID: "mock", model: "mock"))
        #expect(harness.model.activeProvider?.id == "mock")
        #expect(harness.model.chatProvider == harness.model.activeProvider)
        #expect(harness.model.reportProvider == harness.model.activeProvider)

        // A job default naming a provider that is off resolves to nothing, as the job itself would.
        var off = ModelSample.settings { $0.defaults.chat = ProviderRef(providerID: "mock-remote", model: "mock") }
        off.providers["mock-remote"]?.enabled = false
        let other = try await makeModelHarness(settings: off)
        await other.open()
        #expect(other.model.chatProvider == nil)
        #expect(other.model.reportProvider?.id == "mock")
    }

    @Test @MainActor func theChatAndReportProvidersAreObservedThroughSettingsAndSession() async throws {
        let harness = try await makeModelHarness()
        await harness.open()
        let fromSettings = ModelObservedFlag()
        withObservationTracking {
            _ = harness.model.chatProvider
            _ = harness.model.reportProvider
        } onChange: {
            fromSettings.set()
        }
        var settings = harness.model.settings
        settings.defaults.chat = ProviderRef(providerID: "mock-remote", model: "mock")
        harness.model.reloadSettings(settings)
        #expect(fromSettings.isSet)
        #expect(harness.model.chatProvider?.id == "mock-remote")

        let fromSession = ModelObservedFlag()
        withObservationTracking { _ = harness.model.chatProvider } onChange: { fromSession.set() }
        harness.model.setActiveProvider(ProviderRef(providerID: "mock", model: "mock"))      // session.preferredProvider
        #expect(fromSession.isSet)
        #expect(harness.model.chatProvider?.id == "mock")
    }

    // ---- O2: activeAvailability and refreshActiveAvailability() ----

    @Test @MainActor func aLocalActiveProviderIsAskedForItsStatusAndARemoteOneNever() async throws {
        let local = StatusModelProvider(id: "local", isLocal: true, authMode: .local, status: Self.notRunning)
        let api = StatusModelProvider(id: "api", isLocal: false, authMode: .apiKey, status: .ready(detail: "Key set"))
        let cli = StatusModelProvider(id: "cli", isLocal: false, authMode: .subscriptionCLI, status: .ready(detail: "Logged in"))
        let harness = try await makeModelHarness(settings: Self.settings(["local", "api", "cli"], review: "local"), providers: [local, api, cli])
        await harness.model.waitForBackgroundWork()
        #expect(harness.model.activeProvider?.id == "local")
        #expect(harness.model.activeAvailability == Self.notRunning)      // asked as soon as the model had the provider
        #expect(local.availabilityCalls == 1)
        await harness.open()
        #expect(local.availabilityCalls == 1)                             // the provider did not change: not asked again

        for remote in [api, cli] {
            harness.model.setActiveProvider(ProviderRef(providerID: remote.descriptor.id, model: "m"))
            #expect(harness.model.activeProvider?.id == remote.descriptor.id)
            #expect(harness.model.activeAvailability == nil)              // at once, without waiting for anything
            harness.model.refreshActiveAvailability()                     // as the window does when the app becomes active
            await harness.model.waitForBackgroundWork()
            #expect(harness.model.activeAvailability == nil)
        }
        #expect(api.availabilityCalls == 0)                               // an API check would read the Keychain
        #expect(cli.availabilityCalls == 0)                               // a CLI check would start a process

        // Back to the local one: asked again. Once it runs, a check ("Check Again") brings the new status, and the last
        // answer stays until then.
        harness.model.setActiveProvider(ProviderRef(providerID: "local", model: "m"))
        await harness.model.waitForBackgroundWork()
        #expect(harness.model.activeAvailability == Self.notRunning)
        #expect(local.availabilityCalls == 2)
        local.setStatus(.ready(detail: "Ollama 0.40.17"))
        harness.model.refreshActiveAvailability()
        #expect(harness.model.activeAvailability == Self.notRunning)
        await harness.model.waitForBackgroundWork()
        #expect(harness.model.activeAvailability == .ready(detail: "Ollama 0.40.17"))
        #expect(local.availabilityCalls == 3)

        // Switched off: no provider, no status, nobody asked.
        var off = harness.model.settings
        off.providers["local"]?.enabled = false
        harness.model.reloadSettings(off)
        #expect(harness.model.activeProvider == nil)
        #expect(harness.model.activeAvailability == nil)
        harness.model.refreshActiveAvailability()
        await harness.model.waitForBackgroundWork()
        #expect(harness.model.activeAvailability == nil)
        #expect(local.availabilityCalls == 3)
    }

    /// An answer that arrives after the active provider changed is not shown for the new one.
    @Test @MainActor func aLateAnswerForAProviderNoLongerActiveIsDropped() async throws {
        let local = StatusModelProvider(id: "local", isLocal: true, authMode: .local, status: Self.notRunning, delay: .milliseconds(150))
        let other = StatusModelProvider(id: "other", isLocal: true, authMode: .local, status: .ready(detail: "Ready"))
        let api = StatusModelProvider(id: "api", isLocal: false, authMode: .apiKey, status: .ready(detail: "Key set"))
        let settings = Self.settings(["local", "other", "api"], review: "local")
        let harness = try await makeModelHarness(settings: settings, providers: [local, other, api])

        // The local provider was asked when the model was made; its answer takes 150 ms, and the provider changes first.
        var remote = settings
        remote.defaults.review = ProviderRef(providerID: "api", model: "m")
        harness.model.reloadSettings(remote)
        await harness.model.waitForBackgroundWork()
        #expect(harness.model.activeProvider?.id == "api")
        #expect(harness.model.activeAvailability == nil)
        #expect(local.availabilityCalls == 1)

        // From one local provider to another: the first one's late answer is not the second one's status.
        var slow = settings
        slow.defaults.review = ProviderRef(providerID: "local", model: "m")
        harness.model.reloadSettings(slow)
        var quick = settings
        quick.defaults.review = ProviderRef(providerID: "other", model: "m")
        harness.model.reloadSettings(quick)
        #expect(harness.model.activeAvailability == nil)                  // a provider not asked before
        await harness.model.waitForBackgroundWork()
        #expect(harness.model.activeProvider?.id == "other")
        #expect(harness.model.activeAvailability == .ready(detail: "Ready"))
        #expect(local.availabilityCalls == 2)
        #expect(api.availabilityCalls == 0)
    }
}
