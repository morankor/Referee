import Foundation
import Darwin
@testable import CLIProviders
import RefereeCore
import TestSupport

/// The fake CLIs and their lines, written once per test process into a temporary directory.
///
/// Why once: macOS assesses every new executable the first time it is run. Measured here, 40 new two-line scripts run
/// at the same time took up to 8.3 s each (mean 4.1 s), against 0.01 s for a script that had run before, or for a new
/// script run as `/bin/sh <script>`. A fake per test made `--version` miss its deadline. So the only files that are run
/// directly are the few entry scripts made here and run once at once; a test chooses a fake's behaviour through
/// `$HOME/fake.env` in a home directory of its own, and the fakes themselves are run through `/bin/sh`.
final class FakeCLIInstall: @unchecked Sendable {
    static let shared = FakeCLIInstall()

    let root: URL
    /// The four fakes (run through /bin/sh) and their fixtures.
    let fakes: URL
    /// `claude`, `codex`, `agy`, `grok`: what a provider runs. Each reads `$HOME/fake.env`, then runs its fake.
    let bin: URL
    /// Fixed variants of the `claude` fake for the resolver tests: v1, v2, v3 (versions 1.0.1–1.0.3), good (9.9.9),
    /// hang-version, fail-version; and `path/fakecli` (1.0.4), for the PATH step.
    let resolver: URL
    let failure: String?

    private init() {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("referee-wp5-fakes-\(UUID().uuidString)", isDirectory: true)
        Self.removeOldInstalls(near: base)
        root = URL(fileURLWithPath: CLIWorkspace.canonicalPath(fm.temporaryDirectory.path), isDirectory: true)
            .appendingPathComponent(base.lastPathComponent, isDirectory: true)
        fakes = root.appendingPathComponent("fakes", isDirectory: true)
        bin = root.appendingPathComponent("bin", isDirectory: true)
        resolver = root.appendingPathComponent("resolver", isDirectory: true)
        do {
            try Self.install(fakes: fakes, bin: bin, resolver: resolver)
            failure = nil
        } catch {
            failure = "could not install the fake CLIs: \(error)"
        }
        // Run every entry once now, so that the system's first-run assessment is behind us. With an unknown argument and
        // mode a fake does nothing and exits.
        let entries = ["claude", "codex", "agy", "grok"].map { bin.appendingPathComponent($0).path }
            + ["v1", "v2", "v3", "good", "hang-version", "fail-version", "path/fakecli"].map { resolver.appendingPathComponent($0).path }
        let warmUps: [Process] = entries.compactMap { entry in
            let warm = Process()
            warm.executableURL = URL(fileURLWithPath: entry)
            warm.arguments = ["--warm-up"]
            warm.environment = ["PATH": FakeCLIHarness.fixedPath, "HOME": "/nonexistent", "FAKE_MODE": "warm-up"]
            warm.standardInput = FileHandle.nullDevice
            warm.standardOutput = FileHandle.nullDevice
            warm.standardError = FileHandle.nullDevice
            return (try? warm.run()) != nil ? warm : nil
        }
        for warm in warmUps { warm.waitUntilExit() }
        Self.removeAtExit = root.path
        atexit { if let path = FakeCLIInstall.removeAtExit { try? FileManager.default.removeItem(atPath: path) } }
    }

    /// The install is removed when the test process exits (an install that a crash left behind goes an hour later).
    nonisolated(unsafe) static var removeAtExit: String?

    func entry(_ cli: String) -> String { bin.appendingPathComponent(cli).path }
    func resolverEntry(_ name: String) -> String { resolver.appendingPathComponent(name).path }

