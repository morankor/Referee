import SwiftUI
import RefereeCore
import AppCore

/// The Chat tab (plan.md section 9.5): the conversations, newest first (`session.conversations` is in creation order),
/// and at the bottom a field "Ask about the paper…" that starts a conversation with no selection. Empty state:
/// "Select text in the PDF and choose Ask AI."
struct SidebarChatTab: View {
    let model: ReviewSessionModel

    @State private var question = ""

    var body: some View {
        let conversations = Array((model.session?.conversations ?? []).reversed())
        VStack(spacing: 0) {
            if conversations.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.bubble")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Select text in the PDF and choose Ask AI.")
                        .font(Theme.bodyFont)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(Theme.sidebarPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.listSpacing) {
                        ForEach(conversations) { conversation in
                            SidebarConversationCard(model: model, conversation: conversation)
                        }
                    }
                    .padding(Theme.sidebarPadding)
                }
            }
            Divider()
            SidebarMessageInput(placeholder: "Ask about the paper…", text: $question, isLaneBusy: model.streamingTargetID != nil,
                                isStreamingHere: false,
                                send: { model.ask($0, about: nil, in: nil) },
                                stop: { model.cancelReply() })
                .padding(Theme.sidebarPadding)
        }
    }
}

/// One conversation: the quoted passage (click → `revealConversationInPDF`) and its location, the messages, the answer
/// while it streams, a failed answer's red line with Retry, per answer "Make Comment ▾" (kind) and Copy, and a field
/// for a follow-up question.
struct SidebarConversationCard: View {
    let model: ReviewSessionModel
    let conversation: Conversation

    @State private var followUp = ""

    var body: some View {
        let isReceiving = model.streamingTargetID == conversation.id
        let failure = model.replyFailure?.targetID == conversation.id ? model.replyFailure?.message : nil
        VStack(alignment: .leading, spacing: 8) {
            passage
            ForEach(conversation.messages) { message in
                SidebarMessageBubble(role: message.role, text: message.text)
                if message.role == .assistant {
                    answerActions(message)
                }
            }
            if isReceiving {
                SidebarMessageBubble(role: .assistant, text: model.streamingReplyText, isStreaming: true)
            }
            if let failure {
                SidebarReplyFailureLine(message: failure, canRetry: model.streamingTargetID == nil) { model.retryFailedReply() }
            }
            SidebarMessageInput(placeholder: "Ask a follow-up…", text: $followUp, isLaneBusy: model.streamingTargetID != nil,
                                isStreamingHere: isReceiving, sendsWithCommandReturn: false,
                                send: { model.ask($0, about: nil, in: conversation.id) },
                                stop: { model.cancelReply() })
        }
        .sidebarCardChrome(bar: Color(nsColor: Theme.highlightHue(.question)))
    }

    /// The passage the conversation started from, or "About the whole paper"; ⋯ deletes the conversation.
    private var passage: some View {
        HStack(alignment: .top, spacing: 6) {
            if let anchor = conversation.anchor {
                Button {
                    model.revealConversationInPDF(conversation.id)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        if !anchor.locationLabel.isEmpty {
                            Text(anchor.locationLabel)
                                .font(Theme.metadataFont)
                                .foregroundStyle(.secondary)
                        }
                        Text(SidebarText.quoted(anchor.quote))
                            .font(Theme.quoteFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show the passage in the PDF")
            } else {
                Label("About the whole paper", systemImage: "doc.text")
                    .font(Theme.metadataFont)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Menu {
                Button("Delete Conversation", role: .destructive) { model.deleteConversation(conversation.id) }
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
    }

    /// "Make Comment ▾" (the kind of the pending comment it becomes) and Copy, under an answer.
    private func answerActions(_ message: ThreadMessage) -> some View {
        HStack(spacing: 6) {
            Menu("Make Comment") {
                ForEach(CommentKind.allCases, id: \.self) { kind in
                    Button(SidebarCardState.kindName(kind)) {
                        model.convertReplyToComment(conversationID: conversation.id, messageID: message.id, kind: kind)
                    }
                }
            }
            .fixedSize()
            .help("Turn this answer into a pending comment of the chosen kind")
            Button("Copy") { SidebarPasteboard.copy(message.text) }
                .help("Copy the answer")
            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }
}
