import Foundation
import RefereeCore

/// The five HTTP providers of plan section 5.4, all on `environment.urlSession` and the retry rule of section 5.7.
public enum LLMKitFactory {
    /// ids, in order: anthropic-api, openai-api, gemini-api, xai-api, ollama
    public static func makeProviders(environment: ProviderEnvironment) -> [any LLMProvider] {
        makeProviders(environment: environment, retry: .standard)
    }

    /// The same, with a retry rule of the caller's (tests inject an instant sleep).
    static func makeProviders(environment: ProviderEnvironment, retry: RetryPolicy) -> [HTTPProvider] {
        adapters.map { HTTPProvider(adapter: $0, environment: environment, retry: retry) }
    }

    static var adapters: [any HTTPProviderAdapter] {
        [AnthropicAdapter(), OpenAIAdapter(), GeminiAdapter(), XAIAdapter(), OllamaAdapter()]
    }
}
