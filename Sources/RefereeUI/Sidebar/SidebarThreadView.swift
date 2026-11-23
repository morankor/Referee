import SwiftUI
import RefereeCore
import AppCore

/// The discussion under a card (plan.md section 9.3, "discussion open"; section 6.8): the messages, the reply while it
/// streams, a reply that failed (red, with Retry), and the field to write the next message. While a reply streams Send
/// is disabled and Stop shows. The field takes the focus when the thread opens (D, section 9.4).
struct SidebarThreadView: View {
    let model: ReviewSessionModel
    let comment: ReviewComment
    let state: SidebarCardState

    @State private var message = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if comment.thread.isEmpty && !state.isReceivingReply {
                Text("Ask the assistant about this comment, or tell it where it is wrong.")
                    .font(Theme.metadataFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(comment.thread) { message in
                SidebarMessageBubble(role: message.role, text: message.text)
            }
            if state.isReceivingReply {
                SidebarMessageBubble(role: .assistant, text: model.streamingReplyText, isStreaming: true)
            }
            if let failure = state.replyFailureMessage {
                SidebarReplyFailureLine(message: failure, canRetry: model.streamingTargetID == nil) { model.retryFailedReply() }
            }
            SidebarMessageInput(placeholder: "Reply…", text: $message, isLaneBusy: model.streamingTargetID != nil,
                                isStreamingHere: state.isReceivingReply,
                                send: { model.sendDiscussionMessage($0, commentID: comment.id) },
                                stop: { model.cancelReply() },
                                focus: $isInputFocused)
        }
        .onAppear { isInputFocused = true }
    }
}

/// "Proposed revision" under the thread (section 9.3): the new kind, title, body and suggestion, or "Proposes
/// withdrawing this comment"; Accept or Discard. A proposal never changes the comment by itself (section 6.8).
struct SidebarProposalBox: View {
    let model: ReviewSessionModel
    let commentID: UUID
    let proposal: CommentRevision

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Proposed revision", systemImage: "square.and.pencil")
                .font(Theme.metadataFont.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            if proposal.withdraw {
                Text("Proposes withdrawing this comment")
                    .font(Theme.bodyFont)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    SidebarKindBadge(kind: proposal.kind)
                    Text(proposal.title)
                        .font(Theme.cardTitleFont)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !proposal.body.isEmpty {
                    Text(proposal.body)
                        .font(Theme.bodyFont)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let suggestion = proposal.suggestion, !suggestion.isEmpty {
                    Text(SidebarText.labelled("Suggestion:", suggestion))
                        .font(Theme.bodyFont)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 6) {
                Button("Accept") { model.acceptProposedRevision(commentID: commentID) }
                    .buttonStyle(.borderedProminent)
                    .help(proposal.withdraw ? "Withdraw the comment: it becomes rejected" : "Replace the comment with this version")
                Button("Discard") { model.discardProposedRevision(commentID: commentID) }
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1))
    }
}
