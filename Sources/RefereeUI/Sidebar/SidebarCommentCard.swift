import SwiftUI
import RefereeCore
import AppCore

/// One comment in the Comments tab (plan.md section 9.3): the card of the diagram, or its collapsed forms, with the
/// editor, the discussion thread, a reply that failed and a proposed revision under it. What it shows is decided by
/// `SidebarCardState`; this view only draws that and calls the model.
struct SidebarCommentCard: View {
    let model: ReviewSessionModel
    let comment: ReviewComment
    let inputs: SidebarCardInputs

    @State private var isExpanded = false           // a collapsed similar card the referee clicked open
    @State private var showsEverything = false      // "More": quote, body and suggestion in full
    @State private var cutOff: Set<String> = []     // the parts whose line limit hides something
    @State private var isHovered = false

    var body: some View {
        let state = SidebarCardState.make(for: comment, inputs: inputs, isExpanded: isExpanded, isHovered: isHovered)
        VStack(alignment: .leading, spacing: 8) {
            if state.isEditing {
                SidebarCommentEditor(model: model, mode: .edit(comment))
            } else {
                switch state.layout {
                case .full: fullCard(state)
                case .collapsedRejected: rejectedLine(state)
                case .collapsedSimilar: similarLines(state)
                }
            }
            if state.isThreadOpen, !state.isEditing {
                SidebarThreadView(model: model, comment: comment, state: state)
            } else if let failure = state.replyFailureMessage {
                SidebarReplyFailureLine(message: failure, canRetry: inputs.streamingTargetID == nil) { model.retryFailedReply() }
            }
            if let proposal = state.proposal, !state.isEditing {
                SidebarProposalBox(model: model, commentID: comment.id, proposal: proposal)
            }
        }
        .sidebarCardChrome(bar: barColor(state.bar), isSelected: state.isSelected, isMuted: state.layout == .collapsedRejected)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(SidebarCardState.kindName(comment.kind)) comment: \(comment.title)")
    }

    // ---- the three layouts ----

