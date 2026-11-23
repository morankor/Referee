import SwiftUI
import AppKit
import RefereeCore
import AppCore

/// Settings ▸ Venues (step 5, plan.md sections 9.6 and G.9): the venues a paper can be reviewed for, and the one new
/// papers get. On the left the list in the order of the toolbar's menu groups (built-ins marked, the default tagged),
/// reordered by dragging or with ↑ and ↓; Add (a journal or a conference), Duplicate, Delete (not a built-in, which is
/// reset instead). On the right the selected venue: its names, its kind, what a review for it weighs (the referee can
/// paste the venue's own guidelines for reviewers), the report's extra instructions and, for a conference, the ordered
/// labels of its recommendation scale. Every change goes through `SettingsModel`, which saves it and tells the windows.
struct ShellVenuesPane: View {
    let model: SettingsModel
    let navigation: ShellSettingsNavigation
    @State private var deleting: VenueProfile?

    var body: some View {
        let venues = model.venues
        let selected = ShellVenueEditing.selected(navigation.venue, in: venues)
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: Binding(get: { selected?.id }, set: { if let id = $0 { navigation.venue = id } })) {
                    ForEach(venues) { venue in
                        ShellVenueListRow(venue: venue, isDefault: venue.id == model.defaultVenue.id)
                            .tag(venue.id)
                    }
                    .onMove { source, destination in model.moveVenues(fromOffsets: source, toOffset: destination) }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                Divider()
                bottomBar(selected: selected, venues: venues)
            }
            .frame(width: 236)
            .background(Color(nsColor: .controlBackgroundColor))
            Divider()
            if let selected {
                ShellVenueEditor(model: model, venueID: selected.id)
                    .id(selected.id)                            // a new venue: new drafts in every field
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Text("No venue")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .confirmationDialog(deleting.map { "Delete “\(ShellVenueEditing.listTitle($0))”?" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Venue", role: .destructive) {
                if let venue = deleting { delete(venue, in: venues) }
                deleting = nil
            }
        } message: {
            Text("Papers reviewed for it are reviewed for Journal (unspecified) from then on.")
        }
    }

    private func bottomBar(selected: VenueProfile?, venues: [VenueProfile]) -> some View {
        HStack(spacing: 4) {
            Menu {
                Button("Add Journal") { navigation.venue = model.addVenue(kind: .journal) }
                Button("Add Conference") { navigation.venue = model.addVenue(kind: .conference) }
            } label: {
                Image(systemName: "plus")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add a journal or a conference")
            Button {
                if let selected, let copy = model.duplicateVenue(id: selected.id) { navigation.venue = copy }
            } label: {
                Image(systemName: "plus.square.on.square")
            }
            .disabled(selected == nil)
            .help("Duplicate the selected venue")
            Button {
                deleting = selected
            } label: {
                Image(systemName: "minus")
            }
            .disabled(selected?.isBuiltIn ?? true)
            .help(selected?.isBuiltIn == true ? "A built-in venue cannot be deleted; reset it instead" : "Delete the selected venue")
            Spacer(minLength: 4)
            Button {
                move(selected, by: -1, in: venues)
            } label: {
                Image(systemName: "arrow.up")
            }
            .disabled(ShellVenueEditing.position(of: selected, in: venues).map { $0 == 0 } ?? true)
            .help("Move up")
            Button {
                move(selected, by: 1, in: venues)
            } label: {
                Image(systemName: "arrow.down")
            }
            .disabled(ShellVenueEditing.position(of: selected, in: venues).map { $0 == venues.count - 1 } ?? true)
            .help("Move down")
        }
        .buttonStyle(.borderless)
        .padding(8)
    }

    private func move(_ venue: VenueProfile?, by step: Int, in venues: [VenueProfile]) {
        guard let position = ShellVenueEditing.position(of: venue, in: venues) else { return }
        let target = position + step
        guard venues.indices.contains(target) else { return }
        // onMove's offsets: down by one is "before the item after the next".
        model.moveVenues(fromOffsets: IndexSet(integer: position), toOffset: step > 0 ? target + 1 : target)
    }

    private func delete(_ venue: VenueProfile, in venues: [VenueProfile]) {
        let position = ShellVenueEditing.position(of: venue, in: venues) ?? 0
        model.deleteVenue(id: venue.id)
        let remaining = model.venues
        navigation.venue = remaining.isEmpty ? nil : remaining[max(0, min(position, remaining.count) - 1)].id
    }
}

/// One row of the venue list: the kind's symbol; the short name as the toolbar shows it, with "Built in" and "Default"
/// tags; the full name under it.
struct ShellVenueListRow: View {
    let venue: VenueProfile
    let isDefault: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: ShellVenueState.symbol(for: venue.kind))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(ShellVenueState.shortTitle(venue))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if venue.isBuiltIn {
                        CommonTag("Built in", color: .secondary)
                    }
                    if isDefault {
                        CommonTag("Default", color: .accentColor)
                            .help("New papers are reviewed for this venue")
                    }
                }
                Text(ShellVenueEditing.listDetail(venue))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The selected venue's fields.
