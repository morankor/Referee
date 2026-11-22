import SwiftUI
import AppKit
import RefereeCore
import AppCore

/// Settings ▸ Providers (plan.md section 9.6): the providers in three groups on the left, each with its status light
/// and enable switch; the chosen provider's settings on the right; the default provider of each job underneath.
struct ShellProvidersPane: View {
    let model: SettingsModel
    let navigation: ShellSettingsNavigation

    var body: some View {
        let groups = ShellProviderRows.grouped(model.providers)
        let ordered = groups.flatMap(\.providers)
        let selected = ordered.first { $0.id == navigation.provider } ?? ordered.first
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ShellProviderList(model: model, groups: groups,
                                  selection: Binding(get: { selected?.id }, set: { navigation.provider = $0 }))
                    .frame(width: 270)
                Divider()
                if let selected {
                    ShellProviderDetail(model: model, descriptor: selected)
                        .id(selected.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("No providers are registered.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            ShellTaskDefaultsBar(model: model)
        }
    }
}

/// The list of providers.
struct ShellProviderList: View {
    let model: SettingsModel
    let groups: [ShellProviderRows.Section]
    let selection: Binding<ProviderID?>

    var body: some View {
        List(selection: selection) {
            ForEach(groups) { entry in
                Section(entry.group.title) {
                    ForEach(entry.providers, id: \.id) { descriptor in
                        ShellProviderListRow(model: model, descriptor: descriptor)
                            .tag(descriptor.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.sidebarRowSize, .small)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

/// One provider in the list: status light, name, "Experimental" while unverified, and the enable switch.
struct ShellProviderListRow: View {
    let model: SettingsModel
    let descriptor: ProviderDescriptor

    var body: some View {
        let status = ShellProviderRows.status(model.availability[descriptor.id])
        let experimental = ShellProviderRows.showsExperimentalWarning(descriptor, settings: model.settings.providers[descriptor.id])
        HStack(spacing: 8) {
            ShellStatusDot(light: status.light)
            Text(ShellProviderRows.listName(descriptor))
                .lineLimit(1)
                .truncationMode(.tail)
            if experimental {
                Text("Experimental")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.15), in: Capsule())
                    .fixedSize()
            }
            Spacer(minLength: 4)
            Toggle("Enabled", isOn: ShellProviderBindings.enabled(model, descriptor.id))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .help("\(descriptor.displayName): \(status.headline)" + (status.detail.map { " — " + $0 } ?? ""))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(descriptor.displayName), \(status.headline)\(experimental ? ", experimental" : "")"))
    }
}

/// Bindings into one provider's settings, each change through `SettingsModel.update`.
@MainActor enum ShellProviderBindings {
    static func entry(_ model: SettingsModel, _ id: ProviderID) -> ProviderSettings {
        model.settings.providers[id] ?? ProviderSettings(enabled: false, inputMode: .auto)
    }

    static func change(_ model: SettingsModel, _ id: ProviderID, _ mutate: @escaping (inout ProviderSettings) -> Void) {
        model.update { settings in
            var entry = settings.providers[id] ?? ProviderSettings(enabled: false, inputMode: .auto)
            mutate(&entry)
            settings.providers[id] = entry
        }
    }

    static func enabled(_ model: SettingsModel, _ id: ProviderID) -> Binding<Bool> {
        Binding(get: { entry(model, id).enabled }, set: { value in change(model, id) { $0.enabled = value } })
    }

    /// The provider's model; the job defaults that name this provider follow it, so that the model chosen here is the
    /// one a review uses.
    static func chooseModel(_ model: SettingsModel, _ id: ProviderID, _ modelID: String?) {
        model.update { settings in
            var entry = settings.providers[id] ?? ProviderSettings(enabled: false, inputMode: .auto)
            entry.model = modelID
            settings.providers[id] = entry
            if settings.defaults.review?.providerID == id { settings.defaults.review?.model = modelID }
            if settings.defaults.chat?.providerID == id { settings.defaults.chat?.model = modelID }
            if settings.defaults.report?.providerID == id { settings.defaults.report?.model = modelID }
        }
    }
}

/// The settings of one provider.
struct ShellProviderDetail: View {
    let model: SettingsModel
    let descriptor: ProviderDescriptor

    @State private var keyDraft = ""
    @State private var replacingKey = false
    @State private var typingModel = false
    @State private var typedModel = ""
    @State private var showAll = false
    @State private var refreshingModels = false
    @State private var testing = false
    @State private var testResult: Result<String, LLMError>?
    @State private var advancedOpen = false

    private var id: ProviderID { descriptor.id }
    private var entry: ProviderSettings { ShellProviderBindings.entry(model, id) }
    private var isCLI: Bool { descriptor.authMode == .subscriptionCLI }
    private var isHTTP: Bool { descriptor.authMode == .apiKey || descriptor.authMode == .local }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                statusBlock
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                    if let key = ShellProviderRows.secretKey(for: descriptor) { keyRow(key) }
                    modelRow
                    if isCLI { pathRow }
                }
                DisclosureGroup("Advanced", isExpanded: $advancedOpen) {
                    advanced
                        .padding(.top, 8)
                }
                testPrompt
                Label(descriptor.retentionNote, systemImage: "hand.raised")
                    .labelStyle(ShellLeadingIconLabelStyle())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: id) { await loadModelsIfUseful() }
    }

    // ---- name, experimental warning, status ----

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(descriptor.displayName)
                    .font(.title2.weight(.semibold))
                Spacer()
                Toggle("Enabled", isOn: ShellProviderBindings.enabled(model, id))
                    .toggleStyle(.switch)
            }
            if ShellProviderRows.showsExperimentalWarning(descriptor, settings: model.settings.providers[id]) {
                Label(ShellProviderRows.experimentalWarning, systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(ShellLeadingIconLabelStyle())
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusBlock: some View {
        let status = ShellProviderRows.status(model.availability[id])
        let hint = status.hint.map { ShellProviderRows.setupHint($0, isCLI: isCLI) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ShellStatusDot(light: status.light)
                Text(status.headline)
                    .font(.body.weight(.medium))
                if let detail = status.detail {
                    Text(detail)
                        .foregroundStyle(status.light == .red ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button {
                    Task { await model.refreshAvailability(of: id) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Check again")
            }
            if let hint {
                if let text = hint.text {
                    Text(ShellProviderDetail.markdown(text))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !hint.commands.isEmpty {
                    Text(isCLI ? "To install it, run this in Terminal:" : "Run this in Terminal:")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(hint.commands, id: \.self) { command in
                    ShellCommandBox(command: command)
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    // ---- key, model, path ----

    @ViewBuilder private func keyRow(_ key: String) -> some View {
        GridRow {
            Text("API key")
                .gridColumnAlignment(.trailing)
            VStack(alignment: .leading, spacing: 4) {
                if model.storedSecrets.contains(key) && !replacingKey {
                    HStack(spacing: 8) {
                        Text("•••• stored")
                            .font(.system(.body, design: .monospaced))
                        Button("Replace") { replacingKey = true }
                        Button("Remove") { Task { await model.setSecret(nil, for: key); await model.refreshAvailability(of: id) } }
                    }
                } else {
                    HStack(spacing: 8) {
                        SecureField("Paste the API key", text: $keyDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                            .onSubmit { saveKey(key) }
                        Button("Save") { saveKey(key) }
                            .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if replacingKey {
                            Button("Cancel") {
                                keyDraft = ""
                                replacingKey = false
                            }
                        }
                    }
                }
                if let problem = model.secretErrors[key] {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Kept in the Keychain; sent only to \(descriptor.destination).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func saveKey(_ key: String) {
        let value = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        keyDraft = ""
        replacingKey = false
        Task {
            await model.setSecret(value, for: key)
            await model.refreshAvailability(of: id)
            if model.secretErrors[key] == nil { await refreshModels() }
        }
    }

    @ViewBuilder private var modelRow: some View {
        let listed = model.models[id] ?? entry.cachedModels
        let chosen = entry.model
        GridRow {
            Text("Model")
                .gridColumnAlignment(.trailing)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if typingModel {
                        TextField("Model id", text: $typedModel)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: 220)
                            .onSubmit(useTypedModel)
                        Button("Use") { useTypedModel() }
                            .disabled(typedModel.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Cancel") { typingModel = false }
                    } else {
                        Picker("Model", selection: Binding(get: { chosen }, set: { ShellProviderBindings.chooseModel(model, id, $0) })) {
                            Text(isCLI ? "CLI default" : "Not chosen").tag(String?.none)
                            if let chosen, !listed.contains(where: { $0.id == chosen }) {
                                Text(chosen).tag(Optional(chosen))
                            }
                            ForEach(listed) { info in
                                Text(info.displayName == info.id ? info.id : "\(info.displayName) (\(info.id))").tag(Optional(info.id))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button {
                            Task { await refreshModels() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .disabled(refreshingModels)
                        .help("Fetch the model list again")
                        Button("Custom…") {
                            typedModel = chosen ?? ""
                            typingModel = true
                        }
                    }
                }
                if ShellProviderRows.hasShowAll(descriptor) {
                    Toggle("Show all models", isOn: $showAll)
                        .toggleStyle(.checkbox)
                        .onChange(of: showAll) { _, _ in Task { await refreshModels() } }
                }
                if let problem = model.modelErrors[id] {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let info = listed.first(where: { $0.id == chosen }), let window = info.contextWindow {
                    Text("Context window \(ShellFormat.grouped(window)) tokens" + (info.supportsPDFInput == true ? " · reads PDF files" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func useTypedModel() {
        let typed = typedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        ShellProviderBindings.chooseModel(model, id, typed)
        typingModel = false
    }

    @ViewBuilder private var pathRow: some View {
        GridRow {
            Text("Path")
                .gridColumnAlignment(.trailing)
            VStack(alignment: .leading, spacing: 4) {
                ShellCommitField("Found automatically", value: entry.executablePath ?? "", monospaced: true) { text in
                    let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    ShellProviderBindings.change(model, id) { $0.executablePath = path.isEmpty ? nil : path }
                }
                .frame(maxWidth: 340)
                Text("Leave empty to use the copy Referee finds; the version found is shown in the status above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // ---- advanced ----

    private var advanced: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            if isHTTP {
                GridRow {
                    Text("Base URL").gridColumnAlignment(.trailing)
                    ShellCommitField(descriptor.authMode == .local ? "http://127.0.0.1:11434" : "Default", value: entry.baseURL ?? "",
                                     monospaced: true) { text in
                        let url = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        ShellProviderBindings.change(model, id) { $0.baseURL = url.isEmpty ? nil : url }
                    }
                    .frame(maxWidth: 300)
                }
            }
            GridRow {
                Text("Context window").gridColumnAlignment(.trailing)
                numberField(entry.contextWindowOverride, placeholder: "From the model list") { value in
                    ShellProviderBindings.change(model, id) { $0.contextWindowOverride = value }
                }
            }
            GridRow {
                Text("Max output tokens").gridColumnAlignment(.trailing)
                numberField(entry.maxOutputTokens, placeholder: "Provider default") { value in
                    ShellProviderBindings.change(model, id) { $0.maxOutputTokens = value }
                }
            }
            GridRow {
                Text("Input").gridColumnAlignment(.trailing)
                Picker("Input", selection: Binding(get: { entry.inputMode }, set: { mode in
                    ShellProviderBindings.change(model, id) { $0.inputMode = mode }
                })) {
                    Text("Automatic").tag(InputMode.auto)
                    Text("Text").tag(InputMode.text)
                    Text("PDF").tag(InputMode.pdf)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if isCLI {
                GridRow {
                    Text("Extra arguments").gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 3) {
                        ShellCommitField("None", value: entry.extraArguments.joined(separator: " "), monospaced: true) { text in
                            let arguments = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
                            ShellProviderBindings.change(model, id) { $0.extraArguments = arguments }
                        }
                        .frame(maxWidth: 300)
                        Text("Separated by spaces. The options Referee needs for safety are always kept.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if isHTTP {
                GridRow {
                    Text("Extra body JSON").gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 3) {
                        ShellCommitField("{}", value: entry.extraBodyJSON ?? "", monospaced: true) { text in
                            let json = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            ShellProviderBindings.change(model, id) { $0.extraBodyJSON = json.isEmpty ? nil : json }
                        }
                        .frame(maxWidth: 300)
                        if let json = entry.extraBodyJSON, !ShellProviderDetail.isJSONObject(json) {
                            Text("Not a JSON object: it is ignored until it parses.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        } else {
                            Text("Merged into every request body last.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func numberField(_ value: Int?, placeholder: String, commit: @escaping (Int?) -> Void) -> some View {
        ShellCommitField(placeholder, value: value.map(String.init) ?? "") { text in
            let digits = text.filter(\.isNumber)
            commit(Int(digits).flatMap { $0 > 0 ? $0 : nil })
        }
        .frame(maxWidth: 160)
    }

    // ---- test prompt ----

    private var testPrompt: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                testing = true
                testResult = nil
                Task {
                    testResult = await model.sendTestPrompt(to: id)
                    testing = false
                }
            } label: {
                Text("Send Test Prompt")
            }
            .disabled(testing)
            VStack(alignment: .leading, spacing: 2) {
                if testing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for the answer…").foregroundStyle(.secondary)
                    }
                } else if let testResult {
                    switch testResult {
                    case .success(let answer):
                        Label("Answered: \(answer.isEmpty ? "(nothing)" : String(answer.prefix(60)))", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failure(let error):
                        Label(error.userMessage, systemImage: "xmark.octagon.fill")
                            .labelStyle(ShellLeadingIconLabelStyle())
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text(ShellProviderRows.testPromptNote)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }

    // ---- model lists ----

    private func refreshModels() async {
        refreshingModels = true
        await model.refreshModels(of: id, includeHidden: showAll)
        refreshingModels = false
    }

    /// The list is fetched when the provider is ready and none is known yet. A CLI keeps its default and its list is
    /// fetched only on request.
    private func loadModelsIfUseful() async {
        if model.availability[id] == nil { await model.refreshAvailability(of: id) }
        guard !isCLI, case .ready? = model.availability[id], (model.models[id] ?? []).isEmpty else { return }
        await refreshModels()
    }

    // ---- helpers ----

    /// Commands in back quotes as code ("Run `codex login`").
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    static func isJSONObject(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
    }
}

/// The default provider of each job (section 9.6): Review, and Chat and Report, which default to "Same as Review".
struct ShellTaskDefaultsBar: View {
    let model: SettingsModel

    enum Job { case review, chat, report }

    var body: some View {
        HStack(spacing: 18) {
            Text("Default provider")
                .foregroundStyle(.secondary)
            picker("Review", job: .review)
            picker("Chat", job: .chat)
            picker("Report", job: .report)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func picker(_ title: String, job: Job) -> some View {
        let current = ref(job)?.providerID
        let enabled = model.providers.filter { model.settings.providers[$0.id]?.enabled == true || $0.id == current }
        return Picker(title, selection: Binding(get: { current }, set: { choose($0, for: job) })) {
            Text(job == .review ? "None" : "Same as Review").tag(ProviderID?.none)
            ForEach(enabled, id: \.id) { descriptor in
                let on = model.settings.providers[descriptor.id]?.enabled == true
                Text(on ? descriptor.displayName : "\(descriptor.displayName) (off)").tag(Optional(descriptor.id))
            }
        }
        .fixedSize()
    }

    private func ref(_ job: Job) -> ProviderRef? {
        switch job {
        case .review: return model.settings.defaults.review
        case .chat: return model.settings.defaults.chat
        case .report: return model.settings.defaults.report
        }
    }

    /// A job's default names the provider and the model chosen for it on this pane.
    private func choose(_ id: ProviderID?, for job: Job) {
        model.update { settings in
            let ref = id.map { ProviderRef(providerID: $0, model: settings.providers[$0]?.model) }
            switch job {
            case .review: settings.defaults.review = ref
            case .chat: settings.defaults.chat = ref
            case .report: settings.defaults.report = ref
            }
        }
    }
}
