import SwiftUI
import RefereeCore
import AppCore

/// One comment in the Comments tab (plan.md section 9.3): the card of the diagram, its compact form, or its collapsed
/// forms, with the editor, the discussion thread, a proposed revision and a reply that failed under it. What it shows is
/// decided by `SidebarCardState`; this view only draws that and calls the model.
///
/// Step 5 (docs/design-review.md): only the card being worked on is shown in full; the others are compact, their header
/// and title (D1). With the thread open the proposed revision sits where the discussion ends, above the reply field
/// (D18). Locations say what they mean (D17), and VoiceOver hears kind, status, place and title, with the four triage
/// actions (D22).
struct SidebarCommentCard: View {
    let model: ReviewSessionModel
    let comment: ReviewComment
    let inputs: SidebarCardInputs
    /// Called when a click on this card in the list selects it, before the selection changes: the list then leaves its
    /// scroll position alone, since the card is already where the referee looks (D7).
    var onSelectFromList: (UUID) -> Void = { _ in }

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
                case .compact: compactCard(state)
                case .collapsedRejected: rejectedLine(state)
                case .collapsedSimilar: similarLines(state)
                }
            }
            if state.isThreadOpen, !state.isEditing {
                SidebarThreadView(model: model, comment: comment, state: state)
            } else {
                if let proposal = state.proposal, !state.isEditing, state.layout == .full {
                    SidebarProposalBox(model: model, comment: comment, proposal: proposal)
                }
                if let failure = state.replyFailureMessage {
                    SidebarReplyFailureLine(message: failure, canRetry: inputs.streamingTargetID == nil) { model.retryFailedReply() }
                }
            }
        }
        .sidebarCardChrome(bar: barColor(state.bar), isSelected: state.isSelected, isMuted: state.layout == .collapsedRejected)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SidebarCardState.accessibilityLabel(of: comment, location: state.location))
        .accessibilityAction(named: "Approve") { model.setStatus(.approved, for: comment.id) }
        .accessibilityAction(named: "Reject") { model.setStatus(.rejected, for: comment.id) }
        .accessibilityAction(named: "Discuss") { openThread() }
        .accessibilityAction(named: "Edit") { edit() }
    }

    // ---- the four layouts ----

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
        .onTapGesture { selectFromList() }
    }

    /// Compact (D1): the header, with the number of messages and a waiting revision, then the title on two lines at
    /// most. No quote, body, suggestion or buttons; a click selects the comment, which then shows in full.
    private func compactCard(_ state: SidebarCardState) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            header(state)
            Text(comment.title)
                .font(Theme.cardTitleFont)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(comment.title)
        }
        .contentShape(Rectangle())
        .onTapGesture { selectFromList() }
    }

    /// Rejected: one grey line, kind, title and who wrote it; Undo on hover or selection.
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
            if let source = state.source {
                // Title and label share the line, each cut when it must be; no frame of its own, so that the line
                // asks for no width the narrowest inspector does not have (plan.md section 9.2).
                SidebarSourceLabel(source: source)
            }
            if state.actions.contains(.undo) {
                Button("Undo") { model.setStatus(.pending, for: comment.id) }
                    .controlSize(.small)
                    .help("Back to pending (U)")
            }
        }
        .frame(minHeight: 20)
        .contentShape(Rectangle())
        .onTapGesture { selectFromList() }
    }

    /// Similar and still pending: kind, title and who wrote it, then "Similar to: <title> (<who wrote that one>)",
    /// which selects the other comment: two models that raised the same point show as such (step 5b).
    private func similarLines(_ state: SidebarCardState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    SidebarKindBadge(kind: comment.kind)
                    similarTitle
                    if let source = state.source {
                        Spacer(minLength: 8)
                        SidebarSourceLabel(source: source)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        SidebarKindBadge(kind: comment.kind)
                        if let source = state.source { SidebarSourceLabel(source: source) }
                    }
                    similarTitle
                }
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
                        if let otherSource = state.similarToSource {
                            Text("(\(otherSource.text))")
                                .lineLimit(1)
                                .layoutPriority(1)
                        }
                    }
                    .font(Theme.metadataFont)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Show the comment on the same passage: \(otherTitle)"
                      + (state.similarToSource.map { ", written by \($0.text)" } ?? ""))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            isExpanded = true
            selectFromList()
        }
    }

    private var similarTitle: some View {
        Text(comment.title)
            .font(Theme.bodyFont.weight(.semibold))
            .lineLimit(1)
            .help(comment.title)
    }

    // ---- header and footer ----

    /// kind badge · category on the left, the location on the right; then who wrote the comment (step 5b) and, on a
    /// compact card, the number of messages and a waiting revision, on the first line when everything fits.
    private func header(_ state: SidebarCardState) -> some View {
        SidebarCardHeader(hasFacts: hasFacts(state)) {
            headerLeading(state)
        } location: {
            location(state)
        } facts: {
            headerFacts(state)
        }
    }

    private func hasFacts(_ state: SidebarCardState) -> Bool {
        state.source != nil || (state.layout == .compact && (state.threadCount > 0 || state.proposal != nil))
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
                CommonTag("You", color: Theme.ownColor)
            }
            if let category = state.categoryTitle {
                Text(category)
                    .font(Theme.metadataFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if state.showsVerifyTag {
                CommonTag("verify", color: .orange)
                    .help("The model cannot look references up: check any paper it names.")
            }
        }
    }

    /// Who wrote it; on a compact card also the number of messages and a waiting revision (D1).
    private func headerFacts(_ state: SidebarCardState) -> some View {
        HStack(spacing: 6) {
            if let source = state.source {
                SidebarSourceLabel(source: source)
            }
            if state.layout == .compact && state.threadCount > 0 {
                Label("\(state.threadCount)", systemImage: "bubble.left.and.bubble.right")
                    .font(Theme.metadataFont)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .help(state.threadCount == 1 ? "1 message in the discussion" : "\(state.threadCount) messages in the discussion")
                    .accessibilityLabel(state.threadCount == 1 ? "1 message" : "\(state.threadCount) messages")
            }
            if state.layout == .compact && state.proposal != nil {
                CommonTag("Revision proposed", color: .accentColor)
                    .help("The assistant proposed a revision: select the comment to see it")
            }
        }
    }

    @ViewBuilder private func location(_ state: SidebarCardState) -> some View {
        switch state.location {
        case .exact, .fuzzy, .pageOnly:
            if let text = SidebarCardState.locationText(state.location) {
                Button(action: selectFromList) {
                    Text(text)
                        .font(Theme.metadataFont)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .help(SidebarCardState.locationHelp(state.location) ?? "")
                .accessibilityLabel(SidebarCardState.spokenLocation(state.location) ?? text)
            }
        case .notFound:
            Label("Passage not found", systemImage: "exclamationmark.triangle.fill")
                .font(Theme.metadataFont)
                .foregroundStyle(.orange)
                .fixedSize()
        case .noPassage:
            EmptyView()
        }
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
                if state.isThreadOpen {
                    model.openThreadCommentID = nil
                } else {
                    openThread()
                }
            } label: {
                if state.isThreadOpen {
                    Label("Discuss", systemImage: "chevron.up")      // open: the same button hides it again
                } else {
                    Text("Discuss")
                }
            }
            .help(state.isThreadOpen ? "Hide the discussion (Esc)" : "Discuss this comment with the assistant (D)")
        case .edit:
            Button(action: edit) {
                Text("Edit")
            }
            .help("Edit (E)")
        }
    }

    /// ⋯: change kind, earlier versions, include in or exclude from the report, attach to selection, delete (section
    /// 9.3; "Earlier Versions" is D31).
    private func moreMenu(_ state: SidebarCardState) -> some View {
        Menu {
            Menu("Change Kind") {
                ForEach(CommentKind.allCases, id: \.self) { kind in
                    Toggle(SidebarCardState.kindName(kind), isOn: Binding(get: { comment.kind == kind },
                                                                         set: { _ in model.setKind(kind, for: comment.id) }))
                }
            }
            earlierVersionsMenu
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

    /// The versions an edit or an accepted revision replaced, newest first. Choosing one makes it the comment again;
    /// the model keeps the version it replaces, so that the step can be undone the same way (D31).
    private var earlierVersionsMenu: some View {
        let versions = comment.previousVersions
        return Menu("Earlier Versions") {
            ForEach(Array(versions.indices.reversed()), id: \.self) { index in
                let version = versions[index]
                Button(SidebarCardState.versionTitle(version.title)) {
                    model.editComment(comment.id, kind: version.kind, category: comment.category, title: version.title,
                                      body: version.body, suggestion: version.suggestion)
                }
                .help(version.title)
            }
        }
        .disabled(versions.isEmpty)
    }

    // ---- actions ----

    /// A click on the card: selects the comment and shows its passage in the PDF again (section 9.3, "selected"). The
    /// list is told first, so that it does not scroll a card the referee just clicked (D7).
    private func selectFromList() {
        if model.selectedCommentID != comment.id { onSelectFromList(comment.id) }
        model.selectedCommentID = comment.id
        model.revealSelectedCommentInPDF()
    }

    private func openThread() {
        model.selectedCommentID = comment.id
        model.openThreadCommentID = comment.id
    }

    private func edit() {
        model.selectedCommentID = comment.id
        model.editingCommentID = comment.id
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
