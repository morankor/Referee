import Foundation
import RefereeCore

/// Grok Build through `grok agent stdio`, the Agent Client Protocol (plan.md section 5.6.4). Experimental: written from
/// documentation; the binary was not installed when this was written (see docs/contract-notes/wp5-cliproviders.md).
struct GrokBuildAdapter: CLIAdapter {
    static let id: ProviderID = "grok-cli"
    static let maxPromptBytes = 4_000_000

    let pdfDelivery: CLIPDFDelivery = .none

    var descriptor: ProviderDescriptor {
        ProviderDescriptor(id: Self.id, displayName: "Grok Build", vendor: "xAI", authMode: .subscriptionCLI, isLocal: false,
                           destination: "grok", supportsNativePDF: false, streaming: .token, maxPromptBytes: Self.maxPromptBytes,
                           retentionNote: "Runs through your xAI account with tools denied. The CLI saves each conversation in ~/.grok and may sync "
                               + "it to your account; Referee deletes the local copy after each run.",
                           isExperimental: true)
    }

    let spec = CLISpec(name: "grok", candidates: ["~/.local/bin/grok", "~/.grok/bin/grok", "/opt/homebrew/bin/grok", "/usr/local/bin/grok"],
                       versionArguments: ["--version"], helpArguments: [["--help"], ["agent", "stdio", "--help"]],
                       environmentOverride: "REFEREE_CLI_PATH_GROK")
    let installHint = "npm install -g @xai-official/grok"
    let protectedFlags = ["--sandbox", "--permission-mode", "--disallowed-tools", "--disable-web-search", "--no-subagents", "--no-memory", "--no-plan"]
    let timeouts = CLITimeouts(firstOutput: .seconds(300), idle: .seconds(600))
    let extraEnvironment = ["GROK_SANDBOX": "strict"]

    func argumentTable(workspace: URL, model: String?, delivery: CLIPDFDelivery) -> CLIArgumentTable {
        CLIArgumentTable(leading: [
            .plain("--no-auto-update"), .protected("--sandbox", "strict"), .protected("--permission-mode", "dontAsk"),
            .protected("--disallowed-tools", "Bash,Edit,Read,Grep,WebFetch,WebSearch"), .protected("--disable-web-search"),
            .protected("--no-subagents"), .protected("--no-memory"), .protected("--no-plan"),
        ], model: model.map { ["-m", $0] } ?? [], trailing: [.protected("agent", "stdio")])
    }

    func prepareInput(_ prompt: CLIPrompt, workspace: CLIWorkspace, delivery: CLIPDFDelivery) throws -> CLIRunInput {
        guard delivery == .none else { throw LLMError.invalidRequest("Grok Build does not take a pdf document") }
        let text = CLIPrompt.inline(system: prompt.system, user: prompt.user)
        return CLIRunInput(input: .interactive, payloadBytes: text.utf8.count, interactivePrompt: text)
    }

    func makeSession(workspace: URL, delivery: CLIPDFDelivery, input: CLIRunInput) -> CLISession {
        .acp(GrokACPClient(workingDirectory: workspace.path, prompt: input.interactivePrompt ?? ""))
    }

    /// No documented status command.
    func signInStatus(_ binary: ResolvedBinary, host: CLIHost) async -> ProviderAvailability {
        .ready(detail: "installed; sign-in is checked on first use")
    }

    func listModels(host: CLIHost, binary: @Sendable () async -> Result<ResolvedBinary, LLMError>) async throws -> [ModelInfo] {
        let resolved = try await binary().get()
        switch await host.command(resolved, ["models"], extraEnvironment: extraEnvironment) {
        case .success(let output) where output.exitCode == 0:
            return Self.parseModels(output.stdout)
        case .success(let output):
            throw LLMError.cliExited(code: output.exitCode, stderrTail: String(output.stderr.suffix(4_096)))
        case .failure(let error):
            throw error
        }
    }

