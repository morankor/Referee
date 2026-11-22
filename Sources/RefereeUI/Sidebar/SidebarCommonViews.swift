import SwiftUI
import AppKit
import RefereeCore
import AppCore

// Small pieces the three tabs of the sidebar share (plan.md sections 9.3, 9.5 and 9.10).

/// "MAJOR" in the kind's colour (section 9.10), on a tint of it. `muted`: grey, for a rejected comment.
struct SidebarKindBadge: View {
    let kind: CommentKind
    var muted = false

    var body: some View {
        let color = muted ? Color.secondary : Theme.kindColor(kind)
        Text(SidebarCardState.kindTitle(kind))
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
    }
}

/// A small capsule beside the category: "You", "verify".
struct SidebarTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(color.opacity(0.6), lineWidth: 1))
            .fixedSize()
    }
}

/// The look of a card: rounded, with a coloured bar down its left edge and, when selected, an outline in the accent
/// colour (section 9.3).
struct SidebarCardChrome: ViewModifier {
    var bar: Color
    var barOpacity: Double = 1
    var isSelected = false
    var isMuted = false                      // a rejected comment's grey line

    static let barWidth: CGFloat = 4

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
        content
            .padding(.vertical, Theme.cardPadding)
            .padding(.leading, Theme.cardPadding + Self.barWidth)
            .padding(.trailing, Theme.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack(alignment: .leading) {
                    shape.fill(isMuted ? Color(nsColor: .windowBackgroundColor) : Color(nsColor: .controlBackgroundColor))
                    bar.opacity(barOpacity).frame(width: Self.barWidth)
                }
                .clipShape(shape)
            }
            .overlay {
                shape.strokeBorder(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isSelected ? 2 : 0.5)
            }
    }
}

extension View {
    func sidebarCardChrome(bar: Color, barOpacity: Double = 1, isSelected: Bool = false, isMuted: Bool = false) -> some View {
        modifier(SidebarCardChrome(bar: bar, barOpacity: barOpacity, isSelected: isSelected, isMuted: isMuted))
    }
}

/// A text cut to `lineLimit` lines that tells its owner whether the limit cut anything off, so that the card can
/// offer "More" only when there is more (section 9.3: "body: 6 lines, then 'more'"). `lineLimit` nil: the whole text.
struct SidebarClampedText: View {
    let text: AttributedString
    let lineLimit: Int?
    let onTruncation: (Bool) -> Void

    @State private var shownHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    var body: some View {
        Text(text)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                shownHeight = height
                report()
            }
            .background(alignment: .topLeading) {
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        fullHeight = height
                        report()
                    }
            }
    }

    private func report() {
        onTruncation(lineLimit != nil && fullHeight > shownHeight + 0.5)
    }
}

/// One message of a discussion or conversation: the referee's on the right, the assistant's on the left (section 9.3).
struct SidebarMessageBubble: View {
    let role: MessageRole
    let text: String
    var isStreaming = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if role == .user { Spacer(minLength: 32) }
            VStack(alignment: .leading, spacing: 4) {
                if !text.isEmpty {
                    Text(text)
                        .font(Theme.bodyFont)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isStreaming {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("Writing")
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(role == .user ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 9))
            if role == .assistant { Spacer(minLength: 32) }
        }
        .frame(maxWidth: .infinity)
    }
}

/// The field under a thread or a conversation: Send (⌘↩, or Return), or Stop while this target's reply streams.
/// Send is disabled while any reply is in flight: the reply lane takes one job at a time (section 2.3).
struct SidebarMessageInput: View {
    let placeholder: String
    @Binding var text: String
    let isLaneBusy: Bool                     // some reply is streaming
    let isStreamingHere: Bool                // this target's reply is streaming: Stop instead of Send
    var sendsWithCommandReturn = true        // only one field per screen may own ⌘↩
    let send: (String) -> Void
    let stop: () -> Void
    var focus: FocusState<Bool>.Binding?

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            field
            if isStreamingHere {
                Button("Stop", action: stop)
            } else if sendsWithCommandReturn {
                Button("Send", action: submit)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSend)
            } else {
                Button("Send", action: submit)
                    .disabled(!canSend)
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder private var field: some View {
        let base = TextField(placeholder, text: $text, axis: .vertical)
            .lineLimit(1...5)
            .textFieldStyle(.roundedBorder)
            .font(Theme.bodyFont)
            .onSubmit(submit)
        if let focus {
            base.focused(focus)
        } else {
            base
        }
    }

    private var canSend: Bool {
        !isLaneBusy && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canSend else { return }
        let message = text
        text = ""
        send(message)
    }
}

/// A failed reply, in red under its thread or conversation, with Retry (`retryFailedReply()`). Not a banner (section 9.9).
struct SidebarReplyFailureLine: View {
    let message: String
    let canRetry: Bool
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
            Text(message)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry", action: retry)
                .controlSize(.small)
                .disabled(!canRetry)
        }
        .font(Theme.bodyFont)
    }
}

/// The general pasteboard (Copy of a chat answer, Copy Markdown and Copy as plain text of the report).
@MainActor enum SidebarPasteboard {
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// Small text helpers.
enum SidebarText {
    /// `text` with a bold prefix: "Suggestion: …".
    static func labelled(_ label: String, _ text: String) -> AttributedString {
        var prefix = AttributedString(label + " ")
        prefix.inlinePresentationIntent = .stronglyEmphasized
        return prefix + AttributedString(text)
    }

    /// A quoted passage in curly quotation marks.
    static func quoted(_ text: String) -> String { "“" + text + "”" }
}
