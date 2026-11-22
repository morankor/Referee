import Foundation

// referee-cli (plan.md section 10.2): the app's pipeline without the UI, for checking it from the command line.
//
// - The data folder is --home, else a temporary folder removed at the end, so the CLI never touches the user's data
//   unless asked. Keys come from REFEREE_KEY_* only (REFEREE_NO_KEYCHAIN=1) unless --use-keychain is given.
// - `--provider mock` adds the mock provider (REFEREE_ENABLE_MOCK=1), so it works with no setup (section 5.9).
// - Ctrl-C cancels a running review or question; the engine then stops the provider (a CLI provider's whole process
//   tree), and the run ends as cancelled.
// - Exit codes: 0 success; 1 the job failed (or `anchor` found nothing); 2 usage error; 3 provider not set up or not available.

let options: CLIOptions
do {
    options = try CLIOptions(Array(CommandLine.arguments.dropFirst()))
} catch let error as CLIOptions.UsageError {
    Output.note("referee-cli: \(error.message)\n\n\(CLIOptions.usage)")
    exit(2)
}

var environment = ProcessInfo.processInfo.environment
let manager = FileManager.default
let temporaryHome: URL?
if let home = options.home {
    environment["REFEREE_HOME"] = URL(fileURLWithPath: home, isDirectory: true).standardizedFileURL.path
    temporaryHome = nil
} else {
    let folder = manager.temporaryDirectory.appendingPathComponent("referee-cli-home-\(UUID().uuidString)", isDirectory: true)
    try? manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    environment["REFEREE_HOME"] = folder.path
    temporaryHome = folder
}
if options.useKeychain { environment["REFEREE_NO_KEYCHAIN"] = nil } else { environment["REFEREE_NO_KEYCHAIN"] = "1" }
if options.value("--provider") == "mock" { environment["REFEREE_ENABLE_MOCK"] = "1" }

let running = RunningTask()
signal(SIGINT, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
interrupt.setEventHandler {
    if running.cancelIfRunning() {
        Output.note("referee-cli: cancelling…")
    } else {
        if let temporaryHome { try? FileManager.default.removeItem(at: temporaryHome) }
        exit(130)
    }
}
interrupt.resume()

let code: Int32
do {
    code = try await Commands(options: options, environment: environment, running: running).run()
} catch let failure as Commands.Failure {
    Output.note("referee-cli: \(failure.message)")
    code = failure.code
} catch let error as CLIOptions.UsageError {
    Output.note("referee-cli: \(error.message)\n\n\(CLIOptions.usage)")
    code = 2
} catch {
    Output.note("referee-cli: \(error)")
    code = 1
}
if let temporaryHome { try? manager.removeItem(at: temporaryHome) }
exit(code)
