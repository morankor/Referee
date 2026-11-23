import Foundation
import Testing
@testable import CLIProviders
import RefereeCore

/// An adapter with another binary spec (temporary candidates only), so that no real CLI on the machine is ever found.
struct SpecOverride: CLIAdapter {
    let base: any CLIAdapter
    let spec: CLISpec
    var descriptor: ProviderDescriptor { base.descriptor }
    var installHint: String { base.installHint }
    var protectedFlags: [String] { base.protectedFlags }
    var timeouts: CLITimeouts { base.timeouts }
    var extraEnvironment: [String: String] { base.extraEnvironment }
    var passedThroughNames: [String] { base.passedThroughNames }
    var pdfDelivery: CLIPDFDelivery { base.pdfDelivery }
    func argumentTable(workspace: URL, model: String?, delivery: CLIPDFDelivery) -> CLIArgumentTable {
        base.argumentTable(workspace: workspace, model: model, delivery: delivery)
    }
    func prepareInput(_ prompt: CLIPrompt, workspace: CLIWorkspace, delivery: CLIPDFDelivery) throws -> CLIRunInput {
        try base.prepareInput(prompt, workspace: workspace, delivery: delivery)
    }
    func makeSession(workspace: URL, delivery: CLIPDFDelivery, input: CLIRunInput) -> CLISession {
        base.makeSession(workspace: workspace, delivery: delivery, input: input)
    }
    func signInStatus(_ binary: ResolvedBinary, host: CLIHost) async -> ProviderAvailability { await base.signInStatus(binary, host: host) }
    func listModels(host: CLIHost, binary: @Sendable () async -> Result<ResolvedBinary, LLMError>) async throws -> [ModelInfo] {
        try await base.listModels(host: host, binary: binary)
    }
}

