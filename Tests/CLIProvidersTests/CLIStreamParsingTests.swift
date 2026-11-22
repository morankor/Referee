import Foundation
import Testing
@testable import CLIProviders
import RefereeCore

/// Acceptance row "stream parsing": the Appendix D lines give the expected deltas and `.finished`; Codex's cumulative
/// text gives only the new suffix; the Grok ACP exchange of D.8 gives the expected deltas, stop reason and a delete
/// request. Plus the failure lines of D.5–D.7 and garbage. No process is started here.
@Suite struct CLIStreamParsingTests {
    /// Feeds lines to a parser; returns the events, the error a line threw, and the outcome.
    static func feed<P: CLIStreamParser>(_ parser: P, _ lines: [String]) -> (events: [LLMEvent], thrown: LLMError?, parser: P) {
        var parser = parser
        var events: [LLMEvent] = []
        for line in lines {
            do { events += try parser.consume(line) } catch {
                return (events, error as? LLMError, parser)
            }
        }
        return (events, nil, parser)
    }

    static func deltas(_ events: [LLMEvent]) -> [String] {
        events.compactMap { if case .textDelta(let text) = $0 { return text } else { return nil } }
    }

    // MARK: Claude Code (D.5)

    @Test func claudeDocumentedStream() {
        let (events, thrown, parser) = Self.feed(ClaudeStreamParser(), AppendixD.claudeOK)
        #expect(thrown == nil)
        #expect(Self.deltas(events) == ["Hello", " world"])
        #expect(parser.outcome == .success(.endOfTurn, Usage(inputTokens: 40, outputTokens: 2)))
        #expect(parser.finalResult(exitCode: 0, stderrTail: "") == .success(.endOfTurn, Usage(inputTokens: 40, outputTokens: 2)))
    }

    @Test func claudeRetryNoticeIsAStatus() {
        let (events, thrown, _) = Self.feed(ClaudeStreamParser(), [AppendixD.claudeInit, AppendixD.claudeRetry])
        #expect(thrown == nil)
        #expect(events == [.status("retrying (attempt 1)")])
    }

    @Test func claudeResultTextIsTheAnswerWhenNoDeltaCame() {
        // Older versions without partial messages: only the assistant line and the result.
        let lines = [AppendixD.claudeOK[0], AppendixD.claudeOK[4], AppendixD.claudeOK[5]]
        let (events, thrown, parser) = Self.feed(ClaudeStreamParser(), lines)
        #expect(thrown == nil)
        #expect(Self.deltas(events) == ["Hello world"])
        #expect(parser.outcome == .success(.endOfTurn, Usage(inputTokens: 40, outputTokens: 2)))
    }

    @Test func claudeCacheTokensCountAsInput() {
        let result = #"{"type":"result","subtype":"success","is_error":false,"result":"x","usage":{"input_tokens":3,"cache_creation_input_tokens":100,"cache_read_input_tokens":2000,"output_tokens":5},"stop_reason":"max_tokens"}"#
        let (_, _, parser) = Self.feed(ClaudeStreamParser(), [AppendixD.claudeInit, result])
        #expect(parser.outcome == .success(.maxTokens, Usage(inputTokens: 2_103, outputTokens: 5)))
    }

    @Test func claudeFailureResults() {
        func outcome(_ lines: [String]) -> CLIOutcome? { Self.feed(ClaudeStreamParser(), lines).parser.outcome }
        #expect(outcome(AppendixD.claudeAuth) == .failure(.auth("Not logged in · Please run /login")))
        #expect(outcome(AppendixD.claudeExpired) == .failure(.auth("Failed to authenticate: OAuth session expired and could not be refreshed")))
        #expect(outcome(AppendixD.claudeQuota) == .failure(.quotaExhausted("You've hit your session limit · resets 3:45pm")))
        #expect(outcome(AppendixD.claudeDuringExecution) == .failure(.server(status: 500, message: "something broke")))
        let overloaded = #"{"type":"result","subtype":"success","is_error":true,"result":"API Error","api_error_status":529}"#
        #expect(outcome([AppendixD.claudeInit, overloaded]) == .failure(.overloaded(retryAfter: nil)))
        let limited = #"{"type":"result","subtype":"success","is_error":true,"result":"API Error","api_error_status":429}"#
        #expect(outcome([AppendixD.claudeInit, limited]) == .failure(.rateLimited(retryAfter: nil, message: "API Error")))
    }

    @Test func claudeExitWithoutResult() {
        let parser = Self.feed(ClaudeStreamParser(), [AppendixD.claudeInit]).parser
        #expect(parser.finalResult(exitCode: 0, stderrTail: "") == .failure(.malformedResponse("Claude Code ended without reporting a result")))
        #expect(parser.finalResult(exitCode: 2, stderrTail: "boom") == .failure(.cliExited(code: 2, stderrTail: "boom")))
        #expect(parser.finalResult(exitCode: 1, stderrTail: "Not logged in · Please run /login") == .failure(.auth("Not logged in · Please run /login")))
    }

