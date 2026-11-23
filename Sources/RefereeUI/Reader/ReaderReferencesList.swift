import SwiftUI
import AppKit
import RefereeCore
import AppCore

// The navigator's References tab (plan.md section 7.6, refined by design review D23): a filter field and the count
// above the parsed reference list. Each row is headed "Acemoglu et al. (2011)", with the reference as printed (two
// lines) under it and the icon of its latest lookup (`model.references[entry.id]`; none until it was looked up) on the
// left. A click calls `model.lookUpEntry(entryID:)`, which shows the citation card for that entry at the top of the PDF
// pane. The entry of an open card, or the one "Show in References" pointed at, is marked, and the list scrolls to it.
//
// Decisions (also in docs/contract-notes/step5-reader.md):
// - The filter keeps an entry when every word typed occurs in the reference as printed or in its heading, ignoring
//   case and diacritics (`ReaderCitationText.entry(_:matches:)`). Filtering sends nothing: a lookup still happens only
//   on a click. The filter lives in the navigator's state, so it stays when the tab changes; "Show in References"
//   clears it when it hides the entry.
// - Esc in the field clears it and gives the keyboard back to the window, as Esc in the other fields does (D2).

struct ReaderReferencesList: View {
    let controller: ReaderController

    var body: some View {
        let model = controller.model
        let entries = model.citations?.entries ?? []
        if entries.isEmpty {
            ReaderNavigatorMessage(text: model.citations == nil ? "Reading the reference list…" : "No reference list was found in this document.")
        } else {
            let filter = controller.navigator.referenceFilter
            let shown = entries.filter { ReaderCitationText.entry($0, matches: filter) }
            let isFiltering = ReaderCitationText.isFiltering(filter)
            VStack(spacing: 0) {
                ReaderReferencesFilterField(navigator: controller.navigator,
                                            count: ReaderCitationText.referenceCount(shown: shown.count, total: entries.count, isFiltering: isFiltering))
                Divider()
                if shown.isEmpty {
                    ReaderNavigatorMessage(text: "No reference contains these words.")
                } else {
                    list(shown)
                }
            }
        }
    }

    private func list(_ entries: [BibEntry]) -> some View {
        let model = controller.model
        let marked = markedEntryID
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(entries) { entry in
                        ReaderReferenceRow(entry: entry, status: ReaderReferenceStatus.of(model.references[entry.id]), isMarked: entry.id == marked) {
                            controller.navigator.shownEntryID = entry.id
                            model.lookUpEntry(entryID: entry.id)
                        }
                        .id(entry.id)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
            // Also when the list first appears: "Show in References" may have switched to this tab a moment ago.
            .task(id: controller.navigator.scrollRequest) {
                await Task.yield()
                guard let id = controller.navigator.shownEntryID else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    /// The entry of the card on screen when it was opened from this list, else the one "Show in References" chose.
    private var markedEntryID: Int? {
        switch controller.model.citationLookup {
        case .resolving(.entry(let id)), .resolved(.entry(let id), _, _): return id
        default: return controller.navigator.shownEntryID
        }
    }
}

/// The filter field with its magnifying glass, and the count under it: "9 references", "3 of 9 references".
private struct ReaderReferencesFilterField: View {
    @Bindable var navigator: ReaderNavigatorState
    let count: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Filter references", text: $navigator.referenceFilter, prompt: Text("Filter references"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .onExitCommand {
                        navigator.referenceFilter = ""
                        NSApp.keyWindow?.makeFirstResponder(nil)
                    }
            }
            .controlSize(.small)
            Text(count)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, Theme.sidebarPadding)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}

private struct ReaderReferenceRow: View {
    let entry: BibEntry
    let status: ReaderReferenceStatus?
    let isMarked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Group {
                    if let status {
                        Image(systemName: status.systemImage)
                            .foregroundStyle(Self.color(status.tint))
                            .help(status.help)
                    } else {
                        Image(systemName: "circle")
                            .hidden()
                    }
                }
                .font(Theme.metadataFont)
                .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ReaderCitationText.entryHeading(entry))
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                    Text(entry.rawText)
                        .font(Theme.metadataFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(isMarked ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("Look this reference up")
    }

    static func color(_ tint: ReaderReferenceStatus.Tint) -> Color {
        switch tint {
        case .green: return .green
        case .orange: return .orange
        case .secondary: return .secondary
        }
    }
}

/// A line of grey text in the middle of a navigator tab.
struct ReaderNavigatorMessage: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.metadataFont)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(Theme.sidebarPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
