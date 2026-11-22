import Foundation
import Testing
import RefereeCore
@testable import ScholarKit
import TestSupport

/// Acceptance row "validation" (plan.md section 11.4, WP7; the validation of a Crossref candidate in section 8.7).
@Suite struct ScholarKitValidationTests {
    /// Title words of four letters or more: multidimensional, uncertainty, herd, behavior, financial, markets.
    static let avery = BibEntry(id: 1, rawText: "Avery, C. and Zemsky, P. (1998). Multidimensional uncertainty and herd behavior in financial markets. "
                                    + "American Economic Review 88(4), 724–748.",
                                parsed: ParsedReference(authorSurnames: ["Avery", "Zemsky"], year: 1998,
                                                        title: "Multidimensional uncertainty and herd behavior in financial markets"))

    static func candidate(_ title: String, firstAuthor: String = "Avery", year: Int? = 1998) -> CrossrefCandidate {
        CrossrefCandidate(doi: "10.1000/test", title: title,
                          authors: [.init(given: "C.", family: firstAuthor, isFirst: true), .init(given: "P.", family: "Zemsky", isFirst: false)],
                          year: year, venue: "American Economic Review")
    }

    // ---- the rule ----

    @Test func aCandidateWithAnotherFirstAuthorIsRejected() {
        let verdict = CandidateValidator.verdict(for: Self.candidate("Multidimensional uncertainty and herd behavior in financial markets",
                                                                     firstAuthor: "Zemsky"), entry: Self.avery)
        #expect(!verdict.accepted)
    }

    @Test func surnamesAreComparedFolded() {
        let entry = BibEntry(id: 0, rawText: "Müller-Lyer, F. (1889). Optische Urteilstäuschungen. Archiv für Physiologie.",
                             parsed: ParsedReference(authorSurnames: ["Müller-Lyer"], year: 1889))
        let candidate = CrossrefCandidate(doi: "10.1000/x", title: "Optische Urteilstäuschungen",
                                          authors: [.init(given: "F.", family: "MULLER LYER", isFirst: true)], year: 1889)
        let verdict = CandidateValidator.verdict(for: candidate, entry: entry)
        #expect(verdict.accepted)
        #expect(verdict.titleShare == 1)
    }

    @Test func aYearOffByFourWithEveryTitleWordIsAccepted() {
        let verdict = CandidateValidator.verdict(for: Self.candidate("Multidimensional Uncertainty and Herd Behavior in Financial Markets",
                                                                     year: 2002), entry: Self.avery)
        #expect(verdict.accepted)
        #expect(verdict.titleShare == 1)
        #expect(verdict.confidence == 1)
    }

    /// Seven of its ten long words occur in the entry (trading, prices and dynamics do not).
    static let seventyPercent = "Multidimensional uncertainty and herd behavior in financial markets: economic trading, prices and dynamics"

    @Test func aYearOffByFourWithSeventyPercentOfTheTitleIsRejected() {
        let verdict = CandidateValidator.verdict(for: Self.candidate(Self.seventyPercent, year: 2002), entry: Self.avery)
        #expect(!verdict.accepted)
        #expect(verdict.titleShare == 0.7)
    }

    @Test func seventyPercentIsEnoughWhenTheYearsDifferByOneAtMost() {
        for year in [1997, 1998, 1999, nil] {
            let verdict = CandidateValidator.verdict(for: Self.candidate(Self.seventyPercent, year: year), entry: Self.avery)
            #expect(verdict.accepted, "year \(String(describing: year))")
            #expect(abs(verdict.confidence - 0.85) < 1e-12)
        }
    }

    @Test func eightyFivePercentIsWhatAYearOffByMoreThanOneNeeds() {
        // 6 of 7 long words (85.7%): accepted; 5 of 6 (83.3%): rejected.
        let sixOfSeven = Self.candidate("Multidimensional uncertainty, herd behavior, financial markets and dynamics", year: 2002)
        let fiveOfSix = Self.candidate("Multidimensional uncertainty, herd behavior, financial dynamics", year: 2002)
        #expect(CandidateValidator.verdict(for: sixOfSeven, entry: Self.avery).accepted)
        #expect(!CandidateValidator.verdict(for: fiveOfSix, entry: Self.avery).accepted)
    }

    @Test func aTitleSharingLessThanSixtyPercentIsRejected() {
        // 3 of 5 (60%): accepted; 2 of 5 (40%) and 5 of 9 (56%): rejected.
        let threeOfFive = Self.candidate("Multidimensional uncertainty and herd prices dynamics")
        let twoOfFive = Self.candidate("Multidimensional uncertainty trading prices dynamics")
        let fiveOfNine = Self.candidate("Multidimensional uncertainty herd behavior financial trading prices dynamics volatility")
        #expect(CandidateValidator.verdict(for: threeOfFive, entry: Self.avery).accepted)
        #expect(!CandidateValidator.verdict(for: twoOfFive, entry: Self.avery).accepted)
        #expect(!CandidateValidator.verdict(for: fiveOfNine, entry: Self.avery).accepted)
    }

