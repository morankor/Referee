import Foundation
import RefereeCore

/// Codex through `codex exec` (plan.md section 5.6.4).
struct CodexAdapter: CLIAdapter {
    static let id: ProviderID = "codex-cli"
    static let maxPromptBytes = 4_000_000
    /// Set by the delivery experiment of section 5.6.6: variant X1 (page images at 110 dpi, `-i` once per page) passed
    /// on 2026-11-22 with codex-cli 0.167.0-alpha.3.2 (docs/contract-notes/wp5-cliproviders.md).
    static let delivery: CLIPDFDelivery = .pageImages
    /// Planning's limit for page images [A]; the adapter refuses more.
    static let maxPageImages = 40
    static let pageImagesPreamble = "The attached images are the pages of a manuscript, in order."

    var pdfDelivery: CLIPDFDelivery { Self.delivery }

    var descriptor: ProviderDescriptor {
        ProviderDescriptor(id: Self.id, displayName: "Codex (ChatGPT plan)", vendor: "OpenAI", authMode: .subscriptionCLI,
                           isLocal: false, destination: "codex", supportsNativePDF: Self.delivery == .pageImages,
                           pdfDeliveryNote: Self.delivery == .pageImages ? "sent as page images" : nil,
                           streaming: .message, maxPromptBytes: Self.maxPromptBytes,
                           retentionNote: "Runs through your ChatGPT plan with shell and agent tools switched off; session files are not kept.",
                           isExperimental: false)
    }

