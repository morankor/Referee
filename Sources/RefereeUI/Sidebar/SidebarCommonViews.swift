import SwiftUI
import AppKit
import RefereeCore
import AppCore

// Small pieces the three tabs of the sidebar share (plan.md sections 9.3, 9.5 and 9.10).

/// "MAJOR" in the kind's colour (section 9.10), on a tint of it. `muted`: grey, for a rejected comment.
///
/// Step 5 (D16): the tag font and the 15% tint of `CommonTag`, so that badges and tags are one family; the badge keeps
/// its rounded rectangle, which tells a comment's kind apart from the capsule of a tag ("You", "verify").
struct SidebarKindBadge: View {
    let kind: CommentKind
    var muted = false

    var body: some View {
        let color = muted ? Color.secondary : Theme.kindColor(kind)
        Text(SidebarCardState.kindTitle(kind))
            .font(Theme.tagFont)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
    }
}

/// Which provider and model wrote a comment or an answer (step 5b): "Claude Code · Sonnet" after a chip symbol, in the
/// metadata font and the secondary colour, with the full ids as its tooltip.
struct SidebarSourceLabel: View {
    let source: SidebarSource

    var body: some View {
        Label(source.text, systemImage: source.providerID == nil ? "questionmark.circle" : "cpu")
            .font(Theme.metadataFont)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(source.help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(source.spoken)
    }
}

/// The header of a card (D1, step 5b): what the comment is on the left and where it is on the right, then a row of
/// facts (who wrote it, how many messages, a waiting revision) that joins the first line when everything fits. When
/// what and where do not fit on one line, the location goes to the facts' line, on its right; only when that does not
/// fit either does it take a line of its own.
struct SidebarCardHeader<Leading: View, Location: View, Facts: View>: View {
    let hasFacts: Bool
    let leading: Leading
    let location: Location
    let facts: Facts

    init(hasFacts: Bool, @ViewBuilder leading: () -> Leading, @ViewBuilder location: () -> Location, @ViewBuilder facts: () -> Facts) {
        self.hasFacts = hasFacts
        self.leading = leading()
        self.location = location()
        self.facts = facts()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                leading
                Spacer(minLength: 8)
                if hasFacts { facts }
                location
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    leading
                    Spacer(minLength: 8)
                    location
                }
                if hasFacts { facts }
            }
            VStack(alignment: .leading, spacing: 3) {
                leading
                HStack(spacing: 6) {
                    if hasFacts { facts }
                    Spacer(minLength: 8)
                    location
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                leading
                location
                if hasFacts { facts }
            }
        }
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
/// An answer carries, under it, the provider and model that wrote it (step 5b).
struct SidebarMessageBubble: View {
    let role: MessageRole
    let text: String
    var isStreaming = false
    var source: SidebarSource?

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if role == .user { Spacer(minLength: 32) }
            VStack(alignment: .leading, spacing: 3) {
                bubble
                if let source {
                    SidebarSourceLabel(source: source)
                        .padding(.horizontal, 4)
                }
            }
            if role == .assistant { Spacer(minLength: 32) }
        }
        .frame(maxWidth: .infinity)
    }

    private var bubble: some View {
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(role: role, text: text, isStreaming: isStreaming))
    }

    /// Whose message it is, for VoiceOver (D22): "You: …" or "Assistant: …".
    static func accessibilityLabel(role: MessageRole, text: String, isStreaming: Bool = false) -> String {
        let speaker = role == .user ? "You" : "Assistant"
        if isStreaming && text.isEmpty { return speaker + ": writing" }
        return speaker + ": " + text
    }
}

/// The field under a thread or a conversation: Send (⌘↩, or Return), or Stop while this target's reply streams.
/// Send is disabled while any reply is in flight: the reply lane takes one job at a time (section 2.3).
///
/// Esc in the field gives the keyboard back to the comment list (D2): the field lets go of the focus and the window
/// takes it, so that the triage keys work again; a second Esc then reaches the window's key monitor, which closes the
/// thread (section 9.4's order).
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
            .onExitCommand(perform: giveKeyboardBack)
        if let focus {
            base.focused(focus)
        } else {
            base
        }
    }

    private func giveKeyboardBack() {
        focus?.wrappedValue = false
        SidebarKeyboard.giveBackToTheList()
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

/// The general pasteboard (Copy of a chat answer, Copy Text, Copy Markdown and the two journal boxes of the report).
@MainActor enum SidebarPasteboard {
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// The keyboard between the sidebar's fields and triage (D2).
@MainActor enum SidebarKeyboard {
    /// The key window takes the keyboard from whatever text field or editor had it, so that the window's key monitor
    /// sees the single-key triage commands again (section 9.4: they are ignored while a text view has the keyboard).
    static func giveBackToTheList() {
        NSApp.keyWindow?.makeFirstResponder(nil)
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