    // MARK: Codex (D.6)

    @Test func codexDocumentedStream() {
        let (events, thrown, parser) = Self.feed(CodexStreamParser(), AppendixD.codexOK)
        #expect(thrown == nil)
        #expect(Self.deltas(events) == ["Hello", " world"])
        #expect(parser.outcome == .success(.endOfTurn, Usage(inputTokens: 24_763, outputTokens: 122)))
    }

    @Test func codexCumulativeTextGivesOnlyTheNewSuffix() {
        func update(_ text: String, _ type: String = "item.updated", id: String = "m1") -> String {
            #"{"type":"\#(type)","item":{"id":"\#(id)","type":"agent_message","text":"\#(text)"}}"#
        }
        let lines = [update(""), update("Hel"), update("Hello"), update("Hello"), update("Hello wor"), update("Hello world", "item.completed")]
        let (events, thrown, _) = Self.feed(CodexStreamParser(), lines)
        #expect(thrown == nil)
        #expect(Self.deltas(events) == ["Hel", "lo", " wor", "ld"])
        // Text that does not extend what was emitted comes whole, on a new line; a second message starts a new line.
        let (rewritten, _, _) = Self.feed(CodexStreamParser(), [update("Hello"), update("Goodbye"), update("Second", id: "m2")])
        #expect(Self.deltas(rewritten) == ["Hello", "\nGoodbye", "\nSecond"])
    }

    @Test func codexItemsThatAreNotToolsPass() {
        let lines = AppendixD.codexStart + [AppendixD.codexTodo, AppendixD.codexErrorItem, AppendixD.codexOK[2]]
        #expect(Self.feed(CodexStreamParser(), lines).thrown == nil)
    }

