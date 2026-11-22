import Foundation

/// A compiled regular expression with the few calls this target needs. All offsets are UTF-16 (NSString), the unit of
/// `TextRange`.
struct Pattern: @unchecked Sendable {   // NSRegularExpression is immutable and safe to share between threads
    let regex: NSRegularExpression

    init(_ pattern: String, caseInsensitive: Bool = false) {
        // Every pattern is a literal of this file; a typo fails every test at once.
        regex = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    func first(in string: NSString, range: NSRange? = nil) -> NSTextCheckingResult? {
        regex.firstMatch(in: string as String, options: [], range: range ?? NSRange(location: 0, length: string.length))
    }

    func all(in string: NSString, range: NSRange? = nil) -> [NSTextCheckingResult] {
        regex.matches(in: string as String, options: [], range: range ?? NSRange(location: 0, length: string.length))
    }

    func matches(_ string: String) -> Bool { first(in: string as NSString) != nil }
}

extension NSTextCheckingResult {
    /// The text of capture group `group`, or nil when the group did not take part in the match.
    func group(_ group: Int, in string: NSString) -> String? {
        let r = range(at: group)
        return r.location == NSNotFound ? nil : string.substring(with: r)
    }
}

/// The regular expressions of plan.md section 8. Digits are written `[0-9]`: ICU's `\d` also matches the digits of
/// other scripts, which `Int(_:)` cannot read.
enum Patterns {
    /// §8.2 step 1; the trailing digits tolerate a margin number that was not stripped ("References 12").
    static let heading = Pattern(#"^\s*([0-9]+\.?\s+)?(references|bibliography|works cited|literature cited|reference list)\s*[0-9]{0,4}\s*$"#,
                                 caseInsensitive: true)
    /// §8.2 step 2, `NUM`: "[12]" or "12." at the start of a line.
    static let numberLabel = Pattern(#"^\s*(?:\[([0-9]{1,3})\]|([0-9]{1,3})\.)(?:\s|$)"#)
    /// The label at the start of a numeric entry's text, removed before parsing.
    static let leadingLabel = Pattern(#"^\s*(?:\[[0-9]{1,3}\]|[0-9]{1,3}\.)\s*"#)
    /// A year, with an optional letter suffix ("2019a"). The suffix is a single letter not followed by another letter,
    /// so in space-less text "2019and" is the year 2019 without a suffix.
    static let year = Pattern(#"(?<![0-9])((?:1[89]|20)[0-9]{2})(?:([a-z])(?![A-Za-z]))?(?![0-9])"#)
    /// §8.2 step 4: the words that make an entry without a year entry-like.
    static let status = Pattern(#"\b(?:forthcoming|in press|working paper|mimeo|unpublished|manuscript)\b|\bn\.d\."#, caseInsensitive: true)
    /// §8.2 step 5, `KEY`.
    static let keyword = Pattern(#"^(?:online |web |internet )?(?:appendix|appendices|supplementa(?:ry|l)\b.*|tables?|figures?|footnotes|endnotes)\b"#,
                                 caseInsensitive: true)
    /// §8.2 step 5 (a1): a lettered appendix heading ("A Proofs", "B.2 Data").
    static let letteredHeading = Pattern(#"^[A-Z](?:\.[0-9]+)?\.?\s+[A-Z]"#)
    /// A line that ends in a URL (§8.2 step 4, author–year lists that do not hang).
    static let urlAtEnd = Pattern(#"https?://\S+$"#, caseInsensitive: true)
    /// §8.1 (b): a token that starts a DOI.
    static let doiToken = Pattern(#"^(?:doi:)?10\.[0-9]{4,9}/"#, caseInsensitive: true)
    /// §8.3.
    static let doi = Pattern(#"10\.[0-9]{4,9}/[^\s"<>]+"#)
    static let arxivColon = Pattern(#"arXiv:\s*([0-9]{4}\.[0-9]{4,5})(?:v[0-9]+)?"#, caseInsensitive: true)
    static let arxivURL = Pattern(#"arxiv\.org/abs/([\w.\-/]+)"#, caseInsensitive: true)
    static let url = Pattern(#"https?://\S+"#, caseInsensitive: true)
    /// What is blanked out before looking for the year (§8.3): URLs, DOIs and arXiv ids.
    static let identifier = Pattern(#"https?://\S+|10\.[0-9]{4,9}/\S+|arXiv:\s*\S+"#, caseInsensitive: true)
    /// "et al." and everything after it, in an entry's author text.
    static let etAl = Pattern(#"\bet\.?\s*al\b.*$"#)
    /// §8.3 author pieces.
    static let initialsOnly = Pattern(#"^(?:\p{Lu}\.?[\s\-‐]*){1,4}$"#)
    static let springer = Pattern(#"^((?:\p{Ll}+\s+)*\p{Lu}[^\s\p{Lu}]+(?:\p{Lu}[^\s\p{Lu}]+)*)\s*((?:\p{Lu}\.?\s?){1,3})$"#)
    static let capitalisedWordInside = Pattern(#"\s\p{Lu}\p{Ll}"#)
    /// Given names written out ("Christopher", "Abhijit V", "Jean-Pierre"), possibly with initials. A hyphen is only
    /// ever a separator between names, so the pattern cannot backtrack exponentially on a long hyphenated piece.
    static let givenNames = Pattern(#"^(?:\p{Lu}\p{Ll}+(?:['’]\p{Lu}?\p{Ll}+)*|\p{Lu}\.?)(?:[\s\-]+(?:\p{Lu}\p{Ll}+(?:['’]\p{Lu}?\p{Ll}+)*|\p{Lu}\.?))*$"#)
    /// §8.4, numeric: one bracket of numbers and ranges.
    static let numericCitation = Pattern(#"\[([0-9]{1,3}(?:\s*[-–]\s*[0-9]{1,3})?(?:\s*[,;]\s*[0-9]{1,3}(?:\s*[-–]\s*[0-9]{1,3})?)*)\]"#)
    static let numericItem = Pattern(#"([0-9]{1,3})(?:\s*[-–]\s*([0-9]{1,3}))?"#)
}
