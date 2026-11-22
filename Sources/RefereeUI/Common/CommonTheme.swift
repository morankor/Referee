import SwiftUI
import AppKit
import RefereeCore

/// The look the three panes share (plan.md section 9.10; highlight colours from section 7.3). Written in Wave 0 and
/// frozen, so that Reader, Sidebar and Shell agree without talking to each other.
///
/// Every colour is a system colour, which follows the light or dark appearance of its window.
public enum Theme {
    // ---- comment kinds and statuses ----

    /// major red, minor grey, question purple, strength teal.
    public static func kindColor(_ kind: CommentKind) -> Color {
        switch kind {
        case .major: return .red
        case .minor: return .gray
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
}
