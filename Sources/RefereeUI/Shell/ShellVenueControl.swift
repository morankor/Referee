import SwiftUI
import AppKit
import RefereeCore
import AppCore

/// The venue control in the toolbar (step 5, plan.md sections 9.2 and G.9): the paper's venue by its short name ("JET",
/// "EC", "Journal"), after a symbol of its kind, with the full name in the tooltip. A click opens the venue menu, drawn
/// in the window as the destination menu is, so that the snapshot mode can capture it. The venue decides what the review
/// weighs and how the report is written (`ReviewSessionModel.setVenue(id:)`).
///
/// It stands beside the destination indicator and is at most 120 points wide, so that at 1,000 points Review, Report
/// and the sidebar button stay in the toolbar (design review D3's rule, checked by `design-review-long-names`).
struct ShellVenueControl: View {
    let model: ReviewSessionModel
    let windowState: ShellReviewWindowState

    static let maximumWidth: CGFloat = 120

    var body: some View {
        let state = ShellVenueState(venue: model.currentVenue, hasPaper: model.session != nil, typedName: model.session?.meta.targetVenue)
        Button {
            windowState.toggleVenueMenu()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: state.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(state.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: ShellVenueControl.maximumWidth, alignment: .leading)
        }
        .disabled(!state.isEnabled)
        .help(state.help)
        .accessibilityLabel(Text(state.accessibilityLabel))
    }
}

/// What the venue control shows for a venue (pure).
struct ShellVenueState: Equatable {
    var title: String
    var symbol: String
    var help: String
    var accessibilityLabel: String
    var isEnabled: Bool

    /// `typedName`: the paper's `meta.targetVenue`. On an unspecified venue it is a target journal typed before venues
    /// (or the name of a venue since deleted), which the prompts still name; on a named venue it is that venue's name.
    init(venue: VenueProfile, hasPaper: Bool, typedName: String? = nil) {
        title = ShellVenueState.shortTitle(venue)
        symbol = ShellVenueState.symbol(for: venue.kind)
        isEnabled = hasPaper
        accessibilityLabel = "Venue: " + ShellVenueState.name(venue)
        guard hasPaper else {
            help = "Open a PDF to choose the venue it is reviewed for."
            return
        }
        let name = ShellVenueState.name(venue)
        let typed = venue.isUnspecified ? (typedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") : ""
        let general = "the review and the report are written for a \(ShellVenueState.kindName(venue.kind)) in general."
        let what: String
        if !typed.isEmpty {
            what = "\(name), with “\(typed)” named as the target: " + general
        } else if venue.isUnspecified {
            what = "\(name): " + general
        } else {
            what = "\(name), a \(ShellVenueState.kindName(venue.kind)): the review weighs what it looks for, and the report is written for it."
        }
        help = what + " Click to choose another venue."
    }

    /// The short name, else the full name, else "Venue".
    static func shortTitle(_ venue: VenueProfile) -> String {
        let short = venue.shortName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !short.isEmpty { return short }
        let full = venue.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        return full.isEmpty ? "Venue" : full
    }

    /// The name a person reads: "Journal of Economic Theory (JET)", "Journal (unspecified)"; "Untitled venue" for none.
    static func name(_ venue: VenueProfile) -> String {
        let name = venue.displayName
        return name.isEmpty ? "Untitled venue" : name
    }

    /// The kind's symbol, as every pane shows it (`Theme.venueSymbol`).
    static func symbol(for kind: VenueKind) -> String {
        Theme.venueSymbol(kind)
    }

    static func kindName(_ kind: VenueKind) -> String {
        kind == .journal ? "journal" : "conference"
    }
}

/// The venue menu (step 5, G.9): the venues of Settings ▸ Venues grouped by kind, journals first, each group in the order
/// of Settings, the paper's venue checked; then "Edit Venues…", which opens Settings ▸ Venues on that venue. Choosing a
/// venue calls `setVenue(id:)` and closes the menu; Esc and a click outside close it too.
struct ShellVenueMenu: View {
    let model: ReviewSessionModel
    let windowState: ShellReviewWindowState
    let services: ShellWindowServices

