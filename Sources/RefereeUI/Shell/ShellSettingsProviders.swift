import SwiftUI
import AppKit
import RefereeCore
import AppCore

/// Settings ▸ Providers (plan.md section 9.6): the providers in three groups on the left, each with its status light
/// and enable switch; the chosen provider's settings on the right; the default provider of each job underneath.
///
/// Design review D21: with no provider switched on, a box above the list says where to start, and the pane opens on
/// Ollama (kept as the choice, so that switching it on does not move the pane to another provider).
struct ShellProvidersPane: View {
    let model: SettingsModel
    let navigation: ShellSettingsNavigation

    var body: some View {
        let groups = ShellProviderRows.grouped(model.providers)
        let ordered = groups.flatMap(\.providers)
        let selected = ShellProviderRows.shownProvider(in: ordered, chosen: navigation.provider, settings: model.settings)
        let noneOn = ShellProviderRows.noneSwitchedOn(ordered, settings: model.settings)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if noneOn {
                        Label(ShellProviderRows.startWithLocal, systemImage: "laptopcomputer")
                            .labelStyle(ShellLeadingIconLabelStyle())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                            .padding([.horizontal, .top], 8)
                    }
                    ShellProviderList(model: model, groups: groups,
                                      selection: Binding(get: { selected?.id }, set: { navigation.provider = $0 }))
                }
                .frame(width: 270)
                .background(Color(nsColor: .controlBackgroundColor))
                .onChange(of: noneOn, initial: true) { _, isNoneOn in
                    // Ollama becomes the choice, so that switching it on does not move the pane to the first provider.
                    if isNoneOn, navigation.provider == nil, ordered.contains(where: { $0.id == ShellProviderRows.localStart }) {
                        navigation.provider = ShellProviderRows.localStart
                    }
                }
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

/// One provider in the list: status light, name, "Experimental" while unverified, the model chosen for it under the
/// name ("Example Large", "CLI default"), and the enable switch.
struct ShellProviderListRow: View {
    let model: SettingsModel
    let descriptor: ProviderDescriptor

    var body: some View {
        let status = ShellProviderRows.status(model.availability[descriptor.id])
        let entry = model.settings.providers[descriptor.id]
        let experimental = ShellProviderRows.showsExperimentalWarning(descriptor, settings: entry)
        let chosenModel = ShellModelChoices.chosenModelLine(descriptor, entry: entry, listed: model.models[descriptor.id] ?? [])
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    ShellStatusDot(light: status.light)
                    Text(ShellProviderRows.listName(descriptor))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if experimental {
                        CommonTag("Experimental", color: .orange)              // design review D16
                    }
                }
                Text(chosenModel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 17)                      // under the name, past the status light
            }
            Spacer(minLength: 4)
            Toggle("Enabled", isOn: ShellProviderBindings.enabled(model, descriptor.id))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .help("\(descriptor.displayName): \(status.headline)" + (status.detail.map { " — " + $0 } ?? ""))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(descriptor.displayName), \(status.headline)\(experimental ? ", experimental" : ""), model \(chosenModel)"))
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

    /// The enable switch of a provider, through `setEnabled` (design review D5).
    static func enabled(_ model: SettingsModel, _ id: ProviderID) -> Binding<Bool> {
        Binding(get: { entry(model, id).enabled }, set: { value in
            let providers = model.providers
            model.update { settings in setEnabled(value, id, in: &settings, providers: providers) }
        })
    }

    /// D5: a provider switched on while there is no review default becomes the review default; one that already
    /// exists is never replaced. The review default switched off moves to another provider the referee has switched
    /// on, a local one first, or to none; a chat or report default that named it goes back to "Same as Review". The
    /// switch changes only the provider it belongs to: nothing else is ever switched on. `providers`: the registry, in
    /// its order.
    static func setEnabled(_ value: Bool, _ id: ProviderID, in settings: inout AppSettings, providers: [ProviderDescriptor]) {
        var entry = settings.providers[id] ?? ProviderSettings(enabled: false, inputMode: .auto)
        entry.enabled = value
        settings.providers[id] = entry
        if value {
            if settings.defaults.review == nil { settings.defaults.review = ProviderRef(providerID: id, model: entry.model) }
            return
        }
        guard settings.defaults.review?.providerID == id else { return }
        let others = providers.filter { $0.id != id && settings.providers[$0.id]?.enabled == true }
        let next = others.first(where: \.isLocal) ?? others.first
        settings.defaults.review = next.map { ProviderRef(providerID: $0.id, model: settings.providers[$0.id]?.model) }
        if settings.defaults.chat?.providerID == id { settings.defaults.chat = nil }
        if settings.defaults.report?.providerID == id { settings.defaults.report = nil }
    }

    /// The provider's model; the job defaults that name this provider with the model it had follow it, so that the
    /// model chosen here is the one a review uses. A job default on "Default model" follows by itself; one given another
    /// model of its own in the default bar keeps it.
    static func chooseModel(_ model: SettingsModel, _ id: ProviderID, _ modelID: String?) {
        model.update { settings in chooseModel(modelID, for: id, in: &settings) }
    }

