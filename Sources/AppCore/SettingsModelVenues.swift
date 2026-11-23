import Foundation
import RefereeCore

// Settings ▸ Venues (plan.md Appendix G.9; docs/contract-notes/step5-venue.md). Every change goes through `update`, so it
// is saved (debounced 0.5 s) and posted to the open windows like any other setting. The built-ins can be edited and
// reset, never deleted; `AppSettings.venues` puts back any built-in a list lacks.

extension SettingsModel {
    /// Settings ▸ Venues, in menu order.
    public var venues: [VenueProfile] { settings.venues }

    /// The venue a newly opened paper gets.
    public var defaultVenue: VenueProfile { settings.defaultVenue }

    /// A new venue at the end of the list, "New journal" or "New conference" with no guidance (a conference with the
    /// default scale, `DefaultSettings.conferenceScale`); returns its id, a new UUID string.
    @discardableResult
    public func addVenue(kind: VenueKind) -> String {
        let id = UUID().uuidString.lowercased()
        let venue = VenueProfile(id: id, shortName: "", fullName: kind == .journal ? "New journal" : "New conference", kind: kind, guidance: "",
                                 recommendationScale: kind == .conference ? DefaultSettings.conferenceScale : [])
        update { $0.venues.append(venue) }
        return id
    }

    /// Replaces the venue that has `venue.id`, a built-in included, with `venue` as given: the editor may hold a label
    /// still being typed, and `VenueProfile.scale` drops blank and repeated labels where the scale is used. An id that is
    /// not in the list changes nothing.
    public func updateVenue(_ venue: VenueProfile) {
        update { settings in
            var list = settings.venues
            guard let index = list.firstIndex(where: { $0.id == venue.id }) else { return }
            list[index] = venue
            settings.venues = list
        }
    }

    /// A copy of the venue, just after it, named "<full name> (copy)", with a new id; returns that id, nil for an unknown id.
    @discardableResult
    public func duplicateVenue(id: String) -> String? {
        let list = settings.venues
        guard let index = list.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = list[index]
        copy.id = UUID().uuidString.lowercased()
        copy.fullName = copy.fullName.trimmingCharacters(in: .whitespacesAndNewlines) + " (copy)"
        update { $0.venues.insert(copy, at: index + 1) }
        return copy.id
    }

    /// Removes a venue the user added. A built-in is never deleted (reset it instead). When the deleted venue was the
    /// default, new papers get Journal (unspecified) again; papers already on it fall back to Journal (unspecified) too
    /// (`AppSettings.venue(id:)`).
    public func deleteVenue(id: String) {
        guard let venue = settings.venues.first(where: { $0.id == id }), !venue.isBuiltIn else { return }
        update { settings in
            settings.venues.removeAll { $0.id == id }
            if settings.defaultVenueID == id { settings.defaultVenueID = nil }
        }
    }

    /// Reorders the list as SwiftUI's `onMove` reports it: the venues at `source` go, in their order, to the place that
    /// was before `destination`.
    public func moveVenues(fromOffsets source: IndexSet, toOffset destination: Int) {
        update { settings in
            var list = settings.venues
            let offsets = source.filter { list.indices.contains($0) }
            guard !offsets.isEmpty else { return }
            let moving = offsets.map { list[$0] }
            let target = min(max(0, destination), list.count) - offsets.filter { $0 < destination }.count
            for offset in offsets.reversed() { list.remove(at: offset) }
            list.insert(contentsOf: moving, at: min(max(0, target), list.count))
            settings.venues = list
        }
    }

    /// A built-in venue back to its shipped profile (Appendix B.8), in its place in the list. Not a built-in: nothing.
    public func resetVenue(id: String) {
        guard let shipped = DefaultSettings.venues.first(where: { $0.id == id }) else { return }
        update { settings in
            var list = settings.venues
            guard let index = list.firstIndex(where: { $0.id == id }) else { return }
            list[index] = shipped
            settings.venues = list
        }
    }

    /// The venue newly opened papers get. An id that is not in the list changes nothing.
    public func setDefaultVenue(id: String) {
        guard settings.venues.contains(where: { $0.id == id }) else { return }
        update { $0.defaultVenueID = id == VenueProfile.journalID ? nil : id }
    }
}
