import Foundation
import Testing
import RefereeCore
import AppCore
import TestSupport
@testable import RefereeUI

/// The Report tab for the paper's venue (step 5, plan.md section 9.8 and Appendix G.9): the venue's lines, the
/// recommendation on a conference's scale, and "Chance of acceptance" in the journal system's two copies.
@Suite @MainActor struct SidebarReportVenueTests {
    static var jet: VenueProfile { DefaultSettings.venues[2] }
    static var ec: VenueProfile { DefaultSettings.venues[3] }

    static func conferenceReport(recommendation: String, majors: Int) -> String {
        let concerns = majors == 0 ? "None." : (1...majors).map { "\($0). Concern \($0) (p. \($0))." }.joined(separator: "\n")
        return """
            ## Summary assessment

            New, but the proof has a gap.

            ## Recommendation

            \(recommendation)

            ## Chance of acceptance

            15–25%. The gap decides it.

            ## Major concerns

            \(concerns)

            ## Minor concerns

            1. Define the threshold (p. 1).

            ## Questions for the authors

            1. What set the order of the rollout?
            """
    }

    @Test func theTabNamesThePapersVenueAndItsKind() {
        let jet = SidebarReportFacts.venueLines(Self.jet)
        #expect(jet.name == "Journal of Economic Theory (JET)" && jet.kind == "Journal")
        let ec = SidebarReportFacts.venueLines(Self.ec)
        #expect(ec.name == "ACM Conference on Economics and Computation (EC)" && ec.kind == "Conference")
        let journal = SidebarReportFacts.venueLines(.unspecifiedJournal)
        #expect(journal.name == "Journal (unspecified)" && journal.kind == "Journal, no venue named")
        #expect(SidebarReportFacts.venueShortName(Self.ec) == "EC")
        let unnamed = VenueProfile(id: "x", shortName: "", fullName: "Web and Internet Economics", kind: .conference, guidance: "")
        #expect(SidebarReportFacts.venueShortName(unnamed) == "Web and Internet Economics")
        #expect(SidebarReportFacts.venueLines(VenueProfile(id: "y", shortName: "", fullName: "", kind: .journal, guidance: "")).name == "Untitled venue")
    }

    /// A paper saved before venues: Journal (unspecified), whose prompts still name the target journal typed then.
    @Test func aTargetTypedBeforeVenuesIsNamedUnderAnUnspecifiedVenue() {
        let typed = SidebarReportFacts.venueLines(.unspecifiedJournal, typedName: " Journal of Examples ")
        #expect(typed.name == "Journal (unspecified)" && typed.kind == "Journal, named “Journal of Examples” in the prompts")
        #expect(SidebarReportFacts.venueLines(.unspecifiedJournal, typedName: " \n").kind == "Journal, no venue named")
        #expect(SidebarReportFacts.venueLines(Self.jet, typedName: "Journal of Economic Theory (JET)").kind == "Journal")   // its own name
    }

    /// Through the model: an old session's typed target journal reaches the tab's line, and choosing a venue replaces it.
    @Test func theTabReadsTheTargetOfTheSession() async throws {
        let model = try await SidebarTestHarness.open(comments: []).model
        var meta = try #require(model.session?.meta)
        meta.venueID = nil                                                     // as saved before venues
        meta.targetVenue = "Journal of Examples"
        model.updateMeta(meta)
        #expect(model.currentVenue == .unspecifiedJournal)
        #expect(SidebarReportFacts.venueLines(model.currentVenue, typedName: model.session?.meta.targetVenue).kind
                == "Journal, named “Journal of Examples” in the prompts")
        model.setVenue(id: "jet")
        #expect(SidebarReportFacts.venueLines(model.currentVenue, typedName: model.session?.meta.targetVenue).kind == "Journal")
    }

    @Test func aConferenceRecommendationDisagreesWithTheConcernsOnItsScale() {
        let withConcern = Self.conferenceReport(recommendation: "Weak accept.", majors: 1)
        let without = Self.conferenceReport(recommendation: "Weak reject.", majors: 0)
        #expect(SidebarReportFacts.recommendationMismatch(label: "Weak accept", venue: Self.ec, markdown: withConcern))
        #expect(!SidebarReportFacts.recommendationMismatch(label: "Weak reject", venue: Self.ec, markdown: withConcern))
        #expect(SidebarReportFacts.recommendationMismatch(label: "Weak reject", venue: Self.ec, markdown: without))
        #expect(!SidebarReportFacts.recommendationMismatch(label: "Borderline", venue: Self.ec, markdown: withConcern))   // the middle never
        #expect(!SidebarReportFacts.recommendationMismatch(label: "Borderline", venue: Self.ec, markdown: without))
        #expect(!SidebarReportFacts.recommendationMismatch(label: nil, venue: Self.ec, markdown: withConcern))
        // On a journal's scale the label check is the enum's.
        #expect(SidebarReportFacts.recommendationMismatch(label: "Accept", venue: Self.jet, markdown: withConcern)
                == SidebarReportFacts.recommendationMismatch(.accept, markdown: withConcern))
    }

    @Test func theChanceOfAcceptanceGoesToTheCommitteeAndNotToTheAuthors() {
        let report = Self.conferenceReport(recommendation: "Weak reject. The gap is real.", majors: 1)
        let authors = SidebarReportFacts.authorsMarkdown(report)
        let committee = SidebarReportFacts.editorMarkdown(report)
        #expect(!authors.contains("Chance of acceptance") && !authors.contains("## Recommendation"))
        #expect(authors.contains("## Major concerns") && authors.contains("## Questions for the authors"))
        #expect(committee.hasPrefix("## Summary assessment"))
        #expect(committee.contains("## Recommendation\n\nWeak reject. The gap is real.") && committee.contains("## Chance of acceptance\n\n15–25%"))
        #expect(!committee.contains("## Major concerns"))
        #expect(SidebarReportFacts.confidentialCopyTitle(.journal) == "Copy Confidential Comments to the Editor")
        #expect(SidebarReportFacts.confidentialCopyTitle(.conference) == "Copy Confidential Comments to the Program Committee")
    }

    /// The picker's label, through the model, on EC: the scale's labels, set and cleared.
    @Test func thePickerOfAConferenceIsTheVenuesScale() async throws {
        let model = try await SidebarTestHarness.open(comments: []).model
        model.setVenue(id: "ec")
        model.updateReportMarkdown(Self.conferenceReport(recommendation: "Weak accept.", majors: 0))
        #expect(model.recommendationScale == DefaultSettings.conferenceScale)
        model.setRecommendation(label: "Weak accept")
        #expect(model.recommendationLabel == "Weak accept")
        #expect(model.session?.report?.recommendation == nil)
        model.setRecommendation(label: nil)
        #expect(model.recommendationLabel == nil)
    }
}
