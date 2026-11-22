import Foundation
import RefereeCore

/// Claude Code through `claude -p` (plan.md section 5.6.4). Policy note: section 5.6.5; this file and its line in
/// `CLIProviderFactory` are all there is to remove.
struct ClaudeCodeAdapter: CLIAdapter {
    static let id: ProviderID = "claude-cli"
    static let promptArgument = "The complete task is in the piped input. Follow it exactly."
    static let systemPromptFile = "system.txt"
    /// stdin is capped at 10 MB by Claude Code [D]; 9,000,000 leaves room.
    static let maxPromptBytes = 9_000_000
    /// Set by the delivery experiment of section 5.6.6: variant C1 (the PDF as a document block on stdin) passed on
    /// 2026-11-22 with Claude Code 2.1.330 (docs/contract-notes/wp5-cliproviders.md).
    static let delivery: CLIPDFDelivery = .documentBlock

    var pdfDelivery: CLIPDFDelivery { Self.delivery }

    var descriptor: ProviderDescriptor {
        ProviderDescriptor(id: Self.id, displayName: "Claude Code (subscription)", vendor: "Anthropic", authMode: .subscriptionCLI,
                           isLocal: false, destination: "claude", supportsNativePDF: Self.delivery != .none,
                           pdfDeliveryNote: Self.delivery == .readTool ? "read from a private temporary copy by Claude Code's own Read tool" : nil,
                           streaming: .token, maxPromptBytes: Self.maxPromptBytes,
                           retentionNote: "Runs through your Claude Code login with its tools switched off; no session transcript is saved.",
                           isExperimental: false)
    }

    let spec = CLISpec(
        name: "claude",
        candidates: ["~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                     "~/.vscode/extensions/anthropic.claude-code-*/resources/native-binary/claude",
                     "~/.vscode-insiders/extensions/anthropic.claude-code-*/resources/native-binary/claude",
                     "~/.cursor/extensions/anthropic.claude-code-*/resources/native-binary/claude"],
        versionArguments: ["--version"], helpArguments: [["--help"]], environmentOverride: "REFEREE_CLI_PATH_CLAUDE")
    let installHint = "curl -fsSL https://claude.ai/install.sh | bash"
    let protectedFlags = ["--safe-mode", "--tools", "--disallowedTools", "--strict-mcp-config", "--disable-slash-commands",
                          "--no-session-persistence", "--permission-prompts"]
    let timeouts = CLITimeouts(firstOutput: .seconds(300), idle: .seconds(300))
    let extraEnvironment: [String: String] = [:]
    /// A login made with `claude setup-token` lives in this variable; it reaches `claude` and no other CLI (Gate 1).
    let passedThroughNames = ["CLAUDE_CODE_OAUTH_TOKEN"]

    func argumentTable(workspace: URL, model: String?, delivery: CLIPDFDelivery) -> CLIArgumentTable {
        var leading: [CLIArgument] = delivery == .documentBlock ? [.plain("-p")] : [.plain("-p", Self.promptArgument)]
        leading += [
            .protected("--safe-mode"), .protected("--tools", ""), .protected("--disallowedTools", "mcp__*"),
            .protected("--strict-mcp-config"), .protected("--disable-slash-commands"),
            .protected("--no-session-persistence"), .protected("--permission-prompts", "none"),
            .plain("--system-prompt-file", workspace.appendingPathComponent(Self.systemPromptFile).path),
            .plain("--output-format", "stream-json"), .plain("--verbose"), .plain("--include-partial-messages"),
        ]
        if delivery == .documentBlock { leading.append(.plain("--input-format", "stream-json")) }
        return CLIArgumentTable(leading: leading, model: model.map { ["--model", $0] } ?? [])
    }

    func prepareInput(_ prompt: CLIPrompt, workspace: CLIWorkspace, delivery: CLIPDFDelivery) throws -> CLIRunInput {
        try workspace.write(Data(prompt.system.utf8), named: Self.systemPromptFile)
        let stdin: Data
        switch delivery {
        case .documentBlock:
            guard let pdf = prompt.pdf else { throw LLMError.invalidRequest("no pdf document in the request") }
            let encodedSize = (pdf.count + 2) / 3 * 4
            guard encodedSize + prompt.user.utf8.count + 1_024 <= Self.maxPromptBytes else {
                throw LLMError.contextTooLong("the pdf file is too large for Claude Code's input (at most about "
                                              + "\(Self.maxPromptBytes * 3 / 4 / 1_000_000) MB)")
            }
            let line: [String: Any] = ["type": "user", "message": ["role": "user", "content": [
                ["type": "document", "source": ["type": "base64", "media_type": "application/pdf", "data": pdf.base64EncodedString()]],
                ["type": "text", "text": prompt.user],
            ]]]
            stdin = JSONLine.encode(line)
        case .none:
            stdin = Data(prompt.user.utf8)
        case .readTool, .pageImages:
            throw LLMError.invalidRequest("Claude Code does not take a pdf document this way")
        }
        return CLIRunInput(input: .data(stdin), payloadBytes: stdin.count)
    }

