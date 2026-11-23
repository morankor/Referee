import SwiftUI
import AppKit
import RefereeCore
import AppCore

/// What the windows of the Shell need from the app around them. The defaults do nothing, which is what the snapshot
/// mode and the tests get (they make the views with their public initialisers); `ShellWindowManager` fills them in.
@MainActor struct ShellWindowServices {
    /// The app's one settings model, for the switches that change settings of the whole app (Local only in the
    /// destination menu). nil: such a switch changes this window's copy of the settings only.
    var settings: SettingsModel?
    /// Opens the settings window, on the given tab.
    var openSettings: (ShellSettingsTab?) -> Void = { _ in }
    /// Opens Settings ▸ Providers on one provider (the destination menu's "Choose in Settings…" and "More in Settings…").
    var openProviderSettings: (ProviderID) -> Void = { _ in }
    /// Opens Settings ▸ Venues on one venue (the venue menu's "Edit Venues…", on the paper's venue; step 5, G.9).
    var openVenueSettings: (String) -> Void = { _ in }
    /// File ▸ Open…: the open panel.
    var showOpenPanel: () -> Void = {}
    /// PDFs dropped on a window, or chosen in the welcome window.
    var openFiles: ([URL]) -> Void = { _ in }
    /// The closures panes reach through the environment (section 9.1).
    var uiActions = UIActions()
}

/// Window state that is not review state: which columns show, whether the destination menu is open, and a message
/// of the Shell's own (an export that failed). Owned by the window's controller, so that the menu can toggle the
/// columns; a review window made with the public initialiser makes its own.
@MainActor @Observable final class ShellReviewWindowState {
    var navigatorVisibility: NavigationSplitViewVisibility = .all
    var showSidebar = true
    var destinationMenuOpen = false
    /// The venue menu under the toolbar's venue control (step 5, G.9). At most one of the two menus is open.
    var venueMenuOpen = false
    /// The provider whose models the destination menu lists under its row: the one chosen for the paper when the menu
    /// opens, none in Custom; a chevron changes it.
    var expandedProvider: ProviderID?
    var notice: ShellNotice?
    /// The navigator was hidden because the window is narrow (design review D19), and comes back when it is wide again.
    private(set) var navigatorAutoHidden = false
    /// The navigator was shown or hidden by hand: the width rule leaves it alone from then on, for the window's life.
    private(set) var navigatorChosenByHand = false

    /// What the Review button and ⌘R do: the window's controller asks first before a second review goes to a provider
    /// that is not on this Mac (D20). nil (a window made with the public initialiser, as in the snapshot mode): start
    /// the review at once.
    @ObservationIgnored var requestReview: (@MainActor () -> Void)?

    static let narrowWidth: CGFloat = 1_100       // below this the navigator steps aside (D19)
    static let wideWidth: CGFloat = 1_240         // from this on an auto-hidden navigator comes back

    var showsNavigator: Bool { navigatorVisibility != .detailOnly }

    /// Opens the destination menu with the models of the paper's own provider listed (none in Custom), or closes it.
    /// Opening it closes the venue menu.
    func toggleDestinationMenu(chosen: ProviderRef?) {
        if destinationMenuOpen {
            destinationMenuOpen = false
        } else {
            expandedProvider = chosen?.providerID
            venueMenuOpen = false
            destinationMenuOpen = true
        }
    }

    /// Opens the venue menu, closing the destination menu, or closes it (step 5, G.9).
    func toggleVenueMenu() {
        if venueMenuOpen {
            venueMenuOpen = false
        } else {
            destinationMenuOpen = false
            venueMenuOpen = true
        }
    }

    /// Whichever of the two menus is open.
    var menuOpen: Bool { destinationMenuOpen || venueMenuOpen }

    /// A click outside the menus, Esc, or a consent card: both close.
    func closeMenus() {
        destinationMenuOpen = false
        venueMenuOpen = false
    }