    @Test func codexFailures() {
        func outcome(_ lines: [String]) -> CLIOutcome? { Self.feed(CodexStreamParser(), lines).parser.outcome }
        #expect(outcome(AppendixD.codexAuth) == .failure(.auth("unexpected status 401 Unauthorized: please log in again")))
        #expect(outcome(AppendixD.codexQuota) == .failure(.quotaExhausted("You've hit your usage limit. Try again later.")))
        #expect(outcome(AppendixD.codexStart + [#"{"type":"turn.failed","error":{"message":"429 rate limit reached"}}"#])
                == .failure(.rateLimited(retryAfter: nil, message: "429 rate limit reached")))
        #expect(outcome(AppendixD.codexStart + [#"{"type":"turn.failed","error":{"message":"stream disconnected"}}"#])
                == .failure(.server(status: 500, message: "stream disconnected")))
        // An `error` event decides the run only if no turn completes.
        let reconnect = #"{"type":"error","message":"Reconnecting... 1/5"}"#
        let recovered = Self.feed(CodexStreamParser(), AppendixD.codexStart + [reconnect] + AppendixD.codexOK.suffix(3)).parser
        #expect(recovered.finalResult(exitCode: 0, stderrTail: "") == .success(.endOfTurn, Usage(inputTokens: 24_763, outputTokens: 122)))
        let failed = Self.feed(CodexStreamParser(), AppendixD.codexStart + [#"{"type":"error","message":"Unauthorized"}"#]).parser
        #expect(failed.finalResult(exitCode: 1, stderrTail: "") == .failure(.auth("Unauthorized")))
    }

    // MARK: Antigravity (D.7)

    @Test func antigravityDocumentedStream() {
        let (events, thrown, parser) = Self.feed(AntigravityStreamParser(), AppendixD.agyOK)
        #expect(thrown == nil)
        #expect(Self.deltas(events) == ["apple", "\n"])
        #expect(parser.outcome == .success(.endOfTurn, Usage(inputTokens: 30_384, outputTokens: 4)))
    }

    @Test func antigravityFailures() {
        func outcome(_ lines: [String]) -> CLIOutcome? { Self.feed(AntigravityStreamParser(), lines).parser.outcome }
        #expect(outcome(AppendixD.agyAuth) == .failure(.auth("authentication required: sign in to Antigravity first")))
        #expect(outcome(AppendixD.agyQuota) == .failure(.quotaExhausted("quota exceeded for this account")))
        guard case .failure(.modelNotFound(let message))? = outcome(AppendixD.agyModelNotFound) else {
            Issue.record("the unknown-model result is not .modelNotFound")
            return
        }
        #expect(message.contains("not recognized as a known model"))
    }

    // MARK: Grok Build (D.8)

    /// Feeds the agent's lines of D.8 to the client and compares what it writes with D.8's client lines.
    @Test func grokDocumentedExchange() throws {
        var client = GrokACPClient(workingDirectory: "/tmp/referee-cli-x", prompt: "the prompt")
        var written = client.start()
        var events: [LLMEvent] = []
        for (index, line) in AppendixD.grokAgentLines.enumerated() {
            if index == 7 {
                // The answer to the prompt is in; the provider calls this after 500 ms without a line.
                #expect(client.phase == .draining)
                let quiet = client.quietPeriodElapsed()
                written += quiet.outgoing
                #expect(client.phase == .deleting)
            }
            let step = try client.receive(line)
            #expect(step.tripwire == nil)
            written += step.outgoing
            events += step.events
        }
        #expect(Self.deltas(events) == ["Hello", " world"])
        #expect(client.stopReason == .endOfTurn)
        #expect(client.phase == .done)
        #expect(client.sessionDeleted)

        let expected = AppendixD.grokClientLines.map {
            $0.replacingOccurrences(of: "<workdir>", with: "/tmp/referee-cli-x").replacingOccurrences(of: "<prompt>", with: "the prompt")
        }
        #expect(written.count == expected.count)
        for (data, line) in zip(written, expected) {
            #expect(data.last == 0x0A)
            #expect(try Self.json(data) == Self.json(Data(line.utf8)), "client line differs from Appendix D.8: \(line)")
        }
    }

    @Test func grokWithoutSessionDeleteCapabilityAsksForTheCommand() throws {
        var client = GrokACPClient(workingDirectory: "/w", prompt: "p")
        _ = client.start()
        let initialize = AppendixD.grokInitializeResult.replacingOccurrences(of: #"{"sessionCapabilities":{"delete":{}}}"#, with: "{}")
        for line in [initialize] + AppendixD.grokAgentLines[1...6] { _ = try client.receive(line) }
        #expect(client.quietPeriodElapsed().outgoing.isEmpty)
        #expect(client.phase == .done)
        #expect(!client.sessionDeleted)
        #expect(client.sessionID == "sess_1")
    }

    @Test func grokAuthAndErrors() throws {
        var client = GrokACPClient(workingDirectory: "/w", prompt: "p")
        _ = client.start()
        let noCachedToken = #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{},"authMethods":[{"id":"xai.api_key","name":"API key"}]}}"#
        #expect(throws: LLMError.auth(GrokACPClient.authHint)) { try client.receive(noCachedToken) }

        var second = GrokACPClient(workingDirectory: "/w", prompt: "p")
        _ = second.start()
        _ = try second.receive(AppendixD.grokInitializeResult)
        #expect(throws: LLMError.auth(GrokACPClient.authHint)) {
            try second.receive(#"{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"no cached token"}}"#)
        }

        var third = GrokACPClient(workingDirectory: "/w", prompt: "p")
        _ = third.start()
        for line in AppendixD.grokAgentLines[0...2] { _ = try third.receive(line) }
        #expect(throws: LLMError.server(status: 500, message: "internal")) {
            try third.receive(#"{"jsonrpc":"2.0","id":4,"error":{"code":-32603,"message":"internal"}}"#)
        }
    }

    @Test func grokStopReasons() {
        #expect(GrokACPClient.stopReason("end_turn") == .endOfTurn)
        #expect(GrokACPClient.stopReason("max_tokens") == .maxTokens)
        #expect(GrokACPClient.stopReason("refusal") == .refusal)
        #expect(GrokACPClient.stopReason("max_turn_requests") == .other)
        #expect(GrokACPClient.stopReason("cancelled") == .other)
    }

    // MARK: Garbage

    @Test func garbageNeverCrashesAParser() throws {
        var generator = SystemRandomNumberGenerator()
        var lines = String(decoding: AppendixD.garbage, as: UTF8.self).split(separator: "\n").map(String.init)
        for _ in 0..<200 {
            let bytes = (0..<Int.random(in: 0...200, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) }
            lines.append(String(decoding: bytes, as: UTF8.self))
        }
        lines += ["{}", "[]", "null", #"{"type":42}"#, #"{"event":[]}"#, #"{"type":"result"}"#, #"{"event":"result"}"#]
        let claude = Self.feed(ClaudeStreamParser(), lines)
        #expect(claude.events.isEmpty && claude.thrown == nil)
        let codex = Self.feed(CodexStreamParser(), lines)
        #expect(codex.events.isEmpty && codex.thrown == nil)
        let agy = Self.feed(AntigravityStreamParser(), lines)
        #expect(agy.events.isEmpty && agy.thrown == nil)
        var client = GrokACPClient(workingDirectory: "/w", prompt: "p")
        _ = client.start()
        for line in lines {
            let step = try client.receive(line)
            #expect(step.events.isEmpty && step.tripwire == nil)
        }
        // Fail-closed: an item without a type is not let through.
        #expect(Self.feed(CodexStreamParser(), [#"{"type":"item.completed"}"#]).thrown == .toolUseBlocked("an item of no stated type"))
    }

    static func json(_ data: Data) throws -> NSDictionary {
        try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }
}