    private func fullCard(_ state: SidebarCardState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header(state)
            Text(comment.title)
                .font(Theme.cardTitleFont)
                .fixedSize(horizontal: false, vertical: true)
            if state.isExcludedFromReport {
                Label("Not included in the report", systemImage: "doc.badge.ellipsis")
                    .font(Theme.metadataFont)
                    .foregroundStyle(.secondary)
            }
            if let quote = state.quote {
                SidebarClampedText(text: AttributedString(SidebarText.quoted(quote)), lineLimit: showsEverything ? nil : 2) { note("quote", $0) }
                    .font(Theme.quoteFont)
                    .foregroundStyle(.secondary)
                    .help(quote)
            }
            if !comment.body.isEmpty {
                SidebarClampedText(text: AttributedString(comment.body), lineLimit: showsEverything ? nil : 6) { note("body", $0) }
                    .font(Theme.bodyFont)
            }
            if let suggestion = comment.suggestion, !suggestion.isEmpty {
                SidebarClampedText(text: SidebarText.labelled("Suggestion:", suggestion), lineLimit: showsEverything ? nil : 3) {
                    note("suggestion", $0)
                }
                .font(Theme.bodyFont)
            }
            if showsEverything || !cutOff.isEmpty {
                Button(showsEverything ? "Less" : "More") { showsEverything.toggle() }
                    .buttonStyle(.link)
                    .font(Theme.metadataFont)
            }
            footer(state)
        }
        .contentShape(Rectangle())
        .onTapGesture { select() }
    }

    /// Rejected: one grey line, kind and title; Undo on hover or selection.
    private func rejectedLine(_ state: SidebarCardState) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "xmark.circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Rejected")
            SidebarKindBadge(kind: comment.kind, muted: true)
            Text(comment.title)
                .font(Theme.bodyFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(comment.title)
            Spacer(minLength: 4)
            if state.actions.contains(.undo) {
                Button("Undo") { model.setStatus(.pending, for: comment.id) }
                    .controlSize(.small)
                    .help("Back to pending (U)")
            }
        }
        .frame(minHeight: 20)
        .contentShape(Rectangle())
        .onTapGesture { select() }
    }

    /// Similar and still pending: kind and title, then "Similar to: <title>", which selects the other comment.
    private func similarLines(_ state: SidebarCardState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                SidebarKindBadge(kind: comment.kind)
                Text(comment.title)
                    .font(Theme.bodyFont.weight(.semibold))
                    .lineLimit(1)
                    .help(comment.title)
            }
            if let otherID = state.similarToID, let otherTitle = state.similarToTitle {
                Button {
                    model.selectedCommentID = otherID
                    model.revealSelectedCommentInPDF()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.on.square")
                        Text("Similar to:")
                        Text(otherTitle)
                            .underline()
                            .lineLimit(1)
                    }
                    .font(Theme.metadataFont)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Show the comment on the same passage: \(otherTitle)")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            isExpanded = true
            select()
        }
    }

    // ---- header and footer of the full card ----

    /// kind badge · category · location; the location moves to a line of its own when the three do not fit.
    private func header(_ state: SidebarCardState) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                headerLeading(state)
                Spacer(minLength: 8)
                location(state)
            }
            VStack(alignment: .leading, spacing: 3) {
                headerLeading(state)
                location(state)
            }
        }
    }

    private func headerLeading(_ state: SidebarCardState) -> some View {
        HStack(spacing: 5) {
            if state.showsCheckmark {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.statusColor(.approved))
                    .accessibilityLabel("Approved")
            }
            SidebarKindBadge(kind: comment.kind)
            if state.showsYouBadge {
                SidebarTag(text: "You", color: Theme.ownColor)
            }
            if let category = state.categoryTitle {
                Text(category)
                    .font(Theme.metadataFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if state.showsVerifyTag {
                SidebarTag(text: "verify", color: .orange)
                    .help("The model cannot look references up: check any paper it names.")
            }
        }
    }

    @ViewBuilder private func location(_ state: SidebarCardState) -> some View {
        switch state.location {
        case .exact(let label):
            if !label.isEmpty {
                revealButton { Text(label) }
                    .help("Show the passage in the PDF")
            }
        case .fuzzy(let label):
            revealButton { Text("≈ " + label) }
                .help("Approximate match")
        case .pageOnly(let label):
            revealButton { Text(label).underline(true, pattern: .dot) }
                .help("Passage not located on the page")
        case .notFound:
            Label("Passage not found", systemImage: "exclamationmark.triangle.fill")
                .font(Theme.metadataFont)
                .foregroundStyle(.orange)
                .fixedSize()
        case .noPassage:
            EmptyView()
        }
    }

    private func revealButton<Content: View>(@ViewBuilder _ label: () -> Content) -> some View {
        Button(action: select) {
            label()
                .font(Theme.metadataFont)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .buttonStyle(.plain)
    }

    /// The buttons of the state, then "Attach to selection" for an unanchored comment; the ⋯ menu at the end.
    private func footer(_ state: SidebarCardState) -> some View {
        HStack(alignment: .top, spacing: 6) {
            SidebarFlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(state.actions) { action in
                    actionButton(action, state: state)
                }
                if state.showsAttachButton {
                    Button {
                        attachToSelection()
                    } label: {
                        Label("Attach to selection", systemImage: "link")
                    }
                    .disabled(!state.canAttachToSelection)
                    .help(state.canAttachToSelection ? "Anchor the comment to the text selected in the PDF"
                                                     : "Select the passage in the PDF first")
                }
            }
            Spacer(minLength: 0)
            moreMenu(state)
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @ViewBuilder private func actionButton(_ action: SidebarCardState.Action, state: SidebarCardState) -> some View {
        switch action {
        case .approve:
            Button { model.setStatus(.approved, for: comment.id) } label: { Label("Approve", systemImage: "checkmark") }
                .help("Approve (A)")
        case .reject:
            Button { model.setStatus(.rejected, for: comment.id) } label: { Label("Reject", systemImage: "xmark") }
                .help("Reject (R)")
        case .undo:
            Button { model.setStatus(.pending, for: comment.id) } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .help("Back to pending (U)")
        case .discuss:
            Button {
                model.selectedCommentID = comment.id
                model.openThreadCommentID = state.isThreadOpen ? nil : comment.id
            } label: {
                Text(state.isThreadOpen ? "Close" : "Discuss")
            }
            .help("Discuss this comment with the assistant (D)")
        case .edit:
            Button {
                model.selectedCommentID = comment.id
                model.editingCommentID = comment.id
            } label: {
                Text("Edit")
            }
            .help("Edit (E)")
        }
    }

    /// ⋯: change kind, include in or exclude from the report, attach to selection, delete (section 9.3).
    private func moreMenu(_ state: SidebarCardState) -> some View {
        Menu {
            Menu("Change Kind") {
                ForEach(CommentKind.allCases, id: \.self) { kind in
                    Toggle(SidebarCardState.kindName(kind), isOn: Binding(get: { comment.kind == kind },
                                                                         set: { _ in model.setKind(kind, for: comment.id) }))
                }
            }
            Button(comment.includeInReport ? "Exclude from Report" : "Include in Report") {
                model.setIncludeInReport(!comment.includeInReport, for: comment.id)
            }
            Button("Attach to Selection") { attachToSelection() }
                .disabled(!state.canAttachToSelection)
            Divider()
            Button("Delete Comment", role: .destructive) { model.deleteComment(comment.id) }
        } label: {
            Image(systemName: "ellipsis")
                .accessibilityLabel("More actions")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
    }

    // ---- actions ----

    /// Selects the comment and shows its passage in the PDF again (section 9.3, "selected").
    private func select() {
        model.selectedCommentID = comment.id
        model.revealSelectedCommentInPDF()
    }

    private func attachToSelection() {
        guard let selection = model.selection else { return }
        model.reanchorComment(comment.id, to: selection)
    }

    private func note(_ part: String, _ isCut: Bool) {
        if isCut { cutOff.insert(part) } else { cutOff.remove(part) }
    }

    private func barColor(_ bar: SidebarCardState.Bar) -> Color {
        switch bar {
        case .pending: return Theme.statusColor(.pending)
        case .approved: return Theme.statusColor(.approved)
        case .rejected: return Theme.statusColor(.rejected)
        case .own: return Theme.ownColor
        }
    }
}
