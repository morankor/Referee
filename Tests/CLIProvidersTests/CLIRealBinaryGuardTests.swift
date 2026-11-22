import Foundation
import Testing
@testable import CLIProviders
import RefereeCore
import TestSupport

/// Gate 1. (1) The incident of WP5's notes: a fake CLI that missed its `--version` deadline let the resolver go on to
/// the real Codex, which then sent a test prompt. The harness's host must never look beyond the fake: these tests use
/// each adapter's real spec, real candidate list included, and a fake that fails its version check. (2) The child
/// environment: Claude Code's `CLAUDE_CODE_OAUTH_TOKEN` reaches `claude` and no other CLI, and `USER` is always set.
@Suite(.timeLimit(.minutes(1))) struct CLIRealBinaryGuardTests {
    static let adapters: [any CLIAdapter] = [ClaudeCodeAdapter(), CodexAdapter(), AntigravityAdapter(), GrokBuildAdapter()]

    @Test func theHarnessHostNeverSearchesTheDefaultLocations() throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        #expect(harness.host(harness.processEnvironment()).searchesDefaultLocations == false)
        let provider = try harness.provider(ClaudeCodeAdapter())
        #expect(provider.host.searchesDefaultLocations == false)
    }

    @Test(arguments: adapters.map(\.spec.name))
    func aFakeThatFailsItsVersionCheckNeverLetsARealCLIRun(cli: String) async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        let adapter = try #require(Self.adapters.first { $0.spec.name == cli })
        var environment = harness.processEnvironment(home: try harness.makeHome([:]))
        environment[adapter.spec.environmentOverride] = harness.install.resolverEntry("fail-version")
        let host = harness.host(environment, probeTimeout: .seconds(2))
        let resolved = await BinaryResolver(host: host).resolve(adapter.spec, explicitPath: nil)
        guard case .failure(.notConfigured(let reason)) = resolved else {
            Issue.record("\(cli): the resolver found \(resolved) instead of failing; it must never fall through to a real binary")
            return
        }
        #expect(reason.contains("was found but does not run"))
        // The provider refuses to stream at all.
        let provider = CLIProvider(adapter: adapter, environment: FakeCLIHarness.providerEnvironment(environment), host: host)
        let result = await collect(provider.stream(LLMRequest(system: "s", parts: [.text("t")], purpose: .ping)))
        guard case .notConfigured? = result.error else {
            Issue.record("\(cli): expected .notConfigured, got \(String(describing: result.error))")
            return
        }
        #expect(result.deltas.isEmpty)
        #expect(harness.recordedPIDs("run").isEmpty)                      // nothing was started for the prompt
    }

    @Test(arguments: adapters.map(\.spec.name))
    func theClaudeTokenReachesClaudeAndNoOtherCLI(cli: String) async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        let adapter = try #require(Self.adapters.first { $0.spec.name == cli })
        let provider = try harness.provider(adapter, ["FAKE_MODE": "print-env"], environment: ["CLAUDE_CODE_OAUTH_TOKEN": "token-for-the-test"])
        let result = await collect(provider.stream(LLMRequest(system: "s", parts: [.text("t")], purpose: .ping)))
        #expect(result.error == nil)
        let seen = harness.out().split(separator: "\n").contains { $0 == "ENV=CLAUDE_CODE_OAUTH_TOKEN=token-for-the-test" }
        #expect(seen == (cli == "claude"), "\(cli)")
    }

    @Test func userIsAlwaysSet() {
        #expect(ChildEnvironment.make(from: ["HOME": "/nowhere", "USER": "someone"], loginPath: nil)["USER"] == "someone")
        #expect(ChildEnvironment.make(from: ["HOME": "/nowhere", "LOGNAME": "logname"], loginPath: nil)["USER"] == "logname")
        #expect(ChildEnvironment.make(from: ["HOME": "/nowhere"], loginPath: nil)["USER"] == NSUserName())
        // A name passed through for one CLI is copied only when asked for, and the never-copied names stay out.
        let app = ["HOME": "/nowhere", "CLAUDE_CODE_OAUTH_TOKEN": "t", "ANTHROPIC_API_KEY": "k"]
        #expect(ChildEnvironment.make(from: app, loginPath: nil)["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
        #expect(ChildEnvironment.make(from: app, loginPath: nil, passThrough: ["CLAUDE_CODE_OAUTH_TOKEN"])["CLAUDE_CODE_OAUTH_TOKEN"] == "t")
        #expect(ChildEnvironment.make(from: app, loginPath: nil, passThrough: ["ANTHROPIC_API_KEY"])["ANTHROPIC_API_KEY"] == nil)
    }
}