    /// The toolbar button and View ▸ Hide/Show Navigator (⌃⌘S): a choice by hand, which ends the width rule (D19).
    func toggleNavigator() {
        navigatorVisibility = showsNavigator ? .detailOnly : .all
        navigatorAutoHidden = false
        navigatorChosenByHand = true
    }

    /// D19: below 1,100 points the navigator collapses, so that the PDF gets the room; at 1,240 points or more a
    /// navigator that collapsed this way comes back. Once the navigator has been shown or hidden by hand, nothing.
    func adaptNavigator(toWidth width: CGFloat) {
        guard !navigatorChosenByHand else { return }
        if width < Self.narrowWidth, showsNavigator {
            navigatorVisibility = .detailOnly
            navigatorAutoHidden = true
        } else if width >= Self.wideWidth, navigatorAutoHidden {
            navigatorVisibility = .all
            navigatorAutoHidden = false
        }
    }
}

/// A message the Shell shows in the banner place when the model has none (for example "The report could not be
/// exported"). Errors stay until dismissed.
struct ShellNotice: Equatable, Identifiable {
    var id = UUID()
    var style: Banner.Style
    var message: String
}

/// The settings window's tabs (section 9.6). Venues (step 5, G.9) comes after Prompts: both shape what is sent.
enum ShellSettingsTab: String, CaseIterable, Identifiable {
    case providers, prompts, venues, privacy, references, advanced
    var id: String { rawValue }
    var title: String {
        switch self {
        case .providers: return "Providers"
        case .prompts: return "Prompts"
        case .venues: return "Venues"
        case .privacy: return "Privacy"
        case .references: return "References"
        case .advanced: return "Advanced"
        }
    }
    var symbol: String {
        switch self {
        case .providers: return "cpu"
        case .prompts: return "text.quote"
        case .venues: return "building.columns"
        case .privacy: return "hand.raised"
        case .references: return "books.vertical"
        case .advanced: return "gearshape.2"
        }
    }
}

/// The sections of Settings ▸ Prompts (section 9.6). The two conference texts (step 5, G.9) follow the report's.
enum ShellPromptSection: String, CaseIterable, Identifiable {
    case review, discussion, question, report, template, conferenceReport, conferenceTemplate, voice, rubric, quickQuestions, format
    var id: String { rawValue }
    var title: String {
        switch self {
        case .review: return "Review"
        case .discussion: return "Discussion"
        case .question: return "Questions"
        case .report: return "Report"
        case .template: return "Report template"
        case .conferenceReport: return "Conference report"
        case .conferenceTemplate: return "Conference template"
        case .voice: return "Voice revision"
        case .rubric: return "Rubric"
        case .quickQuestions: return "Quick questions"
        case .format: return "Output format"
        }
    }
}

/// Where the settings window is: the tab, the provider shown on Providers, the section shown on Prompts, the venue
/// shown on Venues. Kept outside the view so that the window manager ("Privacy settings…", "Edit Venues…", the
/// window's title) and the settings scenes can choose it.
@MainActor @Observable final class ShellSettingsNavigation {
    var tab: ShellSettingsTab = .providers
    var provider: ProviderID?
    var promptSection: ShellPromptSection = .review
    /// The venue the Venues pane edits; nil: the first of the list.
    var venue: String?
}

/// What the settings window needs from the app. The default deletes the data without closing any window, which is
/// right where no review window exists (the snapshot mode and the tests).
@MainActor struct ShellSettingsServices {
    /// Settings ▸ Privacy ▸ "Delete all review data…", after the confirmation: the window manager closes every review
    /// window first, so that none saves its session again (section 9.6).
    var deleteAllReviewData: (SettingsModel) async throws -> Void = { model in try await model.deleteAllReviewData() }
    var revealInFinder: (URL) -> Void = { url in NSWorkspace.shared.activateFileViewerSelecting([url]) }
}
