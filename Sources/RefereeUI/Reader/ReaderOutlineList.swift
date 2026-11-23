import SwiftUI
import RefereeCore
import AppCore

// The navigator's Outline tab (plan.md section 7.6): `model.paper.outline` as an indented list; a click goes to the top
// of the item's page. The navigator leaves the tab out when the outline is empty.

struct ReaderOutlineList: View {
    let controller: ReaderController

    var body: some View {
        let outline = controller.model.paper?.outline ?? []
        if outline.isEmpty {
            ReaderNavigatorMessage(text: "This document has no outline.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(outline) { item in
                        Button {
                            if let page = item.pageIndex { controller.goToPage(page) }
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(item.title.isEmpty ? "Untitled" : item.title)
                                    .font(item.depth == 0 ? Theme.bodyFont : Theme.metadataFont)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let page = item.pageIndex {
                                    Text("p. \(page + 1)")
                                        .font(Theme.metadataFont)
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.leading, 6 + CGFloat(min(item.depth, 6)) * 12)
                            .padding(.trailing, 6)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(item.pageIndex == nil)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
            }
        }
    }
}