    /// `grok models`: the first whitespace-delimited token of each non-empty line [A]; a token ending in ":" is a heading.
    static func parseModels(_ text: String) -> [ModelInfo] {
        var seen: Set<String> = []
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let token = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init),
                  !token.hasSuffix(":"), !token.hasPrefix("#"), seen.insert(token).inserted else { return nil }
            return ModelInfo(id: token, displayName: token, contextWindow: nil)
        }
    }

    /// Deletes Grok Build's local copy of a conversation when the protocol could not (section 5.6.4).
    static func deleteSessionCommand(_ sessionID: String) -> [String] { ["sessions", "delete", sessionID] }
}

/// The client side of an ACP v1 session with `grok agent stdio` (Appendix D.8), with no I/O of its own: the provider
/// feeds it the agent's lines and writes what it returns.
///
/// Protocol rules (section 5.6.4): the client announces no capabilities and no MCP servers; every request from the agent
/// (permission, file, terminal) and every tool or sub-agent update trips the wire; a permission request is answered
/// "cancelled" first.
struct GrokACPClient: Sendable {
    enum Phase: Equatable, Sendable { case initializing, authenticating, creatingSession, prompting, draining, deleting, done }

    struct Step: Sendable {
        var events: [LLMEvent] = []
        var outgoing: [Data] = []
        /// When set, the provider writes `outgoing`, kills the process and throws `.toolUseBlocked` with this text.
        var tripwire: String?
    }

    static let authHint = "Run `grok login` in Terminal"

    let workingDirectory: String
    let prompt: String
    var clientVersion = GrokACPClient.appVersion

    private(set) var phase: Phase = .initializing
    private(set) var sessionID: String?
    private(set) var canDeleteSession = false
    private(set) var sessionDeleted = false
    private(set) var stopReason: StopReason?
    private var nextID = 1
    private var methodsByID: [Int: String] = [:]

    init(workingDirectory: String, prompt: String) {
        self.workingDirectory = workingDirectory
        self.prompt = prompt
    }

