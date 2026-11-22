import Foundation
import RefereeCore

/// An `LLMRequest` as a CLI receives it: one system text, one user text, at most one PDF.
struct CLIPrompt: Sendable, Equatable {
    var system: String
    var user: String
    var pdf: Data?

    /// Text parts are joined with a blank line; `.cacheBoundary` is a hint for HTTP providers and is dropped here.
    /// More than one PDF is refused.
    init(_ request: LLMRequest) throws {
        system = request.system
        var texts: [String] = []
        var pdf: Data?
        for part in request.parts {
            switch part {
            case .text(let text): texts.append(text)
            case .cacheBoundary: continue
            case .pdf(let data, _):
                if pdf != nil { throw LLMError.invalidRequest("a command-line tool takes one pdf document per request") }
                pdf = data
            }
        }
        user = texts.joined(separator: "\n\n")
        self.pdf = pdf
    }

    init(system: String, user: String, pdf: Data? = nil) {
        self.system = system; self.user = user; self.pdf = pdf
    }

    /// The form for CLIs without a system-prompt option (plan.md section 5.6.3). With no system text the user text is
    /// sent alone.
    static func inline(system: String, user: String) -> String {
        guard !system.isEmpty else { return user }
        return "<<SYSTEM INSTRUCTIONS>>\n\(system)\n<<END SYSTEM INSTRUCTIONS>>\n\n\(user)"
    }
}

/// Small helpers for the JSON lines the CLIs print. Every parser treats a line that is not a JSON object as noise.
enum JSONLine {
    static func object(_ line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return value as? [String: Any]
    }

    /// One JSON value on one line, keys sorted, slashes not escaped, followed by a line break.
    static func encode(_ value: Any) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.intValue }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
        return nil
    }

    /// A short description for a tripwire message: never more than 120 characters.
    static func short(_ text: String) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ")
        return single.count > 120 ? String(single.prefix(117)) + "…" : single
    }
}
