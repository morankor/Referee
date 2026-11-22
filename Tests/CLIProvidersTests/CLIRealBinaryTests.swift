import Foundation
import Testing
@testable import CLIProviders
import RefereeCore

/// The CLIs installed on this machine, as the app would find them. Only the commands the plan allows are run here:
/// `--version`, `--help`, `auth status`, `login status`, `debug prompt-input`. Nothing is sent to a model.
enum RealCLI {
    /// The app's environment, with working directories in the test's own temporary folder.
    static func host(temporary: URL, extra: [String: String] = [:]) -> CLIHost {
        var environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = temporary.path
        for (key, value) in extra { environment[key] = value }
        return CLIHost(processEnvironment: environment)
    }

    /// True when one of the spec's own candidates is an executable file (the PATH is not searched for this).
    static func installed(_ spec: CLISpec) -> Bool {
        let home = ProcessInfo.processInfo.environment["HOME"]
        for candidate in spec.candidates {
            guard let path = ChildEnvironment.expandTilde(candidate, home: home) else { continue }
            let paths = path.contains("*") ? BinaryResolver.globNewestFirst(path) : [path]
            if paths.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return true }
        }
        return false
    }

    static let claude = installed(ClaudeCodeAdapter().spec)
    static let codex = installed(CodexAdapter().spec)
    static let brokenHomebrewCodex = "/opt/homebrew/bin/codex"
}

/// Acceptance rows "real binaries" and "Codex tool list" (skipped when the CLI is absent).
@Suite(.timeLimit(.minutes(2))) struct CLIRealBinaryTests {
    @Test(.enabled(if: RealCLI.claude, "Claude Code is not installed in any of its candidate locations"))
    func claudeThroughTheResolver() async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        let host = RealCLI.host(temporary: harness.temporary)
        let binary = try await BinaryResolver(host: host).resolve(ClaudeCodeAdapter().spec, explicitPath: nil).get()
        #expect(binary.version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+"#, options: .regularExpression) != nil)
        // The flag check passes: every protected flag is in the installed version's help text.
        let provider = CLIProvider(adapter: ClaudeCodeAdapter(), environment: FakeCLIHarness.providerEnvironment(host.processEnvironment), host: host)
        #expect(provider.flagProblem(binary) == nil)
        // `claude auth status` parses (whatever it says; its account fields are not read).
        let status = await host.command(binary, ["auth", "status"], extraEnvironment: [:])
        guard case .success(let output) = status else {
            Issue.record("`claude auth status` did not run: \(status)")
            return
        }
        #expect(ClaudeCodeAdapter.parseAuthStatus(output.stdout) != nil, "`claude auth status` printed no readable status")
    }

    @Test(.enabled(if: RealCLI.codex, "Codex is not installed in any of its candidate locations"))
    func codexThroughTheResolver() async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        let host = RealCLI.host(temporary: harness.temporary)
        let binary = try await BinaryResolver(host: host).resolve(CodexAdapter().spec, explicitPath: nil).get()
        #expect(binary.version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+"#, options: .regularExpression) != nil)
        let provider = CLIProvider(adapter: CodexAdapter(), environment: FakeCLIHarness.providerEnvironment(host.processEnvironment), host: host)
        #expect(provider.flagProblem(binary) == nil)
        // `codex login status` parses: it prints one line (to stderr) and the adapter reads it either way.
        let status = await host.command(binary, ["login", "status"], extraEnvironment: [:])
        guard case .success(let output) = status else {
            Issue.record("`codex login status` did not run: \(status)")
            return
        }
        #expect(output.firstLine != nil)
        switch CodexAdapter.signInStatus(status, version: binary.version) {
        case .ready, .needsSetup: break
        case .unavailable(let reason): Issue.record("unexpected: \(reason)")
        }
    }

    /// The resolver does not pick a `codex` whose `--version` fails (on this machine the npm copy has lost its binary).
    @Test(.enabled(if: RealCLI.codex && FileManager.default.isExecutableFile(atPath: RealCLI.brokenHomebrewCodex),
                   "no codex at /opt/homebrew/bin to compare with"))
    func aCodexWhoseVersionFailsIsNotPicked() async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        let host = RealCLI.host(temporary: harness.temporary)
        let environment = await host.childEnvironment(extra: [:])
        let direct = await CLICommand.run(RealCLI.brokenHomebrewCodex, ["--version"], environment: environment,
                                          temporaryRoot: harness.temporary, timeout: .seconds(20))
        let broken: Bool
        if case .success(let output) = direct { broken = output.exitCode != 0 } else { broken = true }
        try #require(broken, "the codex at /opt/homebrew/bin works on this machine, so there is nothing to show")
        let binary = try await BinaryResolver(host: host).resolve(CodexAdapter().spec, explicitPath: nil).get()
        #expect(binary.path != RealCLI.brokenHomebrewCodex)
    }

    /// `codex debug prompt-input` with the adapter's `-c` and `--disable` arguments and an empty CODEX_HOME renders the
    /// model-visible tools without sending anything. In its `additional_tools` item: no shell, image, sleep, agent or
    /// MCP tool, and the `exec` tool's description documents none of the removed tools.
    @Test(.enabled(if: RealCLI.codex, "Codex is not installed in any of its candidate locations"))
    func codexToolList() async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        let codexHome = harness.root.appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let host = RealCLI.host(temporary: harness.temporary, extra: ["CODEX_HOME": codexHome.path])
        let binary = try await BinaryResolver(host: host).resolve(CodexAdapter().spec, explicitPath: nil).get()
        let arguments = ["debug", "prompt-input"] + CodexAdapter.toolRemovingArguments.flatMap(\.tokens)
        let rendered = await host.command(binary, arguments, extraEnvironment: [:])
        guard case .success(let output) = rendered, output.exitCode == 0 else {
            Issue.record("`codex debug prompt-input` failed: \(rendered)")
            return
        }
        let items = try #require(try JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [[String: Any]])
        let toolsItem = try #require(items.first { ($0["type"] as? String) == "additional_tools" })
        let tools = try #require(toolsItem["tools"] as? [[String: Any]])

        var names: [String] = []
        func collect(_ list: [[String: Any]]) {
            for tool in list {
                if let name = tool["name"] as? String { names.append(name) }
                if let nested = tool["tools"] as? [[String: Any]] { collect(nested) }
            }
        }
        collect(tools)
        #expect(!names.isEmpty)
        for removed in ["exec_command", "write_stdin", "view_image", "sleep", "spawn_agent"] {
            #expect(!names.contains(removed), "\(removed) is still offered")
        }
        #expect(!names.contains { $0.hasPrefix("mcp__") }, "an MCP tool is offered: \(names)")

        func find(_ name: String, in list: [[String: Any]]) -> [String: Any]? {
            for tool in list {
                if (tool["name"] as? String) == name { return tool }
                if let nested = tool["tools"] as? [[String: Any]], let found = find(name, in: nested) { return found }
            }
            return nil
        }
        let exec = try #require(find("exec", in: tools), "no exec tool in \(names)")
        let description = exec["description"] as? String ?? ""
        for heading in ["### `exec_command`", "### `write_stdin`", "### `view_image`"] {
            #expect(!description.contains(heading), "the exec tool still documents \(heading)")
        }
    }
}
