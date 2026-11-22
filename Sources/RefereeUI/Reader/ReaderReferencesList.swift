import SwiftUI
import RefereeCore
import AppCore

// The navigator's References tab (plan.md section 7.6): the parsed reference list, each entry with the icon of its
// latest lookup (`model.references[entry.id]`; none until it was looked up). A click calls `model.lookUpEntry(entryID:)`,
// which shows the citation card for that entry at the top of the PDF pane. The entry of an open card, or the one "Show in
// References" pointed at, is marked, and the list scrolls to it.

struct ReaderReferencesList: View {
    let controller: ReaderController

    var body: some View {
        let model = controller.model
        let entries = model.citations?.entries ?? []
        if entries.isEmpty {
            ReaderNavigatorMessage(text: model.citations == nil ? "Reading the reference list…" : "No reference list was found in this document.")
        } else {
            let marked = markedEntryID
            ScrollViewReader { proxy in
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
                .onChange(of: controller.navigator.scrollRequest) {
                    guard let id = controller.navigator.shownEntryID else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
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
                Text(entry.rawText)
                    .font(Theme.metadataFont)
                    .lineLimit(3)
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
