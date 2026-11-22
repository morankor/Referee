import Foundation
import RefereeCore

// Wave 0 placeholder (plan.md section 11.4, WP0a). WP5 replaces the placeholders with the four CLI adapters of
// section 5.6. The descriptors below carry the roster values of section 5.2 and the retention notes of section 9.7;
// no provider receives the PDF itself until the experiment of section 5.6.6 has been run.

public enum CLIProviderFactory {
    /// ids, in order: claude-cli, codex-cli, antigravity-cli, grok-cli
    public static func makeProviders(environment: ProviderEnvironment) -> [any LLMProvider] {
        [
            ProviderDescriptor(id: "claude-cli", displayName: "Claude Code (subscription)", vendor: "Anthropic", authMode: .subscriptionCLI,
                               isLocal: false, destination: "claude", supportsNativePDF: false, streaming: .token,
                               retentionNote: "Runs through your Claude Code login with its tools switched off; no session transcript is saved.",
                               isExperimental: false),
            ProviderDescriptor(id: "codex-cli", displayName: "Codex (ChatGPT plan)", vendor: "OpenAI", authMode: .subscriptionCLI,
                               isLocal: false, destination: "codex", supportsNativePDF: false, streaming: .message,
                               retentionNote: "Runs through your ChatGPT plan with shell and agent tools switched off; session files are not kept.",
                               isExperimental: false),
            ProviderDescriptor(id: "antigravity-cli", displayName: "Antigravity (Google AI plan)", vendor: "Google", authMode: .subscriptionCLI,
                               isLocal: false, destination: "agy", supportsNativePDF: false, streaming: .token,
                               retentionNote: "Runs through your Google account. Its tools cannot be switched off: Referee stops the run if it uses one. "
                                   + "The CLI may keep a local conversation record.",
                               isExperimental: true),
            ProviderDescriptor(id: "grok-cli", displayName: "Grok Build", vendor: "xAI", authMode: .subscriptionCLI,
                               isLocal: false, destination: "grok", supportsNativePDF: false, streaming: .token,
                               retentionNote: "Runs through your xAI account with tools denied. The CLI saves each conversation in ~/.grok and may sync "
                                   + "it to your account; Referee deletes the local copy after each run.",
                               isExperimental: true),
        ].map { UnimplementedCLIProvider(descriptor: $0) }
    }
}
