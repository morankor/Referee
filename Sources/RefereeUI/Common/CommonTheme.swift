import SwiftUI
import AppKit
import RefereeCore

/// The look the three panes share (plan.md section 9.10; highlight colours from section 7.3). Written in Wave 0 and
/// frozen, so that Reader, Sidebar and Shell agree without talking to each other. Step 5 (design review D16) made the
/// minor colour brown and added the tag font, the feedback time and `CommonTag`.
///
/// Every colour is a system colour, which follows the light or dark appearance of its window.
public enum Theme {
    // ---- comment kinds and statuses ----

    /// major red, minor brown, question purple, strength teal. Minor was grey until step 5 (D16): a minor comment is a
    /// live concern, and its grey badge looked like the muted badge of a rejected comment.
    public static func kindColor(_ kind: CommentKind) -> Color {
        switch kind {
        case .major: return .red
        case .minor: return .brown
        case .question: return .purple
        case .strength: return .teal
        }
    }

    /// pending yellow, approved green, rejected grey.
    public static func statusColor(_ status: CommentStatus) -> Color {
        switch status {
        case .pending: return .yellow
        case .approved: return .green
        case .rejected: return .gray
        }
    }

    /// The reviewer's own comments: blue, whatever their status.
    public static let ownColor: Color = .blue

    // ---- venues (step 5, G.9) ----

    /// The SF Symbol of a venue's kind, the same in the toolbar, its menu, Settings ▸ Venues and the Report tab: a
    /// closed book for a journal, three people (a program committee) for a conference.
    public static func venueSymbol(_ kind: VenueKind) -> String {
        switch kind {
        case .journal: return "book.closed"
        case .conference: return "person.3"
        }
    }

    // ---- highlights in the PDF (section 7.3) ----

    /// What a highlight stands for. A comment written by the reviewer is `.own` whatever its status; `.question` is
    /// the passage a conversation in the Chat tab started from.
    public enum Highlight: Sendable, Equatable, CaseIterable {
        case pending, approved, rejected, own, question
    }

    /// The hue, opaque: yellow, green, grey, blue, purple.
    public static func highlightHue(_ highlight: Highlight) -> NSColor {
        switch highlight {
        case .pending: return .systemYellow
        case .approved: return .systemGreen
        case .rejected: return .systemGray
        case .own: return .systemBlue
        case .question: return .systemPurple
        }
    }

    /// pending 0.35, approved 0.30, rejected 0.15, own 0.30, question 0.25; 0.60 for the selected comment.
    public static func highlightAlpha(_ highlight: Highlight, selected: Bool = false) -> CGFloat {
        if selected { return 0.60 }
        switch highlight {
        case .pending: return 0.35
        case .approved: return 0.30
        case .rejected: return 0.15
        case .own: return 0.30
        case .question: return 0.25
        }
    }

    /// The colour to give a highlight annotation: the hue at its alpha. (A rejected comment is highlighted only when
    /// "Show highlights of rejected comments" is on; that decision is the Reader's, not the theme's.)
    public static func highlightColor(_ highlight: Highlight, selected: Bool = false) -> NSColor {
        highlightHue(highlight).withAlphaComponent(highlightAlpha(highlight, selected: selected))
    }

    /// A fuzzy anchor's highlight has, besides its fill, a dashed border of this width in its hue.
    public static let fuzzyBorderWidth: CGFloat = 1
    public static let fuzzyBorderDash: [CGFloat] = [3, 2]

    /// The background of the PDF view, around the pages.
    public static var pdfBackground: NSColor { .underPageBackgroundColor }

    // ---- metrics (points) ----

    public static let cardCornerRadius: CGFloat = 8
    public static let cardPadding: CGFloat = 10
    public static let listSpacing: CGFloat = 10
    public static let sidebarPadding: CGFloat = 10

    // ---- fonts (system) ----

    public static let cardTitleFont: Font = .headline
    public static let bodyFont: Font = .callout
    public static let quoteFont: Font = .callout.italic()
    public static let metadataFont: Font = .caption
    /// The text of a small tag, `CommonTag` (step 5, D16).
    public static let tagFont: Font = .caption2.weight(.semibold)

    // ---- timing ----

    /// How long a control shows that it acted ("Copied" after Copy) before its label returns (step 5, D16).
    public static let feedbackDuration: Duration = .milliseconds(1_500)
}