    static func chooseModel(_ modelID: String?, for id: ProviderID, in settings: inout AppSettings) {
        var entry = settings.providers[id] ?? ProviderSettings(enabled: false, inputMode: .auto)
        let previous = entry.model
        entry.model = modelID
        settings.providers[id] = entry
        func follow(_ ref: inout ProviderRef?) {
            if ref?.providerID == id, let pinned = ref?.model, pinned == previous { ref?.model = modelID }
        }
        follow(&settings.defaults.review)
        follow(&settings.defaults.chat)
        follow(&settings.defaults.report)
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
            // D21: a key saved while the provider is off does nothing until it is switched on.
            if ShellProviderRows.keyWaitsForSwitch(descriptor, storedSecrets: model.storedSecrets, settings: model.settings.providers[id]) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ShellProviderRows.switchOnNote(descriptor))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Switch On") { ShellProviderBindings.enabled(model, id).wrappedValue = true }
                        .controlSize(.small)
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
                Text("Leave empty to use the copy the app finds; the version found is shown in the status above.")
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
                        Text("Separated by spaces. The options the app needs for safety are always kept.")
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

    /// Pressable only for a provider that is ready (D21); the note says what it does and costs for this kind of provider.
    private var testPrompt: some View {
        let availability = model.availability[id]
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
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
            .disabled(testing || !ShellProviderRows.canSendTestPrompt(availability))
            .help(ShellProviderRows.testPromptHelp(availability) ?? "")
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
                Text(ShellProviderRows.testPromptNote(for: descriptor))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
/// Each job's menu lists the providers switched on, each with its models (step 5b): "Default model (…)" follows the
/// model chosen for the provider on this pane, any other model is the job's own.
struct ShellTaskDefaultsBar: View {
    let model: SettingsModel

    enum Job { case review, chat, report }

    var body: some View {
        HStack(spacing: 14) {
            Text("Default provider")
                .foregroundStyle(.secondary)
            chooser("Review", job: .review)
            chooser("Chat", job: .chat)
            chooser("Report", job: .report)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func chooser(_ title: String, job: Job) -> some View {
        let current = Self.ref(job, in: model.settings)
        let selection = Binding<ProviderRef?>(get: { current }, set: { ref in model.update { Self.set(ref, for: job, in: &$0) } })
        let candidates = model.providers.filter { model.settings.providers[$0.id]?.enabled == true || $0.id == current?.providerID }
        return HStack(spacing: 6) {
            Text(title)
            Menu {
                Picker(title, selection: selection) {
                    Text(Self.noneTitle(job)).tag(ProviderRef?.none)
                }
                .pickerStyle(.inline)
                .labelsHidden()
                ForEach(candidates, id: \.id) { descriptor in
                    let on = model.settings.providers[descriptor.id]?.enabled == true
                    Picker(selection: selection) {
                        ForEach(ShellModelChoices.menu(for: descriptor.id, settings: model.settings, current: current, limit: nil).choices,
                                id: \.self) { choice in
                            Text(choice.title).tag(Optional(choice.ref))
                        }
                    } label: {
                        Text(on ? descriptor.displayName : "\(descriptor.displayName) (off)")
                    }
                    .pickerStyle(.menu)
                }
            } label: {
                Text(Self.label(current, job: job, providers: model.providers, settings: model.settings))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 190)
            .fixedSize(horizontal: false, vertical: true)
            .help(Self.label(current, job: job, providers: model.providers, settings: model.settings))
        }
    }

    static func noneTitle(_ job: Job) -> String { job == .review ? "None" : "Same as Review" }

    static func ref(_ job: Job, in settings: AppSettings) -> ProviderRef? {
        switch job {
        case .review: return settings.defaults.review
        case .chat: return settings.defaults.chat
        case .report: return settings.defaults.report
        }
    }

    /// A job's default: a provider with a model of its own, or with none ("Default model": the model chosen for the
    /// provider on this pane), or nil ("None" for the review, "Same as Review" for the others).
    static func set(_ ref: ProviderRef?, for job: Job, in settings: inout AppSettings) {
        switch job {
        case .review: settings.defaults.review = ref
        case .chat: settings.defaults.chat = ref
        case .report: settings.defaults.report = ref
        }
    }

    /// What the job's menu reads: "Ollama (local) · gemma4:e4b", "Claude Code · Default model", "Same as Review".
    static func label(_ ref: ProviderRef?, job: Job, providers: [ProviderDescriptor], settings: AppSettings) -> String {
        guard let ref else { return noneTitle(job) }
        let descriptor = providers.first { $0.id == ref.providerID }
        var name = descriptor.map(ShellProviderRows.listName) ?? ref.providerID
        if settings.providers[ref.providerID]?.enabled != true { name += " (off)" }
        let modelName = ref.model.map { ShellModelChoices.name(of: $0, in: settings.providers[ref.providerID]?.cachedModels ?? []) }
        return "\(name) · \(modelName ?? ShellModelChoices.defaultModel)"
    }
}
