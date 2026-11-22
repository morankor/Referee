import Foundation
import Testing
@testable import CLIProviders
import RefereeCore
import TestSupport

/// Prints every stdout line of a real run (long lines cut), so that a failure can be studied without sending the
/// prompt again. The log is the test's own output; nothing is written into the repository.
let printRawLines: @Sendable (ProviderID, String) -> Void = { id, line in
    print("RAW \(id) \(line.count > 3_000 ? String(line.prefix(3_000)) + " …(\(line.count) characters)" : line)")
}

/// Acceptance row "smoke": the one prompt of plan.md section 11.6 through each installed, signed-in CLI. Runs only
/// with REFEREE_CLI_SMOKE=1; it uses a few tokens of the user's plan per CLI.
@Suite(.timeLimit(.minutes(10))) struct CLISmokeTests {
    static let enabled = ProcessInfo.processInfo.environment["REFEREE_CLI_SMOKE"] == "1"

    @Test(.enabled(if: enabled, "the smoke prompts run only with REFEREE_CLI_SMOKE=1 (plan.md section 11.6)"))
    func replyWithExactlyOK() async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        var host = RealCLI.host(temporary: harness.temporary)
        host.lineObserver = printRawLines
        let environment = FakeCLIHarness.providerEnvironment(host.processEnvironment, settings: ProviderSettings(enabled: true, inputMode: .auto))
        var ran: [ProviderID] = []
        for provider in CLIProviderFactory.makeProviders(environment: environment, host: host) {
            let id = provider.descriptor.id
            let availability = await provider.availability()
            guard case .ready = availability else {
                print("SMOKE \(id): skipped, \(availability)")
                continue
            }
            let request = LLMRequest(system: "Follow the user's instruction exactly.", parts: [.text("Reply with exactly: OK")], purpose: .ping)
            let result = await collect(provider.stream(request))
            var answer = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if answer.hasSuffix(".") { answer.removeLast() }
            print("SMOKE \(id): text \(String(reflecting: result.text)), finished \(String(describing: result.finished)), "
                  + "error \(String(describing: result.error)), statuses \(result.statuses)")
            ran.append(id)
            if case .toolUseBlocked(let tool)? = result.error { Issue.record("\(id): the tripwire fired (\(tool))") }
            #expect(result.error == nil, "\(id)")
            #expect(result.finished != nil, "\(id)")
            #expect(answer.lowercased() == "ok", "\(id) answered \(String(reflecting: result.text))")
        }
        print("SMOKE ran for: \(ran)")
    }
}

/// The delivery experiment of plan.md section 5.6.6, one variant per run, with `Fixtures/pdf/ay_round_nolinks.pdf`
/// only. Runs only with REFEREE_CLI_EXPERIMENT set to C1 (Claude Code, document block) or X1 (Codex, page images);
/// section 11.6 allows at most three such prompts per CLI. The outcome is recorded in
/// docs/contract-notes/wp5-cliproviders.md and sets the adapters' delivery constants.
@Suite(.timeLimit(.minutes(15))) struct CLIDeliveryExperimentTests {
    static let variant = ProcessInfo.processInfo.environment["REFEREE_CLI_EXPERIMENT"]
    static let question = """
    Answer in exactly two lines and nothing else.
    Line 1: the right-hand side of equation (1), written in LaTeX.
    Line 2: the estimate in the row "Staggered rollout" of Table 2.
    """

    @Test(.enabled(if: variant == "C1" || variant == "X1", "runs only with REFEREE_CLI_EXPERIMENT=C1 or X1 (plan.md section 5.6.6)"))
    func deliveryVariant() async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        var host = RealCLI.host(temporary: harness.temporary)
        host.lineObserver = printRawLines
        let adapter: any CLIAdapter
        switch Self.variant {
        case "C1": adapter = ClaudeCodeAdapter(); host.pdfDelivery = .documentBlock
        default: adapter = CodexAdapter(); host.pdfDelivery = .pageImages
        }
        let provider = CLIProvider(adapter: adapter, environment: FakeCLIHarness.providerEnvironment(host.processEnvironment), host: host)
        let availability = await provider.availability()
        guard case .ready = availability else {
            print("EXPERIMENT \(Self.variant ?? "?"): not run, \(availability)")
            Issue.record("the CLI is not ready: \(availability)")
            return
        }
        let pdf = try Data(contentsOf: Fixtures.url("pdf/ay_round_nolinks.pdf"))
        let request = LLMRequest(system: "You read academic manuscripts and answer questions about them precisely.",
                                 parts: [.pdf(data: pdf, fileName: "manuscript.pdf"), .cacheBoundary, .text(Self.question)], purpose: .question)
        let started = ContinuousClock.now
        let result = await collect(provider.stream(request))
        let passed = result.error == nil && result.finished != nil && result.text.contains("\\frac") && result.text.contains("0.87")
        print("EXPERIMENT \(Self.variant ?? "?"): \(passed ? "PASS" : "FAIL") after \(ContinuousClock.now - started)")
        print("EXPERIMENT text: \(String(reflecting: result.text))")
        print("EXPERIMENT finished: \(String(describing: result.finished)), error: \(String(describing: result.error)), statuses: \(result.statuses)")
        #expect(passed)
    }
}
