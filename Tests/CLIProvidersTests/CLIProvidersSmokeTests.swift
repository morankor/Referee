import Foundation
import Testing
import RefereeCore
import CLIProviders
import TestSupport

/// Wave 0a smoke test. It holds for the placeholders and must keep holding for the real implementation (WP5).
/// It only builds the providers: no binary is looked for and no process is started.
@Suite struct CLIProvidersSmokeTests {
    @Test func factoryMakesTheFourCLIProvidersInOrder() {
        let environment = ProviderEnvironment(settings: { _ in ProviderSettings(enabled: false, inputMode: .auto) }, secrets: InMemorySecretStore(),
                                              urlSession: StubURLProtocol.session(), processEnvironment: [:])
        let descriptors = CLIProviderFactory.makeProviders(environment: environment).map(\.descriptor)
        #expect(descriptors.map(\.id) == ["claude-cli", "codex-cli", "antigravity-cli", "grok-cli"])
        #expect(descriptors.allSatisfy { $0.authMode == .subscriptionCLI && !$0.isLocal })
    }
}
