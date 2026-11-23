import Foundation
import Testing
@testable import CLIProviders
import RefereeCore

/// Acceptance row "timeouts and cancel": `hang` → `.cliTimeout(phase: "start")` with a 1 s timeout; cancelling the
/// consumer kills the fake within 6 s; a fake that starts a child `sleep 600`: after cancellation, and after a
/// tripwire, the child is gone too.
@Suite(.timeLimit(.minutes(1))) struct CLITimeoutTests {
    @Test(arguments: allAdapters.map(\.spec.name))
    func hangTimesOutAtStart(cli: String) async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        let adapter = try #require(allAdapters.first { $0.spec.name == cli })
        let provider = try harness.provider(adapter, ["FAKE_MODE": "hang"],
                                            timeouts: CLITimeouts(firstOutput: .seconds(1), idle: .seconds(60), total: .seconds(60)))
        let started = ContinuousClock.now
        let result = await collect(provider.stream(markedRequest()))
        #expect(result.error == .cliTimeout(phase: "start"))
        // One second, then the graceful end: SIGINT (the fake's shell waits for its `sleep`), SIGTERM 2 s later.
        #expect(ContinuousClock.now - started < .seconds(12))
        #expect(await harness.waitForNoLeftovers(.seconds(3)).isEmpty)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: harness.temporary.path))?.isEmpty == true)
    }

    @Test func idleAndTotalTimeouts() async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        // `slow` prints its first line at once, then one line a second.
        let idle = try harness.provider(ClaudeCodeAdapter(), ["FAKE_MODE": "slow"],
                                        timeouts: CLITimeouts(firstOutput: .seconds(10), idle: .milliseconds(400), total: .seconds(60)))
        #expect(await collect(idle.stream(markedRequest())).error == .cliTimeout(phase: "idle"))
        let total = try harness.provider(ClaudeCodeAdapter(), ["FAKE_MODE": "slow"],
                                         timeouts: CLITimeouts(firstOutput: .seconds(10), idle: .seconds(10), total: .milliseconds(1_500)))
        let result = await collect(total.stream(markedRequest()))
        #expect(result.error == .cliTimeout(phase: "total"))
        #expect(!result.deltas.isEmpty)
        #expect(await harness.waitForNoLeftovers(.seconds(8)).isEmpty)
    }

    /// Reads until the first text delta, then cancels the consumer; returns when the task has ended.
    static func cancelAfterFirstDelta(_ provider: CLIProvider) async {
        let (signal, signalContinuation) = AsyncStream<Void>.makeStream()
        let consumer = Task {
            do {
                for try await event in provider.stream(markedRequest()) {
                    if case .textDelta = event { signalContinuation.yield(()) }
                }
            } catch {}
        }
        for await _ in signal { break }
        consumer.cancel()
        _ = await consumer.value
    }

    @Test(arguments: allAdapters.map(\.spec.name))
    func cancellingTheConsumerKillsTheCLI(cli: String) async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        let adapter = try #require(allAdapters.first { $0.spec.name == cli })
        let provider = try harness.provider(adapter, ["FAKE_MODE": "slow"])
        await Self.cancelAfterFirstDelta(provider)
        let cancelledAt = ContinuousClock.now
        let run = try #require(harness.recordedPIDs("run").first)
        while ProcessTree.isRunning(run) && ContinuousClock.now - cancelledAt < .seconds(6) {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!ProcessTree.isRunning(run), "the CLI was still running 6 s after the consumer was cancelled")
        // The working directory goes too, once the process is gone.
        let deadline = ContinuousClock.now + .seconds(3)
        while (try? FileManager.default.contentsOfDirectory(atPath: harness.temporary.path))?.isEmpty == false && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: harness.temporary.path))?.isEmpty == true)
    }

    @Test(arguments: allAdapters.map(\.spec.name))
    func aChildOfTheCLIDiesWithItWhenCancelled(cli: String) async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        let adapter = try #require(allAdapters.first { $0.spec.name == cli })
        let provider = try harness.provider(adapter, ["FAKE_MODE": "spawn-child"])
        await Self.cancelAfterFirstDelta(provider)
        let cancelledAt = ContinuousClock.now
        let child = try #require(harness.recordedPIDs("child").first)
        while ProcessTree.isRunning(child) && ContinuousClock.now - cancelledAt < .seconds(6) {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!ProcessTree.isRunning(child), "the CLI's child was still running 6 s after cancellation")
        #expect(await harness.waitForNoLeftovers(.seconds(2)).isEmpty)
    }

    @Test(arguments: allAdapters.map(\.spec.name))
    func aChildOfTheCLIDiesWithItAfterATripwire(cli: String) async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        let adapter = try #require(allAdapters.first { $0.spec.name == cli })
        let provider = try harness.provider(adapter, ["FAKE_MODE": "spawn-child", "FAKE_VARIANT": "tool"])
        let result = await collect(provider.stream(markedRequest()))
        guard case .toolUseBlocked? = result.error else {
            Issue.record("expected .toolUseBlocked, got \(String(describing: result.error))")
            return
        }
        let child = try #require(harness.recordedPIDs("child").first)
        let deadline = ContinuousClock.now + .seconds(2)
        while ProcessTree.isRunning(child) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!ProcessTree.isRunning(child), "the CLI's child survived the tripwire")
        #expect(await harness.waitForNoLeftovers(.seconds(2)).isEmpty)
    }

    /// A probe (`--version` and the like) that overruns is killed at once with its tree.
    @Test func aProbeThatHangsIsKilled() async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        let path = harness.install.resolverEntry("hang-version")
        let home = try harness.makeHome([:])
        let started = ContinuousClock.now
        let result = await CLICommand.run(path, ["--version"], environment: ["PATH": FakeCLIHarness.fixedPath, "HOME": home.path],
                                          temporaryRoot: harness.temporary, timeout: .seconds(1))
        #expect(result == .failure(.cliTimeout(phase: "start")))
        // The fake sleeps 600 seconds: ending far under that shows the one-second timeout killed it. The bound is
        // generous because the whole suite runs at once and a busy machine can delay a test by seconds.
        #expect(ContinuousClock.now - started < .seconds(30))
        #expect(await harness.waitForNoLeftovers(.seconds(10)).isEmpty)
    }
}