    static let title = "Review this paper for"
    static let caption = "The venue decides what the review weighs and how the report is written."
    static let editVenues = "Edit Venues…"

    /// One group of the menu.
    struct KindGroup: Equatable, Identifiable {
        var kind: VenueKind
        var title: String
        var venues: [VenueProfile]
        var id: VenueKind { kind }
    }

    /// Journals, then conferences, each in the order of the list; a kind with no venue is left out.
    static func groups(_ venues: [VenueProfile]) -> [KindGroup] {
        VenueKind.allCases.compactMap { kind in
            let matching = venues.filter { $0.kind == kind }
            return matching.isEmpty ? nil : KindGroup(kind: kind, title: kind == .journal ? "Journals" : "Conferences", venues: matching)
        }
    }

    /// A venue chosen in the menu: the paper's from now on, and the menu closes.
    @MainActor static func choose(_ id: String, in model: ReviewSessionModel, windowState: ShellReviewWindowState) {
        model.setVenue(id: id)
        windowState.venueMenuOpen = false
    }

    /// "Edit Venues…": Settings ▸ Venues on the paper's venue, and the menu closes.
    @MainActor static func editVenues(of model: ReviewSessionModel, windowState: ShellReviewWindowState, services: ShellWindowServices) {
        windowState.venueMenuOpen = false
        services.openVenueSettings(model.currentVenue.id)
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }                              // a short window: the menu scrolls instead of being cut off
        }
        .padding(.vertical, 8)
        .frame(minWidth: 0, maxWidth: 420)                     // as wide as the destination menu: EC's full name fits
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
        .padding(.horizontal, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Venue")
    }

    private var content: some View {
        let current = model.currentVenue.id
        return VStack(alignment: .leading, spacing: 0) {
            Text(ShellVenueMenu.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
            Text(ShellVenueMenu.caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.bottom, 4)
            ForEach(ShellVenueMenu.groups(model.venues)) { group in
                Divider().padding(.horizontal, 14).padding(.vertical, 4)
                Text(group.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 2)
                ForEach(group.venues) { venue in
                    row(venue, checked: venue.id == current)
                }
            }
            Divider().padding(.vertical, 6)
            Button {
                ShellVenueMenu.editVenues(of: model, windowState: windowState, services: services)
            } label: {
                Text(ShellVenueMenu.editVenues)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(ShellMenuRowButtonStyle())
        }
    }

    private func row(_ venue: VenueProfile, checked: Bool) -> some View {
        Button {
            ShellVenueMenu.choose(venue.id, in: model, windowState: windowState)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .opacity(checked ? 1 : 0)
                    .frame(width: 12)
                Image(systemName: ShellVenueState.symbol(for: venue.kind))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(ShellVenueMenu.rowTitle(venue))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if let short = ShellVenueMenu.rowShortName(venue) {
                    Text(short)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(ShellMenuRowButtonStyle())
        .accessibilityLabel(Text(ShellVenueState.name(venue)))
        .accessibilityAddTraits(checked ? .isSelected : [])
    }

    /// A row's name: the full name ("Journal of Economic Theory", "Journal (unspecified)"), else the short name.
    static func rowTitle(_ venue: VenueProfile) -> String {
        let full = venue.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        return full.isEmpty ? ShellVenueState.shortTitle(venue) : full
    }

    /// The short name after it, for a named venue whose full name differs from it ("JET"); none for an unspecified venue.
    static func rowShortName(_ venue: VenueProfile) -> String? {
        let short = venue.shortName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !venue.isUnspecified, !short.isEmpty, short != rowTitle(venue) else { return nil }
        return short
    }
}