struct ShellVenueEditor: View {
    let model: SettingsModel
    let venueID: String
    @State private var confirmingReset = false

    var body: some View {
        if let venue = model.venues.first(where: { $0.id == venueID }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header(venue)
                    names(venue)
                    guidance(venue)
                    if venue.kind == .conference {
                        ShellScaleEditor(labels: venue.recommendationScale) { labels in update { $0.recommendationScale = labels } }
                    }
                    reportInstructions(venue)
                }
                .padding(16)
            }
            .confirmationDialog("Reset “\(ShellVenueEditing.listTitle(venue))”?", isPresented: $confirmingReset) {
                Button("Reset Venue", role: .destructive) { model.resetVenue(id: venue.id) }
            } message: {
                Text("Its names, kind, guidance, report instructions and scale go back to those the app came with.")
            }
        }
    }

    private func header(_ venue: VenueProfile) -> some View {
        let isDefault = venue.id == model.defaultVenue.id
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(ShellVenueState.shortTitle(venue))
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            if venue.isBuiltIn {
                CommonTag("Built in", color: .secondary)
            }
            Spacer(minLength: 8)
            if isDefault {
                Label("Default for new papers", systemImage: "checkmark")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Button("Default for New Papers") { model.setDefaultVenue(id: venue.id) }
                    .controlSize(.small)
                    .help("Review every paper opened from now on for this venue; a paper's own choice in the toolbar stays")
            }
            if venue.isBuiltIn {
                Button("Reset…") { confirmingReset = true }
                    .controlSize(.small)
                    .disabled(ShellVenueEditing.isAsShipped(venue))
                    .help("Put back this venue as the app came with it")
            }
        }
    }

    private func names(_ venue: VenueProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    label("Short name")
                    HStack(spacing: 10) {
                        ShellCommitField("Short name", value: venue.shortName) { text in update { $0.shortName = text } }
                            .frame(width: 130)
                            .help("Shown in the toolbar")
                        Spacer(minLength: 4)
                        Text("Kind")
                            .foregroundStyle(.secondary)
                        Picker("Kind", selection: Binding(get: { venue.kind }, set: { kind in update { ShellVenueEditing.change(&$0, to: kind) } })) {
                            Text("Journal").tag(VenueKind.journal)
                            Text("Conference").tag(VenueKind.conference)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .help("A conference's report uses its scale and asks for no revision plan; its review speaks to a program committee")
                    }
                }
                GridRow {
                    label("Full name")
                    ShellCommitField("Full name", value: venue.fullName) { text in update { $0.fullName = text } }
                        .help("Named in the prompts, with the short name")
                }
            }
            ShellVenueProblems(problems: ShellVenueEditing.nameProblems(of: venue))
        }
    }

    private func guidance(_ venue: VenueProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What a review for it weighs")
                .font(.headline)
            Text("Sent with every prompt about a paper on this venue. You can paste the venue's own guidelines for reviewers here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ShellLongTextEditor(value: venue.guidance) { text in update { $0.guidance = text } }
                .frame(height: 80)
        }
    }

    private func reportInstructions(_ venue: VenueProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Report instructions")
                .font(.headline)
            Text("Optional. Added to the report's request only, for example what the venue's review form asks for.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ShellLongTextEditor(value: venue.reportInstructions ?? "") { text in
                update { $0.reportInstructions = ShellVenueEditing.instructions(text) }
            }
            .frame(height: 56)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    /// The venue as it is in the settings now, changed and handed back, so that a draft never overwrites a newer edit.
    private func update(_ change: (inout VenueProfile) -> Void) {
        guard var venue = model.venues.first(where: { $0.id == venueID }) else { return }
        change(&venue)
        model.updateVenue(venue)
    }
}

/// The ordered labels of a conference's recommendation scale, most favourable first: each one edited in place, moved
/// up or down, removed; "Add Label"; "Use Default Scale". The caption says the default is a stand-in (G.9).
struct ShellScaleEditor: View {
    let labels: [String]
    let commit: ([String]) -> Void

    static let caption = "The labels of the venue's review form, most favourable first. The default scale is a stand-in: replace it with the scale of the venue's real review form."

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recommendation scale")
                .font(.headline)
            Text(ShellScaleEditor.caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                HStack(spacing: 6) {
                    Text("\(index + 1).")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 22, alignment: .trailing)
                    ShellCommitField("Label", value: label) { text in commit(ShellVenueEditing.replacingLabel(in: labels, at: index, with: text)) }
                    Button {
                        commit(ShellVenueEditing.movingLabel(in: labels, at: index, by: -1))
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .disabled(index == 0)
                    .help("Move up: more favourable")
                    Button {
                        commit(ShellVenueEditing.movingLabel(in: labels, at: index, by: 1))
                    } label: {
                        Image(systemName: "arrow.down")
                    }
                    .disabled(index == labels.count - 1)
                    .help("Move down: less favourable")
                    Button {
                        commit(ShellVenueEditing.removingLabel(in: labels, at: index))
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .help("Remove this label")
                }
                .buttonStyle(.borderless)
            }
            HStack(spacing: 8) {
                Button {
                    commit(ShellVenueEditing.addingLabel(to: labels))
                } label: {
                    Label("Add Label", systemImage: "plus")
                }
                Button("Use Default Scale") { commit(DefaultSettings.conferenceScale) }
                    .disabled(labels == DefaultSettings.conferenceScale)
                    .help(DefaultSettings.conferenceScale.joined(separator: ", "))
            }
            .controlSize(.small)
            ShellVenueProblems(problems: ShellVenueEditing.scaleProblems(labels))
        }
    }
}

