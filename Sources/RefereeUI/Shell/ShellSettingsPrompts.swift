import SwiftUI
import AppKit
import RefereeCore
import AppCore

/// Settings ▸ Prompts (plan.md section 9.6): the six prompts, the rubric, the quick questions, and the output format the
/// app parses, shown read-only. "Restore Defaults…" puts back all of Appendix B.
struct ShellPromptsPane: View {
    let model: SettingsModel
    let navigation: ShellSettingsNavigation
    @State private var confirmingRestore = false

    var body: some View {
        @Bindable var navigation = navigation
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: Binding(get: { navigation.promptSection }, set: { if let section = $0 { navigation.promptSection = section } })) {
                    Section("Prompts") {
                        ForEach([ShellPromptSection.review, .discussion, .question, .report, .template, .voice]) { section in
                            Text(section.title).tag(section)
                        }
                    }
                    Section("Review") {
                        ForEach([ShellPromptSection.rubric, .quickQuestions, .format]) { section in
                            Text(section.title).tag(section)
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                Divider()
                Button("Restore Defaults…") { confirmingRestore = true }
                    .padding(10)
                    .help("Put back the prompts, rubric and quick questions Referee came with")
            }
            .frame(width: 190)
            .background(Color(nsColor: .controlBackgroundColor))
            Divider()
            ShellPromptSectionView(model: model, section: navigation.promptSection)
                .id(navigation.promptSection)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .confirmationDialog("Restore the default prompts?", isPresented: $confirmingRestore) {
            Button("Restore Defaults", role: .destructive) { model.resetPromptsToDefaults() }
        } message: {
            Text("Your changes to the prompts, the rubric and the quick questions are replaced by the defaults.")
        }
    }
}

/// One section of the Prompts tab.
struct ShellPromptSectionView: View {
    let model: SettingsModel
    let section: ShellPromptSection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.title)
                .font(.title3.weight(.semibold))
            Text(ShellPromptSectionView.explanation(section))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            switch section {
            case .review, .discussion, .question, .report, .template, .voice:
                ShellLongTextEditor(value: ShellPromptSectionView.text(of: section, in: model.settings.prompts),
                                    monospaced: section == .template) { text in
                    model.update { ShellPromptSectionView.setText(text, of: section, in: &$0.prompts) }
                }
            case .rubric:
                ShellRubricEditor(model: model)
            case .quickQuestions:
                ShellQuickQuestionsEditor(model: model)
            case .format:
                ScrollView {
                    Text(FormatSpec.review)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                Label("The app parses this format; it cannot be edited.", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func explanation(_ section: ShellPromptSection) -> String {
        switch section {
        case .review: return "The referee's stance and how to use the rubric. Sent with every review."
        case .discussion: return "How the model answers in a comment's discussion thread."
        case .question: return "How the model answers questions about a passage or the whole paper."
        case .report: return "The voice and rules of the referee report."
        case .template: return "The report's Markdown skeleton with its section headings."
        case .voice: return "How a draft report is revised so that it reads as a human referee wrote it."
        case .rubric: return "The categories comments are filed under. The model is given the enabled ones."
        case .quickQuestions: return "Preset questions offered in the selection bar; they are sent as soon as they are chosen."
        case .format: return "The format a review must be written in. It is part of every review request."
        }
    }

    static func text(of section: ShellPromptSection, in prompts: PromptSet) -> String {
        switch section {
        case .review: return prompts.reviewSystem
        case .discussion: return prompts.discussionSystem
        case .question: return prompts.questionSystem
        case .report: return prompts.reportSystem
        case .template: return prompts.reportTemplate
        case .voice: return prompts.voiceRevisionSystem
        case .rubric, .quickQuestions, .format: return ""
        }
    }

    static func setText(_ text: String, of section: ShellPromptSection, in prompts: inout PromptSet) {
        switch section {
        case .review: prompts.reviewSystem = text
        case .discussion: prompts.discussionSystem = text
        case .question: prompts.questionSystem = text
        case .report: prompts.reportSystem = text
        case .template: prompts.reportTemplate = text
        case .voice: prompts.voiceRevisionSystem = text
        case .rubric, .quickQuestions, .format: break
        }
    }
}

/// The rubric table: enabled, id, name, guidance; add and remove.
struct ShellRubricEditor: View {
    let model: SettingsModel
    @State private var selection: Set<Int> = []

    private struct Row: Identifiable {
        var index: Int
        var category: RubricCategory
        var id: Int { index }
    }

    var body: some View {
        let rows = model.settings.rubric.enumerated().map { Row(index: $0.offset, category: $0.element) }
        VStack(alignment: .leading, spacing: 6) {
            Table(rows, selection: $selection) {
                TableColumn("On") { row in
                    Toggle("Enabled", isOn: Binding(get: { row.category.enabled }, set: { value in
                        change(row.index) { $0.enabled = value }
                    }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                }
                .width(28)
                TableColumn("Id") { row in
                    ShellCommitField("id", value: row.category.id, monospaced: true) { text in
                        let slug = ShellRubricEditor.slug(text)
                        if !slug.isEmpty { change(row.index) { $0.id = slug } }
                    }
                }
                .width(min: 70, ideal: 90, max: 120)
                TableColumn("Name") { row in
                    ShellCommitField("Name", value: row.category.name) { text in change(row.index) { $0.name = text } }
                }
                .width(min: 100, ideal: 140)
                TableColumn("Guidance") { row in
                    ShellCommitField("Guidance", value: row.category.guidance) { text in change(row.index) { $0.guidance = text } }
                }
            }
            .tableStyle(.bordered(alternatesRowBackgrounds: true))
            HStack(spacing: 6) {
                Button {
                    model.update { settings in
                        let id = ShellRubricEditor.newID(existing: settings.rubric.map(\.id))
                        settings.rubric.append(RubricCategory(id: id, name: "New category", guidance: "", enabled: true))
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add a category")
                Button {
                    let removed = selection
                    selection = []
                    model.update { settings in
                        settings.rubric = settings.rubric.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
                    }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection.isEmpty)
                .help("Remove the selected categories")
                Spacer()
                Text("\(model.settings.rubric.filter(\.enabled).count) of \(model.settings.rubric.count) enabled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func change(_ index: Int, _ mutate: @escaping (inout RubricCategory) -> Void) {
        model.update { settings in
            guard settings.rubric.indices.contains(index) else { return }
            mutate(&settings.rubric[index])
        }
    }

    /// Ids are slugs the model writes in its output: lower-case letters, digits and hyphens.
    static func slug(_ text: String) -> String {
        let lowered = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(lowered).split(separator: "-").joined(separator: "-")
    }

    static func newID(existing: [String]) -> String {
        var number = 1
        while existing.contains("category-\(number)") { number += 1 }
        return "category-\(number)"
    }
}

/// The quick questions of the selection bar.
struct ShellQuickQuestionsEditor: View {
    let model: SettingsModel

    var body: some View {
        let questions = model.settings.prompts.quickQuestions
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                        HStack(spacing: 6) {
                            ShellCommitField("Question", value: question) { text in
                                model.update { settings in
                                    guard settings.prompts.quickQuestions.indices.contains(index) else { return }
                                    settings.prompts.quickQuestions[index] = text
                                }
                            }
                            Button {
                                model.update { settings in
                                    guard settings.prompts.quickQuestions.indices.contains(index) else { return }
                                    settings.prompts.quickQuestions.remove(at: index)
                                }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove this question")
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            Button {
                model.update { $0.prompts.quickQuestions.append("New question") }
            } label: {
                Label("Add Question", systemImage: "plus")
            }
        }
    }
}