    let spec = CLISpec(
        name: "codex",
        candidates: ["~/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                     "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"],
        versionArguments: ["--version"], helpArguments: [["exec", "--help"]], environmentOverride: "REFEREE_CLI_PATH_CODEX")
    let installHint = "npm install -g @openai/codex"
    let protectedFlags = ["--ephemeral", "--ignore-user-config", "--ignore-rules", "--strict-config", "--sandbox", "--disable"]
    let timeouts = CLITimeouts(firstOutput: .seconds(300), idle: .seconds(900))
    let extraEnvironment: [String: String] = [:]

    /// The `-c` and `--disable` elements: also what the "Codex tool list" test renders with `codex debug prompt-input`.
    static let toolRemovingArguments: [CLIArgument] = [
        .protected("-c", "web_search=\"disabled\""), .protected("-c", "history.persistence=\"none\""), .protected("-c", "agents.enabled=false"),
        .protected("--disable", "shell_tool"), .protected("--disable", "view_image"), .protected("--disable", "sleep_tool"),
    ]

    func argumentTable(workspace: URL, model: String?, delivery: CLIPDFDelivery) -> CLIArgumentTable {
        let leading: [CLIArgument] = [
            .plain("exec"), .plain("-"), .plain("--json"), .plain("--skip-git-repo-check"),
            .protected("--ephemeral"), .protected("--ignore-user-config"), .protected("--ignore-rules"), .protected("--strict-config"),
            .protected("--sandbox", "read-only"), .plain("-C", workspace.path),
        ] + Self.toolRemovingArguments
        return CLIArgumentTable(leading: leading, model: model.map { ["-m", $0] } ?? [])
    }

    func prepareInput(_ prompt: CLIPrompt, workspace: CLIWorkspace, delivery: CLIPDFDelivery) throws -> CLIRunInput {
        var user = prompt.user
        var attachments: [String] = []
        switch delivery {
        case .none:
            break
        case .pageImages:
            guard let pdf = prompt.pdf else { throw LLMError.invalidRequest("no pdf document in the request") }
            let pages = try PageImageRenderer.render(pdf: pdf, into: workspace, maxPages: Self.maxPageImages)
            attachments = pages.flatMap { ["-i", $0.path] }
            user = Self.pageImagesPreamble + "\n\n" + user
        case .documentBlock, .readTool:
            throw LLMError.invalidRequest("Codex does not take a pdf document this way")
        }
        let stdin = Data(CLIPrompt.inline(system: prompt.system, user: user).utf8)
        return CLIRunInput(input: .data(stdin), attachmentArguments: attachments, payloadBytes: stdin.count)
    }

    func makeSession(workspace: URL, delivery: CLIPDFDelivery, input: CLIRunInput) -> CLISession {
        .lines(CodexStreamParser())
    }

    func signInStatus(_ binary: ResolvedBinary, host: CLIHost) async -> ProviderAvailability {
        Self.signInStatus(await host.command(binary, ["login", "status"], extraEnvironment: extraEnvironment), version: binary.version)
    }

    /// `codex login status` exits 0 and says "Logged in using ChatGPT" for a plan login [V]; it writes that line to stderr.
    static func signInStatus(_ result: Result<CommandResult, LLMError>, version: String) -> ProviderAvailability {
        if case .success(let output) = result, output.exitCode == 0, let line = output.firstLine, line.hasPrefix("Logged in using ChatGPT") {
            return .ready(detail: "Logged in using ChatGPT · codex \(version)")
        }
        return .needsSetup(reason: "Codex is not signed in with ChatGPT", hint: "Run `codex login`")
    }

    func listModels(host: CLIHost, binary: @Sendable () async -> Result<ResolvedBinary, LLMError>) async throws -> [ModelInfo] {
        let resolved = try await binary().get()
        var lastError: LLMError = .malformedResponse("codex debug models printed no model list")
        for arguments in [["debug", "models"], ["debug", "models", "--bundled"]] {
            switch await host.command(resolved, arguments, extraEnvironment: extraEnvironment) {
            case .success(let output) where output.exitCode == 0:
                if let models = Self.parseModels(output.stdout, pageImages: Self.delivery == .pageImages) { return models }
                lastError = .malformedResponse("codex \(arguments.joined(separator: " ")) printed no model list")
            case .success(let output):
                lastError = .cliExited(code: output.exitCode, stderrTail: String(output.stderr.suffix(4_096)))
            case .failure(let error):
                lastError = error
            }
        }
        throw lastError
    }

    /// `{"models":[{"slug","display_name","context_window","visibility","priority",…}]}`: the entries with
    /// `visibility == "list"`, by priority. With page images, a model that does not take images cannot read the PDF.
    static func parseModels(_ json: String, pageImages: Bool) -> [ModelInfo]? {
        guard let start = json.firstIndex(of: "{"), let data = String(json[start...]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else { return nil }
        let listed = models.filter { ($0["visibility"] as? String) == "list" && ($0["slug"] as? String) != nil }
        let sorted = listed.enumerated().sorted { a, b in
            let pa = JSONLine.int(a.element["priority"]) ?? Int.max, pb = JSONLine.int(b.element["priority"]) ?? Int.max
            return pa == pb ? a.offset < b.offset : pa < pb
        }.map(\.element)
        return sorted.map { entry in
            let slug = entry["slug"] as? String ?? ""
            var pdf: Bool?
            if pageImages, let modalities = entry["input_modalities"] as? [String] { pdf = modalities.contains("image") }
            return ModelInfo(id: slug, displayName: (entry["display_name"] as? String) ?? slug,
                             contextWindow: JSONLine.int(entry["context_window"]), supportsPDFInput: pdf)
        }
    }
}

/// Codex's `exec --json` (Appendix D.6) and its tripwire.
struct CodexStreamParser: CLIStreamParser {
    let cliName = "Codex"
    /// Item types that are not tools. Every other type trips the wire: the tool types of `exec_events.rs`
    /// (`command_execution`, `file_change`, `mcp_tool_call`, `collab_tool_call`, `web_search`) and any type not known.
    private static let allowedItems: Set<String> = ["agent_message", "reasoning", "todo_list", "error"]

    private(set) var outcome: CLIOutcome?
    private(set) var pendingError: LLMError?
    private var emitted: [String: String] = [:]
    private var lastItemID: String?
    private var emittedAny = false
    private var lastEmittedEndsWithNewline = true

    mutating func consume(_ line: String) throws -> [LLMEvent] {
        guard let object = JSONLine.object(line), let type = object["type"] as? String else { return [] }
        switch type {
        case "item.started", "item.updated", "item.completed":
            guard let item = object["item"] as? [String: Any], let itemType = item["type"] as? String else {
                throw tripwire("an item of no stated type")
            }
            guard Self.allowedItems.contains(itemType) else { throw tripwire(Self.describe(itemType, item)) }
            return itemType == "agent_message" ? agentText(item) : []
        case "turn.completed":
            let usage = object["usage"] as? [String: Any]
            outcome = .success(.endOfTurn, usage.map { Usage(inputTokens: JSONLine.int($0["input_tokens"]), outputTokens: JSONLine.int($0["output_tokens"])) })
            return []
        case "turn.failed":
            let message = ((object["error"] as? [String: Any])?["message"] as? String) ?? "Codex reported that the turn failed"
            outcome = .failure(Self.classify(message))
            return []
        case "error":
            // Not final by itself: Codex also reports a reconnect this way. It decides the run only if no turn completes.
            pendingError = Self.classify(object["message"] as? String ?? "Codex reported an error")
            return []
        default:
            return []
        }
    }

    /// `text` is cumulative per item id: emit only what is new. Text that does not extend what was emitted is emitted
    /// whole on a new line; a new message starts on a new line.
    private mutating func agentText(_ item: [String: Any]) -> [LLMEvent] {
        let id = item["id"] as? String ?? ""
        let text = item["text"] as? String ?? ""
        let previous = emitted[id] ?? ""
        var piece: String
        if text.unicodeScalars.starts(with: previous.unicodeScalars) {
            var suffix = String.UnicodeScalarView()
            suffix.append(contentsOf: text.unicodeScalars.dropFirst(previous.unicodeScalars.count))
            piece = String(suffix)
        } else {
            piece = "\n" + text
        }
        emitted[id] = text
        guard !piece.isEmpty else { return [] }
        if id != lastItemID, emittedAny, !lastEmittedEndsWithNewline, !piece.hasPrefix("\n") { piece = "\n" + piece }
        lastItemID = id
        emittedAny = true
        lastEmittedEndsWithNewline = piece.hasSuffix("\n")
        return [.textDelta(piece)]
    }

    private static func describe(_ type: String, _ item: [String: Any]) -> String {
        if let server = item["server"] as? String, let tool = item["tool"] as? String { return "\(type) \(server)/\(tool)" }
        return type
    }

    static func classify(_ message: String) -> LLMError {
        let lower = message.lowercased()
        if ["401", "unauthorized", "login", "log in", "logged in"].contains(where: { lower.contains($0) }) { return .auth(message) }
        if lower.contains("usage limit") || lower.contains("quota") { return .quotaExhausted(message) }
        if lower.contains("rate limit") || lower.contains("429") { return .rateLimited(retryAfter: nil, message: message) }
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
