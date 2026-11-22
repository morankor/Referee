import Foundation
import Testing
import RefereeCore
@testable import Persistence

/// WP8a acceptance rows "settings" and the settings half of "versions" (plan.md section 11.4).
@Suite struct SettingsStoreTests {
    /// Settings that differ from the defaults in every section.
    private func customised() -> AppSettings {
        var settings = DefaultSettings.make()
        settings.providers["anthropic-api"] = ProviderSettings(enabled: true, model: "example-large", inputMode: .pdf,
                                                               cachedModels: [ModelInfo(id: "example-large", displayName: "Example Large",
                                                                                        contextWindow: 200_000, supportsPDFInput: true)],
                                                               cachedModelsAt: Samples.moment, verifiedAt: Samples.moment)
        settings.providers["ollama"]?.baseURL = "http://127.0.0.1:11434"
        settings.providers["claude-cli"]?.extraArguments = ["--verbose"]
        settings.defaults = TaskDefaults(review: ProviderRef(providerID: "anthropic-api", model: "example-large"),
                                         chat: ProviderRef(providerID: "ollama", model: "gemma4:e4b"))
        settings.prompts.reviewSystem = "A shorter review prompt."
        settings.prompts.quickQuestions = ["Is this right?"]
        settings.rubric[0].enabled = false
        settings.privacy.localOnly = true
        settings.references.pdfCacheLimitMB = 200
        settings.ui.sidebarWidth = 420
        return settings
    }

    @Test func aMissingFileGivesTheDefaultsAndCreatesNothing() async throws {
        try await withTemporaryFolder { root in
            let store = FileSettingsStore(fileURL: root.appendingPathComponent("settings.json"))
            #expect(await store.load() == DefaultSettings.make())
            #expect(names(in: root).isEmpty)
        }
    }

    @Test func savedSettingsComeBackEqualInTheFormatOfSection3Point7() async throws {
        try await withTemporaryFolder { root in
            let file = root.appendingPathComponent("nested/folder/settings.json")
            let store = FileSettingsStore(fileURL: file)
            let settings = customised()
            try await store.save(settings)
            #expect(await store.load() == settings)
            #expect(await FileSettingsStore(fileURL: file).load() == settings)
            #expect(try Data(contentsOf: file) == (try referenceEncoder().encode(settings)))

            var changed = settings
            changed.ui.showRejectedHighlights.toggle()
            try await store.save(changed)
            #expect(await store.load() == changed)
            #expect(names(in: file.deletingLastPathComponent()) == ["settings.json"])
        }
    }

    @Test func aFileLackingAProviderGainsItsDefaultsOnLoad() async throws {
        try await withTemporaryFolder { root in
            let file = root.appendingPathComponent("settings.json")
            var written = customised()
            written.providers["codex-cli"] = nil
            written.providers["grok-cli"] = nil
            written.providers["mock"] = ProviderSettings(enabled: true, model: "mock", inputMode: .auto)   // unknown here: kept
            try referenceEncoder().encode(written).write(to: file)

            let loaded = await FileSettingsStore(fileURL: file).load()
            let defaults = DefaultSettings.make()
            var expected = written
            expected.providers["codex-cli"] = defaults.providers["codex-cli"]
            expected.providers["grok-cli"] = defaults.providers["grok-cli"]
            #expect(loaded == expected)
            #expect(loaded.providers["codex-cli"] != nil && loaded.providers["mock"]?.enabled == true)
            #expect(Set(loaded.providers.keys) == Set(defaults.providers.keys).union(["mock"]))
        }
    }

    @Test func keysThisVersionDoesNotKnowAreIgnored() async throws {
        try await withTemporaryFolder { root in
            let file = root.appendingPathComponent("settings.json")
            let settings = customised()
            let withExtras = try editedJSON(settings) { object in
                object["aSectionFromTheFuture"] = ["enabled": true, "level": 3]
                var ui = object["ui"] as? [String: Any] ?? [:]
                ui["theme"] = "sepia"
                object["ui"] = ui
                var providers = object["providers"] as? [String: Any] ?? [:]
                var anthropic = providers["anthropic-api"] as? [String: Any] ?? [:]
                anthropic["priority"] = 1
                providers["anthropic-api"] = anthropic
                object["providers"] = providers
            }
            try withExtras.write(to: file)
            #expect(await FileSettingsStore(fileURL: file).load() == settings)
        }
    }

    @Test func aSettingsFileWithoutVerifiedAtDecodes() async throws {
        try await withTemporaryFolder { root in
            let file = root.appendingPathComponent("settings.json")
            var settings = customised()
            let older = try editedJSON(settings) { object in
                var providers = object["providers"] as? [String: Any] ?? [:]
                for (id, value) in providers {
                    var provider = value as? [String: Any] ?? [:]
                    provider["verifiedAt"] = nil
                    providers[id] = provider
                }
                object["providers"] = providers
            }
            #expect(!String(decoding: older, as: UTF8.self).contains("verifiedAt"))
            try older.write(to: file)

            settings.providers["anthropic-api"]?.verifiedAt = nil
            #expect(await FileSettingsStore(fileURL: file).load() == settings)
        }
    }

    @Test func aDamagedFileGivesTheDefaultsAndIsKeptAside() async throws {
        try await withTemporaryFolder { root in
            let file = root.appendingPathComponent("settings.json")
            let garbage = Data("{\"schemaVersion\": 1, \"providers\": ".utf8)
            try garbage.write(to: file)

            let store = FileSettingsStore(fileURL: file)
            #expect(await store.load() == DefaultSettings.make())
            let moved = names(in: root)
            #expect(moved.count == 1)
            let name = try #require(moved.first)
            #expect(name.wholeMatch(of: #/settings\.corrupt-\d{8}T\d{6}Z\.json/#) != nil)
            #expect(try Data(contentsOf: root.appendingPathComponent(name)) == garbage)

            let settings = customised()
            try await store.save(settings)
            #expect(await store.load() == settings)
            #expect(names(in: root) == [name, "settings.json"].sorted())
        }
    }

    @Test func aNewerSchemaGivesTheDefaultsAndTheFileIsNeverReplaced() async throws {
        try await withTemporaryFolder { root in
            let file = root.appendingPathComponent("settings.json")
            let newer = try editedJSON(customised()) { object in object["schemaVersion"] = 2 }
            try newer.write(to: file)

            let store = FileSettingsStore(fileURL: file)
            #expect(await store.load() == DefaultSettings.make())
            #expect(try Data(contentsOf: file) == newer)
            await #expect(throws: StoreError.newerSchema(found: 2, supported: 1)) { try await store.save(DefaultSettings.make()) }
            #expect(try Data(contentsOf: file) == newer)
            #expect(names(in: root) == ["settings.json"])
        }
    }

    @Test func aSaveOverADamagedFileKeepsTheDamagedOneAside() async throws {
        try await withTemporaryFolder { root in
            let file = root.appendingPathComponent("settings.json")
            try Data("not json".utf8).write(to: file)
            try await FileSettingsStore(fileURL: file).save(customised())
            #expect(names(in: root).count == 2)
            #expect(await FileSettingsStore(fileURL: file).load() == customised())
        }
    }
}
