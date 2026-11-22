import Foundation
import RefereeCore

/// Antigravity through `agy` print mode (plan.md section 5.6.4). Experimental: written from documentation only; `agy`
/// was not installed when this was written, and WP5 does not install it.
struct AntigravityAdapter: CLIAdapter {
    static let id: ProviderID = "antigravity-cli"
    static let maxPromptBytes = 4_000_000

    let pdfDelivery: CLIPDFDelivery = .none

    var descriptor: ProviderDescriptor {
        ProviderDescriptor(id: Self.id, displayName: "Antigravity (Google AI plan)", vendor: "Google", authMode: .subscriptionCLI,
                           isLocal: false, destination: "agy", supportsNativePDF: false, streaming: .token, maxPromptBytes: Self.maxPromptBytes,
                           retentionNote: "Runs through your Google account. Its tools cannot be switched off: Referee stops the run if it uses one. "
                               + "The CLI may keep a local conversation record.",
                           isExperimental: true)
    }

    let spec = CLISpec(name: "agy", candidates: ["~/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"],
                       versionArguments: ["--version"], helpArguments: [["--help"]], environmentOverride: "REFEREE_CLI_PATH_AGY")
    let installHint = "curl -fsSL https://antigravity.google/cli/install.sh | bash"
    let protectedFlags = ["--input-format", "--output-format", "--mode", "--sandbox", "--disable-slash-commands"]
    let timeouts = CLITimeouts(firstOutput: .seconds(300), idle: .seconds(600))
    let extraEnvironment: [String: String] = [:]

    func argumentTable(workspace: URL, model: String?, delivery: CLIPDFDelivery) -> CLIArgumentTable {
        CLIArgumentTable(leading: [
            .protected("--input-format", "stream-json"), .protected("--output-format", "stream-json"), .protected("--mode=accept-edits"),
            .protected("--sandbox"), .protected("--disable-slash-commands"), .plain("--print-timeout", "60m"),
        ], model: model.map { ["--model", $0] } ?? [])
    }

    func prepareInput(_ prompt: CLIPrompt, workspace: CLIWorkspace, delivery: CLIPDFDelivery) throws -> CLIRunInput {
        guard delivery == .none else { throw LLMError.invalidRequest("Antigravity does not take a pdf document") }
        let line: [String: Any] = ["event": "user", "message": ["content": CLIPrompt.inline(system: prompt.system, user: prompt.user)]]
        let stdin = JSONLine.encode(line)
        return CLIRunInput(input: .data(stdin), payloadBytes: stdin.count)
    }

    func makeSession(workspace: URL, delivery: CLIPDFDelivery, input: CLIRunInput) -> CLISession {
        .lines(AntigravityStreamParser())
    }

    /// The documentation gives no sign-in status command.
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

    /// `agy models`: lines of slug, two or more spaces, display name [D].
    static func parseModels(_ text: String) -> [ModelInfo] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            if let gap = line.range(of: #"\s{2,}"#, options: .regularExpression) {
                let slug = String(line[..<gap.lowerBound])
                let name = line[gap.upperBound...].trimmingCharacters(in: .whitespaces)
                return ModelInfo(id: slug, displayName: name.isEmpty ? slug : name, contextWindow: nil)
            }
            return ModelInfo(id: line, displayName: line, contextWindow: nil)
        }
    }
}

/// Antigravity's `--output-format stream-json` (Appendix D.7) and its tripwire.
struct AntigravityStreamParser: CLIStreamParser {
    let cliName = "Antigravity"
    private static let safeModes: Set<String> = ["request-review", "strict"]

    private(set) var outcome: CLIOutcome?
    private(set) var sawInit = false

    mutating func consume(_ line: String) throws -> [LLMEvent] {
        guard let object = JSONLine.object(line), let event = object["event"] as? String else { return [] }
        switch event {
        case "init":
            let mode = (object["init"] as? [String: Any])?["permission_mode"] as? String
            guard let mode, Self.safeModes.contains(mode) else { throw tripwire("permission mode \(mode ?? "not reported")") }
            sawInit = true
            return []
        case "step_update":
            guard let step = object["step_update"] as? [String: Any] else { return [] }
            if (step["step_type"] as? String) == "tool" || step["tool_name"] != nil || step["tool_info"] != nil || step["subagent_info"] != nil {
                let name = (step["tool_name"] as? String) ?? ((step["tool_info"] as? [String: Any])?["name"] as? String)
                throw tripwire(name ?? (step["subagent_info"] != nil ? "a sub-agent" : "a tool step"))
            }
            guard (step["step_type"] as? String) == "agent_response", let text = step["text_delta"] as? String, !text.isEmpty else { return [] }
            guard sawInit else { throw tripwire("Antigravity wrote output before its permission mode") }
            return [.textDelta(text)]
        case "result":
            guard let result = object["result"] as? [String: Any] else { return [] }
            let status = result["status"] as? String ?? ""
            if status == "SUCCESS" {
                guard sawInit else { throw tripwire("Antigravity finished without reporting its permission mode") }
                let usage = result["usage"] as? [String: Any]
                outcome = .success(.endOfTurn, usage.map { Usage(inputTokens: JSONLine.int($0["input_tokens"]), outputTokens: JSONLine.int($0["output_tokens"])) })
            } else {
                let message = (result["error"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Antigravity reported \(status.isEmpty ? "an error" : status)"
                outcome = .failure(Self.classify(message))
            }
            return []
        default:
            return []
        }
    }

    static func classify(_ message: String) -> LLMError {
        let lower = message.lowercased()
        if lower.contains("authentication required") { return .auth(message) }
        if lower.contains("not recognized as a known model") { return .modelNotFound(message) }
        if lower.contains("quota") || lower.contains("limit") { return .quotaExhausted(message) }
        return .server(status: 500, message: message)
    }

    func classifyStderr(_ stderr: String) -> LLMError? {
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return nil }
        switch Self.classify(message) {
        case .auth(let m): return .auth(m)
        case .quotaExhausted(let m): return .quotaExhausted(m)
        default: return nil
        }
    }
}