/// The editor's warnings, in orange, one per line.
struct ShellVenueProblems: View {
    let problems: [String]

    var body: some View {
        if !problems.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(problems, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                }
            }
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The pure rules of the Venues pane: which venue is shown, how a row reads, and the editor's checks and list edits.
enum ShellVenueEditing {
    /// The venue with this id, else the first of the list.
    static func selected(_ id: String?, in venues: [VenueProfile]) -> VenueProfile? {
        venues.first { $0.id == id } ?? venues.first
    }

    static func position(of venue: VenueProfile?, in venues: [VenueProfile]) -> Int? {
        guard let venue else { return nil }
        return venues.firstIndex { $0.id == venue.id }
    }

    /// A row's name: the full name, else the short name, else "Untitled venue".
    static func listTitle(_ venue: VenueProfile) -> String {
        let full = venue.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !full.isEmpty { return full }
        let short = venue.shortName.trimmingCharacters(in: .whitespacesAndNewlines)
        return short.isEmpty ? "Untitled venue" : short
    }

    /// The line under a row's short name: the full name ("Journal of Economic Theory"), or the kind ("conference") when
    /// the full name is empty or the same as the short name.
    static func listDetail(_ venue: VenueProfile) -> String {
        let full = venue.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        return full.isEmpty || full == ShellVenueState.shortTitle(venue) ? ShellVenueState.kindName(venue.kind) : full
    }

    /// A built-in exactly as shipped (Reset has nothing to do).
    static func isAsShipped(_ venue: VenueProfile) -> Bool {
        DefaultSettings.venues.contains(venue)
    }

    /// Another kind: a conference that has no label yet starts from the default scale; a journal keeps its labels stored
    /// (unused), so that turning it back into a conference brings them back.
    static func change(_ venue: inout VenueProfile, to kind: VenueKind) {
        venue.kind = kind
        if kind == .conference, venue.recommendationScale.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            venue.recommendationScale = DefaultSettings.conferenceScale
        }
    }

    /// Report instructions as stored: nil for none.
    static func instructions(_ text: String) -> String? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    // ---- checks ----

    static func nameProblems(of venue: VenueProfile) -> [String] {
        let short = venue.shortName.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = venue.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        return short.isEmpty && full.isEmpty ? ["Give the venue a short or a full name: the prompts name it."] : []
    }

    /// What the scale's labels lose when they are used (`VenueProfile.scale` leaves out blank and repeated labels, and
    /// falls back on the default scale when none is left), and a scale too short to choose from.
    static func scaleProblems(_ labels: [String]) -> [String] {
        var problems: [String] = []
        var kept: [String] = []
        var blank = false
        var repeated: [String] = []
        for label in labels {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                blank = true
            } else if kept.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                if !repeated.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) { repeated.append(trimmed) }
            } else {
                kept.append(trimmed)
            }
        }
        if blank { problems.append("A blank label is left out.") }
        for label in repeated { problems.append("“\(label)” is on the scale twice; the second is left out.") }
        if kept.isEmpty {
            problems.append("The scale has no label, so the default scale is used.")
        } else if kept.count == 1 {
            problems.append("A scale needs at least two labels to choose between.")
        }
        return problems
    }

    /// Every check of a venue, in the order the editor shows them.
    static func problems(of venue: VenueProfile) -> [String] {
        nameProblems(of: venue) + (venue.kind == .conference ? scaleProblems(venue.recommendationScale) : [])
    }

    // ---- the scale's edits ----

    /// "New label", or "New label 2", … when that is on the scale already.
    static func addingLabel(to labels: [String]) -> [String] {
        func taken(_ label: String) -> Bool { labels.contains { $0.caseInsensitiveCompare(label) == .orderedSame } }
        var label = "New label"
        var number = 2
        while taken(label) {
            label = "New label \(number)"
            number += 1
        }
        return labels + [label]
    }

    static func movingLabel(in labels: [String], at index: Int, by step: Int) -> [String] {
        let target = index + step
        guard labels.indices.contains(index), labels.indices.contains(target) else { return labels }
        var moved = labels
        moved.swapAt(index, target)
        return moved
    }

    static func removingLabel(in labels: [String], at index: Int) -> [String] {
        guard labels.indices.contains(index) else { return labels }
        var removed = labels
        removed.remove(at: index)
        return removed
    }

    static func replacingLabel(in labels: [String], at index: Int, with text: String) -> [String] {
        guard labels.indices.contains(index) else { return labels }
        var replaced = labels
        replaced[index] = text
        return replaced
    }
}
