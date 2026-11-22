import Foundation
import Testing
@testable import CLIProviders
import RefereeCore

/// Acceptance row "failures": fake `auth` → `.auth`; `quota` → `.quotaExhausted`; `garbage` is ignored and the run
/// ends with `.cliExited` or `.malformedResponse`; a non-zero exit gives `.cliExited` with the stderr tail.
@Suite(.timeLimit(.minutes(1))) struct CLIFailureTests {
    static func run(_ cli: String, _ variables: [String: String]) async throws -> (RunResult, FakeCLIHarness) {
        let harness = try FakeCLIHarness()
        let adapter = try #require(allAdapters.first { $0.spec.name == cli })
        let provider = try harness.provider(adapter, variables)
        return (await collect(provider.stream(markedRequest())), harness)
    }

    @Test(arguments: allAdapters.map(\.spec.name))
    func authFailure(cli: String) async throws {
        let (result, harness) = try await Self.run(cli, ["FAKE_MODE": "auth"])
        defer { harness.cleanup() }
        guard case .auth? = result.error else {
            Issue.record("expected .auth, got \(String(describing: result.error))")
            return
        }
        #expect(result.finished == nil)
        #expect(await harness.waitForNoLeftovers().isEmpty)
    }

    @Test(arguments: allAdapters.map(\.spec.name))
    func quotaFailure(cli: String) async throws {
        let (result, harness) = try await Self.run(cli, ["FAKE_MODE": "quota"])
        defer { harness.cleanup() }
        guard case .quotaExhausted? = result.error else {
            Issue.record("expected .quotaExhausted, got \(String(describing: result.error))")
            return
        }
        #expect(await harness.waitForNoLeftovers().isEmpty)
    }

    @Test(arguments: allAdapters.map(\.spec.name))
    func garbageIsIgnored(cli: String) async throws {
        let (result, harness) = try await Self.run(cli, ["FAKE_MODE": "garbage"])
        defer { harness.cleanup() }
        switch result.error {
        case .cliExited?, .malformedResponse?: break
        default: Issue.record("expected .cliExited or .malformedResponse, got \(String(describing: result.error))")
        }
        #expect(result.deltas.isEmpty)
        #expect(await harness.waitForNoLeftovers().isEmpty)
    }

    @Test(arguments: allAdapters.map(\.spec.name))
    func nonZeroExitCarriesTheStderrTail(cli: String) async throws {
        let (result, harness) = try await Self.run(cli, ["FAKE_MODE": "crash"])
        defer { harness.cleanup() }
        guard case .cliExited(let code, let tail)? = result.error else {
            Issue.record("expected .cliExited, got \(String(describing: result.error))")
            return
        }
        #expect(code == 3)
        #expect(tail.contains("something went wrong"))
    }

    /// A non-zero exit with no result line: stderr is classified first.
    @Test(arguments: allAdapters.map(\.spec.name))
    func stderrIsClassifiedBeforeGivingUp(cli: String) async throws {
        guard cli != "grok" else { return }          // grok's fake has no stderr-auth mode: its auth failure is in the protocol
        let (result, harness) = try await Self.run(cli, ["FAKE_MODE": "stderr-auth"])
        defer { harness.cleanup() }
        guard case .auth? = result.error else {
            Issue.record("expected .auth, got \(String(describing: result.error))")
            return
        }
    }

    @Test func antigravityUnknownModel() async throws {
        let (result, harness) = try await Self.run("agy", ["FAKE_MODE": "model-not-found"])
        defer { harness.cleanup() }
        guard case .modelNotFound? = result.error else {
            Issue.record("expected .modelNotFound, got \(String(describing: result.error))")
            return
        }
    }

    @Test func aBinaryThatCannotBeSpawned() async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        // A file that passes the resolver (it is executable and answers --version) but is gone when the run starts
        // cannot be arranged without a race, so the runner is tested directly.
        let invocation = CLIInvocation(executable: harness.root.appendingPathComponent("missing").path, arguments: [], input: .data(Data()),
                                       workingDirectory: harness.temporary, environment: [:])
        #expect(throws: LLMError.self) { _ = try CLIRunner().start(invocation) }
        do {
            _ = try CLIRunner().start(invocation)
        } catch let error as LLMError {
            guard case .cliLaunchFailed = error else {
                Issue.record("expected .cliLaunchFailed, got \(error)")
                return
            }
        }
    }

    @Test func errorsHaveTheEngineMessage() {
        #expect(LLMError.toolUseBlocked("Bash").userMessage
                == "The command-line tool tried to use a tool (Bash); the run was stopped and nothing it produced after that point was used.")
    }
}
