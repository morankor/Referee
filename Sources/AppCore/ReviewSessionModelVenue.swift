import Foundation
import RefereeCore

// The paper's venue (plan.md Appendix G.9; docs/contract-notes/step5-venue.md): which venue the open paper is reviewed
// for, and the recommendation on that venue's scale. The venue is `session.meta.venueID`, resolved against
// `settings.venues`; the engine gets it in `EngineContext.venue`, so every prompt and the report's style check follow it.
//
// Decisions (all in the notes file):
// - A session saved before venues has no venue id and is on Journal (unspecified), with its free-text `targetVenue`
//   still named in the prompts as before; so is a session whose venue was deleted from Settings.
// - `setVenue(id:)` sets `targetVenue` to the venue's display name (nil for an unspecified venue), so that anything that
//   reads `targetVenue` still names the venue. Choosing the venue the paper is already on changes nothing.
// - A change of venue keeps the report as it is, its recommendation and its label included: a journal's report reads
//   `recommendation`, a conference's `recommendationLabel` (`recommendationLabel` below picks by the current venue).

extension ReviewSessionModel {
    /// Settings ▸ Venues, in menu order: the built-ins and the user's own (`AppSettings.venues`).
    public var venues: [VenueProfile] { settings.venues }

    /// The venue the open paper is reviewed for: `session.meta.venueID` in `venues`; Journal (unspecified) for a session
    /// saved before venues, or one whose venue was deleted. With no paper open, the venue a new paper would get.
    public var currentVenue: VenueProfile {
        guard let session else { return settings.defaultVenue }
        return settings.venue(id: session.meta.venueID)
    }

    /// The paper's venue becomes the one with this id: `meta.venueID`, and `meta.targetVenue` its display name (nil for an
    /// unspecified venue). Saves at once, refreshes the plan and checks the report again for the new venue; comments,
    /// conversations and the report are kept as they are. Nothing happens without an open paper, for an id that is not in
    /// `venues`, or for the venue the paper is already on.
    public func setVenue(id: String) {
        guard session != nil, let venue = venues.first(where: { $0.id == id }), venue.id != currentVenue.id else { return }
        mutateSession { session in
            session.meta.venueID = venue.id
            session.meta.targetVenue = venue.isUnspecified ? nil : venue.displayName
        }
        Log.event("model.venue.set", ["kind": .id(venue.kind.rawValue), "builtIn": .bool(venue.isBuiltIn)])
        refreshPlan()
        if let markdown = session?.report?.markdown { lint(markdown) }
        track { [weak self] in await self?.flushPendingSave() }
    }

    /// The labels the report's recommendation is chosen from, most favourable first: the current venue's scale (for a
    /// journal "Accept", "Minor revision", "Major revision", "Reject").
    public var recommendationScale: [String] { currentVenue.scale }

    /// The report's recommendation as a label of `recommendationScale`, spelled as the scale spells it: for a journal
    /// `report.recommendation`, for a conference `report.recommendationLabel`. nil without a report, when none is set, or
    /// when the label is not on the current scale (the venue or its scale changed since).
    public var recommendationLabel: String? {
        guard let report = session?.report else { return nil }
        let venue = currentVenue
        let label = venue.kind == .conference ? report.recommendationLabel : report.recommendation?.label
        guard let label else { return nil }
        return venue.scale.first { $0.caseInsensitiveCompare(label.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }
    }

    /// The recommendation picker for either scale: a label of `recommendationScale` (ignoring case), or nil for none. For a
    /// journal it sets `report.recommendation`, as `setRecommendation(_:)` does; for a conference `report.recommendationLabel`,
    /// with `report.recommendation` nil. A label that is not on the scale, or no report, changes nothing.
    public func setRecommendation(label: String?) {
        guard session?.report != nil else { return }
        let venue = currentVenue
        var chosen: String?
        if let label {
            let wanted = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let match = venue.scale.first(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame }) else { return }
            chosen = match
        }
        mutateSession { session in
            switch venue.kind {
            case .journal:
                session.report?.recommendation = chosen.flatMap { Recommendation(label: $0) }
            case .conference:
                session.report?.recommendation = nil
                session.report?.recommendationLabel = chosen
            }
        }
    }

    /// The metadata of a paper opened for the first time: its title guess and the default venue of Settings ▸ Venues.
    func metaForNewPaper(title: String?) -> ManuscriptMeta {
        let venue = settings.defaultVenue
        return ManuscriptMeta(title: title, targetVenue: venue.isUnspecified ? nil : venue.displayName, reviewerNotes: "", venueID: venue.id)
    }
}
