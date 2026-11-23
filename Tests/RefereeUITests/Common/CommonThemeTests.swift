import AppKit
import SwiftUI
import Testing
import RefereeCore
@testable import RefereeUI

/// The shared theme and the actions panes get from the shell (plan.md sections 7.3, 9.1 and 9.10), with the tokens and
/// the tag of step 5 (design review D16).
@Suite struct CommonThemeTests {
    @Test func kindAndStatusColoursAreTheOnesOfSection910() {
        #expect(Theme.kindColor(.major) == .red)
        #expect(Theme.kindColor(.minor) == .brown)                          // grey until step 5 (D16)
        #expect(Theme.kindColor(.question) == .purple)
        #expect(Theme.kindColor(.strength) == .teal)
        #expect(Theme.statusColor(.pending) == .yellow)
        #expect(Theme.statusColor(.approved) == .green)
        #expect(Theme.statusColor(.rejected) == .gray)
        #expect(Theme.ownColor == .blue)
        // A minor comment is a live concern: its badge must not look like the grey of a rejected one (D16).
        #expect(Theme.kindColor(.minor) != Theme.statusColor(.rejected))
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
        #expect(Theme.tagFont == .caption2.weight(.semibold))               // step 5 (D16)
    }

    /// D16: how long "Copied" and the like stay before the label returns.
    @Test func theFeedbackTimeIsOneAndAHalfSeconds() {
        #expect(Theme.feedbackDuration == .milliseconds(1_500))
    }

    /// D16: one look for every small tag. The text in the tag font, 6 points either side and 1 above and below, at its
    /// own size whatever it is offered: a tag never wraps and is never cut.
    @Test @MainActor func aTagIsItsTextInTheTagFontWithItsPaddingAtItsOwnSize() {
        let tag = CommonTag("Open access", color: .green)
        #expect(tag.text == "Open access")
        #expect(tag.color == .green)
        let roomy = CGSize(width: 1_000, height: 1_000)
        for text in ["You", "verify", "Revision proposed", "Open access", "Experimental"] {
            let label = NSHostingController(rootView: Text(text).font(Theme.tagFont).fixedSize()).sizeThatFits(in: roomy)
            let hosted = NSHostingController(rootView: CommonTag(text, color: .orange))
            let size = hosted.sizeThatFits(in: roomy)
            #expect(abs(size.width - (label.width + 12)) < 0.5, "\(text): the tag is \(size.width) wide, its text \(label.width)")
            #expect(abs(size.height - (label.height + 2)) < 0.5, "\(text): the tag is \(size.height) high, its text \(label.height)")
            #expect(hosted.sizeThatFits(in: CGSize(width: 4, height: 4)) == size, "\(text): offered 4 points, the tag changed its size")
        }
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
