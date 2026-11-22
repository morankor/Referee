import Foundation
import Testing
@testable import CLIProviders
import RefereeCore
import TestSupport

/// Runs through the fake CLIs: the documented streams end to end, and the rows "no manuscript in arguments",
/// "environment", "working directory" and "stdin".
@Suite(.timeLimit(.minutes(1))) struct CLIRunTests {
    static let expectedText: [String: String] = ["claude": "Hello world", "codex": "Hello world", "agy": "apple\n", "grok": "Hello world"]

    @Test(arguments: allAdapters.map(\.spec.name))
    func documentedStreamEndToEnd(cli: String) async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        let adapter = try #require(allAdapters.first { $0.spec.name == cli })
        let provider = try harness.provider(adapter, ["FAKE_MODE": "ok"])
        let result = await collect(provider.stream(markedRequest()))
        #expect(result.error == nil)
        #expect(result.text == Self.expectedText[cli])
        let finished = try #require(result.finished)
        #expect(finished.0 == .endOfTurn)
        if case .finished = result.events.last {} else { Issue.record("the last event is not .finished") }
        #expect(await harness.waitForNoLeftovers().isEmpty)
        if cli == "grok" {
            // The local copy of the conversation is deleted through the protocol (the fake advertises session/delete).
            #expect(harness.log().contains(#""method":"session/delete""#))
            #expect(harness.log().contains(#""sessionId":"sess_1""#))
        }
    }

    @Test func grokWithoutDeleteCapabilityRunsTheDeleteCommand() async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        let provider = try harness.provider(GrokBuildAdapter(), ["FAKE_MODE": "ok", "FAKE_VARIANT": "no-delete"])
        let result = await collect(provider.stream(markedRequest()))
        #expect(result.error == nil)
        #expect(result.text == "Hello world")
        #expect(harness.log().contains("sessions delete sess_1"))
        #expect(result.statuses.isEmpty)
    }

    /// An agent that exits right after answering, before the quiet period: the answer stands and the copy is deleted
    /// with the command.
    @Test func grokThatExitsRightAfterAnswering() async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        let provider = try harness.provider(GrokBuildAdapter(), ["FAKE_MODE": "ok", "FAKE_VARIANT": "exit-after-answer"])
        let result = await collect(provider.stream(markedRequest()))
        #expect(result.error == nil)
        #expect(result.text == "Hello world")
        #expect(result.finished?.0 == .endOfTurn)
        #expect(harness.log().contains("sessions delete sess_1"))
    }

    @Test func grokReportsAFailedDeletionOnce() async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        let provider = try harness.provider(GrokBuildAdapter(), ["FAKE_MODE": "ok", "FAKE_VARIANT": "no-delete", "FAKE_DELETE_EXIT": "1"])
        let result = await collect(provider.stream(markedRequest()))
        #expect(result.error == nil)
        #expect(result.statuses == ["could not delete Grok Build's local copy of this conversation"])
        #expect(result.finished != nil)
    }

    /// Row "no manuscript in arguments": the markers of the system and user texts are in no argument of any CLI.
    @Test(arguments: allAdapters.map(\.spec.name))
    func noManuscriptInArguments(cli: String) async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        let adapter = try #require(allAdapters.first { $0.spec.name == cli })
        let provider = try harness.provider(adapter, ["FAKE_MODE": "print-env"])
        let result = await collect(provider.stream(markedRequest(model: "some-model")))
        #expect(result.error == nil)
        let arguments = harness.out().split(separator: "\n").filter { $0.hasPrefix("ARG=") }
        #expect(!arguments.isEmpty)
        for argument in arguments {
            #expect(!argument.contains("MARKER"), "an argument carries prompt text: \(argument)")
        }
        #expect(arguments.contains("ARG=some-model"))
    }

    /// Row "environment": API keys in the app's environment never reach the CLI; HOME, a PATH with /opt/homebrew/bin,
    /// TERM=dumb and NO_COLOR=1 do; grok also sees GROK_SANDBOX=strict.
    @Test(arguments: allAdapters.map(\.spec.name))
    func environmentIsBuiltFromScratch(cli: String) async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        let adapter = try #require(allAdapters.first { $0.spec.name == cli })
        let keys = ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "CODEX_API_KEY", "GEMINI_API_KEY", "XAI_API_KEY", "ANTHROPIC_BASE_URL",
                    "CLAUDE_CODE_USE_BEDROCK", "GOOGLE_API_KEY"]
        var extra = Dictionary(uniqueKeysWithValues: keys.map { ($0, "secret-\($0.lowercased())") })
        extra["SOME_OTHER_VARIABLE"] = "not copied either"
        extra["HTTPS_PROXY"] = "http://proxy.invalid:8080"
        let provider = try harness.provider(adapter, ["FAKE_MODE": "print-env"], environment: extra)
        let result = await collect(provider.stream(markedRequest()))
        #expect(result.error == nil)
        let lines = harness.out().split(separator: "\n").map(String.init)
        let environment = Dictionary(lines.filter { $0.hasPrefix("ENV=") }.compactMap { line -> (String, String)? in
            let body = line.dropFirst(4)
            guard let equals = body.firstIndex(of: "=") else { return nil }
            return (String(body[..<equals]), String(body[body.index(after: equals)...]))
        }, uniquingKeysWith: { first, _ in first })
        for key in keys { #expect(environment[key] == nil, "\(key) reached the CLI") }
        #expect(!harness.out().contains("secret-"))
        #expect(environment["SOME_OTHER_VARIABLE"] == nil)
        #expect(environment["HOME"] == provider.host.processEnvironment["HOME"])
        #expect(environment["USER"] == "tester")
        #expect(environment["HTTPS_PROXY"] == "http://proxy.invalid:8080")
        #expect(environment["PATH"]?.split(separator: ":").contains("/opt/homebrew/bin") == true)
        #expect(environment["TERM"] == "dumb")
        #expect(environment["NO_COLOR"] == "1")
        #expect(environment["GROK_SANDBOX"] == (cli == "grok" ? "strict" : nil))
    }

    /// Row "working directory": the CLI runs in a directory that holds only what the adapter put there, and that is gone
    /// after the run.
    @Test(arguments: allAdapters.map(\.spec.name))
    func workingDirectoryIsPrivateAndRemoved(cli: String) async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        let adapter = try #require(allAdapters.first { $0.spec.name == cli })
        let provider = try harness.provider(adapter, ["FAKE_MODE": "print-env"])
        let result = await collect(provider.stream(markedRequest()))
        #expect(result.error == nil)
        let lines = harness.out().split(separator: "\n").map(String.init)
        let cwd = try #require(lines.first { $0.hasPrefix("CWD=") }).dropFirst(4)
        let listing = try #require(lines.first { $0.hasPrefix("LS=") }).dropFirst(3).trimmingCharacters(in: .whitespaces)
        #expect(cwd.hasPrefix(harness.temporary.path + "/referee-cli-"))
        #expect(listing == (cli == "claude" ? "system.txt" : ""))
        #expect(!FileManager.default.fileExists(atPath: String(cwd)))
        // Nothing else was left in the temporary directory either.
        #expect((try? FileManager.default.contentsOfDirectory(atPath: harness.temporary.path))?.isEmpty == true)
    }

    @Test func claudeSystemPromptGoesInAFileNotAnArgument() async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        let provider = try harness.provider(ClaudeCodeAdapter(), ["FAKE_MODE": "print-env"])
        _ = await collect(provider.stream(markedRequest()))
        let arguments = harness.out().split(separator: "\n").filter { $0.hasPrefix("ARG=") }.map { String($0.dropFirst(4)) }
        let index = try #require(arguments.firstIndex(of: "--system-prompt-file"))
        #expect(arguments[index + 1].hasSuffix("/system.txt"))
        #expect(arguments.contains(ClaudeCodeAdapter.promptArgument))
    }

    /// Row "stdin": a 2 MB prompt reaches the fake intact, although the fake writes 300 KB to stdout before it reads.
    @Test(arguments: ["claude", "codex"])
    func twoMegabytesOfStdinWithoutDeadlock(cli: String) async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        let adapter = try #require(allAdapters.first { $0.spec.name == cli })
        let copy = harness.root.appendingPathComponent("stdin-copy")
        let provider = try harness.provider(adapter, ["FAKE_MODE": "echo-bytes", "FAKE_STDIN_COPY": copy.path])
        var user = ""
        let line = "The quick brown fox jumps over the lazy dog — ünïcödé ✓ 0123456789.\n"
        while user.utf8.count < 2_000_000 { user += line }
        let request = LLMRequest(system: "system text", parts: [.text(user)], purpose: .review)
        let result = await collect(provider.stream(request))
        #expect(result.error == nil)
        let expected = cli == "claude" ? Data(user.utf8) : Data(CLIPrompt.inline(system: "system text", user: user).utf8)
        #expect(result.text == String(expected.count))
        #expect(try Data(contentsOf: copy) == expected)
    }

    @Test func aPromptAboveTheTransportLimitIsRefusedBeforeAnyProcess() async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        let provider = try harness.provider(CodexAdapter(), ["FAKE_MODE": "ok"])
        let request = LLMRequest(system: "s", parts: [.text(String(repeating: "x", count: CodexAdapter.maxPromptBytes + 1))], purpose: .review)
        let result = await collect(provider.stream(request))
        guard case .contextTooLong? = result.error else {
            Issue.record("expected .contextTooLong, got \(String(describing: result.error))")
            return
        }
        #expect(harness.recordedPIDs("run").isEmpty)
    }

    @Test func aPDFPartIsRefusedWhenTheRouteIsTextOnly() async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        let provider = try harness.provider(AntigravityAdapter(), ["FAKE_MODE": "ok"])
        let result = await collect(provider.stream(markedRequest(pdf: Data("%PDF-1.4".utf8))))
        guard case .invalidRequest? = result.error else {
            Issue.record("expected .invalidRequest, got \(String(describing: result.error))")
            return
        }
        #expect(harness.recordedPIDs("run").isEmpty)
    }

    @Test func aModelIdThatLooksLikeAFlagIsRefused() async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        let provider = try harness.provider(ClaudeCodeAdapter(), ["FAKE_MODE": "ok"])
        let result = await collect(provider.stream(markedRequest(model: "--dangerously-skip-permissions")))
        guard case .invalidRequest? = result.error else {
            Issue.record("expected .invalidRequest, got \(String(describing: result.error))")
            return
        }
        #expect(harness.recordedPIDs("run").isEmpty)
    }

    /// The `.documentBlock` delivery (section 5.6.6, C1) end to end: no prompt argument, stream-json input, the PDF on
    /// stdin, nothing but the system prompt in the working directory.
    @Test func claudeDocumentBlockThroughTheFake() async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        let copy = harness.root.appendingPathComponent("stdin-copy")
        let provider = try harness.provider(ClaudeCodeAdapter(), ["FAKE_MODE": "echo-bytes", "FAKE_STDIN_COPY": copy.path]) { $0.pdfDelivery = .documentBlock }
        let pdf = try Data(contentsOf: Fixtures.url("pdf/ay_round_nolinks.pdf"))
        let result = await collect(provider.stream(markedRequest(pdf: pdf)))
        #expect(result.error == nil)
        let stdin = try Data(contentsOf: copy)
        #expect(result.text == String(stdin.count))
        let line = try #require(try JSONSerialization.jsonObject(with: stdin) as? [String: Any])
        let content = try #require((line["message"] as? [String: Any])?["content"] as? [[String: Any]])
        #expect(((content.first?["source"] as? [String: Any])?["data"] as? String) == pdf.base64EncodedString())
        #expect(content.last?["text"] as? String == "USER-MARKER-7Q2 Please review.")

        let printing = try harness.provider(ClaudeCodeAdapter(), ["FAKE_MODE": "print-env"]) { $0.pdfDelivery = .documentBlock }
        #expect(await collect(printing.stream(markedRequest(pdf: pdf))).error == nil)
        let lines = harness.out().split(separator: "\n").map(String.init)
        let arguments = lines.filter { $0.hasPrefix("ARG=") }.map { String($0.dropFirst(4)) }
        #expect(arguments.first == "-p")
        #expect(!arguments.contains(ClaudeCodeAdapter.promptArgument))
        #expect(arguments.suffix(2) == ["--input-format", "stream-json"])
        #expect(lines.contains("LS=system.txt "))
    }

    /// The `.pageImages` delivery (section 5.6.6, X1) end to end: four PNGs in the working directory, one `-i` each.
    @Test func codexPageImagesThroughTheFake() async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        let provider = try harness.provider(CodexAdapter(), ["FAKE_MODE": "print-env"]) { $0.pdfDelivery = .pageImages }
        let pdf = try Data(contentsOf: Fixtures.url("pdf/ay_round_nolinks.pdf"))
        let result = await collect(provider.stream(markedRequest(pdf: pdf)))
        #expect(result.error == nil)
        #expect(result.text == "Hello world")
        let lines = harness.out().split(separator: "\n").map(String.init)
        let cwd = try #require(lines.first { $0.hasPrefix("CWD=") }).dropFirst(4)
        #expect(lines.contains("LS=p001.png p002.png p003.png p004.png "))
        let arguments = lines.filter { $0.hasPrefix("ARG=") }.map { String($0.dropFirst(4)) }
        let images = arguments.indices.filter { arguments[$0] == "-i" }.map { arguments[$0 + 1] }
        #expect(images == (1...4).map { "\(cwd)/" + String(format: "p%03d.png", $0) })
        #expect(!FileManager.default.fileExists(atPath: String(cwd)))
    }

    /// The stream is cold: nothing is started until it is iterated.
    @Test func nothingStartsBeforeTheStreamIsRead() async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        let provider = try harness.provider(ClaudeCodeAdapter(), ["FAKE_MODE": "ok"])
        let stream = provider.stream(markedRequest())
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.recordedPIDs("probe").isEmpty && harness.recordedPIDs("run").isEmpty)
        let result = await collect(stream)
        #expect(result.text == "Hello world")
    }
}
