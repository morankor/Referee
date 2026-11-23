import SwiftUI
import RefereeCore
import AppCore

/// The Comments tab (plan.md section 9.3). Header: the filter chips and the Kind menu, a thin progress bar with "12 of
/// 31 decided" (or "All 31 decided" and Write Report), "+" for a new own comment and a ⋯ menu ("Show Full Text of Every
/// Comment", "Clear Undecided AI Comments…"). List: the editing card of a new comment at the top while `model.composing`
/// is set, then the cards in the order of `model.visibleComments`, then the drafts of a review in progress under
/// "Writing… · 2 received".
///
/// The list follows the model: a new selection (J/K, A and R with auto-advance, a highlight clicked in the PDF) scrolls
/// its card to the top, so that the eye finds the current comment in the same place after every key (D7); a click on a
/// card in the list leaves the list where it is. An opened thread or editor scrolls its card to the top too.
///
/// With no comment at all the tab says why and what to do (D6): "No comments yet" with Run Review and Add Comment, or
/// Set Up AI Provider… when there is no provider, or "Reviewing…" while a review has not delivered anything yet.
struct SidebarCommentsTab: View {
    let model: ReviewSessionModel
    /// "Show Full Text of Every Comment" (D1): kept by the window's sidebar, so that it survives a change of tab.
    @Binding var expandsAllCards: Bool

    @Environment(\.uiActions) private var uiActions
    @State private var confirmsClearing = false
    @State private var clickedID: UUID?             // a card the referee clicked in the list: no scrolling for it (D7)

    var body: some View {
        let comments = model.session?.comments ?? []
        VStack(spacing: 0) {
            // Chips and progress only once there is a comment to filter or count (D6): a first comment being written
            // or streamed does not bring back a row of zeros.
            if comments.isEmpty {
                emptyHeader(comments)
            } else {
                header(comments)
            }
            if comments.isEmpty && model.drafts.isEmpty && model.composing == nil {
                emptyState
            } else {
                Divider()
                list(comments)
            }
        }
    }

    // ---- the list ----

