import Foundation

/// The folded author strings by which an author–year citation names an entry (plan.md section 8.4 step 1), from the
/// folded surnames s1 … sn:
/// one author: s1; two: s1 "and" s2, and s1 s2 (for "&"); three or more: s1 "etal", s1 s2 … "and" sn, and s1 s2 … sn.
/// If s1 begins with a lower-case particle ("van der Berg"), every key also without it ("Berg").
/// An entry whose list printed "et al." also gets s1 "etal", whatever the number of names left.
enum AuthorKeys {
    private static let and = Folding.fold("and")
    private static let etAl = Folding.fold("etal")

    /// Longest first.
    static func keys(surnames: [String], truncated: Bool) -> [[UInt32]] {
        let named = surnames.map { ($0, Folding.fold($0)) }.filter { !$0.1.isEmpty }
        guard let first = named.first else { return [] }
        let others = named.dropFirst().map(\.1)
        var firsts = [first.1]
        if let bare = withoutParticles(first.0) {
            let folded = Folding.fold(bare)
            if !folded.isEmpty { firsts.append(folded) }
        }
        var keys = Set<[UInt32]>()
        for s1 in firsts {
            switch others.count {
            case 0:
                keys.insert(s1)
            case 1:
                keys.insert(s1 + and + others[0])
                keys.insert(s1 + others[0])
            default:
                keys.insert(s1 + etAl)
                keys.insert(s1 + others.dropLast().joined() + and + others[others.count - 1])
                keys.insert(s1 + others.joined())
            }
            if truncated { keys.insert(s1 + etAl) }
        }
        return keys.sorted { $0.count != $1.count ? $0.count > $1.count : $0.lexicographicallyPrecedes($1) }
    }

    /// "van der Berg" -> "Berg"; nil when the name does not begin with a lower-case particle.
    static func withoutParticles(_ surname: String) -> String? {
        let words = surname.split(whereSeparator: \.isWhitespace)
        guard words.count > 1, let firstWord = words.first, firstWord.first?.isLowercase == true,
              EntryParser.particles.contains(firstWord.lowercased()) else { return nil }
        let rest = words.drop { EntryParser.particles.contains($0.lowercased()) }
        return rest.isEmpty ? nil : rest.joined(separator: " ")
    }
}
