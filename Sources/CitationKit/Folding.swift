import Foundation

/// The folding of plan.md section 6.7, which this target uses wherever a name has to be recognised: each Unicode scalar
/// is decomposed (NFKD, which also expands ligatures and maps µ to μ, superscript digits and mathematical letters to
/// plain ones) and only letters and digits are kept, lower-cased. Spaces, line breaks, hyphens, brackets and all other
/// punctuation fold to nothing, so "Bikhchan-\ndani" and "Bikhchandani" fold alike.
///
/// Folded text is kept as arrays of scalar values: comparing their tails is all the matching needs.
enum Folding {
    static func isLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    static func isUppercase(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .titlecaseLetter: return true
        default: return false
        }
    }

    /// Appends the folding of one scalar (zero or more scalar values) to `out`.
    static func fold(_ scalar: Unicode.Scalar, into out: inout [UInt32]) {
        let value = scalar.value
        if value < 0x80 {                                   // ASCII, nearly all of the text
            switch value {
            case 0x30...0x39, 0x61...0x7A: out.append(value)
            case 0x41...0x5A: out.append(value + 0x20)
            default: break
            }
            return
        }
        for decomposed in String(Character(scalar)).decomposedStringWithCompatibilityMapping.unicodeScalars where isLetterOrDigit(decomposed) {
            for lower in decomposed.properties.lowercaseMapping.unicodeScalars where isLetterOrDigit(lower) {
                out.append(lower.value)
            }
        }
    }

    static func fold(_ string: String) -> [UInt32] {
        var out: [UInt32] = []
        out.reserveCapacity(string.utf16.count)
        for scalar in string.unicodeScalars { fold(scalar, into: &out) }
        return out
    }

    /// The scalar that starts at UTF-16 offset `position` of `string` (nil for an unpaired surrogate or out of range).
    static func scalar(at position: Int, in string: NSString) -> Unicode.Scalar? {
        guard position >= 0, position < string.length else { return nil }
        let unit = string.character(at: position)
        if UTF16.isLeadSurrogate(unit), position + 1 < string.length {
            let trail = string.character(at: position + 1)
            guard UTF16.isTrailSurrogate(trail) else { return nil }
            return Unicode.Scalar(0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(trail) - 0xDC00))
        }
        return Unicode.Scalar(unit)
    }

    /// The scalar that ends just before UTF-16 offset `position`, with the offset where it starts.
    static func scalar(before position: Int, in string: NSString) -> (scalar: Unicode.Scalar?, start: Int)? {
        guard position > 0, position <= string.length else { return nil }
        let unit = string.character(at: position - 1)
        if UTF16.isTrailSurrogate(unit), position >= 2 {
            let lead = string.character(at: position - 2)
            if UTF16.isLeadSurrogate(lead) {
                return (Unicode.Scalar(0x10000 + ((UInt32(lead) - 0xD800) << 10) + (UInt32(unit) - 0xDC00)), position - 2)
            }
        }
        return (Unicode.Scalar(unit), position - 1)
    }
}