/// Acceptance rows "resolver order", "flag check", "availability" and "model lists".
@Suite(.timeLimit(.minutes(1))) struct CLIResolverTests {
    /// Candidates and PATH searched: only with specs whose name ("fakecli") and candidates exist nowhere but in the
    /// harness's temporary directory, so that no real CLI can be found.
    static func searching(_ host: CLIHost) -> CLIHost {
        var host = host
        host.searchesDefaultLocations = true
        return host
    }

    static func spec(candidates: [String]) -> CLISpec {
        CLISpec(name: "fakecli", candidates: candidates, versionArguments: ["--version"], helpArguments: [["--help"]],
                environmentOverride: "REFEREE_CLI_PATH_FAKECLI")
    }

    /// Explicit path beats the environment override beats the candidates beats the PATH; nothing → `.notConfigured`.
    @Test func resolutionOrder() async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        let explicit = harness.install.resolverEntry("v1")
        let override = harness.install.resolverEntry("v2")
        let candidate = harness.install.resolverEntry("v3")
        let pathDirectory = harness.install.resolver.appendingPathComponent("path", isDirectory: true)   // holds `fakecli`, 1.0.4

        func version(explicitPath: String?, override: String?, candidates: [String]) async -> Result<String, LLMError> {
            var environment = harness.processEnvironment()
            environment["REFEREE_CLI_PATH_FAKECLI"] = override
            var host = harness.host(environment)
            host.loginPath = .fixed(pathDirectory.path + ":" + FakeCLIHarness.fixedPath)
            host.searchesDefaultLocations = true      // safe: the name "fakecli" matches nothing real on the PATH
            let resolver = BinaryResolver(host: host)
            return await resolver.resolve(Self.spec(candidates: candidates), explicitPath: explicitPath).map(\.version)
        }
        #expect(await version(explicitPath: explicit, override: override, candidates: [candidate]) == .success("1.0.1"))
        #expect(await version(explicitPath: nil, override: override, candidates: [candidate]) == .success("1.0.2"))
        #expect(await version(explicitPath: nil, override: nil, candidates: [candidate]) == .success("1.0.3"))
        #expect(await version(explicitPath: nil, override: nil, candidates: []) == .success("1.0.4"))
        // A missing explicit path is passed over.
        #expect(await version(explicitPath: harness.root.appendingPathComponent("nope").path, override: nil, candidates: [candidate])
                == .success("1.0.3"))

        var environment = harness.processEnvironment()
        environment["REFEREE_CLI_PATH_FAKECLI"] = nil
        let resolver = BinaryResolver(host: Self.searching(harness.host(environment)))
        #expect(await resolver.resolve(Self.spec(candidates: [harness.root.appendingPathComponent("nope").path]), explicitPath: nil)
                == .failure(.notConfigured("fakecli is not installed")))
    }

    /// A candidate whose `--version` hangs is skipped after the timeout; one whose `--version` fails is skipped too.
    @Test func brokenCandidatesAreSkipped() async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        let hanging = harness.install.resolverEntry("hang-version")
        let failing = harness.install.resolverEntry("fail-version")
        let good = harness.install.resolverEntry("good")
        let home = try harness.makeHome([:])                    // so that the fakes record their pids
        let resolver = BinaryResolver(host: Self.searching(harness.host(harness.processEnvironment(home: home), probeTimeout: .seconds(1))))
        let started = ContinuousClock.now
        let result = await resolver.resolve(Self.spec(candidates: [hanging, failing, good]), explicitPath: nil)
        #expect(result.map(\.path) == .success(good))
        #expect(result.map(\.version) == .success("9.9.9"))
        let elapsed = ContinuousClock.now - started
        #expect(elapsed >= .seconds(1) && elapsed < .seconds(6))
        // The hung --version was killed with its `sleep`.
        #expect(await harness.waitForNoLeftovers(.seconds(2)).isEmpty)

        // Only broken candidates: the reason says the binary does not run.
        let none = await resolver.resolve(Self.spec(candidates: [failing]), explicitPath: nil)
        guard case .failure(.notConfigured(let reason)) = none else {
            Issue.record("expected .notConfigured, got \(none)")
            return
        }
        #expect(reason.hasPrefix("fakecli was found but does not run"))
    }

    @Test func theResultIsCachedUntilTheFileChanges() async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        // A binary of this test's own, so that it can be replaced (its first run is assessed by the system, which takes
        // a moment; the 20 s cap leaves room).
        func writeBinary(_ version: String) throws -> String {
            let url = harness.root.appendingPathComponent("replaceable")
            let script = "#!/bin/sh\nexport FAKE_VERSION_TEXT=\(version)\n[ -f \"$HOME/fake.env\" ] && . \"$HOME/fake.env\"\n"
                + "exec /bin/sh \(FakeCLIInstall.quote(harness.install.fakes.appendingPathComponent("claude").path)) \"$@\"\n"
            try? FileManager.default.removeItem(at: url)
            try Data(script.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url.path
        }
        let path = try writeBinary("1.0.0")
        let home = try harness.makeHome([:])
        let resolver = BinaryResolver(host: Self.searching(harness.host(harness.processEnvironment(home: home))))
        #expect(await resolver.resolve(Self.spec(candidates: [path]), explicitPath: nil).map(\.version) == .success("1.0.0"))
        let probes = harness.recordedPIDs("probe").count
        #expect(await resolver.resolve(Self.spec(candidates: [path]), explicitPath: nil).map(\.version) == .success("1.0.0"))
        #expect(harness.recordedPIDs("probe").count == probes)                     // nothing was run again
        // A reinstall (another file at the same path) is noticed.
        #expect(try writeBinary("2.0.0") == path)
        #expect(await resolver.resolve(Self.spec(candidates: [path]), explicitPath: nil).map(\.version) == .success("2.0.0"))
    }

    @Test func candidatesExpandTildeAndGlobsNewestFirst() async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        for version in ["2.1.99", "2.1.330", "2.1.327"] {
            let directory = harness.home.appendingPathComponent(".vscode/extensions/anthropic.claude-code-\(version)-darwin-arm64/resources/native-binary")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data().write(to: directory.appendingPathComponent("claude"))
        }
        // Paths are only listed here, never run.
        let resolver = BinaryResolver(host: Self.searching(harness.host(harness.processEnvironment())))
        let paths = await resolver.candidatePaths(ClaudeCodeAdapter().spec, explicitPath: "~/bin/claude", childPath: "/usr/bin:relative")
        let home = harness.home.path
        #expect(paths.first == home + "/bin/claude")
        let globbed = paths.filter { $0.contains(".vscode") }
        #expect(globbed == ["2.1.330", "2.1.327", "2.1.99"].map {
            home + "/.vscode/extensions/anthropic.claude-code-\($0)-darwin-arm64/resources/native-binary/claude"
        })
        #expect(paths.contains(home + "/.local/bin/claude"))
        #expect(paths.last == "/usr/bin/claude")                                    // the relative PATH entry is ignored
    }

    // MARK: Flag check

    static let missingFlag = ["claude": "--strict-mcp-config", "codex": "--ignore-rules", "agy": "--sandbox", "grok": "--disallowed-tools"]
    static let versions = ["claude": "2.1.330", "codex": "0.167.0-alpha.3.2", "agy": "1.7.2", "grok": "0.1.0"]

    /// A help text without a protected flag makes the provider unavailable, naming the flag; `stream` throws without
    /// starting the CLI.
    @Test(arguments: allAdapters.map(\.spec.name))
    func flagCheck(cli: String) async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        let adapter = try #require(allAdapters.first { $0.spec.name == cli })
        let provider = try harness.provider(adapter, ["FAKE_HELP": "missing-flag"])
        let flag = try #require(Self.missingFlag[cli])
        let reason = "\(cli) \(Self.versions[cli]!) does not list the option \(flag), which the app needs in order to run it safely"
        #expect(await provider.availability() == .unavailable(reason: reason))
        let result = await collect(provider.stream(markedRequest()))
        #expect(result.error == .notConfigured(reason))
        #expect(harness.recordedPIDs("run").isEmpty)
        // With the full help text the same provider passes.
        let healthy = try harness.provider(adapter, [:])
        if case .unavailable(let other) = await healthy.availability() { Issue.record("unexpectedly unavailable: \(other)") }
    }

    @Test func grokWithoutAgentStdioIsUnavailable() async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        let provider = try harness.provider(GrokBuildAdapter(), ["FAKE_HELP": "no-stdio"])
        guard case .unavailable(let reason) = await provider.availability() else {
            Issue.record("grok without `agent stdio` is not unavailable")
            return
        }
        #expect(reason.contains("`grok agent stdio --help` exited with 2"))
    }

    @Test func wholeWordsOnly() {
        #expect(CLIArguments.containsWholeWord("--tools", in: "  --tools <tools...>  Built-in tools"))
        #expect(CLIArguments.containsWholeWord("--disallowedTools", in: "--disallowedTools, --disallowed-tools <tools...>"))
        #expect(!CLIArguments.containsWholeWord("--tools", in: "--toolset <x>"))
        #expect(!CLIArguments.containsWholeWord("--disable", in: "--disable-slash-commands"))
        #expect(!CLIArguments.containsWholeWord("--sandbox", in: "--no--sandbox-x"))
        #expect(CLIArguments.containsWholeWord("--mode", in: "--mode=<mode>"))
        #expect(CLIArguments.firstMissingFlag(["--a", "--b"], in: "--a only") == "--b")
    }

    // MARK: Availability

    @Test func claudeSignInStates() async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        let ready = try harness.provider(ClaudeCodeAdapter(), ["FAKE_AUTH": "subscription"])
        #expect(await ready.availability() == .ready(detail: "Logged in · claude 2.1.330"))
        let apiKey = try harness.provider(ClaudeCodeAdapter(), ["FAKE_AUTH": "apikey"])
        #expect(await apiKey.availability() == .needsSetup(reason: "Claude Code is signed in with an API key, not a subscription",
                                                          hint: "Run `claude` and use /login"))
        let out = try harness.provider(ClaudeCodeAdapter(), ["FAKE_AUTH": "loggedout"])
        #expect(await out.availability() == .needsSetup(reason: "Claude Code is not signed in", hint: "Run `claude` in Terminal and use /login"))
    }

    @Test func codexSignInStates() async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        let ready = try harness.provider(CodexAdapter(), ["FAKE_LOGIN": "chatgpt"])
        #expect(await ready.availability() == .ready(detail: "Logged in using ChatGPT · codex 0.167.0-alpha.3.2"))
        for login in ["apikey", "out"] {
            let provider = try harness.provider(CodexAdapter(), ["FAKE_LOGIN": login])
            #expect(await provider.availability() == .needsSetup(reason: "Codex is not signed in with ChatGPT", hint: "Run `codex login`"))
        }
    }

    @Test func experimentalCLIsAreReadyWhenInstalled() async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        for adapter in [AntigravityAdapter() as any CLIAdapter, GrokBuildAdapter()] {
            let provider = try harness.provider(adapter, [:])
            #expect(await provider.availability() == .ready(detail: "installed; sign-in is checked on first use"))
        }
    }

    @Test(arguments: allAdapters.map(\.spec.name))
    func notInstalledNeedsSetupWithTheInstallCommand(cli: String) async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        let adapter = try #require(allAdapters.first { $0.spec.name == cli })
        let missing = SpecOverride(base: adapter, spec: CLISpec(name: cli, candidates: [harness.root.appendingPathComponent("absent").path],
                                                                versionArguments: ["--version"], helpArguments: [["--help"]],
                                                                environmentOverride: "REFEREE_CLI_PATH_UNUSED"))
        var host = harness.host(harness.processEnvironment())
        host.loginPath = .fixed(harness.root.appendingPathComponent("empty-path").path)
        let provider = CLIProvider(adapter: missing, environment: FakeCLIHarness.providerEnvironment(harness.processEnvironment()), host: host)
        let installs = ["claude": "curl -fsSL https://claude.ai/install.sh | bash", "codex": "npm install -g @openai/codex",
                        "agy": "curl -fsSL https://antigravity.google/cli/install.sh | bash", "grok": "curl -fsSL https://x.ai/cli/install.sh | bash"]
        let availability = await provider.availability()
        guard case .needsSetup(let reason, let hint) = availability else {
            Issue.record("expected .needsSetup, got \(availability)")
            return
        }
        #expect(hint == installs[cli])
        #expect(reason == "\(cli) is not installed")
        guard case .notConfigured? = await collect(provider.stream(markedRequest())).error else {
            Issue.record("a stream without a binary did not fail with .notConfigured")
            return
        }
    }

    // MARK: Model lists

    @Test func codexModelsFromTheRecordedList() throws {
        let models = try #require(CodexAdapter.parseModels(AppendixD.codexDebugModels, pageImages: false))
        #expect(models.map(\.id) == ["gpt-6.2-sol", "gpt-6.2-astra", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-astra", "gpt-6-sol",
                                     "gpt-6-luna", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"])
        #expect(models.first == ModelInfo(id: "gpt-6.2-sol", displayName: "GPT-6.2-Sol", contextWindow: 500_000))
        #expect(models.allSatisfy { $0.contextWindow != nil && $0.supportsPDFInput == nil })
        let withImages = try #require(CodexAdapter.parseModels(AppendixD.codexDebugModels, pageImages: true))
        #expect(withImages.allSatisfy { $0.supportsPDFInput == true })
        #expect(CodexAdapter.parseModels("not json", pageImages: false) == nil)
    }

    @Test func codexModelsThroughTheCLIWithTheBundledFallback() async throws {
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        let live = try harness.provider(CodexAdapter(), [:])
        #expect(try await live.listModels().count == 10)
        let fallback = try harness.provider(CodexAdapter(), ["FAKE_MODELS": "fail"])
        #expect(try await fallback.listModels().map(\.id).first == "gpt-6.2-sol")
    }

    @Test func antigravityModelsFromTheDocumentedText() async throws {
        #expect(AntigravityAdapter.parseModels(AppendixD.agyModels) == [
            ModelInfo(id: "gemini-4-neon-high", displayName: "Gemini 4 Neon (High)"),
            ModelInfo(id: "gemini-4-neon-low", displayName: "Gemini 4 Neon (Low)"),
            ModelInfo(id: "gemini-4-flash", displayName: "Gemini 4 Flash"),
        ])
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        #expect(try await harness.provider(AntigravityAdapter(), [:]).listModels().count == 3)
    }

    @Test func grokAndClaudeModels() async throws {
        #expect(GrokBuildAdapter.parseModels(AppendixD.grokModels).map(\.id) == ["grok-code-fast-1", "grok-4.2"])
        #expect(GrokBuildAdapter.parseModels("Available models:\ngrok-4\n\ngrok-4\n").map(\.id) == ["grok-4"])
        let harness = try FakeCLIHarness()
        defer { harness.cleanup() }
        let claude = try await harness.provider(ClaudeCodeAdapter(), [:]).listModels()
        #expect(claude.map(\.id) == ["default", "opus", "sonnet", "haiku", "fable"])
        #expect(claude.allSatisfy { $0.contextWindow == nil })
        #expect(harness.recordedPIDs("probe").isEmpty)                              // no CLI call for Claude's aliases
    }
}