    private func list(_ comments: [ReviewComment]) -> some View {
        let visible = model.visibleComments
        let inputs = SidebarCardInputs(model: model, expandsAllCards: expandsAllCards)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.listSpacing) {
                    if model.composing != nil {
                        SidebarCommentEditor(model: model, mode: .compose)
                            .sidebarCardChrome(bar: Theme.ownColor, isSelected: true)
                            .id(SidebarListKey.composing)
                    }
                    if visible.isEmpty && model.drafts.isEmpty && model.composing == nil {
                        noMatch
                    }
                    ForEach(visible, id: \.listKey) { comment in
                        SidebarCommentCard(model: model, comment: comment, inputs: inputs, onSelectFromList: { clickedID = $0 })
                            .id(comment.listKey)
                    }
                    if !model.drafts.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text(writingLabel(comments))
                                .font(Theme.metadataFont.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                        .id(SidebarListKey.writing)
                        let source = SidebarSourceNames(model: model).runningSource
                        ForEach(model.drafts, id: \.listKey) { draft in
                            SidebarDraftCard(draft: draft, rubric: model.settings.rubric, source: source)
                                .id(draft.listKey)
                        }
                    }
                }
                .padding(Theme.sidebarPadding)
            }
            .onAppear { scroll(proxy, to: model.selectedCommentID) }
            .onChange(of: model.selectedCommentID) { _, id in
                defer { clickedID = nil }
                guard id == nil || id != clickedID else { return }
                scroll(proxy, to: id)
            }
            .onChange(of: model.openThreadCommentID) { _, id in scroll(proxy, to: id) }
            .onChange(of: model.editingCommentID) { _, id in scroll(proxy, to: id) }
            .onChange(of: model.composing != nil) { _, isComposing in
                if isComposing { withAnimation(Self.scrollAnimation) { proxy.scrollTo(SidebarListKey.composing, anchor: .top) } }
            }
        }
    }

    /// "Writing… · 2 received" while a review streams (D6).
    private func writingLabel(_ comments: [ReviewComment]) -> String {
        guard let start = SidebarCommentsFacts.reviewStart(of: model) else { return SidebarCommentsFacts.writingLabel(received: 0) }
        return SidebarCommentsFacts.writingLabel(received: SidebarCommentsFacts.receivedCount(of: comments, since: start))
    }

    static let scrollAnimation: Animation = .easeOut(duration: 0.2)

    /// The card of `id` to the top of the list (D7).
    private func scroll(_ proxy: ScrollViewProxy, to id: UUID?) {
        guard let id, model.visibleComments.contains(where: { $0.id == id }) else { return }
        withAnimation(Self.scrollAnimation) { proxy.scrollTo(SidebarListKey.comment(id), anchor: .top) }
    }

    // ---- header ----

    private func header(_ comments: [ReviewComment]) -> some View {
        let triage = model.triage
        return VStack(alignment: .leading, spacing: 8) {
            SidebarFlowLayout(spacing: 5, lineSpacing: 5) {
                ForEach(SidebarFilterChip.chips(for: comments)) { chip in
                    SidebarFilterChipButton(chip: chip, isSelected: model.filter == chip.filter) { model.filter = chip.filter }
                }
                SidebarKindFilterMenu(model: model, comments: comments)
            }
            HStack(spacing: 8) {
                if SidebarFilterChip.isAllDecided(decided: triage.decided, total: triage.total) {
                    Label(SidebarFilterChip.allDecidedText(total: triage.total), systemImage: "checkmark.circle.fill")
                        .font(Theme.metadataFont.weight(.semibold))
                        .foregroundStyle(Theme.statusColor(.approved))
                        .fixedSize()
                    Button("Write Report") { model.sidebarTab = .report }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Open the Report tab (⌘3)")
                    Spacer(minLength: 0)
                } else {
                    ProgressView(value: Double(triage.decided), total: Double(max(1, triage.total)))
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .accessibilityLabel("Comments decided")
                    Text(SidebarFilterChip.triageText(decided: triage.decided, total: triage.total))
                        .font(Theme.metadataFont)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                addButton
                moreMenu(comments)
            }
            if confirmsClearing {
                clearingConfirmation(count: undecidedAICount(comments))
            }
        }
        .padding(.horizontal, Theme.sidebarPadding)
        .padding(.vertical, 8)
    }

    /// With no comment: only "+" and "⋯", at the top right (D6). Also while the first comment is written or streamed.
    private func emptyHeader(_ comments: [ReviewComment]) -> some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            addButton
            moreMenu(comments)
        }
        .padding(.horizontal, Theme.sidebarPadding)
        .padding(.vertical, 8)
    }

    private var addButton: some View {
        Button {
            model.beginComposingComment()
        } label: {
            Image(systemName: "plus")
                .accessibilityLabel("New comment")
        }
        .buttonStyle(.borderless)
        .help("New comment (N)")
    }

    private func moreMenu(_ comments: [ReviewComment]) -> some View {
        Menu {
            Toggle("Show Full Text of Every Comment", isOn: $expandsAllCards)
            Divider()
            Button("Clear Undecided AI Comments…") { confirmsClearing = true }
                .disabled(undecidedAICount(comments) == 0)
        } label: {
            Image(systemName: "ellipsis.circle")
                .accessibilityLabel("More")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }

    /// Asked in place, not in a sheet: deleting the pending AI comments cannot be undone.
    private func clearingConfirmation(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(count == 1 ? "Delete the 1 AI comment that is still pending?" : "Delete the \(count) AI comments that are still pending?")
                .font(Theme.bodyFont)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button("Cancel") { confirmsClearing = false }
                Button("Delete", role: .destructive) {
                    model.deletePendingAIComments()
                    confirmsClearing = false
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    private func undecidedAICount(_ comments: [ReviewComment]) -> Int {
        comments.filter { comment in
            if case .ai = comment.origin { return comment.status == .pending }
            return false
        }.count
    }

    // ---- empty states (section 9.9; D6) ----

    /// Comments exist, but none passes the filter.
    private var noMatch: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No comments match this filter.")
                .font(Theme.bodyFont)
                .foregroundStyle(.secondary)
            Button("Show All") { model.filter = .all }
                .controlSize(.small)
        }
        .padding(.top, 8)
    }

    /// No comment, no draft, nothing being written: what the referee can do next. In a scroll view, so that the tab
    /// asks for no height of its own (plan.md section 9.2; the window's minimum size is measured at a width of zero).
    private var emptyState: some View {
        GeometryReader { geometry in
            ScrollView {
                emptyContent
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: geometry.size.height)
            }
        }
    }

    @ViewBuilder private var emptyContent: some View {
        if SidebarCommentsFacts.reviewStart(of: model) != nil {
            ContentUnavailableView {
                Label {
                    Text("Reviewing…")
                } icon: {
                    ProgressView()
                }
            } description: {
                Text("Comments appear here as the model writes them.")
            }
        } else if model.activeProvider == nil {
            ContentUnavailableView {
                Label("No comments yet", systemImage: "text.badge.checkmark")
            } description: {
                emptyDescription("Set up an AI provider to run a review. You can still read the paper and add your own comments.")
            } actions: {
                Button("Set Up AI Provider…") { uiActions.openSettings() }
                    .buttonStyle(.borderedProminent)
                    .help("Open Settings ▸ Providers")
                addCommentButton
            }
        } else {
            ContentUnavailableView {
                Label("No comments yet", systemImage: "text.badge.checkmark")
            } description: {
                emptyDescription("Run a review to have the AI read the paper and draft comments, or select a passage and add your own.")
            } actions: {
                Button("Run Review") { model.startReview() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canStartReview)
                    .help(model.sendPlan?.blockingReason ?? "Run the review (⌘R)")
                addCommentButton
            }
        }
    }

    /// The sentence, then the document facts in a smaller line under it.
    private func emptyDescription(_ sentence: String) -> some View {
        VStack(spacing: 8) {
            Text(sentence)
            if let facts = SidebarCommentsFacts.documentFacts(of: model) {
                Text(facts)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var addCommentButton: some View {
        Button("Add Comment") { model.beginComposingComment() }
            .buttonStyle(.bordered)
            .help("Add your own comment (N)")
    }
}

/// The identity of a row of the Comments list. A comment and the draft it replaces carry the same UUID (the engine
/// gives the finished comment its draft's id), so rows are told apart by kind as well: with UUIDs alone the lazy
/// stack kept showing a finished comment as the draft it had been.
enum SidebarListKey: Hashable {
    case composing
    case comment(UUID)
    case writing
    case draft(UUID)
}

fileprivate extension ReviewComment {
    var listKey: SidebarListKey { .comment(id) }
}

fileprivate extension DraftComment {
    var listKey: SidebarListKey { .draft(id) }
}

/// The look of a filter chip: its title and count in a capsule, filled with the accent colour when it is in force.
struct SidebarChipLabel: View {
    let title: String
    let count: Int?
    var showsChevron = false
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            if let count {
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
            }
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
            }
        }
        .font(Theme.metadataFont.weight(.medium))
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.13), in: Capsule())
        .contentShape(Capsule())
        .fixedSize()
    }
}

