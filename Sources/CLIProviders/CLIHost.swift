import Foundation
import RefereeCore

/// How an adapter hands the manuscript itself to its CLI (plan.md section 5.6.6). Each adapter has one constant, set
/// from the delivery experiment.
enum CLIPDFDelivery: String, Sendable, CaseIterable {
    case none, documentBlock, readTool, pageImages
}

/// First output / idle / total, per CLI (plan.md section 5.6.4).
struct CLITimeouts: Sendable, Equatable {
    var firstOutput: Duration
    var idle: Duration
    var total: Duration = .seconds(3600)
}

/// What the four CLI providers share: the app's environment and the knobs tests turn. The app uses the defaults.
struct CLIHost: Sendable {
    var processEnvironment: [String: String]
    var loginPath: LoginPathSource = .loginShell
    /// Where working directories are made: the app's TMPDIR, else the system's temporary directory.
    var temporaryRoot: URL
    /// The cap on `--version`, help commands, sign-in status, model lists and session deletion (section 5.6.1: 20 s).
    var probeTimeout: Duration = .seconds(20)
    /// False: the resolver looks only at the explicit path and the environment override, never at the built-in
    /// candidates or the PATH. Tests that run fake CLIs set this, so that a fake that fails cannot let a real CLI run.
    var searchesDefaultLocations = true
    /// Replaces every adapter's own run timeouts (tests).
    var runTimeouts: CLITimeouts?
    /// How long a CLI may keep running after its last line reported success before it is ended.
    var postResultGrace: Duration = .seconds(10)
    /// Grok Build: how long to keep reading after the prompt's answer (section 5.6.4: 500 ms with no line).
    var quietPeriod: Duration = .milliseconds(500)
    /// Replaces the adapters' delivery constants (tests and the delivery experiment).
    var pdfDelivery: CLIPDFDelivery?
    /// Sees every stdout line of a run (tests and the delivery experiment; never set by the app).
    var lineObserver: (@Sendable (ProviderID, String) -> Void)?

    init(processEnvironment: [String: String]) {
        self.processEnvironment = processEnvironment
        if let tmp = processEnvironment["TMPDIR"], tmp.hasPrefix("/") {
            temporaryRoot = URL(fileURLWithPath: tmp, isDirectory: true)
        } else {
            temporaryRoot = FileManager.default.temporaryDirectory
        }
    }

    /// The environment of every process started for an adapter (section 5.6.2).
    func childEnvironment(extra: [String: String]) async -> [String: String] {
        let loginShellPath: String?
        switch loginPath {
        case .fixed(let value): loginShellPath = value
        case .loginShell: loginShellPath = await LoginShellPath.shared.path(for: processEnvironment, temporaryRoot: temporaryRoot)
        }
        return ChildEnvironment.make(from: processEnvironment, loginPath: loginShellPath, extra: extra)
    }

    /// Runs a short command of an adapter's binary, with the adapter's child environment.
    func command(_ binary: ResolvedBinary, _ arguments: [String], extraEnvironment: [String: String]) async -> Result<CommandResult, LLMError> {
        let environment = await childEnvironment(extra: extraEnvironment)
        return await CLICommand.run(binary.path, arguments, environment: environment, temporaryRoot: temporaryRoot, timeout: probeTimeout)
    }
}
