import Foundation
import RefereeCore

/// The environment of a CLI child process, built from scratch (plan.md section 5.6.2).
enum ChildEnvironment {
    /// Copied from the app's environment when present.
    static let copiedNames = ["HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "TMPDIR", "SHELL", "SSH_AUTH_SOCK", "CLAUDE_CONFIG_DIR",
                              "CODEX_HOME", "XDG_CONFIG_HOME", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY"]

    /// Never copied, so that the subscription login is what authenticates. None of them is in `copiedNames`; the set is
    /// checked again on the finished environment, so that no future edit of either list can let one through.
    static let neverCopiedNames: Set<String> = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_MODEL", "ANTHROPIC_PROFILE",
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "OPENAI_API_KEY", "OPENAI_BASE_URL",
        "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_GEMINI_BASE_URL", "XAI_API_KEY",
    ]

    /// Appended to the login shell's PATH for anything it lacks. npm-installed CLIs are `#!/usr/bin/env node` scripts.
    static let fallbackPath = ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    static func make(from app: [String: String], loginPath: String?, extra: [String: String] = [:]) -> [String: String] {
        var environment: [String: String] = [:]
        for name in copiedNames {
            if let value = app[name], !value.isEmpty { environment[name] = value }
        }
        environment["PATH"] = path(loginPath: loginPath, home: app["HOME"])
        environment["TERM"] = "dumb"
        environment["NO_COLOR"] = "1"
        for (name, value) in extra { environment[name] = value }
        for name in neverCopiedNames { environment[name] = nil }
        return environment
    }

    static func path(loginPath: String?, home: String?) -> String {
        var entries: [String] = []
        for entry in (loginPath ?? "").split(separator: ":").map(String.init) where !entry.isEmpty && !entries.contains(entry) {
            entries.append(entry)
        }
        for entry in fallbackPath {
            guard let expanded = expandTilde(entry, home: home), !entries.contains(expanded) else { continue }
            entries.append(expanded)
        }
        return entries.joined(separator: ":")
    }

    /// "~/x" → "<home>/x"; nil when the path needs a home directory and there is none.
    static func expandTilde(_ path: String, home: String?) -> String? {
        if path == "~" { return home.flatMap { $0.isEmpty ? nil : $0 } }
        guard path.hasPrefix("~/") else { return path }
        guard let home, !home.isEmpty else { return nil }
        return (home.hasSuffix("/") ? String(home.dropLast()) : home) + "/" + path.dropFirst(2)
    }
}

/// Where the PATH of the child comes from.
enum LoginPathSource: Sendable {
    /// `/bin/zsh -l -c 'printf %s "$PATH"'`, run once per home directory with a 5 s cap (the app's case).
    case loginShell
    /// A fixed value (tests); nil = only the fallback list.
    case fixed(String?)
}

/// The login shell's PATH, computed once per home directory and process.
final class LoginShellPath: @unchecked Sendable {
    static let shared = LoginShellPath()

    private let lock = NSLock()
    private var cache: [String: String?] = [:]

    func path(for app: [String: String], temporaryRoot: URL, timeout: Duration = .seconds(5)) async -> String? {
        let key = app["HOME"] ?? ""
        if let cached = lock.withLock({ cache[key] }) { return cached }
        let value = await compute(app: app, temporaryRoot: temporaryRoot, timeout: timeout)
        lock.withLock { cache[key] = value }
        return value
    }

    /// The marker keeps whatever a profile script prints out of the result. Non-interactive, so `.zshrc` is not read
    /// and nothing can prompt; stdin is empty.
    private func compute(app: [String: String], temporaryRoot: URL, timeout: Duration) async -> String? {
        let marker = "__REFEREE_PATH__"
        var environment: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "dumb"]
        for name in ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL"] {
            if let value = app[name], !value.isEmpty { environment[name] = value }
        }
        let result = await CLICommand.run("/bin/zsh", ["-l", "-c", "printf '\\n\(marker)%s' \"$PATH\""], environment: environment,
                                          temporaryRoot: temporaryRoot, timeout: timeout)
        guard case .success(let output) = result, output.exitCode == 0,
              let range = output.stdout.range(of: marker, options: .backwards) else { return nil }
        let path = output.stdout[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
