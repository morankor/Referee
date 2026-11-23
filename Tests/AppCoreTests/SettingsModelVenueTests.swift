import Foundation
import Testing
import RefereeCore
@testable import AppCore
import TestSupport

/// Settings ▸ Venues (plan.md Appendix G.9): add, edit, duplicate, delete, reorder and reset venues, and the default
/// venue of new papers. Built-ins can be edited and reset, never deleted.
@Suite struct SettingsModelVenueTests {
    @Test @MainActor func addingAVenueSavesAndPostsLikeAnyOtherSetting() async throws {
        let parts = try SettingsModelTests.make()
        let counter = SettingsNotificationCounter(for: parts.model)
        defer { counter.stop() }
        let id = parts.model.addVenue(kind: .conference)
        let added = try #require(parts.model.venues.last)
        #expect(added.id == id && !id.isEmpty)
        #expect(added.fullName == "New conference" && added.kind == .conference && added.guidance.isEmpty)
        #expect(added.recommendationScale == DefaultSettings.conferenceScale)
        #expect(!added.isBuiltIn && !added.isUnspecified)
        #expect(parts.model.venues.map(\.id) == ["journal", "conference", "jet", "ec", id])
        #expect(counter.count == 1)
        let pending = parts.model.saveTask
        parts.clock.advance(by: 0.6)
        await pending?.value
        #expect(await parts.store.load().venues == parts.model.venues)

        let journal = parts.model.addVenue(kind: .journal)
        #expect(parts.model.venues.last?.fullName == "New journal")
        #expect(parts.model.venues.last?.recommendationScale.isEmpty == true)
        #expect(journal != id)
    }

    @Test @MainActor func aBuiltInCanBeEditedAndResetButNotDeleted() throws {
        let parts = try SettingsModelTests.make()
        var ec = parts.model.settings.venue(id: "ec")
        ec.guidance = "Weigh the mechanism design."
        ec.recommendationScale = ["Strong accept", "Accept", "Reject", "Strong reject"]   // the scale of a real review form
        parts.model.updateVenue(ec)
        #expect(parts.model.settings.venue(id: "ec") == ec)
        #expect(parts.model.settings.venue(id: "ec").scale == ["Strong accept", "Accept", "Reject", "Strong reject"])
        parts.model.deleteVenue(id: "ec")
        parts.model.deleteVenue(id: VenueProfile.journalID)
        #expect(parts.model.venues.map(\.id) == ["journal", "conference", "jet", "ec"])
        parts.model.resetVenue(id: "ec")
        #expect(parts.model.settings.venue(id: "ec") == DefaultSettings.venues[3])
        #expect(parts.model.settings.venueProfiles == nil)                       // the shipped list again: nothing stored

        parts.model.updateVenue(VenueProfile(id: "no-such-venue", shortName: "", fullName: "Ghost", kind: .journal, guidance: ""))
        #expect(parts.model.venues == DefaultSettings.venues)
    }

    @Test @MainActor func aVenueTheUserAddedCanBeDuplicatedEditedAndDeleted() throws {
        let parts = try SettingsModelTests.make()
        let copy = try #require(parts.model.duplicateVenue(id: "ec"))
        #expect(parts.model.venues.map(\.id) == ["journal", "conference", "jet", "ec", copy])
        let duplicate = parts.model.settings.venue(id: copy)
        #expect(duplicate.fullName == "ACM Conference on Economics and Computation (copy)")
        #expect(duplicate.shortName == "EC" && duplicate.kind == .conference && duplicate.guidance == DefaultSettings.venues[3].guidance)
        #expect(!duplicate.isBuiltIn)
        #expect(parts.model.duplicateVenue(id: "no-such-venue") == nil)

        var edited = duplicate
        edited.fullName = "ACM EC, the year after"
        edited.reportInstructions = "Answer the form's questions in order."
        parts.model.updateVenue(edited)
        #expect(parts.model.settings.venue(id: copy) == edited)

        parts.model.setDefaultVenue(id: copy)
        #expect(parts.model.defaultVenue == edited)
        parts.model.deleteVenue(id: copy)
        #expect(parts.model.venues == DefaultSettings.venues)
        #expect(parts.model.settings.defaultVenueID == nil)                       // the default was deleted: Journal (unspecified)
        #expect(parts.model.defaultVenue == .unspecifiedJournal)
    }

    @Test @MainActor func venuesAreReorderedAsAListMovesThem() throws {
        let parts = try SettingsModelTests.make()
        let own = parts.model.addVenue(kind: .journal)
        parts.model.moveVenues(fromOffsets: IndexSet(integer: 3), toOffset: 0)            // EC to the top
        #expect(parts.model.venues.map(\.id) == ["ec", "journal", "conference", "jet", own])
        parts.model.moveVenues(fromOffsets: IndexSet([0, 1]), toOffset: 5)               // two to the end
        #expect(parts.model.venues.map(\.id) == ["conference", "jet", own, "ec", "journal"])
        parts.model.moveVenues(fromOffsets: IndexSet(integer: 2), toOffset: 2)            // onto itself: no change
        #expect(parts.model.venues.map(\.id) == ["conference", "jet", own, "ec", "journal"])
        parts.model.moveVenues(fromOffsets: IndexSet(integer: 9), toOffset: 0)            // out of range: no change
        #expect(parts.model.venues.map(\.id) == ["conference", "jet", own, "ec", "journal"])
    }

    @Test @MainActor func theDefaultVenueIsOneOfTheList() throws {
        let parts = try SettingsModelTests.make()
        #expect(parts.model.defaultVenue == .unspecifiedJournal)
        parts.model.setDefaultVenue(id: "jet")
        #expect(parts.model.settings.defaultVenueID == "jet")
        #expect(parts.model.defaultVenue.id == "jet")
        parts.model.setDefaultVenue(id: "no-such-venue")
        #expect(parts.model.settings.defaultVenueID == "jet")
        parts.model.setDefaultVenue(id: VenueProfile.journalID)
        #expect(parts.model.settings.defaultVenueID == nil)
        #expect(parts.model.settings == DefaultSettings.make())
    }

    @Test @MainActor func resettingThePromptsRestoresTheConferenceReportToo() throws {
        let parts = try SettingsModelTests.make()
        parts.model.update { settings in
            settings.prompts.conferenceReportSystem = "My conference rules."
            settings.prompts.conferenceReportTemplate = nil
        }
        #expect(parts.model.settings.prompts.reportSystem(for: .conference) == "My conference rules.")
        parts.model.resetPromptsToDefaults()
        #expect(parts.model.settings.prompts == DefaultSettings.make().prompts)
    }
}