    private static func install(fakes: URL, bin: URL, resolver: URL) throws {
        let fm = FileManager.default
        for directory in [fakes, bin, resolver.appendingPathComponent("path", isDirectory: true)] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        func write(_ text: String, to url: URL, executable: Bool) throws {
            try Data(text.utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
        }
        for (name, script) in FakeCLIScripts.all {
            try write(script, to: fakes.appendingPathComponent(name), executable: false)
            let entry = """
            #!/bin/sh
            [ -f "$HOME/fake.env" ] && . "$HOME/fake.env"
            exec /bin/sh \(quote(fakes.appendingPathComponent(name).path)) "$@"

            """
            try write(entry, to: bin.appendingPathComponent(name), executable: true)
        }
        let variants: [(String, String)] = [("v1", "FAKE_VERSION_TEXT=1.0.1"), ("v2", "FAKE_VERSION_TEXT=1.0.2"), ("v3", "FAKE_VERSION_TEXT=1.0.3"),
                                            ("good", "FAKE_VERSION_TEXT='9.9.9 (good)'"), ("hang-version", "FAKE_VERSION=hang"),
                                            ("fail-version", "FAKE_VERSION=fail"), ("path/fakecli", "FAKE_VERSION_TEXT=1.0.4")]
        for (name, setting) in variants {
            let entry = """
            #!/bin/sh
            [ -f "$HOME/fake.env" ] && . "$HOME/fake.env"
            export \(setting)
            exec /bin/sh \(quote(fakes.appendingPathComponent("claude").path)) "$@"

            """
            try write(entry, to: resolver.appendingPathComponent(name), executable: true)
        }
        try installFixtures(in: fakes.appendingPathComponent("fixtures", isDirectory: true))
    }

    private static func installFixtures(in directory: URL) throws {
        func lines(_ list: [String]) -> Data { Data((list.joined(separator: "\n") + "\n").utf8) }
        let files: [String: [String: Data]] = [
            "claude": [
                "ok.jsonl": lines(AppendixD.claudeOK), "tool-blocks.jsonl": lines(AppendixD.claudeToolBlocks),
                "tool-assistant.jsonl": lines(AppendixD.claudeToolAssistantOnly), "tools-on-bash.jsonl": lines(AppendixD.claudeToolsOnBash),
                "tools-on-missing.jsonl": lines(AppendixD.claudeToolsOnMissing), "auth.jsonl": lines(AppendixD.claudeAuth),
                "quota.jsonl": lines(AppendixD.claudeQuota), "garbage.txt": AppendixD.garbage, "help.txt": Data(FakeCLIScripts.claudeHelp.utf8),
                "auth-subscription.json": Data((AppendixD.claudeAuthSubscription + "\n").utf8),
                "auth-apikey.json": Data((AppendixD.claudeAuthAPIKey + "\n").utf8),
                "auth-loggedout.json": Data((AppendixD.claudeAuthLoggedOut + "\n").utf8),
            ],
            "codex": [
                "ok.jsonl": lines(AppendixD.codexOK), "tool-command.jsonl": lines(AppendixD.codexToolCommand),
                "tool-unknown.jsonl": lines(AppendixD.codexToolUnknown), "auth.jsonl": lines(AppendixD.codexAuth),
                "quota.jsonl": lines(AppendixD.codexQuota), "garbage.txt": AppendixD.garbage, "help.txt": Data(FakeCLIScripts.codexHelp.utf8),
                "debug-models.json": Data((AppendixD.codexDebugModels + "\n").utf8),
            ],
            "agy": [
                "ok.jsonl": lines(AppendixD.agyOK), "tool.jsonl": lines(AppendixD.agyTool),
                "tools-on-always.jsonl": lines(AppendixD.agyToolsOnAlways), "tools-on-missing.jsonl": lines(AppendixD.agyToolsOnMissing),
                "auth.jsonl": lines(AppendixD.agyAuth), "quota.jsonl": lines(AppendixD.agyQuota),
                "model-not-found.jsonl": lines(AppendixD.agyModelNotFound), "garbage.txt": AppendixD.garbage,
                "help.txt": Data(FakeCLIScripts.agyHelp.utf8), "models.txt": Data(AppendixD.agyModels.utf8),
            ],
            "grok": [
                "help.txt": Data(FakeCLIScripts.grokHelp.utf8), "models.txt": Data(AppendixD.grokModels.utf8),
                "garbage.txt": AppendixD.garbage, "tool-call.jsonl": lines([AppendixD.grokToolCall]),
                "permission.jsonl": lines([AppendixD.grokPermission]), "prompt-answer.jsonl": lines(Array(AppendixD.grokAgentLines[3...6])),
            ],
        ]
        for (cli, entries) in files {
            let folder = directory.appendingPathComponent(cli, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (name, data) in entries { try data.write(to: folder.appendingPathComponent(name)) }
        }
    }

    /// Installs of earlier test runs (more than an hour old).
    private static func removeOldInstalls(near base: URL) {
        let parent = base.deletingLastPathComponent()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else { return }
        for name in names where name.hasPrefix("referee-wp5-fakes-") {
            let path = parent.appendingPathComponent(name).path
            if let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
               modified < Date().addingTimeInterval(-3600) {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// One test's world: its own temporary directory (working directories, homes, the files the fakes write), and
/// providers that find the shared fake CLIs through the injected environment (never through `setenv`).
///
/// Tests run in parallel in one process with every other target's tests, so nothing here touches the process's own
/// environment or current directory, and `cleanup()` kills any process a fake recorded that is still alive.
final class FakeCLIHarness: @unchecked Sendable {
    let install = FakeCLIInstall.shared
    let root: URL
    /// TMPDIR of the providers: their working directories are made here.
    let temporary: URL
    /// The default HOME of the injected environment: empty, so no candidate under `~` exists.
    let home: URL
    let pidFile: URL
    let outFile: URL
    let logFile: URL
    private let createdAt: UInt64

    static let fixedPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    init() throws {
        if let failure = FakeCLIInstall.shared.failure { throw FakeCLIError(message: failure) }
        var now = timeval()
        gettimeofday(&now, nil)
        createdAt = UInt64(now.tv_sec) * 1_000_000 + UInt64(now.tv_usec)
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("referee-wp5-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: CLIWorkspace.canonicalPath(base.path), isDirectory: true)
        temporary = root.appendingPathComponent("tmp", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        pidFile = root.appendingPathComponent("pids.txt")
        outFile = root.appendingPathComponent("out.txt")
        logFile = root.appendingPathComponent("log.txt")
        for directory in [temporary, home] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
    }

    // MARK: - Homes and providers

    /// A home directory whose `fake.env` gives the fakes `variables` (and where to record what they did).
    func makeHome(_ variables: [String: String]) throws -> URL {
        let directory = root.appendingPathComponent("home-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var all = ["FAKE_PIDS": pidFile.path, "FAKE_OUT": outFile.path, "FAKE_LOG": logFile.path]
        for (key, value) in variables { all[key] = value }
        let exports = all.keys.sorted().map { "export \($0)=\(FakeCLIInstall.quote(all[$0]!))" }.joined(separator: "\n")
        try Data((exports + "\n").utf8).write(to: directory.appendingPathComponent("fake.env"))
        return directory
    }

    /// The app environment a provider sees: a temporary HOME and TMPDIR, plus `extra`.
    func processEnvironment(home: URL? = nil, _ extra: [String: String] = [:]) -> [String: String] {
        var environment = ["HOME": (home ?? self.home).path, "USER": "tester", "LOGNAME": "tester", "TMPDIR": temporary.path,
                           "LANG": "en_US.UTF-8"]
        for (key, value) in extra { environment[key] = value }
        return environment
    }

    /// A host for fakes: fixed PATH, and the resolver never looks beyond the explicit path and the override variable,
    /// so that a fake that misbehaves can never make a test fall through to a real CLI on this machine.
    func host(_ environment: [String: String], timeouts: CLITimeouts? = nil, probeTimeout: Duration = .seconds(20)) -> CLIHost {
        var host = CLIHost(processEnvironment: environment)
        host.loginPath = .fixed(Self.fixedPath)
        host.runTimeouts = timeouts
        host.probeTimeout = probeTimeout
        host.searchesDefaultLocations = false
        return host
    }

    /// A provider for `adapter` that runs the shared fake with `variables`.
    func provider(_ adapter: any CLIAdapter, _ variables: [String: String] = [:], settings: ProviderSettings = FakeCLIHarness.settings(),
                  environment extra: [String: String] = [:], timeouts: CLITimeouts? = nil,
                  configure: (inout CLIHost) -> Void = { _ in }) throws -> CLIProvider {
        var environment = processEnvironment(home: try makeHome(variables), extra)
        environment[adapter.spec.environmentOverride] = install.entry(adapter.spec.name)
        var host = self.host(environment, timeouts: timeouts)
        configure(&host)
        return CLIProvider(adapter: adapter, environment: Self.providerEnvironment(environment, settings: settings), host: host)
    }

    static func settings(extraArguments: [String] = [], executablePath: String? = nil) -> ProviderSettings {
        ProviderSettings(enabled: true, executablePath: executablePath, inputMode: .auto, extraArguments: extraArguments)
    }

    static func providerEnvironment(_ environment: [String: String], settings: ProviderSettings = settings()) -> ProviderEnvironment {
        ProviderEnvironment(settings: { _ in settings }, secrets: InMemorySecretStore(), urlSession: URLSession.shared,
                            processEnvironment: environment)
    }

    // MARK: - What the fakes recorded

    /// Pids the fakes noted, of one kind: "probe", "run" or "child".
    func recordedPIDs(_ kind: String) -> [pid_t] {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ")
            return parts.count == 2 && parts[0] == kind ? pid_t(parts[1]) : nil
        }
    }

    func out() -> String { (try? String(contentsOf: outFile, encoding: .utf8)) ?? "" }
    func log() -> String { (try? String(contentsOf: logFile, encoding: .utf8)) ?? "" }

    /// Recorded processes that are still running.
    func leftovers() -> [pid_t] {
        ["probe", "run", "child"].flatMap(recordedPIDs).filter(isOurs)
    }

    /// Waits until every recorded process is gone (or `limit` passes); returns those still running.
    func waitForNoLeftovers(_ limit: Duration = .seconds(8)) async -> [pid_t] {
        let deadline = ContinuousClock.now + limit
        var left = leftovers()
        while !left.isEmpty && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            left = leftovers()
        }
        return left
    }

    /// Kills whatever a fake left running (a failing test must not leave processes behind) and removes the directory.
    /// A run whose consumer was cancelled finishes in the background (it ends its process, then removes its working
    /// directory), so the removal waits up to five seconds for the working directories to go.
    func cleanup() {
        for pid in leftovers() { _ = Darwin.kill(pid, SIGKILL) }
        let fm = FileManager.default
        let deadline = Date().addingTimeInterval(5)
        while ((try? fm.contentsOfDirectory(atPath: temporary.path))?.isEmpty == false) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        for _ in 0..<5 {
            if (try? fm.removeItem(at: root)) != nil || !fm.fileExists(atPath: root.path) { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// Running, started after this harness, and a shell or `sleep`: never another process that reused the id.
    private func isOurs(_ pid: pid_t) -> Bool {
        guard let identity = ProcessTree.identity(of: pid), identity.startTime >= createdAt, ProcessTree.isRunning(identity) else { return false }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        let path = String(cString: buffer)
        return path.hasPrefix("/bin/") || path.hasPrefix("/usr/bin/")
    }
}

struct FakeCLIError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// What a stream produced.
struct RunResult {
    var events: [LLMEvent] = []
    var error: LLMError?

    var text: String {
        events.compactMap { if case .textDelta(let text) = $0 { return text } else { return nil } }.joined()
    }
    var deltas: [String] {
        events.compactMap { if case .textDelta(let text) = $0 { return text } else { return nil } }
    }
    var statuses: [String] {
        events.compactMap { if case .status(let text) = $0 { return text } else { return nil } }
    }
    var finished: (StopReason, Usage?)? {
        for event in events { if case .finished(let stop, let usage) = event { return (stop, usage) } }
        return nil
    }
}

func collect(_ stream: AsyncThrowingStream<LLMEvent, Error>) async -> RunResult {
    var result = RunResult()
    do {
        for try await event in stream { result.events.append(event) }
    } catch {
        result.error = error as? LLMError ?? .malformedResponse("not an LLMError: \(error)")
    }
    return result
}

/// A request whose system and user texts carry markers that must never show up in a process's arguments.
func markedRequest(model: String? = nil, user: String = "USER-MARKER-7Q2 Please review.", pdf: Data? = nil) -> LLMRequest {
    var parts: [LLMPart] = []
    if let pdf { parts.append(.pdf(data: pdf, fileName: "manuscript.pdf")) }
    parts += [.cacheBoundary, .text(user)]
    return LLMRequest(model: model, system: "SYSTEM-MARKER-3K9 You are a referee.", parts: parts, purpose: .review)
}

let allAdapters: [any CLIAdapter] = [ClaudeCodeAdapter(), CodexAdapter(), AntigravityAdapter(), GrokBuildAdapter()]
