import SwiftUI
import RefereeCore
import AppCore

/// The Comments tab (plan.md section 9.3). Header: the filter chips, a thin progress bar with "12 of 31 decided", "+"
/// for a new own comment and a ⋯ menu ("Clear undecided AI comments", section 6.6). List: the editing card of a new
/// comment at the top while `model.composing` is set, then the cards in the order of `model.visibleComments`, then the
/// drafts of a review in progress under "Writing…".
///
/// The list follows the model: a new selection (J/K, a highlight clicked in the PDF, auto-advance) scrolls its card
/// into view; an opened thread or editor scrolls its card to the top so that what opened is visible.
struct SidebarCommentsTab: View {
    let model: ReviewSessionModel

    @State private var confirmsClearing = false

    var body: some View {
        let comments = model.session?.comments ?? []
        let visible = model.visibleComments
        let inputs = SidebarCardInputs(model: model)
        VStack(spacing: 0) {
            header(comments)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.listSpacing) {
                        if model.composing != nil {
                            SidebarCommentEditor(model: model, mode: .compose)
                                .sidebarCardChrome(bar: Theme.ownColor, isSelected: true)
                                .id(SidebarListKey.composing)
                        }
                        if visible.isEmpty && model.drafts.isEmpty && model.composing == nil {
                            emptyState(hasComments: !comments.isEmpty)
                        }
                        ForEach(visible, id: \.listKey) { comment in
                            SidebarCommentCard(model: model, comment: comment, inputs: inputs)
                                .id(comment.listKey)
                        }
                        if !model.drafts.isEmpty {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Writing…")
                                    .font(Theme.metadataFont.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 4)
                            .id(SidebarListKey.writing)
                            ForEach(model.drafts, id: \.listKey) { draft in
                                SidebarDraftCard(draft: draft, rubric: model.settings.rubric)
                                    .id(draft.listKey)
                            }
                        }
                    }
                    .padding(Theme.sidebarPadding)
                }
                .onAppear { scroll(proxy, to: model.selectedCommentID, anchor: nil) }
                .onChange(of: model.selectedCommentID) { _, id in scroll(proxy, to: id, anchor: nil) }
                .onChange(of: model.openThreadCommentID) { _, id in scroll(proxy, to: id, anchor: .top) }
                .onChange(of: model.editingCommentID) { _, id in scroll(proxy, to: id, anchor: .top) }
                .onChange(of: model.composing != nil) { _, isComposing in
                    if isComposing { withAnimation { proxy.scrollTo(SidebarListKey.composing, anchor: .top) } }
                }
            }
        }
    }

    // ---- header ----

    private func header(_ comments: [ReviewComment]) -> some View {
        let triage = model.triage
        return VStack(alignment: .leading, spacing: 8) {
            SidebarFlowLayout(spacing: 5, lineSpacing: 5) {
                ForEach(SidebarFilterChip.chips(for: comments)) { chip in
                    SidebarFilterChipButton(chip: chip, isSelected: model.filter == chip.filter) { model.filter = chip.filter }
                }
            }
            HStack(spacing: 8) {
                if triage.total > 0 {
                    ProgressView(value: Double(triage.decided), total: Double(triage.total))
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .accessibilityLabel("Comments decided")
                    Text(SidebarFilterChip.triageText(decided: triage.decided, total: triage.total))
                        .font(Theme.metadataFont)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                } else {
                    Text("No comments")
                        .font(Theme.metadataFont)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                Button {
                    model.beginComposingComment()
                } label: {
                    Image(systemName: "plus")
                        .accessibilityLabel("New comment")
                }
                .buttonStyle(.borderless)
                .help("New comment (N)")
                Menu {
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
            if confirmsClearing {
                clearingConfirmation(count: undecidedAICount(comments))
            }
        }
        .padding(.horizontal, Theme.sidebarPadding)
        .padding(.vertical, 8)
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

    // ---- empty states (section 9.9) ----

    @ViewBuilder private func emptyState(hasComments: Bool) -> some View {
        if hasComments {
            VStack(alignment: .leading, spacing: 6) {
                Text("No comments match this filter.")
                    .font(Theme.bodyFont)
                    .foregroundStyle(.secondary)
                Button("Show All") { model.filter = .all }
                    .controlSize(.small)
            }
            .padding(.top, 8)
        } else {
            Text("No comments yet. Run a review (⌘R) or add your own (N).")
                .font(Theme.bodyFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to id: UUID?, anchor: UnitPoint?) {
        guard let id, model.visibleComments.contains(where: { $0.id == id }) else { return }
        withAnimation { proxy.scrollTo(SidebarListKey.comment(id), anchor: anchor) }
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

/// One filter chip: its title and count; filled with the accent colour when it is the filter in force.
struct SidebarFilterChipButton: View {
    let chip: SidebarFilterChip
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(chip.title)
                Text("\(chip.count)")
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
            }
            .font(Theme.metadataFont.weight(.medium))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.13), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(chip.title), \(chip.count)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
