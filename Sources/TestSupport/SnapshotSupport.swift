import Foundation
import RefereeCore

/// The provider registry and the settings of the snapshot mode (plan.md sections 5.9 and 10.1). Nothing here opens a
/// connection or starts a process.
public enum SnapshotSupport {
    /// The ids of the four mock providers, in the order `providers()` returns them.
    static let mockIDs: [ProviderID] = ["mock", "mock-remote", "mock-fail", "mock-stall"]

    /// "mock" (local), "mock-remote" (non-local, destination "mock.example.org"), "mock-fail" (.failsAfterTwoComments),
    /// "mock-stall" (.stallsAfterTwoComments), then one StaticProvider per provider id of section 5.2 in mixed states.
    ///
    /// "mock-fail" and "mock-stall" are local, so a scene can start a review through them without the consent card.
    /// The nine static providers carry the descriptors of the real ones and, between them, every status the settings
    /// pane shows: ready with models, needs setup, unavailable.
    public static func providers() -> [any LLMProvider] {
        let mocks: [any LLMProvider] = [
            MockLLMProvider(id: "mock"),
            MockLLMProvider(id: "mock-remote", isLocal: false),
            MockLLMProvider(id: "mock-fail", script: .failsAfterTwoComments),
            MockLLMProvider(id: "mock-stall", script: .stallsAfterTwoComments),
        ]
        return mocks + staticProviders()
    }

    /// DefaultSettings.make() with the four mocks enabled and "mock" as the review default.
    ///
    /// Each mock has its one model, "mock", chosen, and the review default names that model too.
    public static func settings() -> AppSettings {
        var settings = DefaultSettings.make()
        for id in mockIDs {
            settings.providers[id] = ProviderSettings(enabled: true, model: "mock", inputMode: .auto)
        }
        settings.defaults.review = ProviderRef(providerID: "mock", model: "mock")
        return settings
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
            row("claude-cli", "Claude Code (subscription)", "Anthropic", .subscriptionCLI, destination: "claude", pdf: false,
                note: "Runs through your Claude Code login with its tools switched off; no session transcript is saved.",
                .ready(detail: "Logged in"),
                models: ["default", "opus", "sonnet", "haiku"].map { ModelInfo(id: $0, displayName: $0, contextWindow: 200_000) }),
            row("codex-cli", "Codex (ChatGPT plan)", "OpenAI", .subscriptionCLI, destination: "codex", pdf: false, streaming: .message,
                note: "Runs through your ChatGPT plan with shell and agent tools switched off; session files are not kept.",
                .needsSetup(reason: "Codex is not signed in with ChatGPT", hint: "Run `codex login`")),
            row("antigravity-cli", "Antigravity (Google AI plan)", "Google", .subscriptionCLI, destination: "agy", pdf: false, experimental: true,
                note: "Runs through your Google account. Its tools cannot be switched off: Referee stops the run if it uses one. "
                    + "The CLI may keep a local conversation record.",
                .needsSetup(reason: "Antigravity is not installed", hint: "curl -fsSL https://antigravity.google/cli/install.sh | bash")),
            row("grok-cli", "Grok Build", "xAI", .subscriptionCLI, destination: "grok", pdf: false, experimental: true,
                note: "Runs through your xAI account with tools denied. The CLI saves each conversation in ~/.grok and may sync "
                    + "it to your account; Referee deletes the local copy after each run.",
                .unavailable(reason: unavailableGrok)),
        ]
    }

    /// One static provider. The descriptor fields are the roster values of section 5.2 and the retention notes of section 9.7.
    private static func row(_ id: ProviderID, _ displayName: String, _ vendor: String, _ authMode: AuthMode, isLocal: Bool = false,
                            destination: String, pdf: Bool, streaming: StreamingGranularity = .token, experimental: Bool = false,
                            note: String, _ availability: ProviderAvailability, models: [ModelInfo] = []) -> any LLMProvider {
        StaticProvider(descriptor: ProviderDescriptor(id: id, displayName: displayName, vendor: vendor, authMode: authMode, isLocal: isLocal,
                                                      destination: destination, supportsNativePDF: pdf, streaming: streaming,
                                                      retentionNote: note, isExperimental: experimental),
                       availability: availability, models: models)
    }
}
