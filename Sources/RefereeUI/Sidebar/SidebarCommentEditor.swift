import SwiftUI
import RefereeCore
import AppCore

/// The editor of a comment (plan.md section 9.3, "editing"): kind and category pickers, title field, body and suggestion
/// editors, Save (⌘↩) and Cancel (Esc). The same editor writes a new own comment while `model.composing` is set; it
/// then shows the passage it will be anchored to, starts as a minor comment in category "other", and saves with
/// `addUserComment`, suggestion included (the parameter was added at Wave 3; docs/contract-notes/wave3.md).
///
/// Step 5 (D2): the editor opens with the cursor in the comment, so that E and N lead straight to typing; after Save or
/// Cancel the window takes the keyboard back, so that the triage keys work at once.
struct SidebarCommentEditor: View {
    enum Mode {
        case edit(ReviewComment)
        case compose
    }

    /// The editor's three text fields.
    enum EditorField: Hashable { case title, body, suggestion }

    let model: ReviewSessionModel
    let mode: Mode

    @State private var kind: CommentKind
    @State private var category: String
    @State private var title: String
    @State private var text: String
    @State private var suggestion: String
    @FocusState private var focusedField: EditorField?

    init(model: ReviewSessionModel, mode: Mode) {
        self.model = model
        self.mode = mode
        switch mode {
        case .edit(let comment):
            _kind = State(initialValue: comment.kind)
            _category = State(initialValue: comment.category)
            _title = State(initialValue: comment.title)
            _text = State(initialValue: comment.body)
            _suggestion = State(initialValue: comment.suggestion ?? "")
        case .compose:
            _kind = State(initialValue: .minor)
            _category = State(initialValue: "other")
            _title = State(initialValue: "")
            _text = State(initialValue: "")
            _suggestion = State(initialValue: "")
        }
    }

    private var isComposing: Bool {
        if case .compose = mode { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isComposing ? "New comment" : "Edit comment")
                .font(Theme.cardTitleFont)
            if isComposing { passage }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    fieldLabel("Kind")
                    Picker("Kind", selection: $kind) {
                        ForEach(CommentKind.allCases, id: \.self) { Text(SidebarCardState.kindName($0)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    fieldLabel("Category")
                    Picker("Category", selection: $category) {
                        ForEach(categoryChoices, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                }
                GridRow {
                    fieldLabel("Title")
                    TextField("Title", text: $title, prompt: Text("Title (optional)"), axis: .vertical)
                        .lineLimit(1...3)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .focused($focusedField, equals: .title)
                        .help("Left empty, the title is taken from the comment")
                }
            }
            .controlSize(.small)
            fieldLabel("Comment")
            SidebarTextArea(text: $text, height: 96, focus: $focusedField, field: .body)
            fieldLabel("Suggestion")
            SidebarTextArea(text: $suggestion, height: 52, focus: $focusedField, field: .suggestion)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .help("Cancel (Esc)")
                Button("Save", action: save)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!SidebarEditorRules.canSave(title: title, body: text))
                    .help("Save (⌘↩)")
            }
            .controlSize(.small)
        }
        .onExitCommand(perform: cancel)
        .onAppear { focusedField = .body }
    }

    /// The passage a new comment will be anchored to: the selection captured when composing began.
    @ViewBuilder private var passage: some View {
        if let selection = model.composing?.selection, !selection.text.isEmpty {
            Text(SidebarText.quoted(selection.text))
                .font(Theme.quoteFont)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Not tied to a passage. To anchor a comment, select the text in the PDF first.")
                .font(Theme.metadataFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The rubric's enabled categories, "other" always among them, and the comment's own category when the rubric no
    /// longer has it (so the picker can show it).
    private var categoryChoices: [RubricCategory] {
        var choices = model.settings.rubric.filter(\.enabled)
        if !choices.contains(where: { $0.id == "other" }) {
            choices.append(RubricCategory(id: "other", name: "Other", guidance: "", enabled: true))
        }
        if !choices.contains(where: { $0.id == category }) {
            let name = model.settings.rubric.first { $0.id == category }?.name ?? category
            choices.append(RubricCategory(id: category, name: name, guidance: "", enabled: true))
        }
        return choices
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.metadataFont)
            .foregroundStyle(.secondary)
    }

    private func save() {
        guard SidebarEditorRules.canSave(title: title, body: text) else { return }
        let finalTitle = SidebarEditorRules.title(title, body: text)
        focusedField = nil
        switch mode {
        case .edit(let comment):
            model.editComment(comment.id, kind: kind, category: category, title: finalTitle, body: text, suggestion: suggestion)
        case .compose:
            model.addUserComment(kind: kind, category: category, title: finalTitle, body: text, suggestion: suggestion,
                                 anchoredTo: model.composing?.selection)
        }
        SidebarKeyboard.giveBackToTheList()
    }

    private func cancel() {
        focusedField = nil
        switch mode {
        case .edit: model.editingCommentID = nil
        case .compose: model.cancelComposing()
        }
        SidebarKeyboard.giveBackToTheList()
    }
}

/// A multi-line plain-text field in the look of a text field. With `focus`, it takes part in the editor's focus (D2).
struct SidebarTextArea: View {
    @Binding var text: String
    let height: CGFloat
    var focus: FocusState<SidebarCommentEditor.EditorField?>.Binding?
    var field: SidebarCommentEditor.EditorField = .body

    var body: some View {
        focusable(TextEditor(text: $text))
            .font(Theme.bodyFont)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 3)
            .padding(.vertical, 4)
            .frame(height: height)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }

    @ViewBuilder private func focusable(_ editor: TextEditor) -> some View {
        if let focus {
            editor.focused(focus, equals: field)
        } else {
            editor
        }
    }
}

/// The editor's rules. Pure.
enum SidebarEditorRules {
    /// A comment needs a title or a body.
    static func canSave(title: String, body: String) -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The title to save: the one typed, trimmed and on one line; when it is empty, the first ten words of the body (at
    /// most 120 characters), the rule the parser applies to a block without a title (plan.md section 6.5).
    static func title(_ title: String, body: String) -> String {
        let typed = title.split(whereSeparator: { $0.isNewline }).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty { return typed }
        let words = body.split(whereSeparator: { $0.isWhitespace }).prefix(10).joined(separator: " ")
        return words.count > 120 ? String(words.prefix(120)) : words
    }
}
