import Foundation
import Testing
@testable import CLIProviders
import RefereeCore

/// Acceptance rows "tripwire, tool used" and "tripwire, tools not off".
@Suite(.timeLimit(.minutes(1))) struct CLITripwireTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let cli: String
        let mode: String
        let variant: String?
        var testDescription: String { "\(cli) \(mode) \(variant ?? "")" }
    }

    static let toolCases = [
        Case(cli: "claude", mode: "tool", variant: "assistant"), Case(cli: "claude", mode: "tool", variant: "blocks"),
        Case(cli: "codex", mode: "tool", variant: "command"), Case(cli: "codex", mode: "tool", variant: "unknown"),
        Case(cli: "agy", mode: "tool", variant: nil),
        Case(cli: "grok", mode: "tool", variant: nil), Case(cli: "grok", mode: "tool", variant: "permission"),
    ]

    static let toolsOnCases = [
        Case(cli: "claude", mode: "tools-on", variant: "bash"), Case(cli: "claude", mode: "tools-on", variant: "missing"),
        Case(cli: "agy", mode: "tools-on", variant: "always"), Case(cli: "agy", mode: "tools-on", variant: "missing"),
    ]

    /// `.toolUseBlocked`; the process is gone within 2 s; nothing after the tool line is delivered.
    @Test(arguments: toolCases)
    func aToolEndsTheRun(_ testCase: Case) async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        let adapter = try #require(allAdapters.first { $0.spec.name == testCase.cli })
        var variables = ["FAKE_MODE": testCase.mode]
        if let variant = testCase.variant { variables["FAKE_VARIANT"] = variant }
        let provider = try harness.provider(adapter, variables)
        let result = await collect(provider.stream(markedRequest()))
        let failedAt = ContinuousClock.now
        guard case .toolUseBlocked(let tool)? = result.error else {
            Issue.record("expected .toolUseBlocked, got \(String(describing: result.error)) after \(result.events)")
            return
        }
        #expect(!tool.isEmpty)
        #expect(result.text == "Before the tool. ")
        #expect(!result.text.contains("AFTER"))
        #expect(result.finished == nil)
        let run = try #require(harness.recordedPIDs("run").first)
        while ProcessTree.isRunning(run) && ContinuousClock.now - failedAt < .seconds(2) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!ProcessTree.isRunning(run), "the CLI was still running 2 s after the tripwire")
        #expect(await harness.waitForNoLeftovers(.seconds(2)).isEmpty)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: harness.temporary.path))?.isEmpty == true)
    }

    /// An init line that does not prove tools are off ends the run before any text is forwarded.
    @Test(arguments: toolsOnCases)
    func toolsNotOffEndTheRunBeforeAnyDelta(_ testCase: Case) async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        let adapter = try #require(allAdapters.first { $0.spec.name == testCase.cli })
        let provider = try harness.provider(adapter, ["FAKE_MODE": testCase.mode, "FAKE_VARIANT": testCase.variant ?? ""])
        let result = await collect(provider.stream(markedRequest()))
        guard case .toolUseBlocked? = result.error else {
            Issue.record("expected .toolUseBlocked, got \(String(describing: result.error)) after \(result.events)")
            return
        }
        #expect(result.deltas.isEmpty)
        #expect(await harness.waitForNoLeftovers(.seconds(2)).isEmpty)
    }

    // MARK: The rules, line by line

    @Test func claudeRules() {
        func trips(_ lines: [String]) -> Bool {
            if case .toolUseBlocked? = CLIStreamParsingTests.feed(ClaudeStreamParser(), lines).thrown { return true }
            return false
        }
        #expect(trips(AppendixD.claudeToolsOnBash))
        #expect(trips(AppendixD.claudeToolsOnMissing))
        #expect(trips([#"{"type":"system","subtype":"init","tools":[]}"#]))                                     // no MCP list
        #expect(trips([#"{"type":"system","subtype":"init","tools":[],"mcp_servers":[{"name":"x","status":"connected"}]}"#]))
        #expect(trips([AppendixD.claudeOK[2]]))                                                                 // text before init
        #expect(trips([AppendixD.claudeInit, AppendixD.claudeToolBlockStart]))
        #expect(trips([AppendixD.claudeInit, AppendixD.claudeToolAssistant]))
        for type in ["server_tool_use", "mcp_tool_use", "web_search_tool_result", "some_future_block"] {
            #expect(trips([AppendixD.claudeInit, #"{"type":"assistant","message":{"content":[{"type":"\#(type)","name":"x"}]}}"#]), "\(type)")
            #expect(trips([AppendixD.claudeInit, #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"\#(type)"}}}"#]), "\(type)")
        }
        #expect(trips([AppendixD.claudeInit, #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{"}}}"#]))
        #expect(trips([AppendixD.claudeInit, #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_1"}]}}"#]))
        #expect(trips([AppendixD.claudeInit, #"{"type":"stream_event","event":{"type":"message_start"},"parent_tool_use_id":"tu_9"}"#]))
        #expect(trips([#"{"type":"result","subtype":"success","is_error":false,"result":"text"}"#]))           // success with no init
        // Thinking is not a tool.
        #expect(!trips([AppendixD.claudeInit, #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"thinking"}}}"#,
                        #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"…"},{"type":"redacted_thinking"},{"type":"text","text":"x"}]}}"#]))
    }

    @Test func codexRules() {
        func trips(_ line: String) -> Bool {
            if case .toolUseBlocked? = CLIStreamParsingTests.feed(CodexStreamParser(), [line]).thrown { return true }
            return false
        }
        for line in [AppendixD.codexCommand, AppendixD.codexFileChange, AppendixD.codexMCP, AppendixD.codexUnknown,
                     #"{"type":"item.updated","item":{"id":"i","type":"web_search"}}"#,
                     #"{"type":"item.completed","item":{"id":"i","type":"collab_tool_call"}}"#,
                     #"{"type":"item.started","item":{"id":"i"}}"#] {
            #expect(trips(line), "\(line)")
        }
        for line in [AppendixD.codexTodo, AppendixD.codexErrorItem, AppendixD.codexOK[2], AppendixD.codexOK[3]] {
            #expect(!trips(line), "\(line)")
        }
    }

    @Test func antigravityRules() {
        func trips(_ lines: [String]) -> Bool {
            if case .toolUseBlocked? = CLIStreamParsingTests.feed(AntigravityStreamParser(), lines).thrown { return true }
            return false
        }
        #expect(trips(AppendixD.agyToolsOnAlways))
        #expect(trips(AppendixD.agyToolsOnMissing))
        #expect(trips([AppendixD.agyInit, AppendixD.agyToolStep]))
        #expect(trips([AppendixD.agyInit, #"{"event":"step_update","step_update":{"step_type":"agent_response","tool_name":"x"}}"#]))
        #expect(trips([AppendixD.agyInit, #"{"event":"step_update","step_update":{"step_type":"planner","tool_info":{}}}"#]))
        #expect(trips([AppendixD.agyInit, #"{"event":"step_update","step_update":{"step_type":"x","subagent_info":{}}}"#]))
        #expect(trips([AppendixD.agyOK[2]]))                                                                    // text before init
        #expect(!trips([#"{"event":"init","init":{"permission_mode":"strict"}}"#, AppendixD.agyOK[2]]))
    }

    @Test func grokRules() throws {
        func ready() throws -> GrokACPClient {
            var client = GrokACPClient(workingDirectory: "/w", prompt: "p")
            _ = client.start()
            for line in AppendixD.grokAgentLines[0...2] { _ = try client.receive(line) }
            return client
        }
        var client = try ready()
        let tool = try client.receive(AppendixD.grokToolCall)
        #expect(tool.tripwire == "Reading file")
        #expect(tool.outgoing.isEmpty)

        client = try ready()
        let permission = try client.receive(AppendixD.grokPermission)
        #expect(permission.tripwire == "a permission request (call_001)")
        // Answered "cancelled" before the process is killed.
        #expect(permission.outgoing.count == 1)
        let answer = try JSONSerialization.jsonObject(with: permission.outgoing[0]) as? NSDictionary
        let expected = try JSONSerialization.jsonObject(with: Data(AppendixD.grokPermissionAnswer.utf8)) as? NSDictionary
        #expect(answer == expected)

        for line in [#"{"jsonrpc":"2.0","id":"r1","method":"fs/read_text_file","params":{"path":"/etc/passwd"}}"#,
                     #"{"jsonrpc":"2.0","id":9,"method":"terminal/create","params":{}}"#,
                     #"{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"tool_call_update","toolCallId":"c"}}}"#,
                     #"{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"subagent_update"}}}"#] {
            client = try ready()
            #expect(try client.receive(line).tripwire != nil, "\(line)")
        }
        // Updates that are not tools pass.
        client = try ready()
        for kind in ["agent_thought_chunk", "plan", "usage_update", "available_commands_update", "current_mode_update",
                     "session_info_update", "some_future_update"] {
            let line = #"{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"\#(kind)"}}}"#
            #expect(try client.receive(line).tripwire == nil, "\(kind)")
        }
    }
}
