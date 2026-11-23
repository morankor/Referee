import SwiftUI
import RefereeCore
import AppCore

// The review window's inspector column (plan.md sections 9.2, 9.3, 9.5 and 9.8): Comments | Chat | Report.
//
// The tab switch is bound to `model.sidebarTab`, which the View menu (⌘1–⌘3), the toolbar's Report button,
// `ask` (opens Chat) and `beginComposingComment` (opens Comments) set as well. The sidebar declares no minimum width
// (section 9.2): every row wraps or shortens instead, so the window keeps the size it was given.

public struct ReviewSidebar: View {
    @Bindable private var model: ReviewSessionModel
    /// "Show Full Text of Every Comment" in the Comments tab's ⋯ menu (step 5, D1): one setting per window, kept here so
    /// that it survives a change of tab, off when the window opens.
    @State private var expandsAllCards = false

    public init(model: ReviewSessionModel) {
        _model = Bindable(model)
    }

    public var body: some View {
        VStack(spacing: 0) {
            Picker("Sidebar", selection: $model.sidebarTab) {
                Text("Comments").tag(SidebarTab.comments)
                Text("Chat").tag(SidebarTab.chat)
                Text("Report").tag(SidebarTab.report)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, Theme.sidebarPadding)
            .padding(.vertical, 8)
            Divider()
            Group {
                if model.session == nil {
                    SidebarNoDocumentView(phase: model.phase)
                } else {
                    switch model.sidebarTab {
                    case .comments: SidebarCommentsTab(model: model, expandsAllCards: $expandsAllCards)
                    case .chat: SidebarChatTab(model: model)
                    case .report: SidebarReportTab(model: model)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// What the sidebar shows before a review session exists: while the document opens, after it failed (the window says
/// why), or with no document.
struct SidebarNoDocumentView: View {
    let phase: DocumentPhase

    var body: some View {
        VStack(spacing: 8) {
            switch phase {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                Text("Opening…")
            case .failed:
                Text("No review: the document could not be opened.")
            case .empty, .ready:
                Text("Open a PDF to review it.")
            }
        }
        .font(Theme.bodyFont)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(Theme.sidebarPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
