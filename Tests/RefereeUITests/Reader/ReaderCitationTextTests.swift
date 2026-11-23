import Foundation
import Testing
import RefereeCore
import AppCore
@testable import RefereeUI

/// The words and addresses of the citation card and the References list (plan.md sections 7.6, 8.6 and 9.9).
@Suite struct ReaderCitationTextTests {
    private func reference(_ entryID: Int = 2, status: ResolutionStatus = .resolved, failureReason: String? = nil, year: Int? = 1992,
                           doi: String? = nil, landing: String? = nil, pdf: String? = nil, venue: String? = nil) -> ResolvedReference {
        ResolvedReference(entryID: entryID, status: status, failureReason: failureReason, title: "A simple model of herd behavior",
                          authors: ["Banerjee"], year: year, venue: venue, doi: doi, landingURL: landing, openAccessPDFURL: pdf,
                          confidence: 1, resolvedAt: ReaderTestSupport.date)
    }

    @Test func theMentionIsShownReadable() {
        #expect(ReaderCitationText.displayMention("Acemoglu et al. [2011") == "Acemoglu et al. [2011]")
        #expect(ReaderCitationText.displayMention("Smith and Jones (2019") == "Smith and Jones (2019)")
        #expect(ReaderCitationText.displayMention("Avery and Zem- sky, 1998") == "Avery and Zemsky, 1998")
        #expect(ReaderCitationText.displayMention("Bikhchan- dani et al. (1992") == "Bikhchandani et al. (1992)")
        #expect(ReaderCitationText.displayMention("(Smith and Sørensen, 2000") == "(Smith and Sørensen, 2000)")
        #expect(ReaderCitationText.displayMention("12") == "12")
        #expect(ReaderCitationText.displayMention(" Lee [2021] ") == "Lee [2021]")
        #expect(ReaderCitationText.displayMention("Office- Specific (2020") == "Office- Specific (2020)")   // capital after the break: kept
        #expect(ReaderCitationText.displayMention("") == "")
    }

