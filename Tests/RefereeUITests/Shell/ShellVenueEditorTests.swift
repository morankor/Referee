import Foundation
import Testing
import RefereeCore
import AppCore
import TestSupport
@testable import RefereeUI

/// Settings ▸ Venues and the conference texts of Settings ▸ Prompts (step 5, plan.md section 9.6 and Appendix G.9): the
/// editor's checks, its edits of the scale, the list's rows, and what the panes hand to `SettingsModel`.
@Suite @MainActor struct ShellVenueEditorTests {
    static var ec: VenueProfile { DefaultSettings.venues[3] }

    // ---- the tab ----

    @Test func venuesIsATabOfSettingsAfterPrompts() {
        #expect(ShellSettingsTab.allCases.map(\.title) == ["Providers", "Prompts", "Venues", "Privacy", "References", "Advanced"])
        #expect(ShellSettingsTab.venues.symbol == "building.columns")
        #expect(ShellSettingsNavigation().venue == nil)
    }

    // ---- the list ----

    @Test func theListShowsWhichVenueIsShownAndHowEachRowReads() {
        let venues = DefaultSettings.venues
        #expect(ShellVenueEditing.selected(nil, in: venues)?.id == "journal")                    // nothing chosen: the first
        #expect(ShellVenueEditing.selected("ec", in: venues)?.id == "ec")
        #expect(ShellVenueEditing.selected("deleted", in: venues)?.id == "journal")
        #expect(ShellVenueEditing.selected(nil, in: []) == nil)
        #expect(ShellVenueEditing.position(of: Self.ec, in: venues) == 3)
        #expect(ShellVenueEditing.position(of: nil, in: venues) == nil)
        #expect(venues.map(ShellVenueEditing.listDetail) == ["Journal (unspecified)", "Conference (unspecified)", "Journal of Economic Theory",
                                                              "ACM Conference on Economics and Computation"])
        let same = VenueProfile(id: "x", shortName: "WINE", fullName: "WINE", kind: .conference, guidance: "")
        #expect(ShellVenueEditing.listDetail(same) == "conference")                                // the full name would repeat the title
        #expect(ShellVenueEditing.listTitle(VenueProfile(id: "y", shortName: "", fullName: " ", kind: .journal, guidance: "")) == "Untitled venue")
        #expect(venues.allSatisfy { ShellVenueEditing.isAsShipped($0) })
        var edited = Self.ec
        edited.guidance = "Mine."
        #expect(!ShellVenueEditing.isAsShipped(edited))
    }

    // ---- the checks ----

    @Test func aVenueNeedsAName() {
        var venue = VenueProfile(id: "x", shortName: " ", fullName: "", kind: .journal, guidance: "")
        #expect(ShellVenueEditing.nameProblems(of: venue) == ["Give the venue a short or a full name: the prompts name it."])
        venue.fullName = "Journal of Examples"
        #expect(ShellVenueEditing.nameProblems(of: venue).isEmpty)
        #expect(ShellVenueEditing.problems(of: Self.ec).isEmpty)
    }

    @Test func theScaleWarnsOfWhatItsLabelsLose() {
        #expect(ShellVenueEditing.scaleProblems(DefaultSettings.conferenceScale).isEmpty)
        #expect(ShellVenueEditing.scaleProblems(["Accept", " ", "Reject"]) == ["A blank label is left out."])
        #expect(ShellVenueEditing.scaleProblems(["Accept", "Reject", "accept", "ACCEPT"])
                == ["“accept” is on the scale twice; the second is left out."])
        #expect(ShellVenueEditing.scaleProblems(["", "  "]) == ["A blank label is left out.", "The scale has no label, so the default scale is used."])
        #expect(ShellVenueEditing.scaleProblems([]) == ["The scale has no label, so the default scale is used."])
        #expect(ShellVenueEditing.scaleProblems(["Accept"]) == ["A scale needs at least two labels to choose between."])
        // A journal's stored labels are not used, so they are not checked.
        var journal = VenueProfile(id: "j", shortName: "J", fullName: "J", kind: .journal, guidance: "", recommendationScale: [""])
        #expect(ShellVenueEditing.problems(of: journal).isEmpty)
        journal.kind = .conference
        #expect(!ShellVenueEditing.problems(of: journal).isEmpty)
    }

    // ---- the edits ----

    @Test func aJournalTurnedIntoAConferenceStartsFromTheDefaultScaleAndKeepsItsOwn() {
        var venue = VenueProfile(id: "j", shortName: "J", fullName: "J", kind: .journal, guidance: "")
        ShellVenueEditing.change(&venue, to: .conference)
        #expect(venue.kind == .conference)
        #expect(venue.recommendationScale == DefaultSettings.conferenceScale)
        venue.recommendationScale = ["Yes", "No"]
        ShellVenueEditing.change(&venue, to: .journal)
        #expect(venue.recommendationScale == ["Yes", "No"])                                       // kept, unused
        ShellVenueEditing.change(&venue, to: .conference)
        #expect(venue.recommendationScale == ["Yes", "No"])                                       // and back
        #expect(ShellVenueEditing.instructions("  \n") == nil)
        #expect(ShellVenueEditing.instructions("Fill in the form's boxes.") == "Fill in the form's boxes.")
    }

    @Test func theScalesLabelsAreAddedMovedReplacedAndRemoved() {
        #expect(ShellVenueEditing.addingLabel(to: ["Accept"]) == ["Accept", "New label"])
        #expect(ShellVenueEditing.addingLabel(to: ["new label", "New label 2"]) == ["new label", "New label 2", "New label 3"])
        let scale = ["Accept", "Borderline", "Reject"]
        #expect(ShellVenueEditing.movingLabel(in: scale, at: 2, by: -1) == ["Accept", "Reject", "Borderline"])
        #expect(ShellVenueEditing.movingLabel(in: scale, at: 0, by: -1) == scale)                 // nowhere to go
        #expect(ShellVenueEditing.movingLabel(in: scale, at: 2, by: 1) == scale)
        #expect(ShellVenueEditing.removingLabel(in: scale, at: 1) == ["Accept", "Reject"])
        #expect(ShellVenueEditing.removingLabel(in: scale, at: 5) == scale)
        #expect(ShellVenueEditing.replacingLabel(in: scale, at: 1, with: "Weak accept") == ["Accept", "Weak accept", "Reject"])
        #expect(ShellVenueEditing.replacingLabel(in: scale, at: -1, with: "x") == scale)
    }

    /// What the pane hands on reaches the settings: a label edited in EC's scale, then the venue reset.
    @Test func anEditedScaleIsSavedAndAResetPutsBackTheShippedVenue() throws {
        let model = SettingsModel(dependencies: ShellTestModels.dependencies(), settings: DefaultSettings.make())
        var ec = try #require(model.venues.first { $0.id == "ec" })
        ec.recommendationScale = ShellVenueEditing.replacingLabel(in: ec.recommendationScale, at: 2, with: "Borderline, leaning reject")
        model.updateVenue(ec)
        #expect(model.settings.venue(id: "ec").scale[2] == "Borderline, leaning reject")
        #expect(!ShellVenueEditing.isAsShipped(model.settings.venue(id: "ec")))
        model.resetVenue(id: "ec")
        #expect(ShellVenueEditing.isAsShipped(model.settings.venue(id: "ec")))
    }

    // ---- Settings ▸ Prompts: the conference texts ----

    @Test func theConferenceTextsAreEditedAndResetInPrompts() {
        var prompts = DefaultSettings.make().prompts
        #expect(ShellPromptSectionView.text(of: .conferenceReport, in: prompts) == DefaultSettings.conferenceReportSystem)
        #expect(ShellPromptSectionView.text(of: .conferenceTemplate, in: prompts) == DefaultSettings.conferenceReportTemplate)
        #expect(ShellPromptSectionView.isDefault(.conferenceReport, in: prompts))
        ShellPromptSectionView.setText("My conference report rules.", of: .conferenceReport, in: &prompts)
        #expect(prompts.conferenceReportSystem == "My conference report rules.")
        #expect(prompts.reportSystem(for: .conference) == "My conference report rules.")
        #expect(prompts.reportSystem == DefaultSettings.make().prompts.reportSystem)              // the journal's is untouched
        #expect(!ShellPromptSectionView.isDefault(.conferenceReport, in: prompts))
        ShellPromptSectionView.reset(.conferenceReport, in: &prompts)
        #expect(ShellPromptSectionView.isDefault(.conferenceReport, in: prompts))
        // A settings file from before venues has neither text: the defaults show, and Reset has nothing to do.
        prompts.conferenceReportTemplate = nil
        #expect(ShellPromptSectionView.text(of: .conferenceTemplate, in: prompts) == DefaultSettings.conferenceReportTemplate)
        #expect(ShellPromptSectionView.isDefault(.conferenceTemplate, in: prompts))
        #expect(ShellPromptSectionView.defaultText(of: .review) == nil)                           // only the two conference texts reset alone
        #expect(ShellPromptSection.conferenceReport.title == "Conference report")
        #expect(!ShellPromptSectionView.explanation(.conferenceTemplate).isEmpty)
    }
}
