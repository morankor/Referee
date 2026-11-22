import SwiftUI
import AppKit
import RefereeCore
import AppCore

// The selection bar (plan.md section 9.5): [Ask AI] [Comment] [Copy] [Questions ▾], 6 pt above the first rectangle of
// the normalised selection. Ask AI turns the bar into a field ("Ask about this passage…", Return sends); the question
// and its answer then live in the Chat tab, which the model opens. A quick question is sent at once. Comment starts an
// own comment on the selection (the model shows the Comments tab). Copy puts the normalised text on the pasteboard.

struct ReaderSelectionBar: View {
    let model: ReviewSessionModel
    let selection: SelectionInfo
    @State private var isAsking = false
    @State private var question = ""
    @FocusState private var fieldIsFocused: Bool

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
            .help("Write your own comment on this passage")
            Button {
                ReaderPasteboard.copy(selection.text)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
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
                .onExitCommand { isAsking = false }
            Button("Send", action: send)
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button {
                isAsking = false
            } label: {
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
        isAsking = false
    }
}

/// The general pasteboard, written as text.
enum ReaderPasteboard {
    @MainActor static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
