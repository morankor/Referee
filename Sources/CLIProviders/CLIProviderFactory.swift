import Foundation
import RefereeCore

public enum CLIProviderFactory {
    /// ids, in order: claude-cli, codex-cli, antigravity-cli, grok-cli
    ///
    /// Building the providers looks for nothing and starts nothing; the binaries are found when a provider is first
    /// asked for its availability, its models or a stream.
    public static func makeProviders(environment: ProviderEnvironment) -> [any LLMProvider] {
        makeProviders(environment: environment, host: CLIHost(processEnvironment: environment.processEnvironment))
    }

    /// The same, with the knobs tests turn (timeouts, PATH, delivery).
    static func makeProviders(environment: ProviderEnvironment, host: CLIHost) -> [CLIProvider] {
        adapters.map { CLIProvider(adapter: $0, environment: environment, host: host) }
    }

    static let adapters: [any CLIAdapter] = [ClaudeCodeAdapter(), CodexAdapter(), AntigravityAdapter(), GrokBuildAdapter()]
}