    func makeSession(workspace: URL, delivery: CLIPDFDelivery, input: CLIRunInput) -> CLISession {
        .lines(ClaudeStreamParser())
    }

    func signInStatus(_ binary: ResolvedBinary, host: CLIHost) async -> ProviderAvailability {
        Self.signInStatus(await host.command(binary, ["auth", "status"], extraEnvironment: extraEnvironment, passThrough: passedThroughNames),
                          version: binary.version)
    }

    /// `claude auth status` prints JSON and exits 0 when logged in, 1 when not [D]. Only `loggedIn` and `authMethod` are
    /// read; the account fields next to them are ignored.
    static func signInStatus(_ result: Result<CommandResult, LLMError>, version: String) -> ProviderAvailability {
        let unreadable = ProviderAvailability.needsSetup(reason: "Could not read Claude Code's sign-in status",
                                                         hint: "Run `claude auth status` in Terminal")
        guard case .success(let output) = result, let status = parseAuthStatus(output.stdout) else { return unreadable }
        guard status.loggedIn else {
            return .needsSetup(reason: "Claude Code is not signed in", hint: "Run `claude` in Terminal and use /login")
        }
        guard status.authMethod == "claude.ai" || status.authMethod == "oauth_token" else {
            return .needsSetup(reason: "Claude Code is signed in with an API key, not a subscription", hint: "Run `claude` and use /login")
        }
        return .ready(detail: "Logged in · claude \(version)")
    }

    static func parseAuthStatus(_ stdout: String) -> (loggedIn: Bool, authMethod: String)? {
        guard let start = stdout.firstIndex(of: "{"), let end = stdout.lastIndex(of: "}"), start < end,
              let object = JSONLine.object(String(stdout[start...end]).replacingOccurrences(of: "\n", with: " ")),
              let loggedIn = JSONLine.bool(object["loggedIn"]) else { return nil }
        return (loggedIn, object["authMethod"] as? String ?? "")
    }

    func listModels(host: CLIHost, binary: @Sendable () async -> Result<ResolvedBinary, LLMError>) async throws -> [ModelInfo] {
        // Claude Code has no command that lists models: the documented aliases (section 5.2).
        [("default", "Default"), ("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku"), ("fable", "Fable")]
            .map { ModelInfo(id: $0.0, displayName: $0.1, contextWindow: nil) }
    }
}

/// Claude Code's `--output-format stream-json` (Appendix D.5) and its tripwire.
struct ClaudeStreamParser: CLIStreamParser {
    let cliName = "Claude Code"
    private static let allowedBlocks: Set<String> = ["text", "thinking", "redacted_thinking"]

    private(set) var sawInit = false
    private(set) var outcome: CLIOutcome?
    private var sawText = false
    private var stopReason: StopReason?

