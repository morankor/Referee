import Foundation
import Testing
@testable import CLIProviders
import RefereeCore
import TestSupport

/// Acceptance row "argument lists": for each CLI the exact argument array of plan.md section 5.6.4 for the default
/// model and an explicit one, with `extraArguments` appended; `!--print-timeout` removes that argument; `!--sandbox`
/// and `!--tools` remove nothing and give the "cannot be removed" status.
@Suite struct CLIArgumentListTests {
    static let workdir = URL(fileURLWithPath: "/private/var/folders/x/T/referee-cli-TEST", isDirectory: true)

    static func arguments(_ adapter: any CLIAdapter, model: String? = nil, extra: [String] = []) -> CLIArgumentList {
        CLIArguments.build(adapter.argumentTable(workspace: workdir, model: model, delivery: .none), extraArguments: extra)
    }

    static let claude = ["-p", "The complete task is in the piped input. Follow it exactly.",
                         "--safe-mode", "--tools", "", "--disallowedTools", "mcp__*", "--strict-mcp-config", "--disable-slash-commands",
                         "--no-session-persistence", "--permission-prompts", "none",
                         "--system-prompt-file", workdir.path + "/system.txt",
                         "--output-format", "stream-json", "--verbose", "--include-partial-messages"]
    static let codex = ["exec", "-", "--json", "--skip-git-repo-check",
                        "--ephemeral", "--ignore-user-config", "--ignore-rules", "--strict-config", "--sandbox", "read-only", "-C", workdir.path,
                        "-c", "web_search=\"disabled\"", "-c", "history.persistence=\"none\"", "-c", "agents.enabled=false",
                        "--disable", "shell_tool", "--disable", "view_image", "--disable", "sleep_tool"]
    static let agy = ["--input-format", "stream-json", "--output-format", "stream-json", "--mode=accept-edits", "--sandbox",
                      "--disable-slash-commands", "--print-timeout", "60m"]
    static let grokOptions = ["--no-auto-update", "--sandbox", "strict", "--permission-mode", "dontAsk",
                              "--disallowed-tools", "Bash,Edit,Read,Grep,WebFetch,WebSearch",
                              "--disable-web-search", "--no-subagents", "--no-memory", "--no-plan"]

