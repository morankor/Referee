import Foundation

/// The command line of plan.md section 10.2, parsed by hand: a subcommand, its positional arguments, its options.
struct CLIOptions {
    static let usage = """
    usage: referee-cli <command> [arguments] [--home <dir>] [--use-keychain]

      providers [--json]                                   availability of every provider (no tokens spent)
      dump-raw <pdf>                                       RawDocument JSON
      extract <pdf> [--pages A-B] [--stats]                the text a model would receive; --stats: line kinds per page,
                                                           margin-number ranges, lines numbered in step 6 of section 7.2
      anchor <pdf> --quote <text> [--page N] [--json]      confidence and label; exit 0 found, 1 not found
      citations <pdf> [--json]                             style, entries, mentions (text and link counts)
      plan <pdf> --provider <id> [--model <m>]             the SendPlan
      review <pdf> --provider <id> [--model <m>] [--mode auto|text|pdf] [--context <tokens>] [--json]
      ask <pdf> --provider <id> [--model <m>] --question <text> [--quote <text>]

      --home <dir>     data folder (REFEREE_HOME); default: a temporary folder, removed at the end
      --use-keychain   read API keys from the Keychain as the app does; default: REFEREE_KEY_* variables only

    exit codes: 0 success; 1 the job failed (or, for anchor, the quote was not found); 2 usage error;
                3 the provider is not configured or not available
    """

    /// Options that take a value, and flags, per command; the two global options are accepted everywhere.
    private static let valued: [String: Set<String>] = [
        "providers": [], "dump-raw": [], "extract": ["--pages"], "anchor": ["--quote", "--page"], "citations": [],
        "plan": ["--provider", "--model", "--mode", "--context"],
        "review": ["--provider", "--model", "--mode", "--context"],
        "ask": ["--provider", "--model", "--question", "--quote", "--mode", "--context"],
    ]
    private static let flags: [String: Set<String>] = [
        "providers": ["--json"], "dump-raw": [], "extract": ["--stats"], "anchor": ["--json"], "citations": ["--json"],
        "plan": [], "review": ["--json"], "ask": [],
    ]
    private static let positionals: [String: Int] = [
        "providers": 0, "dump-raw": 1, "extract": 1, "anchor": 1, "citations": 1, "plan": 1, "review": 1, "ask": 1,
    ]

    let command: String
    let positional: [String]
    let values: [String: String]
    let setFlags: Set<String>
    let home: String?
    let useKeychain: Bool

    struct UsageError: Error { let message: String }

    init(_ arguments: [String]) throws {
        guard let command = arguments.first else { throw UsageError(message: "no command given") }
        guard let valued = Self.valued[command], let flags = Self.flags[command], let count = Self.positionals[command] else {
            throw UsageError(message: "unknown command \(command)")
        }
        var positional: [String] = []
        var values: [String: String] = [:]
        var setFlags: Set<String> = []
        var home: String?
        var useKeychain = false
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--home" || valued.contains(argument) {
                guard index + 1 < arguments.count else { throw UsageError(message: "\(argument) needs a value") }
                if argument == "--home" { home = arguments[index + 1] } else { values[argument] = arguments[index + 1] }
                index += 2
                continue
            }
            if argument == "--use-keychain" {
                useKeychain = true
            } else if flags.contains(argument) {
                setFlags.insert(argument)
            } else if argument.hasPrefix("--") {
                throw UsageError(message: "\(command) does not take \(argument)")
            } else {
                positional.append(argument)
            }
            index += 1
        }
        guard positional.count == count else {
            throw UsageError(message: count == 0 ? "\(command) takes no file" : "\(command) needs one PDF file")
        }
        self.command = command
        self.positional = positional
        self.values = values
        self.setFlags = setFlags
        self.home = home
        self.useKeychain = useKeychain
    }

    var pdfPath: String { positional[0] }
    func value(_ name: String) -> String? { values[name] }
    func flag(_ name: String) -> Bool { setFlags.contains(name) }

    func required(_ name: String) throws -> String {
        guard let value = values[name], !value.isEmpty else { throw UsageError(message: "\(command) needs \(name)") }
        return value
    }

    /// "3" → 2..<3; "2-4" → 1..<4 (pages are 1-based and inclusive on the command line).
    static func pageRange(_ text: String, pageCount: Int) throws -> Range<Int> {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard (1...2).contains(parts.count), let first = parts.first ?? nil, let last = parts.last ?? nil,
              first >= 1, last >= first, last <= pageCount else {
            throw UsageError(message: "--pages must be N or A-B with 1 ≤ A ≤ B ≤ \(pageCount)")
        }
        return (first - 1)..<last
    }
}