    mutating func consume(_ line: String) throws -> [LLMEvent] {
        guard let object = JSONLine.object(line) else { return [] }
        if let parent = object["parent_tool_use_id"], !(parent is NSNull) {
            throw tripwire("output of a sub-agent or tool (\(String(describing: parent)))")
        }
        switch object["type"] as? String {
        case "system":
            switch object["subtype"] as? String {
            case "init":
                try checkInit(object)
                sawInit = true
                return []
            case "api_retry":
                let attempt = JSONLine.int(object["attempt"]).map(String.init) ?? "?"
                return [.status("retrying (attempt \(attempt))")]
            default:
                return []
            }
        case "stream_event":
            guard sawInit else { throw tripwire("Claude Code wrote output before its tool list") }
            return try streamEvent(object["event"] as? [String: Any])
        case "assistant":
            guard sawInit else { throw tripwire("Claude Code wrote output before its tool list") }
            try checkBlocks((object["message"] as? [String: Any])?["content"])
            if let reason = (object["message"] as? [String: Any])?["stop_reason"] as? String { stopReason = Self.stopReason(reason) }
            return []
        case "user":
            // In this stream a user line carries tool results; with no tools there is none.
            if let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]],
               content.contains(where: { ($0["type"] as? String) == "tool_result" }) {
                throw tripwire("a tool result")
            }
            return []
        case "result":
            return try result(object)
        default:
            return []
        }
    }

    /// The first `system`/`init` line must list no tools and no MCP servers; a missing list counts as a failure.
    private func checkInit(_ object: [String: Any]) throws {
        guard let tools = object["tools"] as? [Any] else { throw tripwire("Claude Code's init line has no tool list") }
        guard let servers = object["mcp_servers"] as? [Any] else { throw tripwire("Claude Code's init line has no MCP server list") }
        if !tools.isEmpty {
            throw tripwire("tools offered: " + tools.map { ($0 as? String) ?? String(describing: $0) }.joined(separator: ", "))
        }
        if !servers.isEmpty {
            let names = servers.map { (($0 as? [String: Any])?["name"] as? String) ?? String(describing: $0) }
            throw tripwire("MCP servers: " + names.joined(separator: ", "))
        }
    }

    private mutating func streamEvent(_ event: [String: Any]?) throws -> [LLMEvent] {
        guard let event else { return [] }
        switch event["type"] as? String {
        case "content_block_start":
            let block = event["content_block"] as? [String: Any]
            let type = block?["type"] as? String ?? "unknown"
            guard Self.allowedBlocks.contains(type) else { throw tripwire((block?["name"] as? String) ?? type) }
            return []
        case "content_block_delta":
            let delta = event["delta"] as? [String: Any]
            switch delta?["type"] as? String {
            case "text_delta":
                guard let text = delta?["text"] as? String, !text.isEmpty else { return [] }
                sawText = true
                return [.textDelta(text)]
            case "input_json_delta":
                throw tripwire("tool input")
            default:
                return []
            }
        case "message_delta":
            if let reason = (event["delta"] as? [String: Any])?["stop_reason"] as? String { stopReason = Self.stopReason(reason) }
            return []
        default:
            return []
        }
    }

    private func checkBlocks(_ content: Any?) throws {
        guard let blocks = content as? [[String: Any]] else { return }
        for block in blocks {
            let type = block["type"] as? String ?? "unknown"
            if !Self.allowedBlocks.contains(type) { throw tripwire((block["name"] as? String) ?? type) }
        }
    }

    private mutating func result(_ object: [String: Any]) throws -> [LLMEvent] {
        let isError = JSONLine.bool(object["is_error"]) ?? ((object["subtype"] as? String) != "success")
        if isError {
            var message = object["result"] as? String ?? ""
            if message.isEmpty, let errors = object["errors"] as? [Any] {
                message = errors.map { ($0 as? String) ?? String(describing: $0) }.joined(separator: "; ")
            }
            if message.isEmpty { message = "Claude Code reported an error (\(object["subtype"] as? String ?? "unknown"))" }
            outcome = .failure(Self.classify(message, status: JSONLine.int(object["api_error_status"])))
            return []
        }
        guard sawInit else { throw tripwire("Claude Code finished without reporting its tool list") }
        if let reason = object["stop_reason"] as? String { stopReason = Self.stopReason(reason) }
        var events: [LLMEvent] = []
        if !sawText, let text = object["result"] as? String, !text.isEmpty { events.append(.textDelta(text)) }
        outcome = .success(stopReason ?? .endOfTurn, Self.usage(object["usage"] as? [String: Any]))
        return events
    }

    static func classify(_ message: String, status: Int?) -> LLMError {
        let authMarkers = ["Not logged in", "Failed to authenticate", "Login expired", "/login"]
        if authMarkers.contains(where: { message.contains($0) }) || status == 401 { return .auth(message) }
        let lower = message.lowercased()
        if lower.contains("hit your") && lower.contains("limit") { return .quotaExhausted(message) }
        switch status {
        case 429: return .rateLimited(retryAfter: nil, message: message)
        case 529: return .overloaded(retryAfter: nil)
        default: return .server(status: status ?? 500, message: message)
        }
    }

    func classifyStderr(_ stderr: String) -> LLMError? {
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return nil }
        switch Self.classify(message, status: nil) {
        case .auth(let m): return .auth(m)
        case .quotaExhausted(let m): return .quotaExhausted(m)
        default: return nil
        }
    }

    static func stopReason(_ value: String) -> StopReason {
        switch value {
        case "max_tokens": return .maxTokens
        case "refusal": return .refusal
        case "end_turn", "stop_sequence": return .endOfTurn
        default: return .other
        }
    }

    /// Input tokens include those read from or written to the prompt cache.
    static func usage(_ object: [String: Any]?) -> Usage? {
        guard let object else { return nil }
        let parts = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].compactMap { JSONLine.int(object[$0]) }
        return Usage(inputTokens: parts.isEmpty ? nil : parts.reduce(0, +), outputTokens: JSONLine.int(object["output_tokens"]))
    }
}
