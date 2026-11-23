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
    var notice: ShellNotice?

    var showsNavigator: Bool { navigatorVisibility != .detailOnly }

    func toggleNavigator() {
        navigatorVisibility = showsNavigator ? .detailOnly : .all
    }
}

/// A message the Shell shows in the banner place when the model has none (for example "The report could not be
/// exported"). Errors stay until dismissed.
struct ShellNotice: Equatable, Identifiable {
    var id = UUID()
    var style: Banner.Style
    var message: String
}

/// The settings window's tabs (section 9.6).
enum ShellSettingsTab: String, CaseIterable, Identifiable {
    case providers, prompts, privacy, references, advanced
    var id: String { rawValue }
    var title: String {
        switch self {
        case .providers: return "Providers"
        case .prompts: return "Prompts"
        case .privacy: return "Privacy"
        case .references: return "References"
        case .advanced: return "Advanced"
        }
    }
    var symbol: String {
        switch self {
        case .providers: return "cpu"
        case .prompts: return "text.quote"
        case .privacy: return "hand.raised"
        case .references: return "books.vertical"
        case .advanced: return "gearshape.2"
        }
    }
}

/// The sections of Settings ▸ Prompts (section 9.6).
enum ShellPromptSection: String, CaseIterable, Identifiable {
    case review, discussion, question, report, template, voice, rubric, quickQuestions, format
    var id: String { rawValue }
    var title: String {
        switch self {
        case .review: return "Review"
        case .discussion: return "Discussion"
        case .question: return "Questions"
        case .report: return "Report"
        case .template: return "Report template"
        case .voice: return "Voice revision"
        case .rubric: return "Rubric"
        case .quickQuestions: return "Quick questions"
        case .format: return "Output format"
        }
    }
}

/// Where the settings window is: the tab, the provider shown on Providers, the section shown on Prompts. Kept outside
/// the view so that the window manager ("Privacy settings…") and the settings scenes can choose it.
@MainActor @Observable final class ShellSettingsNavigation {
    var tab: ShellSettingsTab = .providers
    var provider: ProviderID?
    var promptSection: ShellPromptSection = .review
}

/// What the settings window needs from the app. The default deletes the data without closing any window, which is
/// right where no review window exists (the snapshot mode and the tests).
@MainActor struct ShellSettingsServices {
    /// Settings ▸ Privacy ▸ "Delete all review data…", after the confirmation: the window manager closes every review
    /// window first, so that none saves its session again (section 9.6).
    var deleteAllReviewData: (SettingsModel) async throws -> Void = { model in try await model.deleteAllReviewData() }
    var revealInFinder: (URL) -> Void = { url in NSWorkspace.shared.activateFileViewerSelecting([url]) }
}