/// One filter chip: its title and count; filled with the accent colour when it is the filter in force.
struct SidebarFilterChipButton: View {
    let chip: SidebarFilterChip
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SidebarChipLabel(title: chip.title, count: chip.count, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(chip.title), \(chip.count)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The fifth chip (D11): a menu of the kinds with their counts, the one in force checked; choosing it again shows every
/// comment. Its label is "Kind ▾" while no kind is filtered, else "{Kind} {count}", filled like a chip in force.
struct SidebarKindFilterMenu: View {
    let model: ReviewSessionModel
    let comments: [ReviewComment]

    var body: some View {
        let inForce = SidebarFilterChip.kindInForce(model.filter, comments: comments)
        Menu {
            ForEach(SidebarFilterChip.kindItems(for: comments)) { item in
                Toggle(item.menuTitle, isOn: Binding(get: { model.filter == item.filter }, set: { _ in choose(item.filter) }))
            }
        } label: {
            if let inForce {
                SidebarChipLabel(title: inForce.title, count: inForce.count, isSelected: true)
            } else {
                SidebarChipLabel(title: "Kind", count: nil, showsChevron: true, isSelected: false)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show the comments of one kind")
        .accessibilityLabel(inForce.map { "Kind: \($0.title), \($0.count)" } ?? "Kind")
    }

    private func choose(_ filter: CommentFilter) {
        guard case .kind(let kind) = filter else { return }
        model.filter = SidebarFilterChip.filter(choosing: kind, current: model.filter)
    }
}
