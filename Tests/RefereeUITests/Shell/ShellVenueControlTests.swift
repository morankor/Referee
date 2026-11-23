import Foundation
import Testing
import RefereeCore
import AppCore
import TestSupport
@testable import RefereeUI

/// The toolbar's venue control and its menu (step 5, plan.md section 9.2 and Appendix G.9).
@Suite @MainActor struct ShellVenueControlTests {
    static let venues = DefaultSettings.venues
    static var jet: VenueProfile { venues[2] }
    static var ec: VenueProfile { venues[3] }

    // ---- the control ----

    @Test func theControlShowsTheShortNameTheKindsSymbolAndTheFullNameInItsTooltip() {
        let states = Self.venues.map { ShellVenueState(venue: $0, hasPaper: true) }
        #expect(states.map(\.title) == ["Journal", "Conference", "JET", "EC"])
        #expect(states.map(\.symbol) == ["book.closed", "person.3", "book.closed", "person.3"])
        #expect(states.allSatisfy { $0.isEnabled })
        #expect(states[2].help == "Journal of Economic Theory (JET), a journal: the review weighs what it looks for, and the report is written "
                + "for it. Click to choose another venue.")
        #expect(states[3].help.hasPrefix("ACM Conference on Economics and Computation (EC), a conference: "))
        #expect(states[0].help == "Journal (unspecified): the review and the report are written for a journal in general. Click to choose another venue.")
        #expect(states[1].help.hasPrefix("Conference (unspecified): the review and the report are written for a conference in general."))
        #expect(states[3].accessibilityLabel == "Venue: ACM Conference on Economics and Computation (EC)")
    }

    /// A paper saved before venues is on Journal (unspecified) and its prompts still name the target journal typed then.
    @Test func theTooltipNamesATargetTypedBeforeVenues() {
        #expect(ShellVenueState(venue: .unspecifiedJournal, hasPaper: true, typedName: " JET ").help
                == "Journal (unspecified), with “JET” named as the target: the review and the report are written for a journal in general. "
                + "Click to choose another venue.")
        #expect(ShellVenueState(venue: .unspecifiedJournal, hasPaper: true, typedName: "  ").help
                == ShellVenueState(venue: .unspecifiedJournal, hasPaper: true).help)
        // On a named venue the paper's target is that venue's own name: nothing more to say.
        #expect(ShellVenueState(venue: Self.jet, hasPaper: true, typedName: "Journal of Economic Theory (JET)")
                == ShellVenueState(venue: Self.jet, hasPaper: true))
        #expect(ShellVenueState(venue: .unspecifiedJournal, hasPaper: true, typedName: "JET").title == "Journal")
    }

    @Test func withoutAPaperTheControlCannotBeUsed() {
        let state = ShellVenueState(venue: .unspecifiedJournal, hasPaper: false)
        #expect(!state.isEnabled)
        #expect(state.title == "Journal")
        #expect(state.help == "Open a PDF to choose the venue it is reviewed for.")
    }

    @Test func aVenueWithoutAShortNameIsShownByItsFullNameAndOneWithNoNameAsVenue() {
        let wine = VenueProfile(id: "wine", shortName: "  ", fullName: "Web and Internet Economics", kind: .conference, guidance: "")
        #expect(ShellVenueState(venue: wine, hasPaper: true).title == "Web and Internet Economics")
        let blank = VenueProfile(id: "x", shortName: "", fullName: "", kind: .journal, guidance: "")
        #expect(ShellVenueState(venue: blank, hasPaper: true).title == "Venue")
        #expect(ShellVenueState(venue: blank, hasPaper: true).accessibilityLabel == "Venue: Untitled venue")
        #expect(Theme.venueSymbol(.journal) == ShellVenueState.symbol(for: .journal))
    }

    // ---- the menu ----

    @Test func theMenuGroupsJournalsThenConferencesInTheOrderOfSettings() {
        let wine = VenueProfile(id: "wine", shortName: "WINE", fullName: "Web and Internet Economics", kind: .conference, guidance: "")
        let groups = ShellVenueMenu.groups([Self.ec, wine, .unspecifiedJournal, Self.jet])
        #expect(groups.map(\.title) == ["Journals", "Conferences"])
        #expect(groups.map { $0.venues.map(\.id) } == [["journal", "jet"], ["ec", "wine"]])
        #expect(ShellVenueMenu.groups([Self.jet]).map(\.title) == ["Journals"])                 // a kind without a venue is left out
        #expect(ShellVenueMenu.groups([]).isEmpty)
    }

    @Test func aRowNamesTheFullNameAndTheShortNameAfterIt() {
        #expect(ShellVenueMenu.rowTitle(Self.jet) == "Journal of Economic Theory")
        #expect(ShellVenueMenu.rowShortName(Self.jet) == "JET")
        #expect(ShellVenueMenu.rowTitle(.unspecifiedJournal) == "Journal (unspecified)")
        #expect(ShellVenueMenu.rowShortName(.unspecifiedJournal) == nil)                         // an unspecified venue: no short name
        let shortOnly = VenueProfile(id: "x", shortName: "WINE", fullName: "", kind: .conference, guidance: "")
        #expect(ShellVenueMenu.rowTitle(shortOnly) == "WINE")
        #expect(ShellVenueMenu.rowShortName(shortOnly) == nil)                                  // not twice
    }

    @Test func choosingAVenueSetsThePapersVenueAndClosesTheMenu() async throws {
        let model = try await ShellTestModels.openedOnTheSnapshotRegistry(settings: SnapshotSupport.settings())
        let windowState = ShellReviewWindowState()
        windowState.toggleVenueMenu()
        #expect(windowState.venueMenuOpen)
        #expect(model.currentVenue.id == VenueProfile.journalID)                               // a new paper: Settings' default venue
        ShellVenueMenu.choose("ec", in: model, windowState: windowState)
        #expect(model.currentVenue.id == "ec")
        #expect(model.session?.meta.targetVenue == "ACM Conference on Economics and Computation (EC)")
        #expect(!windowState.venueMenuOpen)
        #expect(ShellVenueState(venue: model.currentVenue, hasPaper: model.session != nil).title == "EC")
    }

    @Test func aNewPaperTakesTheDefaultVenueOfSettings() async throws {
        var settings = SnapshotSupport.settings()
        settings.defaultVenueID = "jet"
        let model = try await ShellTestModels.openedOnTheSnapshotRegistry(settings: settings)
        #expect(model.currentVenue.id == "jet")
        #expect(ShellVenueState(venue: model.currentVenue, hasPaper: true).title == "JET")
    }

    @Test func editVenuesOpensSettingsOnThePapersVenue() async throws {
        let model = try await ShellTestModels.openedOnTheSnapshotRegistry(settings: SnapshotSupport.settings())
        model.setVenue(id: "jet")
        let windowState = ShellReviewWindowState()
        windowState.toggleVenueMenu()
        var opened: [String] = []
        var services = ShellWindowServices()
        services.openVenueSettings = { opened.append($0) }
        ShellVenueMenu.editVenues(of: model, windowState: windowState, services: services)
        #expect(opened == ["jet"])
        #expect(!windowState.venueMenuOpen)
    }

    // ---- the window's two menus ----

    @Test func atMostOneOfTheTwoMenusIsOpen() {
        let state = ShellReviewWindowState()
        state.toggleDestinationMenu(chosen: nil)
        #expect(state.destinationMenuOpen && !state.venueMenuOpen && state.menuOpen)
        state.toggleVenueMenu()
        #expect(state.venueMenuOpen && !state.destinationMenuOpen)
        state.toggleDestinationMenu(chosen: ProviderRef(providerID: "mock", model: nil))
        #expect(state.destinationMenuOpen && !state.venueMenuOpen)
        #expect(state.expandedProvider == "mock")
        state.closeMenus()
        #expect(!state.menuOpen)
        state.toggleVenueMenu()
        state.toggleVenueMenu()
        #expect(!state.venueMenuOpen)
    }

    /// The Report tab's "Change…" reaches its own window's venue menu through `uiActions.chooseVenue`.
    @Test func theReportTabsChangeOpensThisWindowsVenueMenu() {
        let state = ShellReviewWindowState()
        state.toggleDestinationMenu(chosen: nil)
        var settingsOpened = 0
        var app = UIActions()
        app.openSettings = { settingsOpened += 1 }
        let actions = ReviewWindowView.windowActions(app, windowState: state)
        actions.chooseVenue()
        #expect(state.venueMenuOpen && !state.destinationMenuOpen)
        actions.chooseVenue()                                                                     // already open: stays open
        #expect(state.venueMenuOpen)
        actions.openSettings()
        #expect(settingsOpened == 1)                                                              // the app's closures stay
        UIActions().chooseVenue()                                                                 // the default does nothing
    }
}
