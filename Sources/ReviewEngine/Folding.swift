import Foundation

/// The folding of plan.md section 6.7, which the engine needs for its own comparisons (repeated comments, empty
/// suggestions, category names). PaperText has the matcher's copy; implementation targets do not import each other.
///
/// Compatibility decomposition (NFKD), then only letters and decimal digits survive, lower-cased. Whitespace, hyphens
/// and dashes, quotation marks, punctuation, symbols and combining marks fold to nothing, so "office-specific",
/// "office- specific" and "Office specific" fold alike, and so do "N/A" and "na".
enum Folding {
    static func fold(_ text: String) -> String {
        var folded = String.UnicodeScalarView()
        for scalar in text.decomposedStringWithCompatibilityMapping.lowercased().unicodeScalars {
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber:
                folded.append(scalar)
            default:
                continue
            }
        }
        return String(folded)
    }
}
