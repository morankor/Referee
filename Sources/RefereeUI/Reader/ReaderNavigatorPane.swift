import SwiftUI
import RefereeCore
import AppCore

// The navigator, the review window's left column (plan.md sections 7.6 and 9.2): three tabs. Pages: a PDFThumbnailView
// bound to the controller's PDF view. Outline: the paper's outline as an indented list, a click goes to its page; the
// tab is left out when the paper has no outline. References: the parsed reference list with a status icon per entry
// (none until it was looked up); a click looks it up and shows its card at the top of the PDF pane.
//
// The pane declares no width: the Shell gives the column 160–240 points (section 9.2).

public struct NavigatorPane: View {       // Pages / Outline / References
    private let controller: ReaderController

    public init(controller: ReaderController) { self.controller = controller }

    public var body: some View {
        let navigator = controller.navigator
        let hasOutline = !(controller.model.paper?.outline.isEmpty ?? true)
        let tabs = ReaderNavigatorTab.allCases.filter { $0 != .outline || hasOutline }
        let shown: ReaderNavigatorTab = navigator.tab == .outline && !hasOutline ? .pages : navigator.tab
        VStack(spacing: 0) {
            // The picker shows the tab on screen, which is Pages when Outline was chosen for a paper that has none.
            Picker("Navigator", selection: Binding(get: { shown }, set: { navigator.tab = $0 })) {
                ForEach(tabs) { tab in Text(tab.title).tag(tab) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, Theme.sidebarPadding)
            .padding(.vertical, 8)
            Divider()
            Group {
                switch shown {
                case .pages:
                    ReaderThumbnailsRepresentable(pdfView: controller.pdfView)
                case .outline:
                    ReaderOutlineList(controller: controller)
                case .references:
                    ReaderReferencesList(controller: controller)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
