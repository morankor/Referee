import Foundation
import RefereeCore

/// The validation of a Crossref candidate (plan.md section 8.7): the folded first-author surname equals the entry's,
/// and at least 60% of the candidate title's words of four letters or more occur in the entry's folded text; when
/// the years differ by more than one, at least 85%. Confidence = 0.5 + 0.5 × that share.
enum CandidateValidator {
    struct Verdict: Sendable, Equatable {
        var accepted: Bool
        var titleShare: Double           // 0…1
        var confidence: Double { 0.5 + 0.5 * titleShare }
    }

    static let minimumWordLength = 4
    static let requiredPercent = 60
    static let requiredPercentWhenYearsDiffer = 85

    /// The accepted candidate with the highest title share; among equals, the one Crossref ranked higher. nil when
    /// every candidate fails.
    static func choose(from candidates: [CrossrefCandidate], for entry: BibEntry) -> (candidate: CrossrefCandidate, verdict: Verdict)? {
        var best: (candidate: CrossrefCandidate, verdict: Verdict)?
        for candidate in candidates {
            let verdict = verdict(for: candidate, entry: entry)
            guard verdict.accepted else { continue }
            if best == nil || verdict.titleShare > best?.verdict.titleShare ?? 0 { best = (candidate, verdict) }
        }
        return best
    }

    static func verdict(for candidate: CrossrefCandidate, entry: BibEntry) -> Verdict {
        let rejected = Verdict(accepted: false, titleShare: 0)
        guard let entrySurname = entry.parsed.authorSurnames.first.map(ReferenceText.fold), !entrySurname.isEmpty,
              let candidateSurname = candidate.firstAuthor?.surname.map(ReferenceText.fold), candidateSurname == entrySurname,
              let title = candidate.title else { return rejected }
        let allWords = ReferenceText.titleWords(title)
        let longWords = allWords.filter { $0.count >= minimumWordLength }
        let words = longWords.isEmpty ? allWords : longWords     // a title such as "On AI" still has words to count
        guard !words.isEmpty else { return rejected }
        let text = ReferenceText.fold(entry.rawText)
        let matched = words.filter { text.contains($0) }.count
        let share = Double(matched) / Double(words.count)
        var required = requiredPercent
        if let entryYear = entry.parsed.year, let candidateYear = candidate.year, abs(entryYear - candidateYear) > 1 {
            required = requiredPercentWhenYearsDiffer
        }
        return Verdict(accepted: matched * 100 >= words.count * required, titleShare: share)
    }
}