    @Test func claudeCode() {
        #expect(Self.arguments(ClaudeCodeAdapter()).arguments == Self.claude)
        #expect(Self.arguments(ClaudeCodeAdapter(), model: "opus", extra: ["--effort", "high"]).arguments
                == Self.claude + ["--model", "opus", "--effort", "high"])
    }

    @Test func codex() {
        #expect(Self.arguments(CodexAdapter()).arguments == Self.codex)
        #expect(Self.arguments(CodexAdapter(), model: "gpt-6.2-sol", extra: ["--color", "never"]).arguments
                == Self.codex + ["-m", "gpt-6.2-sol", "--color", "never"])
    }

    @Test func antigravity() {
        #expect(Self.arguments(AntigravityAdapter()).arguments == Self.agy)
        #expect(Self.arguments(AntigravityAdapter(), model: "gemini-4-flash", extra: ["--effort", "low"]).arguments
                == Self.agy + ["--model", "gemini-4-flash", "--effort", "low"])
    }

    @Test func grokBuild() {
        #expect(Self.arguments(GrokBuildAdapter()).arguments == Self.grokOptions + ["agent", "stdio"])
        // The model flag and the extra arguments go before the subcommand.
        #expect(Self.arguments(GrokBuildAdapter(), model: "grok-4.2", extra: ["--verbose"]).arguments
                == Self.grokOptions + ["-m", "grok-4.2", "--verbose", "agent", "stdio"])
    }

    @Test func removingAnUnprotectedArgument() {
        let agy = Self.arguments(AntigravityAdapter(), extra: ["!--print-timeout"])
        #expect(agy.arguments == Array(Self.agy.dropLast(2)))
        #expect(agy.statuses.isEmpty)
        let claude = Self.arguments(ClaudeCodeAdapter(), extra: ["!--verbose", "--debug"])
        #expect(claude.arguments == Self.claude.filter { $0 != "--verbose" } + ["--debug"])
        let grok = Self.arguments(GrokBuildAdapter(), extra: ["!--no-auto-update"])
        #expect(grok.arguments == Array(Self.grokOptions.dropFirst()) + ["agent", "stdio"])
        let codex = Self.arguments(CodexAdapter(), extra: ["!-C"])
        #expect(codex.arguments == Self.codex.filter { $0 != "-C" && $0 != Self.workdir.path })
    }

    @Test func protectedArgumentsCannotBeRemoved() {
        let claude = Self.arguments(ClaudeCodeAdapter(), extra: ["!--tools", "!--safe-mode"])
        #expect(claude.arguments == Self.claude)
        #expect(claude.statuses == ["ignored: --tools cannot be removed", "ignored: --safe-mode cannot be removed"])
        for (adapter, expected) in [(CodexAdapter() as any CLIAdapter, Self.codex), (AntigravityAdapter(), Self.agy),
                                    (GrokBuildAdapter(), Self.grokOptions + ["agent", "stdio"])] {
            let list = Self.arguments(adapter, extra: ["!--sandbox"])
            #expect(list.arguments == expected, "\(adapter.spec.name)")
            #expect(list.statuses == ["ignored: --sandbox cannot be removed"], "\(adapter.spec.name)")
        }
        let codex = Self.arguments(CodexAdapter(), extra: ["!-c", "!--disable", "!--ephemeral"])
        #expect(codex.arguments == Self.codex)
        #expect(codex.statuses.count == 3)
        let grok = Self.arguments(GrokBuildAdapter(), extra: ["!agent"])
        #expect(grok.statuses == ["ignored: agent cannot be removed"])
        let agy = Self.arguments(AntigravityAdapter(), extra: ["!--mode"])
        #expect(agy.statuses == ["ignored: --mode cannot be removed"])
    }

    @Test func aRemovalThatNamesNothing() {
        let list = Self.arguments(CodexAdapter(), extra: ["!--tools", "!"])
        #expect(list.arguments == Self.codex)
        #expect(list.statuses == ["ignored: --tools is not a default argument", "ignored: ! is not a default argument"])
    }

    /// Every protected element of a table is one the flag check looks for, and the other way round.
    @Test(arguments: allAdapters.map(\.spec.name))
    func protectedFlagsMatchTheTable(cli: String) throws {
        let adapter = try #require(allAdapters.first { $0.spec.name == cli })
        let table = adapter.argumentTable(workspace: Self.workdir, model: nil, delivery: .none)
        let protectedFlags = Set((table.leading + table.trailing).filter(\.isProtected).map(\.flagName))
        let checked = Set(adapter.protectedFlags)
        // `-c` (Codex) and `agent` (Grok Build) are protected but are not options a help text lists by themselves.
        #expect(protectedFlags.subtracting(["-c", "agent"]) == checked)
    }

    @Test func pageImagesAddOneImageArgumentPerPage() throws {
        let workspace = try CLIWorkspace.create(in: FileManager.default.temporaryDirectory)
        defer { workspace.remove() }
        let pdf = try Data(contentsOf: Fixtures.url("pdf/ay_round_nolinks.pdf"))
        let input = try CodexAdapter().prepareInput(CLIPrompt(system: "s", user: "u", pdf: pdf), workspace: workspace, delivery: .pageImages)
        let images = (1...4).map { workspace.url.appendingPathComponent(String(format: "p%03d.png", $0)).path }
        #expect(input.attachmentArguments == images.flatMap { ["-i", $0] })
        guard case .data(let stdin) = input.input else {
            Issue.record("Codex input is not data")
            return
        }
        #expect(String(decoding: stdin, as: UTF8.self) == CLIPrompt.inline(system: "s", user: CodexAdapter.pageImagesPreamble + "\n\nu"))
    }

    @Test func claudeDocumentBlockInput() throws {
        let workspace = try CLIWorkspace.create(in: FileManager.default.temporaryDirectory)
        defer { workspace.remove() }
        let pdf = Data("%PDF-1.4 fake".utf8)
        let table = ClaudeCodeAdapter().argumentTable(workspace: workspace.url, model: nil, delivery: .documentBlock)
        let arguments = CLIArguments.build(table, extraArguments: []).arguments
        #expect(arguments.first == "-p")
        #expect(!arguments.contains(ClaudeCodeAdapter.promptArgument))
        #expect(arguments.suffix(2) == ["--input-format", "stream-json"])
        let input = try ClaudeCodeAdapter().prepareInput(CLIPrompt(system: "s", user: "the task", pdf: pdf), workspace: workspace,
                                                         delivery: .documentBlock)
        guard case .data(let stdin) = input.input else {
            Issue.record("Claude input is not data")
            return
        }
        #expect(stdin.last == 0x0A)
        #expect(stdin.dropLast().contains(0x0A) == false)
        let line = try #require(try JSONSerialization.jsonObject(with: stdin) as? [String: Any])
        let message = try #require(line["message"] as? [String: Any])
        let content = try #require(message["content"] as? [[String: Any]])
        #expect(line["type"] as? String == "user")
        #expect(message["role"] as? String == "user")
        #expect(content.count == 2)
        let source = try #require(content[0]["source"] as? [String: Any])
        #expect(content[0]["type"] as? String == "document")
        #expect(source["media_type"] as? String == "application/pdf")
        #expect(source["data"] as? String == pdf.base64EncodedString())
        #expect(content[1]["text"] as? String == "the task")
    }
}