    @Test func shortWordsDoNotCountUnlessTheTitleHasNoOther() {
        // "the", "art", "of" and "it" do not occur in the entry and are not counted: 2 of 2 long words.
        #expect(CandidateValidator.verdict(for: Self.candidate("Herd behavior: the art of it"), entry: Self.avery).titleShare == 1)
        // A title of short words only is judged on all of them.
        let entry = BibEntry(id: 0, rawText: "Lee, J. (2021). On AI. Mimeo.", parsed: ParsedReference(authorSurnames: ["Lee"], year: 2021))
        let candidate = CrossrefCandidate(doi: "10.1000/ai", title: "On AI", authors: [.init(family: "Lee", isFirst: true)], year: 2021)
        #expect(CandidateValidator.verdict(for: candidate, entry: entry).accepted)
    }

    @Test func aCandidateWithoutTitleOrAuthorIsRejected() {
        var untitled = Self.candidate("x")
        untitled.title = nil
        var anonymous = Self.candidate("Multidimensional uncertainty and herd behavior in financial markets")
        anonymous.authors = []
        #expect(!CandidateValidator.verdict(for: untitled, entry: Self.avery).accepted)
        #expect(!CandidateValidator.verdict(for: anonymous, entry: Self.avery).accepted)
        #expect(!CandidateValidator.verdict(for: Self.candidate("Herd behavior"), entry: Entries.withoutSurname).accepted)
    }

    @Test func theHighestTitleShareWinsAndCrossrefsOrderBreaksTies() {
        var first = Self.candidate(Self.seventyPercent)
        first.doi = "10.1000/first"
        var second = Self.candidate("Multidimensional uncertainty and herd behavior in financial markets")
        second.doi = "10.1000/second"
        var third = second
        third.doi = "10.1000/third"
        #expect(CandidateValidator.choose(from: [first, second, third], for: Self.avery)?.candidate.doi == "10.1000/second")
        #expect(CandidateValidator.choose(from: [Self.candidate("Unrelated words entirely")], for: Self.avery) == nil)
    }

    // ---- through the resolver ----

    @Test func aTopHitWithAnotherFirstAuthorIsPassedOver() async throws {
        let body = Bodies.crossref([
            .init(doi: "10.1000/wrong-author", title: "Long Short-Term Memory", authors: [("Jürgen", "Schmidhuber"), ("Sepp", "Hochreiter")], year: 1997),
            .init(doi: "10.1162/neco.1997.9.8.1735", title: "Long Short-Term Memory", authors: [("Sepp", "Hochreiter"), ("Jürgen", "Schmidhuber")], year: 1997),
        ])
        StubURLProtocol.setHandler(Stub.services(crossref: body, openAlex: Bodies.openAlexHochreiter))
        let harness = ResolverHarness()
        defer { harness.cleanUp() }

        let reference = await harness.resolver.resolve(try Entries.hochreiter(), documentSHA256: Documents.first)

        #expect(reference.status == .resolved)
        #expect(reference.doi == "10.1162/neco.1997.9.8.1735")
        #expect(StubURLProtocol.recordedRequests.last?.url?.path == "/works/doi:10.1162/neco.1997.9.8.1735")
    }

    @Test func whenEveryCandidateIsRejectedTheEntryIsNotFoundAndOpenAlexIsNotAsked() async throws {
        let body = Bodies.crossref([
            .init(doi: "10.1000/wrong-author", title: "Long Short-Term Memory", authors: [("Jürgen", "Schmidhuber")], year: 1997),
            .init(doi: "10.1162/neco.1997.9.1.1", title: "Flat Minima", authors: [("Sepp", "Hochreiter")], year: 1997),
        ])
        StubURLProtocol.setHandler(Stub.services(crossref: body, openAlex: Bodies.openAlexHochreiter))
        let harness = ResolverHarness()
        defer { harness.cleanUp() }
        let entry = try Entries.hochreiter()

        let reference = await harness.resolver.resolve(entry, documentSHA256: Documents.first)

        #expect(reference == ResolvedReference(entryID: entry.id, status: .notFound, confidence: 0, resolvedAt: harness.clock.now()))
        #expect(StubURLProtocol.recordedRequests.map { $0.url?.host } == ["api.crossref.org"])
    }

    @Test func anEmptyAnswerIsNotFound() async throws {
        StubURLProtocol.setHandler(Stub.services(crossref: Bodies.crossrefEmpty, openAlex: Bodies.openAlexHochreiter))
        let harness = ResolverHarness()
        defer { harness.cleanUp() }

        #expect(await harness.resolver.resolve(try Entries.hochreiter(), documentSHA256: Documents.first).status == .notFound)
    }

    /// Appendix D.10's third fixture: the same item issued in 2001, for an entry dated 1997, every title word matching.
    @Test func theRecordIssuedFourYearsLaterIsAcceptedWithItsOwnYear() async throws {
        StubURLProtocol.setHandler { request in
            request.url?.host == "api.crossref.org" ? Stub.json(Bodies.crossrefHochreiter2001) : Stub.status(404)
        }
        let harness = ResolverHarness()
        defer { harness.cleanUp() }

        let reference = await harness.resolver.resolve(try Entries.hochreiter(), documentSHA256: Documents.first)

        #expect(reference.status == .resolved)
        #expect(reference.year == 2001)
        #expect(reference.doi == "10.1162/neco.1997.9.8.1735")
        #expect(reference.confidence == 1)
    }
}
