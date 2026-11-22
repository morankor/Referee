import Foundation

/// Joins the lines of a reference entry into its text (plan.md section 8.1): single spaces between lines, except
/// - when the last token so far contains "://" or starts a DOI and ends in one of / - _ . = &, the next line is
///   appended without a space (a DOI broken at a slash: "https://doi.org/10.3115/v1/" + "D14-1179");
/// - otherwise, a line ending in a hyphen after a letter, followed by a line that starts with a lower-case letter, is
///   joined without the hyphen ("Bikhchan-" + "dani").
/// The URL rule is checked first, so that a hyphen inside a broken DOI or URL is kept.
enum EntryText {
    static func join(_ lines: [String]) -> String {
        var text = ""
        var lastToken = ""
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if text.isEmpty {
                text = line
                lastToken = lastWhitespaceToken(of: line)
                continue
            }
            if continuesIdentifier(lastToken) {
                text += line
                lastToken = line.contains(where: \.isWhitespace) ? lastWhitespaceToken(of: line) : lastToken + line
            } else if endsInWordHyphen(text), let first = line.first, first.isLowercase {
                text.removeLast()
                text += line
                lastToken = line.contains(where: \.isWhitespace) ? lastWhitespaceToken(of: line) : String(lastToken.dropLast()) + line
            } else {
                text += " " + line
                lastToken = lastWhitespaceToken(of: line)
            }
        }
        return text
    }

    /// Whether the next line continues `token` without a space: a URL or DOI that ends in / - _ . = &.
    static func continuesIdentifier(_ token: String) -> Bool {
        guard let last = token.last, "/-_.=&".contains(last) else { return false }
        return token.contains("://") || Patterns.doiToken.matches(token)
    }

    static func endsInWordHyphen(_ text: String) -> Bool {
        guard text.last == "-" else { return false }
        return text.dropLast().last?.isLetter ?? false
    }

    private static func lastWhitespaceToken(of text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
    }
}