    @Test @MainActor func anEntryIsHeadedByItsAuthorsAndYear() {
        #expect(ReaderCitationText.entryHeading(ReaderTestSupport.entry(2)) == "Banerjee (1992)")
        #expect(ReaderCitationText.entryHeading(ReaderTestSupport.entry(1, surnames: ["Avery", "Zemsky"], year: 1998)) == "Avery and Zemsky (1998)")
        #expect(ReaderCitationText.entryHeading(ReaderTestSupport.entry(0, surnames: ["Acemoglu", "Dahleh", "Lobel", "Ozdaglar"], year: 2011))
                == "Acemoglu et al. (2011)")
        #expect(ReaderCitationText.entryHeading(ReaderTestSupport.entry(3, surnames: ["Lee"], year: nil)) == "Lee")
        #expect(ReaderCitationText.entryHeading(ReaderTestSupport.entry(12, surnames: [], year: nil, label: "13")) == "[13]")
        #expect(ReaderCitationText.entryHeading(ReaderTestSupport.entry(4, surnames: [], year: nil)) == "Reference 5")
        var suffixed = ReaderTestSupport.entry(5, surnames: ["Kogan"], year: 2020)
        suffixed.parsed.yearSuffix = "a"
        #expect(ReaderCitationText.entryHeading(suffixed) == "Kogan (2020a)")
    }

    @Test func differingYearsAreSaid() {
        #expect(ReaderCitationText.yearNote(listYear: 2019, recordYear: 2022) == "year differs: the list says 2019, this record 2022")
        #expect(ReaderCitationText.yearNote(listYear: 2019, recordYear: 2019) == nil)
        #expect(ReaderCitationText.yearNote(listYear: nil, recordYear: 2022) == nil)
        #expect(ReaderCitationText.yearNote(listYear: 2019, recordYear: nil) == nil)
    }

    @Test @MainActor func openInBrowserPrefersTheLandingPageThenTheDOIThenTheEntrysURL() {
        let entry = ReaderTestSupport.entry(2, doi: "10.2307/2118364", url: "https://example.org/entry")
        #expect(ReaderCitationText.browserURL(reference: reference(landing: "https://example.org/landing"), entry: entry)?.absoluteString
                == "https://example.org/landing")
        #expect(ReaderCitationText.browserURL(reference: reference(), entry: entry)?.absoluteString == "https://doi.org/10.2307/2118364")
        #expect(ReaderCitationText.browserURL(reference: reference(doi: "10.1000/record"), entry: entry)?.absoluteString == "https://doi.org/10.1000/record")
        let bare = ReaderTestSupport.entry(2, url: "https://example.org/entry")
        #expect(ReaderCitationText.browserURL(reference: nil, entry: bare)?.absoluteString == "https://example.org/entry")
        // Only web addresses count.
        let odd = ReaderTestSupport.entry(2, url: "ftp://example.org/paper")
        #expect(ReaderCitationText.browserURL(reference: reference(landing: "javascript:alert(1)"), entry: odd) == nil)
        #expect(ReaderCitationText.browserURL(reference: nil, entry: ReaderTestSupport.entry(2)) == nil)
    }

    @Test @MainActor func theDOIToCopyIsTheRecordsElseTheEntrys() {
        let entry = ReaderTestSupport.entry(2, doi: "10.2307/2118364")
        #expect(ReaderCitationText.doi(reference: reference(doi: "10.1000/record"), entry: entry) == "10.1000/record")
        #expect(ReaderCitationText.doi(reference: reference(doi: "  "), entry: entry) == "10.2307/2118364")
        #expect(ReaderCitationText.doi(reference: nil, entry: ReaderTestSupport.entry(2)) == nil)
    }

    @Test @MainActor func recordLinesAndFailures() {
        #expect(ReaderCitationText.recordDetails(reference(venue: "Quarterly Journal of Economics")) == "1992 · Quarterly Journal of Economics")
        #expect(ReaderCitationText.recordDetails(reference(year: nil)) == nil)
        #expect(ReaderCitationText.authorsLine(["Acemoglu", " ", "Ozdaglar"]) == "Acemoglu, Ozdaglar")
        #expect(ReaderCitationText.authorsLine([]) == nil)
        #expect(ReaderCitationText.failureLine(reference(status: .failed, failureReason: "Crossref is busy; try again in a minute."))
                == "Lookup failed: Crossref is busy; try again in a minute.")
        #expect(ReaderCitationText.failureLine(reference(status: .failed)) == "Lookup failed.")
        #expect(ReaderCitationText.viewerTitle(reference: reference(), entry: ReaderTestSupport.entry(2)) == "A simple model of herd behavior")
        var untitled = ReaderTestSupport.entry(2)
        untitled.parsed.title = nil
        #expect(ReaderCitationText.viewerTitle(reference: nil, entry: untitled) == "Banerjee (1992)")
        #expect(ReaderCitationText.searchEntry(forMention: "Kogan [2020").rawText == "Kogan [2020]")
    }

    @Test func theReferencesListShowsAnIconOnlyOnceAnEntryWasLookedUp() {
        #expect(ReaderReferenceStatus.of(nil) == nil)
        #expect(ReaderReferenceStatus.of(reference())?.systemImage == "checkmark.circle")
        #expect(ReaderReferenceStatus.of(reference(pdf: "https://example.org/a.pdf"))?.systemImage == "checkmark.circle.fill")
        #expect(ReaderReferenceStatus.of(reference())?.tint == .green)
        #expect(ReaderReferenceStatus.of(reference(status: .notFound))?.help == "No match found")
        let failed = ReaderReferenceStatus.of(reference(status: .failed, failureReason: "OpenAlex did not answer."))
        #expect(failed?.systemImage == "exclamationmark.triangle.fill")
        #expect(failed?.tint == .orange)
        #expect(failed?.help == "Lookup failed: OpenAlex did not answer.")
    }

    @Test @MainActor func theCardFollowsTheLookup() throws {
        let entries = [ReaderTestSupport.entry(0, surnames: ["Acemoglu", "Dahleh", "Lobel"], year: 2011), ReaderTestSupport.entry(1)]
        let mention = CitationMention(id: 4, pageIndex: 0, text: "Acemoglu et al. [2011", rects: [], entryIDs: [0], source: .linkAnnotation)
        let orphan = CitationMention(id: 5, pageIndex: 0, text: "Nobody (1990", rects: [], entryIDs: [], source: .textPattern)
        let index = CitationIndex(style: .authorYear, entries: entries, mentions: [mention, orphan])

        #expect(ReaderCardContent.make(.idle, citations: index) == nil)
        let resolving = try #require(ReaderCardContent.make(.resolving(target: .mention(4)), citations: index))
        #expect(resolving.heading == "Acemoglu et al. [2011]")
        #expect(resolving.entries.map(\.id) == [0])
        #expect(resolving.isResolving)
        #expect(resolving.references.isEmpty)

        let result = reference(0)
        let resolved = try #require(ReaderCardContent.make(.resolved(target: .mention(4), entries: [entries[0]], references: [result]), citations: index))
        #expect(!resolved.isResolving)
        #expect(resolved.references[0] == result)

        let none = try #require(ReaderCardContent.make(.resolving(target: .mention(5)), citations: index))
        #expect(none.entries.isEmpty)
        #expect(none.mentionText == "Nobody (1990")

        let entryCard = try #require(ReaderCardContent.make(.resolving(target: .entry(1)), citations: index))
        #expect(entryCard.heading == "Banerjee (1992)")
        #expect(entryCard.entries.map(\.id) == [1])

        #expect(ReaderCardContent.make(.resolving(target: .mention(99)), citations: index) == nil)
        #expect(ReaderCardContent.make(.resolving(target: .entry(0)), citations: nil) == nil)
    }
}
