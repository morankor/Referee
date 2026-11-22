import Foundation
import Testing
import RefereeCore
import TestSupport
import Composition

/// Gate 0, step 4 (plan.md section 11.4): the engine of the snapshot graph finds the snapshot providers. In the first
/// version of the plan the model saw the mocks while the engine was built on the real registry, so every scene that
/// starts a review would have failed with "Provider is not set up".
///
/// Written to hold for the Wave 0 placeholder engine and for the real one (WP6): it asserts where a run went and that
/// the engine knew the provider, never whether the run completed. ("mock-stall" is left out: the real engine would
/// wait on it for ever.)
@Suite struct SnapshotGraphTests {
    @Test(arguments: [("mock-remote", "mock.example.org", false), ("mock", "this Mac", true), ("mock-fail", "this Mac", true)])
    func theEngineOfTheSnapshotGraphFindsTheSnapshotProviders(id: String, destination: String, isLocal: Bool) async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("referee-snapshot-graph-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        // The overrides the snapshot runner passes (section 10.1, step 1).
        let dependencies = await LiveDependencies.make(environment: ["REFEREE_HOME": home.path, "REFEREE_SNAPSHOT": "1", "REFEREE_NO_KEYCHAIN": "1"])
        let paper = try await dependencies.paperService.load(url: Fixtures.url("pdf/ay_round_nolinks.pdf"))

        // The context the model would build for this provider from the snapshot settings.
        let settings = SnapshotSupport.settings()
        let provider = try #require(dependencies.providers.provider(id: id))
        let reference = ProviderRef(providerID: id, model: "mock")
        let context = EngineContext(provider: reference, providerSettings: try #require(settings.providers[id]),
                                    model: try await provider.listModels().first { $0.id == "mock" }, prompts: settings.prompts,
                                    rubric: settings.rubric, meta: ManuscriptMeta(reviewerNotes: ""))

        let plan = await dependencies.engine.plan(paper: paper, context: context)
        #expect(plan.destination == destination)
        #expect(plan.isLocal == isLocal)

        var events: [ReviewEvent] = []
        for try await event in dependencies.engine.review(paper: paper, existing: [], context: context) { events.append(event) }
        guard case .started(let started)? = events.first, case .finished(let run)? = events.last else {
            Issue.record("a review starts with .started and ends with .finished; got \(events)")
            return
        }
        #expect(started.id == run.id)
        #expect(run.kind == .review)
        #expect(run.provider.providerID == id)
        #expect(run.destination == destination)
        if case .failed(let message) = run.status {
            // The placeholder fails every run, the real engine fails "mock-fail" on purpose: neither may say that the
            // provider is missing.
            #expect(!message.contains(LLMError.notConfigured("").userMessage))
            #expect(!message.contains("no provider with the id"))
        }
    }
}
