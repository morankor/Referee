import Foundation
import RefereeCore

// The process runner of plan.md section 5.6.3.

enum CLIInput: Sendable {
    case data(Data)          // written by a separate thread, then stdin is closed
    case interactive         // the adapter writes with send(_:) and closes with closeInput()  (Grok Build)
}

/// How a timeout, or a consumer that walks away, ends the process.
enum CLITermination: Sendable {
    case graceful            // SIGINT, wait 2 s, SIGTERM, wait 3 s, SIGKILL to the whole tree (runs)
    case immediate           // SIGKILL to the whole tree at once (probes such as --version)
}

struct CLIInvocation: Sendable {
    var executable: String
    var arguments: [String]
    var input: CLIInput
    var workingDirectory: URL
    var environment: [String: String]
    var firstOutputTimeout: Duration = .seconds(300)   // spawn → first stdout byte
    var idleTimeout: Duration = .seconds(300)          // between stdout lines
    var totalTimeout: Duration = .seconds(3600)
    var termination: CLITermination = .graceful
}

enum CLIOutput: Sendable, Equatable {
    case line(String)
    case exit(code: Int32, stderrTail: String)   // stderrTail: last 4 KB; a death by signal n is reported as 128 + n
}

struct CLIRunner {
    /// Starts the process. Throws `LLMError.cliLaunchFailed` when it cannot be spawned.
    func start(_ invocation: CLIInvocation) throws -> CLIProcess {
        try CLIProcess(invocation)
    }
}
