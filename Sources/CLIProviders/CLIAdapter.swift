import Foundation
import RefereeCore

/// Everything that differs between the four CLIs. One conforming type per CLI, each in a file of its own, so that a
/// provider can be removed with its file and its line in `CLIProviderFactory` (plan.md section 5.6.5).
protocol CLIAdapter: Sendable {
    var descriptor: ProviderDescriptor { get }
    var spec: CLISpec { get }
    /// Shown in Settings when the binary is missing.
    var installHint: String { get }
    /// The flag names the first help command must list (section 5.6.1); the same list as the protected table elements.
    var protectedFlags: [String] { get }
    var timeouts: CLITimeouts { get }
    /// Added to the child environment of every process started for this CLI.
    var extraEnvironment: [String: String] { get }
    /// Copied from the app's environment for this CLI only, when present (section 5.6.2). Default: none.
    var passedThroughNames: [String] { get }
    /// The constant of section 5.6.6.
    var pdfDelivery: CLIPDFDelivery { get }

    /// The table of section 5.6.4 for a run in `workspace`; `delivery` is `.none` for a text request.
    func argumentTable(workspace: URL, model: String?, delivery: CLIPDFDelivery) -> CLIArgumentTable
    /// Writes the run's files into the working directory and returns what goes to the process.
    func prepareInput(_ prompt: CLIPrompt, workspace: CLIWorkspace, delivery: CLIPDFDelivery) throws -> CLIRunInput
    /// The reader of the CLI's stdout for one run.
    func makeSession(workspace: URL, delivery: CLIPDFDelivery, input: CLIRunInput) -> CLISession
    /// After the binary and the flag check passed: is the CLI signed in?
    func signInStatus(_ binary: ResolvedBinary, host: CLIHost) async -> ProviderAvailability
    /// The model list; `binary` resolves the CLI only when the list needs it.
    func listModels(host: CLIHost, binary: @Sendable () async -> Result<ResolvedBinary, LLMError>) async throws -> [ModelInfo]
}

extension CLIAdapter {
    var passedThroughNames: [String] { [] }
}

/// What a prepared run sends to the process.
struct CLIRunInput: Sendable {
    var input: CLIInput
    /// Arguments placed after the model flag and before `extraArguments` (Codex: `-i <png>` once per page).
    var attachmentArguments: [String] = []
    /// The bytes that go to stdin (`input == .data`), for the size check; for Grok Build the prompt text.
    var payloadBytes: Int
    /// Grok Build: the text of `session/prompt`.
    var interactivePrompt: String?
}

enum CLISession {
    case lines(any CLIStreamParser)
    case acp(GrokACPClient)
}

/// How a run ends, as far as the CLI's own output says.
enum CLIOutcome: Sendable, Equatable {
    case success(StopReason, Usage?)
    case failure(LLMError)
}

/// The reader of a CLI that prints JSON lines and reads nothing back (Claude Code, Codex, Antigravity).
protocol CLIStreamParser: Sendable {
    /// "Claude Code", for messages.
    var cliName: String { get }
    /// Events for one stdout line. Throws `LLMError.toolUseBlocked` when the line shows a tool or fails to prove that
    /// tools are off (the tripwire, section 5.6.3).
    mutating func consume(_ line: String) throws -> [LLMEvent]
    /// Set by the line that ends the turn.
    var outcome: CLIOutcome? { get }
    /// An error the CLI reported without ending the turn; used if the process exits without a result.
    var pendingError: LLMError? { get }
    /// Auth and quota patterns of the CLI's stderr, for a non-zero exit without a result.
    func classifyStderr(_ stderr: String) -> LLMError?
}

extension CLIStreamParser {
    var pendingError: LLMError? { nil }

    /// The end of the run once the process has exited: the reported result, else a classified non-zero exit, else a
    /// malformed response.
    func finalResult(exitCode: Int32, stderrTail: String) -> CLIOutcome {
        if let outcome { return outcome }
        if let pendingError { return .failure(pendingError) }
        if exitCode != 0 {
            return .failure(classifyStderr(stderrTail) ?? .cliExited(code: exitCode, stderrTail: stderrTail))
        }
        return .failure(.malformedResponse("\(cliName) ended without reporting a result"))
    }
}

/// Builds the `.toolUseBlocked` error of a tripwire.
func tripwire(_ description: String) -> LLMError {
    .toolUseBlocked(JSONLine.short(description))
}
