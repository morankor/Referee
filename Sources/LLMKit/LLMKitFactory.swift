import Foundation
import RefereeCore

// Wave 0 placeholder (plan.md section 11.4, WP0a). WP4 replaces the placeholders with the five HTTP providers of
// section 5.4. The descriptors below carry the roster values of section 5.2 and the retention notes of section 9.7.

public enum LLMKitFactory {
    /// ids, in order: anthropic-api, openai-api, gemini-api, xai-api, ollama
    public static func makeProviders(environment: ProviderEnvironment) -> [any LLMProvider] {
        [
            ProviderDescriptor(id: "anthropic-api", displayName: "Anthropic API", vendor: "Anthropic", authMode: .apiKey, isLocal: false,
                               destination: "api.anthropic.com", supportsNativePDF: true, streaming: .token,
                               retentionNote: "Sent to Anthropic under your API account's data terms.", isExperimental: false),
            ProviderDescriptor(id: "openai-api", displayName: "OpenAI API", vendor: "OpenAI", authMode: .apiKey, isLocal: false,
                               destination: "api.openai.com", supportsNativePDF: true, streaming: .token,
                               retentionNote: "Sent with store=false; not kept for retrieval by the API.", isExperimental: false),
            ProviderDescriptor(id: "gemini-api", displayName: "Gemini API", vendor: "Google", authMode: .apiKey, isLocal: false,
                               destination: "generativelanguage.googleapis.com", supportsNativePDF: true, streaming: .token,
                               retentionNote: "Sent with store=false.", isExperimental: false),
            ProviderDescriptor(id: "xai-api", displayName: "xAI API", vendor: "xAI", authMode: .apiKey, isLocal: false,
                               destination: "api.x.ai", supportsNativePDF: false, streaming: .token,
                               retentionNote: "Sent to an endpoint that does not store requests.", isExperimental: false),
            ProviderDescriptor(id: "ollama", displayName: "Ollama (local)", vendor: "Ollama", authMode: .local, isLocal: true,
                               destination: "127.0.0.1:11434", supportsNativePDF: false, streaming: .token,
                               retentionNote: "Processed on this Mac; nothing is sent.", isExperimental: false),
        ].map { UnimplementedHTTPProvider(descriptor: $0) }
    }
}
