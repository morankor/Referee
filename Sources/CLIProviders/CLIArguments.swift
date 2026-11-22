import Foundation
import RefereeCore

/// One element of an argument table: a flag with its values (`["--sandbox", "read-only"]`), protected or not
/// (plan.md section 5.6.3). Protected elements remove tools, select a sandbox or permission mode, isolate the CLI from
/// the user's configuration, or keep the manuscript out of session files.
struct CLIArgument: Sendable, Equatable {
    var tokens: [String]
    var isProtected: Bool

    static func protected(_ tokens: String...) -> CLIArgument { CLIArgument(tokens: tokens, isProtected: true) }
    static func plain(_ tokens: String...) -> CLIArgument { CLIArgument(tokens: tokens, isProtected: false) }

    /// The flag's name: the first token, up to an "=" (`--mode=accept-edits` → `--mode`).
    var flagName: String {
        let first = tokens.first ?? ""
        return first.split(separator: "=", maxSplits: 1).first.map(String.init) ?? first
    }
}

/// An adapter's table for one run. `extraArguments` go between `leading` and `trailing` (Grok Build's `agent stdio`
/// stays last); the model flag goes right after `leading`.
struct CLIArgumentTable: Sendable, Equatable {
    var leading: [CLIArgument]
    var model: [String] = []
    var trailing: [CLIArgument] = []
}

struct CLIArgumentList: Sendable, Equatable {
    var arguments: [String]
    var statuses: [String]          // emitted as `.status` before the run starts
}

enum CLIArguments {
    /// The table, then the model flag, then `extraArguments` verbatim, then the trailing elements. An extra argument
    /// "!X" is not passed: it removes the unprotected table element whose flag is X (or whose tokens joined by spaces
    /// are X). A "!" that names a protected element removes nothing and gives the status "ignored: X cannot be removed";
    /// one that names nothing in the table gives "ignored: X is not a default argument".
    static func build(_ table: CLIArgumentTable, extraArguments: [String]) -> CLIArgumentList {
        var leading = table.leading
        var trailing = table.trailing
        var extra: [String] = []
        var statuses: [String] = []
        for argument in extraArguments {
            guard argument.hasPrefix("!") else {
                extra.append(argument)
                continue
            }
            let name = String(argument.dropFirst()).trimmingCharacters(in: .whitespaces)
            func matches(_ element: CLIArgument) -> Bool {
                !name.isEmpty && (element.flagName == name || element.tokens.joined(separator: " ") == name)
            }
            let matched = (leading + trailing).filter(matches)
            if matched.isEmpty {
                statuses.append("ignored: \(name.isEmpty ? "!" : name) is not a default argument")
            } else if matched.contains(where: \.isProtected) {
                statuses.append("ignored: \(name) cannot be removed")
            } else {
                leading.removeAll(where: matches)
                trailing.removeAll(where: matches)
            }
        }
        let arguments = leading.flatMap(\.tokens) + table.model + extra + trailing.flatMap(\.tokens)
        return CLIArgumentList(arguments: arguments, statuses: statuses)
    }

    /// The first protected flag that `help` does not list as a whole word, or nil (plan.md section 5.6.1).
    static func firstMissingFlag(_ flags: [String], in help: String) -> String? {
        flags.first { !containsWholeWord($0, in: help) }
    }

    /// True when `word` occurs in `text` with neither a letter, a digit, "_" nor "-" right before or after it.
    static func containsWholeWord(_ word: String, in text: String) -> Bool {
        guard !word.isEmpty else { return true }
        func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "-" }
        var searchStart = text.startIndex
        while let range = text.range(of: word, range: searchStart..<text.endIndex) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            if !(before.map(isWordCharacter) ?? false) && !(after.map(isWordCharacter) ?? false) { return true }
            searchStart = text.index(after: range.lowerBound)
        }
        return false
    }

    /// A model id is passed as one argument after its flag; anything that could be read as a flag or that is not one
    /// printable token is refused.
    static func checkedModel(_ model: String?) throws -> String? {
        guard let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else { return nil }
        let printable = model.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value != 0x7F }
        guard printable, !model.hasPrefix("-"), model.count <= 200 else {
            throw LLMError.invalidRequest("the model id \"\(model.prefix(60))\" cannot be passed to a command-line tool")
        }
        return model
    }
}
