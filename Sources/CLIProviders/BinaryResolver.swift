import Foundation
import Darwin
import RefereeCore

// Finding and validating the binary (plan.md section 5.6.1).

struct CLISpec: Sendable {
    let name: String                  // "claude"
    let candidates: [String]          // absolute paths or globs, ~ expanded, in priority order
    let versionArguments: [String]    // ["--version"]
    let helpArguments: [[String]]     // [["--help"]]: the first one's output is searched by the flag check; every one must exit 0
    let environmentOverride: String   // "REFEREE_CLI_PATH_CLAUDE": tests and power users
}

struct ResolvedBinary: Sendable, Equatable {
    let path: String
    let version: String
    let helpText: String              // stdout and stderr of the first help command
    /// A help command that did not exit 0 in time, as "`grok agent stdio --help` exited with 2"; nil when all did.
    var helpFailure: String? = nil
}

actor BinaryResolver {
    /// What identifies a version of the file on disk: a reinstall changes at least one of these.
    private struct FileKey: Equatable {
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let inode: UInt64
        let size: Int64
    }

    private enum Validation {
        case valid(ResolvedBinary)
        case invalid(String)          // why its version command failed
    }
    private struct CacheEntry {
        let key: FileKey
        let validation: Validation
        let at: Date
    }

    private let host: CLIHost
    private let extraEnvironment: [String: String]
    private var cache: [String: CacheEntry] = [:]
    /// A failed validation is tried again after this long even if the file did not change (a busy machine can make a
    /// healthy binary miss the version deadline).
    private let failureLifetime: TimeInterval = 300

    init(host: CLIHost, extraEnvironment: [String: String] = [:]) {
        self.host = host
        self.extraEnvironment = extraEnvironment
    }

    /// Order: (1) the explicit path, (2) the environment override, (3) the spec's candidates, (4) the PATH of the
    /// child (the login shell's PATH and the fallbacks). The first that exists, is executable and answers its version
    /// command in time with exit code 0 wins; its help commands are then run and kept for the flag check.
    func resolve(_ spec: CLISpec, explicitPath: String?) async -> Result<ResolvedBinary, LLMError> {
        let environment = await host.childEnvironment(extra: extraEnvironment)
        var failures: [String] = []
        for path in candidatePaths(spec, explicitPath: explicitPath, childPath: environment["PATH"] ?? "") {
            guard let key = Self.fileKey(path) else { continue }
            if let entry = cache[path], entry.key == key {
                switch entry.validation {
                case .valid(let binary): return .success(binary)
                case .invalid(let reason) where Date().timeIntervalSince(entry.at) < failureLifetime:
                    failures.append(reason)
                    continue
                case .invalid: break
                }
            }
            let validation = await validate(spec, path: path, environment: environment)
            cache[path] = CacheEntry(key: key, validation: validation, at: Date())
            switch validation {
            case .valid(let binary): return .success(binary)
            case .invalid(let reason): failures.append(reason)
            }
        }
        if let first = failures.first {
            return .failure(.notConfigured("\(spec.name) was found but does not run (\(first)); reinstall it"))
        }
        return .failure(.notConfigured("\(spec.name) is not installed"))
    }

    /// Every place to look, in order, without duplicates; `~` is expanded with the app's HOME and globs are expanded
    /// newest version first.
    func candidatePaths(_ spec: CLISpec, explicitPath: String?, childPath: String) -> [String] {
        let home = host.processEnvironment["HOME"]
        var result: [String] = []
        func add(_ raw: String?) {
            guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
                  let path = ChildEnvironment.expandTilde(raw, home: home), path.hasPrefix("/"), !result.contains(path) else { return }
            result.append(path)
        }
        add(explicitPath)
        add(host.processEnvironment[spec.environmentOverride])
        for candidate in spec.candidates {
            if candidate.contains("*") {
                guard let pattern = ChildEnvironment.expandTilde(candidate, home: home) else { continue }
                for match in Self.globNewestFirst(pattern) { add(match) }
            } else {
                add(candidate)
            }
        }
        for directory in childPath.split(separator: ":") where directory.hasPrefix("/") {
            add(directory + "/" + spec.name)
        }
        return result
    }

    private func validate(_ spec: CLISpec, path: String, environment: [String: String]) async -> Validation {
        let version = await CLICommand.run(path, spec.versionArguments, environment: environment, temporaryRoot: host.temporaryRoot,
                                           timeout: host.probeTimeout)
        let output: CommandResult
        switch version {
        case .failure(.cliTimeout):
            return .invalid("\(spec.versionArguments.joined(separator: " ")) did not answer within \(Self.seconds(host.probeTimeout)) s")
        case .failure(let error):
            return .invalid(error.userMessage)
        case .success(let result) where result.exitCode != 0:
            return .invalid("\(spec.versionArguments.joined(separator: " ")) exited with \(result.exitCode)")
        case .success(let result):
            output = result
        }
        var helpText = ""
        var helpFailure: String?
        for (index, arguments) in spec.helpArguments.enumerated() {
            let shown = "`" + ([spec.name] + arguments).joined(separator: " ") + "`"
            switch await CLICommand.run(path, arguments, environment: environment, temporaryRoot: host.temporaryRoot,
                                        timeout: host.probeTimeout) {
            case .success(let result) where result.exitCode == 0:
                if index == 0 { helpText = result.stdout + "\n" + result.stderr }
            case .success(let result):
                if helpFailure == nil { helpFailure = "\(shown) exited with \(result.exitCode)" }
            case .failure:
                if helpFailure == nil { helpFailure = "\(shown) did not answer" }
            }
        }
        return .valid(ResolvedBinary(path: path, version: Self.versionNumber(in: output), helpText: helpText, helpFailure: helpFailure))
    }

    // MARK: - Helpers

    /// "2.1.330 (Claude Code)" → "2.1.330"; "codex-cli 0.167.0-alpha.3.2" → "0.167.0-alpha.3.2".
    static func versionNumber(in output: CommandResult) -> String {
        guard let line = output.firstLine else { return "unknown version" }
        let pattern = #"[0-9]+(\.[0-9]+)+([-+][0-9A-Za-z.+-]+)?"#
        if let range = line.range(of: pattern, options: .regularExpression) { return String(line[range]) }
        return String(line.prefix(40))
    }

    /// Follows symbolic links; nil unless the path is an executable regular file.
    private static func fileKey(_ path: String) -> FileKey? {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, access(path, X_OK) == 0 else { return nil }
        return FileKey(modifiedSeconds: Int(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int(info.st_mtimespec.tv_nsec),
                       inode: UInt64(info.st_ino), size: Int64(info.st_size))
    }

    static func globNewestFirst(_ pattern: String) -> [String] {
        var matches = glob_t()
        defer { globfree(&matches) }
        guard glob(pattern, 0, nil, &matches) == 0 else { return [] }
        var paths: [String] = []
        for index in 0..<Int(matches.gl_matchc) {
            if let entry = matches.gl_pathv[index] { paths.append(String(cString: entry)) }
        }
        return paths.sorted { naturalOrder($1, $0) }
    }

    /// Compares runs of digits as numbers, so that "2.1.330" sorts after "2.1.99".
    static func naturalOrder(_ a: String, _ b: String) -> Bool {
        func runs(_ s: String) -> [String] {
            var result: [String] = []
            var current = ""
            var digits = false
            for character in s {
                let isDigit = character.isASCII && character.isNumber
                if !current.isEmpty && isDigit != digits {
                    result.append(current)
                    current = ""
                }
                digits = isDigit
                current.append(character)
            }
            if !current.isEmpty { result.append(current) }
            return result
        }
        let left = runs(a), right = runs(b)
        for (l, r) in zip(left, right) where l != r {
            if let x = Int(l), let y = Int(r) { return x < y }
            return l < r
        }
        return left.count < right.count
    }

    private static func seconds(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
