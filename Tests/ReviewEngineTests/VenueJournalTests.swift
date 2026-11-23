import Foundation
import Testing
@testable import ReviewEngine
import RefereeCore
import TestSupport

/// "Journal (unspecified)" yields the prompts and the parsing of the code before venues, byte for byte (plan.md
/// Appendix G.9). `golden` holds the SHA-256 of every serialised request of `VenueGolden.requests()` and of every style
/// check of `VenueGolden.reportTexts()`, taken from the code at commit c1c6ee3 by running the same scenarios before any
/// venue code was written (the text of each is easy to print again with `VenueGolden.serialize`).
@Suite struct VenueJournalTests {
    static let golden: [String: String] = [
        "review.text.full#1": "5b33673d8da8c53150354cbba82c88d94de18de7fe60fff10b2e7e2b97b5e872",
        "review.text.bare#1": "82562d78799677ac3eff75d36bd0376d3592631dfba9bdbbcc4486efd152b235",
        "review.pdf.full#1": "e7ba4ba7a8201aa2bf8f3afc33b5864cfaec41e894d5cb6bbc2f019c865c0abf",
        "review.pdf.bare#1": "80ce71fcd8854171af558806f7262f81f0e44c864b4ac414587022c011d89224",
        "review.parts#1": "9668de302a70e5460d2993b3dc0f3c04f14a28f22e7b9fcc8617b49483d988b2",
        "review.parts#2": "e46a5fe0b777a39f3a78c47f04f300447177c8db1e546ba03488fe48dca98242",
        "review.parts#3": "45590dc135af941c057c99522de39faf4093f1cf19a1f6754abcb0794b0ab371",
        "review.parts#4": "3f152f6081e20505747a6671fa7dc41cd50cfe2609b3ec5927a9c30d1b412dee",
        "review.continued#1": "284b2594fb9e42506a72a2ed8798b998226aa416c4eeab643b7db3c7180b2322",
        "review.continued#2": "2fee53b44538255f487d5f9ed62d4c92f1cbcc4ce64923ced9aee7e7d44198d2",
        "discuss.text#1": "7231769879d01010a25586db2db635b4bd203fed5cb3a48b04a5405de81947f8",
        "discuss.pdf#1": "e4ce0f5f3302e38e26f822e849eee7be2a8bf22c9f7031c94392448b7b1f8879",
        "discuss.excerpt#1": "ebd2482dfa98876b66e722f729d3bbfc2b63017d1073f9fe0e37b21dd6b0ab26",
        "ask.selection#1": "df270eac443b19ee29261645ab111e4b9b611b6f897eb85f0de4a00da6597d66",
        "ask.general#1": "a6035375664845e1860336c802683b7935d5576898333ee07bf25ed4665acda3",
        "ask.excerpt#1": "d06102d2b78b2fa40620f9aa0b44addaefefc634eb686ee3e34567541770d01b",
        "report.text.full#1": "17d464099234f024d98a8eb133ac3159f1e74e6a76eef4a6cea319f249fa6110",
        "report.text.bare#1": "233d15e18a06367cbaf2a1fc62eb14ebdcf1e23f625939386e202178271370a5",
        "report.pdf#1": "9d251217e472c45c0201c884056ac5a2242bf673561411425129cc9a0494863e",
        "report.excerpt#1": "f88bb3c51bbac43e3a8297ba9de5830dee1c6764aa18fa1510eadf084381d3eb",
        "revise#1": "3662eecdaf11b06b12447e023b862eed7f6b1aa4f7cf67346d36aa520c06ba95",
        "lint.sample": "c4a35aceb88abbeed658afe8782d3d5e29d6f5c67349ada7cb85cc7440548994",
        "lint.clean": "feb409ae60eefd3c5614221e0dd2aab6a440648b906a018929ff166fd5175d49",
        "lint.accept-with-majors": "4cdaf859f411f4c46bfd99792c59e233033503b9542ca6cefce2f84c4036e479",
        "lint.reject-without-majors": "abe94295467046af98a99164827a619d8dcaf12b3833828343051129f8bf242b",
        "lint.accept-with-minor-revisions": "4a75be17f706f10f3d8e03e48a64b0f087760f8dda4e49c5a513fa6a9e93fce3",
        "lint.bold-headings": "96c5ccc504b5ec44549ea81876f8aeecc7a615c801232e37aa5c9d9db006762f",
        "lint.weak-accept": "45df713343fca528e013883be670e4e5405d91e5ba1b6dc95147861549d9e9bd",
        "lint.no-sections": "76ffee152e70a6f4905c08e58576327449a5cafed6bd4be84ef07cda5467cc36",
    ]

