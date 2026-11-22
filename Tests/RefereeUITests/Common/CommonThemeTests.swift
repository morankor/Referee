import AppKit
import SwiftUI
import Testing
import RefereeCore
import RefereeUI

/// The shared theme and the actions panes get from the shell (plan.md sections 7.3, 9.1 and 9.10).
@Suite struct CommonThemeTests {
    @Test func kindAndStatusColoursAreTheOnesOfSection910() {
        #expect(Theme.kindColor(.major) == .red)
        #expect(Theme.kindColor(.minor) == .gray)
        #expect(Theme.kindColor(.question) == .purple)
        #expect(Theme.kindColor(.strength) == .teal)
        #expect(Theme.statusColor(.pending) == .yellow)
        #expect(Theme.statusColor(.approved) == .green)
        #expect(Theme.statusColor(.rejected) == .gray)
        #expect(Theme.ownColor == .blue)
    }

    @Test func highlightsHaveTheHuesAndAlphasOfSection73() {
        #expect(Theme.highlightAlpha(.pending) == 0.35)
        #expect(Theme.highlightAlpha(.approved) == 0.30)
        #expect(Theme.highlightAlpha(.rejected) == 0.15)
        #expect(Theme.highlightAlpha(.own) == 0.30)
        #expect(Theme.highlightAlpha(.question) == 0.25)
        for highlight in Theme.Highlight.allCases {
            #expect(Theme.highlightAlpha(highlight, selected: true) == 0.60)        // the selected comment: same hue, stronger
            #expect(Theme.highlightColor(highlight).alphaComponent == Theme.highlightAlpha(highlight))
            #expect(Theme.highlightColor(highlight, selected: true).alphaComponent == 0.60)
            #expect(Theme.highlightHue(highlight).alphaComponent == 1)
        }
        #expect(Theme.highlightHue(.pending) == .systemYellow)
        #expect(Theme.highlightHue(.approved) == .systemGreen)
        #expect(Theme.highlightHue(.own) == .systemBlue)
        #expect(Theme.highlightHue(.question) == .systemPurple)
        #expect(Theme.fuzzyBorderWidth == 1)
        #expect(!Theme.fuzzyBorderDash.isEmpty)
    }

    @Test func metricsAndFontsAreTheOnesOfSection910() {
        #expect(Theme.cardCornerRadius == 8)
        #expect(Theme.cardPadding == 10)
        #expect(Theme.listSpacing == 10)
        #expect(Theme.sidebarPadding == 10)
        #expect(Theme.cardTitleFont == .headline)
        #expect(Theme.bodyFont == .callout)
        #expect(Theme.quoteFont == .callout.italic())
        #expect(Theme.metadataFont == .caption)
    }

    /// The defaults do nothing, which is what the snapshot mode relies on; the shell replaces them.
    @Test @MainActor func theDefaultActionsDoNothingAndCanBeReplaced() throws {
        var actions = UIActions()
        let page = try #require(URL(string: "https://example.org/reference/3"))
        actions.openSettings()
        actions.openInBrowser(page)
        actions.openReferenceViewer(URL(fileURLWithPath: "/tmp/paper.pdf"), "A cited paper")

        var opened: [URL] = []
        actions.openInBrowser = { opened.append($0) }
        actions.openInBrowser(page)
        #expect(opened == [page])

        // The environment carries the defaults until a window's root view sets real ones.
        var environment = EnvironmentValues()
        environment.uiActions.openSettings()
        var settingsOpened = 0
        environment.uiActions.openSettings = { settingsOpened += 1 }
        environment.uiActions.openSettings()
        #expect(settingsOpened == 1)
    }
}
