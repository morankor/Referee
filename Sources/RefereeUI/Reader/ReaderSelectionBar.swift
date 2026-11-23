import SwiftUI
import AppKit
import Observation
import RefereeCore
import AppCore

// The selection bar (plan.md section 9.5, refined by design review D14 and D2): [Ask AI] [Comment] [Copy] [Questions ▾],
// 6 pt above the first rectangle of the normalised selection. Ask AI turns the bar into a field ("Ask about this
// passage…", Return sends); the question and its answer then live in the Chat tab, which the model opens. A quick
// question is sent at once. Comment starts an own comment on the selection (the model shows the Comments tab). Copy
// puts the normalised text on the pasteboard.
//
// Decisions (also in docs/contract-notes/step5-reader.md):
// - The bar steps aside once it has been used (D14): it is not shown for a selection whose result is in the sidebar
//   already, that is while an own comment is being written on it (`model.composing`), when a conversation is about it,
//   or when an own comment was made from it (the comment saved, the passage still selected). Passages are compared by
//   their spans: a comment begun before the selection's rectangles arrived is still on the same passage. The PDF
//   selection itself stays, so the passage stays marked while the comment is written.
// - Copy reads "Copied" for `Theme.feedbackDuration`; then the bar steps aside until the selection changes.
// - When the ask field goes (Return, Esc, Send, ×), the window gets the keyboard back, so that the triage keys work
//   again (D2).
// - Whether the bar shows, and for which selection, is the controller's (`ReaderController.selectionBarSelection`, fed
//   by `ReaderSelectionBarState`), so that tests and scenes can check it; the view only draws it.

struct ReaderSelectionBar: View {
    let controller: ReaderController
    let selection: SelectionInfo
    @State private var isAsking = false
    @State private var question = ""
    @FocusState private var fieldIsFocused: Bool

    private var model: ReviewSessionModel { controller.model }

    var body: some View {
        Group {
            if isAsking { askField } else { buttons }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
        .fixedSize()
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            Button {
                isAsking = true
            } label: {
                Label("Ask AI", systemImage: "sparkles")
            }
            .help("Ask the AI about this passage")
            Button {
                model.beginComposingComment()
            } label: {
                Label("Comment", systemImage: "text.bubble")
            }
            .help("Write your own comment on this passage (N)")
            Button {
                controller.copySelection(selection)
            } label: {
                if controller.selectionBar.isShowingCopied(for: selection) {
                    Label("Copied", systemImage: "checkmark")
                } else {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
            .help("Copy the passage without margin numbers")
            Divider().frame(height: 16)
            Menu {
                ForEach(Array(model.settings.prompts.quickQuestions.enumerated()), id: \.offset) { _, preset in
                    Button(preset) { model.ask(preset, about: selection, in: nil) }
                }
            } label: {
                Text("Questions")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(model.settings.prompts.quickQuestions.isEmpty)
            .help("Ask one of the quick questions about this passage")
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
    }

    private var askField: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
            TextField("Ask about this passage…", text: $question)
                .textFieldStyle(.plain)
                .frame(width: 260)
                .focused($fieldIsFocused)
                .onSubmit(send)
                .onExitCommand(perform: stopAsking)
            Button("Send", action: send)
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(action: stopAsking) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Cancel")
        }
        .onAppear { fieldIsFocused = true }
    }

    private func send() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.ask(text, about: selection, in: nil)
        question = ""
        stopAsking()
    }

    /// The field goes, and the keyboard goes back to the window: J, K and the other triage keys work again (D2).
    private func stopAsking() {
        isAsking = false
        fieldIsFocused = false
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
}

/// When the selection bar shows (section 9.5; D14). The controller reports every change of the model's selection; the
/// bar is for a selection of at least three characters, with its rectangles, 200 ms after it last changed.
@MainActor @Observable
final class ReaderSelectionBarState {
    /// The bar appears this long after the selection settles (section 9.5).
    static let delay: Duration = .milliseconds(200)
    /// A selection shorter than this has no bar (section 9.5).
    static let minimumLength = 3

    /// The model's selection once it has stayed the same for `delay`; nil before, and for a selection with no bar.
    private(set) var settled: SelectionInfo?
    /// Copy was pressed for the passage with these spans: its button reads "Copied" (D14).
    private(set) var copiedSpans: [TextSpan]?
    /// After "Copied", the bar steps aside for the passage with these spans until the selection changes (D14).
    private(set) var steppedAsideSpans: [TextSpan]?

    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var copyTask: Task<Void, Never>?

    /// The model's selection changed (to an unequal value). A passage with other spans, or none, ends Copy's feedback
    /// and its stepping aside.
    func selectionDidChange(to selection: SelectionInfo?) {
        settleTask?.cancel()
        settled = nil
        if let copied = copiedSpans, selection?.spans != copied {
            copyTask?.cancel()
            copiedSpans = nil
        }
        if let aside = steppedAsideSpans, selection?.spans != aside { steppedAsideSpans = nil }
        guard let selection, selection.text.count >= Self.minimumLength, !selection.rects.isEmpty else { return }
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled else { return }
            self?.settled = selection
        }
    }

    /// Copy: "Copied" for `Theme.feedbackDuration`, then the bar steps aside for this passage.
    func didCopy(_ selection: SelectionInfo) {
        copyTask?.cancel()
        copiedSpans = selection.spans
        copyTask = Task { [weak self] in
            try? await Task.sleep(for: Theme.feedbackDuration)
            guard !Task.isCancelled, let self else { return }
            self.copiedSpans = nil
            self.steppedAsideSpans = selection.spans
        }
    }

    func isShowingCopied(for selection: SelectionInfo) -> Bool {
        copiedSpans == selection.spans
    }

    /// Whether the bar keeps out of the way of `selection` because its result is in the sidebar already (D14): an own
    /// comment being written on it, a conversation about it, or an own comment made from it. Compared by spans.
    static func stepsAside(for selection: SelectionInfo, composing: ComposingComment?, session: ReviewSession?) -> Bool {
        let spans = selection.spans
        guard !spans.isEmpty else { return false }
        if composing?.selection?.spans == spans { return true }
        guard let session else { return false }
        if session.conversations.contains(where: { $0.anchor?.spans == spans }) { return true }
        return session.comments.contains { comment in
            guard case .user = comment.origin else { return false }
            return comment.anchor.spans == spans
        }
    }
}

/// The general pasteboard (or another one, for tests and scenes), written as text.
enum ReaderPasteboard {
    @MainActor static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
