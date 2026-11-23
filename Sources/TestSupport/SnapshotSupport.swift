import Foundation
import RefereeCore

/// The provider registry and the settings of the snapshot mode (plan.md sections 5.9 and 10.1). Nothing here opens a
/// connection or starts a process.
public enum SnapshotSupport {
    /// The ids of the four mock providers, in the order `providers()` returns them.
    static let mockIDs: [ProviderID] = ["mock", "mock-remote", "mock-fail", "mock-stall"]

    /// "mock" (local), "mock-remote" (non-local, destination "mock.example.org"), "mock-fail" (.failsAfterTwoComments),
    /// "mock-stall" (.stallsAfterTwoComments), then one StaticProvider per provider id of section 5.2 in mixed states,
    /// then two stand-ins that `settings()` leaves off (step 5, design review O3): "mock-slow" (.sample with 40 ms
    /// between deltas, every purpose) and "mock-offline" (a local StaticProvider whose status is .needsSetup, "Ollama
    /// is not running").
    ///
    /// "mock-fail" and "mock-stall" are local, so a scene can start a review through them without the consent card.
    /// The nine static providers carry the descriptors of the real ones and, between them, every status the settings
    /// pane shows: ready with models, needs setup, unavailable. The two stand-ins are local and built in (`.none`),
    /// as the mocks are; a scene that wants one enables it and chooses it.
    public static func providers() -> [any LLMProvider] {
        let mocks: [any LLMProvider] = [
            MockLLMProvider(id: "mock"),
            MockLLMProvider(id: "mock-remote", isLocal: false),
            MockLLMProvider(id: "mock-fail", script: .failsAfterTwoComments),
            MockLLMProvider(id: "mock-stall", script: .stallsAfterTwoComments),
        ]
        return mocks + staticProviders() + standIns()
    }

    /// DefaultSettings.make() with the four mocks enabled and "mock" as the review default.
    ///
    /// Each mock has its one model, "mock", chosen, and the review default names that model too. "mock-slow" and
    /// "mock-offline" have no entry, so they are off.
    public static func settings() -> AppSettings {
        var settings = DefaultSettings.make()
        for id in mockIDs {
            settings.providers[id] = ProviderSettings(enabled: true, model: "mock", inputMode: .auto)
        }
        settings.defaults.review = ProviderRef(providerID: "mock", model: "mock")
        return settings
    }

    /// The name of the environment variable through which a snapshot scene chooses its lookups (plan.md section 10.6).
    public static let lookupsVariable = "REFEREE_SNAPSHOT_LOOKUPS"
    /// The reason a failed snapshot lookup gives, as the real resolver words a busy Crossref.
    public static let failedLookupReason = "Crossref is busy; try again in a minute."

    /// The snapshot graph's resolver (step 5c): a `FakeResolver` that resolves every entry, except those `lookups` names.
    /// `lookups` is the value of REFEREE_SNAPSHOT_LOOKUPS: items "failed=<text>" and "notFound=<text>" separated by ";",
    /// each matching the entries whose printed text contains <text>, ignoring case; the first item that matches wins. A
    /// failed lookup gives `failedLookupReason`. Items it cannot read are ignored; nil or "" resolves everything. No
    /// request is ever made, whatever the answer.
    public static func resolver(lookups: String?) -> FakeResolver {
        let rules: [(text: String, answer: FakeResolver.Answer)] = (lookups ?? "").split(separator: ";").compactMap { item in
            let parts = item.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[1].isEmpty else { return nil }
            switch parts[0] {
            case "failed": return (parts[1], .failed(reason: failedLookupReason))
            case "notFound": return (parts[1], .notFound)
            default: return nil
            }
        }
        guard !rules.isEmpty else { return FakeResolver() }
        return FakeResolver(answers: { entry in
            rules.first { entry.rawText.range(of: $0.text, options: .caseInsensitive) != nil }?.answer ?? .resolved
        })
    }

    // ---- the nine real provider ids as static rows ----