    static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.1.0"
    }

    mutating func start() -> [Data] {
        [request("initialize", ["protocolVersion": 1,
                                "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
                                "clientInfo": ["name": "referee", "version": clientVersion]])]
    }

    mutating func receive(_ line: String) throws -> Step {
        guard let message = JSONLine.object(line) else { return Step() }
        let id = message["id"].flatMap { $0 is NSNull ? nil : $0 }
        let method = message["method"] as? String
        if let id, let method {
            var step = Step()
            if method == "session/request_permission" {
                step.outgoing.append(Self.response(id: id, result: ["outcome": ["outcome": "cancelled"]]))
            }
            step.tripwire = Self.describeRequest(method, message["params"] as? [String: Any])
            return step
        }
        if let method {
            return method == "session/update" ? try update(message["params"] as? [String: Any]) : Step()
        }
        guard let number = JSONLine.int(id), let requestMethod = methodsByID.removeValue(forKey: number) else { return Step() }
        return try response(to: requestMethod, message)
    }

    /// Called when the answer to the prompt is in and no line came for the quiet period.
    mutating func quietPeriodElapsed() -> Step {
        guard phase == .draining else { return Step() }
        if canDeleteSession, let sessionID {
            phase = .deleting
            return Step(outgoing: [request("session/delete", ["sessionId": sessionID])])
        }
        phase = .done
        return Step()
    }

    /// The agent did not answer `session/delete` in time.
    mutating func giveUpDeleting() {
        if phase == .deleting { phase = .done }
    }

    // MARK: - Private

    private mutating func update(_ params: [String: Any]?) throws -> Step {
        let update = params?["update"] as? [String: Any]
        let kind = update?["sessionUpdate"] as? String
        switch kind {
        case "tool_call", "tool_call_update":
            let name = (update?["title"] as? String) ?? (update?["kind"] as? String) ?? (update?["toolCallId"] as? String) ?? "a tool call"
            return Step(tripwire: name)
        case "subagent_update":
            return Step(tripwire: "a sub-agent")
        case "agent_message_chunk":
            guard phase == .prompting || phase == .draining,
                  let content = update?["content"] as? [String: Any], (content["type"] as? String) == "text",
                  let text = content["text"] as? String, !text.isEmpty else { return Step() }
            return Step(events: [.textDelta(text)])
        default:
            // agent_thought_chunk, plan, usage_update, available_commands_update, current_mode_update,
            // session_info_update and kinds not known yet are ignored.
            return Step()
        }
    }

    private mutating func response(to method: String, _ message: [String: Any]) throws -> Step {
        let error = message["error"] as? [String: Any]
        let result = message["result"] as? [String: Any]
        switch method {
        case "initialize":
            if let error { throw Self.classify(error) }
            if let version = JSONLine.int(result?["protocolVersion"]), version != 1 {
                throw LLMError.malformedResponse("Grok Build answered with Agent Client Protocol version \(version); Referee speaks version 1")
            }
            let methods = (result?["authMethods"] as? [[String: Any]]) ?? []
            guard methods.contains(where: { ($0["id"] as? String) == "cached_token" }) else { throw LLMError.auth(Self.authHint) }
            let capabilities = (result?["agentCapabilities"] as? [String: Any])?["sessionCapabilities"] as? [String: Any]
            canDeleteSession = capabilities?["delete"] != nil && !(capabilities?["delete"] is NSNull)
            phase = .authenticating
            return Step(outgoing: [request("authenticate", ["methodId": "cached_token", "_meta": ["headless": true]])])
        case "authenticate":
            if error != nil { throw LLMError.auth(Self.authHint) }
            phase = .creatingSession
            return Step(outgoing: [request("session/new", ["cwd": workingDirectory, "mcpServers": [Any]()])])
        case "session/new":
            if let error { throw Self.classify(error) }
            guard let id = result?["sessionId"] as? String, !id.isEmpty else {
                throw LLMError.malformedResponse("Grok Build did not return a session id")
            }
            sessionID = id
            phase = .prompting
            return Step(outgoing: [request("session/prompt", ["sessionId": id, "prompt": [["type": "text", "text": prompt]]])])
        case "session/prompt":
            if let error { throw Self.classify(error) }
            stopReason = Self.stopReason(result?["stopReason"] as? String)
            phase = .draining
            return Step()
        case "session/delete":
            sessionDeleted = error == nil
            phase = .done
            return Step()
        default:
            return Step()
        }
    }

    private mutating func request(_ method: String, _ params: [String: Any]) -> Data {
        let id = nextID
        nextID += 1
        methodsByID[id] = method
        return JSONLine.encode(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    private static func response(id: Any, result: [String: Any]) -> Data {
        JSONLine.encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    static func stopReason(_ value: String?) -> StopReason {
        switch value {
        case "end_turn": return .endOfTurn
        case "max_tokens": return .maxTokens
        case "refusal": return .refusal
        default: return .other
        }
    }

    static func classify(_ error: [String: Any]) -> LLMError {
        let message = (error["message"] as? String) ?? "Grok Build reported an error"
        let lower = message.lowercased()
        if lower.contains("auth") || lower.contains("login") || lower.contains("log in") { return .auth(message) }
        if lower.contains("quota") || lower.contains("usage limit") { return .quotaExhausted(message) }
        if lower.contains("rate limit") { return .rateLimited(retryAfter: nil, message: message) }
        return .server(status: 500, message: message)
    }

    static func classifyStderr(_ stderr: String) -> LLMError? {
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return nil }
        switch classify(["message": message]) {
        case .auth(let m): return .auth(m)
        case .quotaExhausted(let m): return .quotaExhausted(m)
        default: return nil
        }
    }

    private static func describeRequest(_ method: String, _ params: [String: Any]?) -> String {
        if method == "session/request_permission" {
            let call = params?["toolCall"] as? [String: Any]
            let name = (call?["title"] as? String) ?? (call?["toolCallId"] as? String)
            return "a permission request" + (name.map { " (\($0))" } ?? "")
        }
        return "a request to the client (\(method))"
    }
}
