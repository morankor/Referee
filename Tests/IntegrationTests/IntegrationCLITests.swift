import Foundation
import Testing

/// Gate 1 (plan.md section 11.4), row "CLI": the built `referee-cli`, run as a subprocess. `scripts/test.sh` does not
/// build executables, so `scripts/build.sh` must have run first (the acceptance of Gate 1 runs it first).
@Suite(.timeLimit(.minutes(2))) struct IntegrationCLITests {
    /// The repository root, from this file's own path (Tests/IntegrationTests/<file>).
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let binary = root.appendingPathComponent(".build/debug/referee-cli")

    struct Result {
        var status: Int32
        var stdout: String
        var stderr: String
        var lines: [String] { stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
    }

    /// Runs the CLI from the repository root with `arguments`; ends it after `timeout` seconds.
    static func run(_ arguments: [String], timeout: TimeInterval = 60) async throws -> Result {
        try #require(FileManager.default.isExecutableFile(atPath: binary.path),
                     "\(binary.lastPathComponent) is not built: run scripts/build.sh before scripts/test.sh")
        var environment = ProcessInfo.processInfo.environment
        environment["REFEREE_HOME"] = nil                          // the CLI makes a temporary one of its own
        let output = try await Subprocess.run(binary, arguments, directory: root, environment: environment, timeout: timeout)
        if output.timedOut { Issue.record("referee-cli \(arguments.first ?? "") did not finish within \(timeout) s") }
        return Result(status: output.status, stdout: String(decoding: output.stdout, as: UTF8.self),
                      stderr: String(decoding: output.stderr, as: UTF8.self))
    }

    @Test func providersAsJSONParse() async throws {
        let result = try await Self.run(["providers", "--json"])
        #expect(result.status == 0)
        let rows = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]])
        #expect(rows.compactMap { $0["id"] as? String } == ["anthropic-api", "openai-api", "gemini-api", "xai-api", "ollama",
                                                            "claude-cli", "codex-cli", "antigravity-cli", "grok-cli"])
        #expect(rows.allSatisfy { ["ready", "needsSetup", "unavailable"].contains($0["status"] as? String ?? "") })
    }

    @Test func aMockReviewEndsWithACompletedSummary() async throws {
        let result = try await Self.run(["review", "Fixtures/pdf/ay_round_nolinks.pdf", "--provider", "mock"])
        #expect(result.status == 0, "\(result.stderr)")
        let summary = try #require(result.lines.last { $0.hasPrefix("SUMMARY ") })
        #expect(summary.hasPrefix("SUMMARY comments=6 anchored="))
        #expect(summary.contains(" status=completed "))
        #expect(summary.contains(" requests=1 "))
        #expect(summary.hasSuffix(" model=-"))                                 // the mock's stream names no model (step 5c)
        #expect(result.lines.contains { $0.hasPrefix("[major] p. 1 (exact)  ") })
        #expect(result.stderr.contains("sending text to this Mac"))

        let json = try await Self.run(["review", "Fixtures/pdf/ay_round_nolinks.pdf", "--provider", "mock", "--json"])
        #expect(json.status == 0)
        let events = json.stdout.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        #expect(events.first?["event"] as? String == "started")
        #expect(events.last?["event"] as? String == "summary")
        #expect(events.last?["status"] as? String == "completed")
        #expect(events.last?["model"] as? String == "-")
        #expect(events.filter { $0["event"] as? String == "comment" }.count == 6)
    }

    @Test func anchorExitCodes() async throws {
        let found = try await Self.run(["anchor", "Fixtures/pdf/ay_nolinks.pdf", "--quote",
                                        "The coefficient in Table 2 is 0.91 with a confidence interval that crosses one"])
        #expect(found.status == 0)
        #expect(found.stdout.hasPrefix("exact  p. 1, lines 13–14"))
        let missing = try await Self.run(["anchor", "Fixtures/pdf/ay_nolinks.pdf", "--quote", "this sentence is not in the paper at all whatsoever"])
        #expect(missing.status == 1)
        #expect(missing.stdout == "not found\n")
        let usage = try await Self.run(["anchor", "Fixtures/pdf/ay_nolinks.pdf"])
        #expect(usage.status == 2)
        let unknown = try await Self.run(["plan", "Fixtures/pdf/ay_nolinks.pdf", "--provider", "no-such-provider"])
        #expect(unknown.status == 2)
        let json = try await Self.run(["anchor", "Fixtures/pdf/s1_ruler.pdf", "--json", "--quote",
                                       "The coefficient in Table 2 is 0.91 with a confidence interval that crosses one"])
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any])
        #expect(object["label"] as? String == "p. 1, lines 47–49")
        #expect((object["rects"] as? [[String: Any]])?.allSatisfy { ($0["x"] as? Double ?? 0) >= 100 } == true)
    }

    @Test func extractStatsReportsTheMarginNumbers() async throws {
        let lineno = try await Self.run(["extract", "Fixtures/pdf/ay_nolinks.pdf", "--stats"])
        #expect(lineno.status == 0)
        #expect(lineno.lines.contains("margin numbers 1–54 on 4 pages"))
        #expect(lineno.lines.filter { $0.hasPrefix("page ") }.count == 4)
        let ruler = try await Self.run(["extract", "Fixtures/pdf/s1_ruler.pdf", "--stats"])
        #expect(ruler.status == 0)
        #expect(ruler.lines.contains("ruler 1–60 on 4 pages"))
        #expect(ruler.lines.filter { $0.hasPrefix("page ") && $0.contains("margin numbers 1–60") }.count == 4)
        let plain = try await Self.run(["extract", "Fixtures/pdf/ay_round_nolinks.pdf", "--stats"])
        #expect(plain.lines.contains("no margin line numbers"))
        let text = try await Self.run(["extract", "Fixtures/pdf/ay_round_nolinks.pdf", "--pages", "2"])
        #expect(text.stdout.hasPrefix("[[page 2]]\n"))
        #expect(!text.stdout.contains("[[page 1]]"))
    }

    @Test func planAndCitationsOnTheMock() async throws {
        let plan = try await Self.run(["plan", "Fixtures/pdf/ay_long.pdf", "--provider", "mock"])
        #expect(plan.status == 0)
        #expect(plan.stdout.hasPrefix("PLAN sendsPDF=false requests=1 "))
        let citations = try await Self.run(["citations", "Fixtures/pdf/ay_links.pdf"])
        #expect(citations.status == 0)
        #expect(citations.lines.first == "style authorYear; 9 entries; 15 mentions: 0 from text patterns, 15 from link annotations")
    }
}
