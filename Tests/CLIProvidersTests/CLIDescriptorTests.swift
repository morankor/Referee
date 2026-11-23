import Foundation
import Testing
@testable import CLIProviders
import RefereeCore
import TestSupport

/// The four descriptors: roster values of plan.md section 5.2, transport limits of section 5.6.4, retention notes of
/// section 9.7, and the PDF fields that the delivery experiment of section 5.6.6 set.
@Suite struct CLIDescriptorTests {
    static let environment = ProviderEnvironment(settings: { _ in ProviderSettings(enabled: false, inputMode: .auto) }, secrets: InMemorySecretStore(),
                                                 urlSession: URLSession.shared, processEnvironment: [:])

    @Test func descriptorsAfterTheDeliveryExperiment() throws {
        let descriptors = CLIProviderFactory.makeProviders(environment: Self.environment).map(\.descriptor)
        #expect(descriptors.map(\.id) == ["claude-cli", "codex-cli", "antigravity-cli", "grok-cli"])
        #expect(descriptors.map(\.displayName) == ["Claude Code (subscription)", "Codex (ChatGPT plan)", "Antigravity (Google AI plan)", "Grok Build"])
        #expect(descriptors.map(\.destination) == ["claude", "codex", "agy", "grok"])
        #expect(descriptors.map(\.vendor) == ["Anthropic", "OpenAI", "Google", "xAI"])
        #expect(descriptors.map(\.streaming) == [.token, .message, .token, .token])
        #expect(descriptors.map(\.maxPromptBytes) == [9_000_000, 4_000_000, 4_000_000, 4_000_000])
        #expect(descriptors.map(\.isExperimental) == [false, false, true, true])
        #expect(descriptors.allSatisfy { $0.authMode == .subscriptionCLI && !$0.isLocal })
        // C1 passed: Claude Code reads the PDF from a document block. X1 passed: Codex reads page images.
        #expect(descriptors.map(\.supportsNativePDF) == [true, true, false, false])
        #expect(descriptors.map(\.pdfDeliveryNote) == [nil, "sent as page images", nil, nil])
        #expect(ClaudeCodeAdapter.delivery == .documentBlock)
        #expect(CodexAdapter.delivery == .pageImages)
        #expect(descriptors[0].retentionNote == "Runs through your Claude Code login with its tools switched off; no session transcript is saved.")
        #expect(descriptors[1].retentionNote == "Runs through your ChatGPT plan with shell and agent tools switched off; session files are not kept.")
        #expect(descriptors[2].retentionNote == "Runs through your Google account. Its tools cannot be switched off: the app stops the run if it uses one. "
                + "The CLI may keep a local conversation record.")
        #expect(descriptors[3].retentionNote == "Runs through your xAI account with tools denied. The CLI saves each conversation in ~/.grok and may sync "
                + "it to your account; the app deletes the local copy after each run.")
    }

    /// Making the providers looks for nothing and starts nothing.
    @Test func makingTheProvidersStartsNothing() {
        let before = ProcessTree.children(of: getpid())
        _ = CLIProviderFactory.makeProviders(environment: Self.environment)
        #expect(ProcessTree.children(of: getpid()).count <= before.count)
    }
}