    private static func staticProviders() -> [any LLMProvider] {
        let unavailableGrok = "grok 0.1.0 does not list the option --disallowed-tools, which Referee needs in order to run it safely"
        return [
            row("anthropic-api", "Anthropic API", "Anthropic", .apiKey, destination: "api.anthropic.com", pdf: true,
                note: "Sent to Anthropic under your API account's data terms.",
                .ready(detail: "Key set"),
                models: [ModelInfo(id: "example-large", displayName: "Example Large", contextWindow: 1_000_000, maxOutputTokens: 128_000, supportsPDFInput: true),
                         ModelInfo(id: "example-small", displayName: "Example Small", contextWindow: 200_000, maxOutputTokens: 64_000, supportsPDFInput: true)]),
            row("openai-api", "OpenAI API", "OpenAI", .apiKey, destination: "api.openai.com", pdf: true,
                note: "Sent with store=false; not kept for retrieval by the API.",
                .needsSetup(reason: "No API key", hint: "Paste an API key to use this provider.")),
            row("gemini-api", "Gemini API", "Google", .apiKey, destination: "generativelanguage.googleapis.com", pdf: true,
                note: "Sent with store=false.",
                .needsSetup(reason: "No API key", hint: "Paste an API key to use this provider.")),
            row("xai-api", "xAI API", "xAI", .apiKey, destination: "api.x.ai", pdf: false,
                note: "Sent to an endpoint that does not store requests.",
                .ready(detail: "Key set"),
                models: [ModelInfo(id: "example-chat", displayName: "Example Chat", contextWindow: 256_000)]),
            row("ollama", "Ollama (local)", "Ollama", .local, isLocal: true, destination: "127.0.0.1:11434", pdf: false,
                note: "Processed on this Mac; nothing is sent.",
                .ready(detail: "Ollama 0.40.17"),
                models: [ModelInfo(id: "gemma4:e4b", displayName: "gemma4:e4b", contextWindow: 131_072, supportsPDFInput: false),
                         ModelInfo(id: "phi4", displayName: "phi4", contextWindow: 16_384, supportsPDFInput: false)]),
            row("claude-cli", "Claude Code (subscription)", "Anthropic", .subscriptionCLI, destination: "claude", pdf: true, maxPromptBytes: 9_000_000,
                note: "Runs through your Claude Code login with its tools switched off; no session transcript is saved.",
                .ready(detail: "Logged in"),
                models: ["default", "opus", "sonnet", "haiku"].map { ModelInfo(id: $0, displayName: $0, contextWindow: 200_000) }),
            row("codex-cli", "Codex (ChatGPT plan)", "OpenAI", .subscriptionCLI, destination: "codex", pdf: true, pdfNote: "sent as page images",
                maxPromptBytes: 4_000_000, streaming: .message,
                note: "Runs through your ChatGPT plan with shell and agent tools switched off; session files are not kept.",
                .needsSetup(reason: "Codex is not signed in with ChatGPT", hint: "Run `codex login`")),
            row("antigravity-cli", "Antigravity (Google AI plan)", "Google", .subscriptionCLI, destination: "agy", pdf: false,
                maxPromptBytes: 4_000_000, experimental: true,
                note: "Runs through your Google account. Its tools cannot be switched off: Referee stops the run if it uses one. "
                    + "The CLI may keep a local conversation record.",
                .needsSetup(reason: "Antigravity is not installed", hint: "curl -fsSL https://antigravity.google/cli/install.sh | bash")),
            row("grok-cli", "Grok Build", "xAI", .subscriptionCLI, destination: "grok", pdf: false, maxPromptBytes: 4_000_000, experimental: true,
                note: "Runs through your xAI account with tools denied. The CLI saves each conversation in ~/.grok and may sync "
                    + "it to your account; Referee deletes the local copy after each run.",
                .unavailable(reason: unavailableGrok)),
        ]
    }

    /// One static provider. The descriptor fields are the roster values of section 5.2, the retention notes of section
    /// 9.7 and, for the CLIs, the outcome of the delivery experiment of section 5.6.6 (WP5): Claude Code takes the PDF as
    /// a document block, Codex as page images, and the transport limits of section 5.6.4. A test in IntegrationTests
    /// compares these descriptors with the real providers' (Gate 1).
    private static func row(_ id: ProviderID, _ displayName: String, _ vendor: String, _ authMode: AuthMode, isLocal: Bool = false,
                            destination: String, pdf: Bool, pdfNote: String? = nil, maxPromptBytes: Int? = nil,
                            streaming: StreamingGranularity = .token, experimental: Bool = false,
                            note: String, _ availability: ProviderAvailability, models: [ModelInfo] = []) -> any LLMProvider {
        StaticProvider(descriptor: ProviderDescriptor(id: id, displayName: displayName, vendor: vendor, authMode: authMode, isLocal: isLocal,
                                                      destination: destination, supportsNativePDF: pdf, pdfDeliveryNote: pdfNote,
                                                      streaming: streaming, maxPromptBytes: maxPromptBytes, retentionNote: note,
                                                      isExperimental: experimental),
                       availability: availability, models: models)
    }

    // ---- two stand-ins for the design scenes of step 5 (O3), off in `settings()` ----

    /// Between two deltas of "mock-slow": at 7 characters a delta, report_sample takes about 6.5 s and review_clean
    /// about 15 s, so a scene captures a report or a review half written.
    static let slowDelayPerChunk: Duration = .milliseconds(40)

    /// "mock-slow" for the report mid-generation (`design-report-streaming`), "mock-offline" for a local provider that
    /// is not running (`design-review-provider-offline`). Neither can reach anything: one plays a script in-process,
    /// the other only reports its status.
    private static func standIns() -> [any LLMProvider] {
        let offline = ProviderDescriptor(id: "mock-offline", displayName: "Mock (offline)", vendor: "Mock", authMode: .none, isLocal: true,
                                         destination: "this Mac", supportsNativePDF: false, streaming: .token,
                                         retentionNote: "A stand-in for tests and snapshots; nothing leaves this Mac.", isExperimental: false)
        return [
            MockLLMProvider(id: "mock-slow", script: slowed(.sample)),
            StaticProvider(descriptor: offline,
                           availability: .needsSetup(reason: "Ollama is not running", hint: "Start the Ollama app or run `ollama serve`."),
                           models: [ModelInfo(id: "mock", displayName: "mock", contextWindow: 1_000_000, supportsPDFInput: false)]),
        ]
    }

    /// `script` with `slowDelayPerChunk` between the deltas of every response.
    private static func slowed(_ script: MockScript) -> MockScript {
        MockScript(responses: script.responses.mapValues { responses in
            responses.map { response in
                var slow = response
                slow.delayPerChunk = slowDelayPerChunk
                return slow
            }
        })
    }
}