    /// The ways a context reaches "Journal (unspecified)": the default of `EngineContext`, the profile itself, the settings'
    /// answer for a session saved before venues (no id), and for a session made after them (the id "journal").
    static let journalContexts: [(String, VenueGolden.Adjust)] = [
        ("the default", { _ in }),
        ("the profile", { $0.venue = .unspecifiedJournal }),
        ("a session saved before venues", { $0.venue = DefaultSettings.make().venue(id: $0.meta.venueID) }),
        ("a new session", { context in
            context.meta.venueID = VenueProfile.journalID
            context.venue = DefaultSettings.make().venue(id: context.meta.venueID)
        }),
    ]

    @Test(arguments: 0..<4)
    func journalUnspecifiedSendsThePromptsOfBeforeVenuesByteForByte(_ way: Int) async throws {
        let (name, adjust) = Self.journalContexts[way]
        let requests = try await VenueGolden.requests(adjust)
        #expect(requests.count == 21, "\(name)")
        for (scenario, request) in requests {
            let expected = try #require(Self.golden[scenario], "no golden hash for \(scenario)")
            #expect(VenueGolden.sha256(VenueGolden.serialize(request)) == expected, "\(scenario), with \(name)")
        }
    }

    /// The style check and the recommendation of every journal (Journal (unspecified) and JET alike) are as before.
    @Test func everyJournalParsesAndChecksReportsAsBefore() throws {
        let engine = EngineTest.engine([MockLLMProvider()], paper: try makeSamplePaper())
        let journals = [VenueProfile.unspecifiedJournal, DefaultSettings.make().venue(id: "jet")]
        for (name, markdown) in try VenueGolden.reportTexts() {
            let expected = try #require(Self.golden["lint." + name])
            let recommendation = ReportStructure.recommendation(in: markdown)
            #expect(VenueGolden.sha256(VenueGolden.serialize(findings: engine.lint(reportMarkdown: markdown), recommendation: recommendation))
                    == expected, "\(name)")
            for venue in journals {
                let findings = engine.lint(reportMarkdown: markdown, venue: venue)
                #expect(VenueGolden.sha256(VenueGolden.serialize(findings: findings, recommendation: recommendation)) == expected, "\(name), \(venue.id)")
            }
        }
    }

    /// A journal's report draft carries a `recommendation` and no label; a voice revision keeps the label it had.
    @Test func aJournalReportGetsARecommendationAndNoLabel() async throws {
        let paper = EngineTest.paper(pages: [["Line one of page one."]])
        let approved = ReviewComment(id: UUID(), origin: .user, status: .approved, kind: .major, category: "claims", title: "T", body: "B",
                                     anchor: Anchor(quote: "", confidence: .none, locationLabel: ""), includeInReport: true, createdAt: Date(), updatedAt: Date())
        let session = ReviewSession(schemaVersion: 1, id: UUID(), document: paper.ref, meta: VenueGolden.fullMeta, comments: [approved],
                                    createdAt: Date(), updatedAt: Date())
        let jet = DefaultSettings.make().venue(id: "jet")
        let engine = EngineTest.engine([MockLLMProvider()], paper: paper)
        var context = EngineTest.context(meta: VenueGolden.fullMeta)
        context.venue = jet
        let generated = try #require(try await EngineTest.collect(engine.generateReport(paper: paper, session: session, context: context)).finished)
        #expect(generated.draft.recommendation == .majorRevision)
        #expect(generated.draft.recommendationLabel == nil)
        let earlier = ReportDraft(markdown: "## Summary assessment\n\nOld.", recommendation: .reject, recommendationLabel: "Weak reject", userEdited: true)
        let revised = try #require(try await EngineTest.collect(engine.reviseVoice(draft: earlier, findings: [], context: context)).finished)
        #expect(revised.draft.recommendation == .majorRevision)              // report_sample names one
        #expect(revised.draft.recommendationLabel == "Weak reject")          // a journal leaves the label alone
    }
}
