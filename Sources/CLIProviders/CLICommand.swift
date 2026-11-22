import Foundation
import RefereeCore

/// What a short command printed (`--version`, `--help`, `auth status`, `login status`, `models`, …).
struct CommandResult: Sendable, Equatable {
    var exitCode: Int32
    var stdout: String
    var stderr: String

    /// The first non-empty line of stdout, else of stderr, trimmed. (`codex login status` writes to stderr.)
    var firstLine: String? {
        for text in [stdout, stderr] {
            for line in text.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }
}

/// Runs a command to completion in a temporary working directory of its own, with nothing on stdin and one time limit
/// for everything. A command that overruns is killed at once, with its whole process tree.
enum CLICommand {
    static func run(_ executable: String, _ arguments: [String], environment: [String: String], temporaryRoot: URL,
                    timeout: Duration) async -> Result<CommandResult, LLMError> {
        let workspace: CLIWorkspace
        do { workspace = try CLIWorkspace.create(in: temporaryRoot) } catch {
            return .failure(error as? LLMError ?? .cliLaunchFailed("could not create a temporary working directory"))
        }
        let invocation = CLIInvocation(executable: executable, arguments: arguments, input: .data(Data()),
                                       workingDirectory: workspace.url, environment: environment,
                                       firstOutputTimeout: timeout, idleTimeout: timeout, totalTimeout: timeout,
                                       termination: .immediate)
        let process: CLIProcess
        do {
            process = try CLIRunner().start(invocation)
        } catch {
            workspace.remove()
            return .failure(error as? LLMError ?? .cliLaunchFailed(error.localizedDescription))
        }
        var lines: [String] = []
        var result: Result<CommandResult, LLMError> = .failure(.cancelled)
        do {
            for try await output in process.output {
                switch output {
                case .line(let line):
                    lines.append(line)
                case .exit(let code, _):
                    result = .success(CommandResult(exitCode: code, stdout: lines.joined(separator: "\n"), stderr: process.stderrText()))
                }
            }
        } catch {
            result = .failure(error as? LLMError ?? .cliLaunchFailed(error.localizedDescription))
        }
        if case .failure = result { process.kill() }
        await process.waitUntilGone()
        workspace.remove()
        return result
    }
}
