import SwiftUI
import AppKit
import RefereeCore
import AppCore

/// The destination indicator in the toolbar (plan.md section 9.7): where a review of this document would go. A click
/// opens the destination menu, or Settings when no provider is set up.
///
/// Design review D3: a title over a detail line, never wider than 260 points, so that at 1,000 points a long one
/// cannot push Review, Report and the sidebar button into the toolbar's overflow menu; the tooltip has the whole text.
struct ShellDestinationIndicator: View {
    let model: ReviewSessionModel
    let windowState: ShellReviewWindowState
    let services: ShellWindowServices

    static let maximumWidth: CGFloat = 260

    var body: some View {
        let state = ShellDestination.state(of: model)
        let tint = ShellDestinationIndicator.color(state.tint)
        Button {
            if state.opensSettings {
                windowState.destinationMenuOpen = false
                services.openSettings(.providers)
            } else {
                windowState.destinationMenuOpen.toggle()
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: state.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 0) {
                    Text(state.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                    if let detail = state.detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if state.debugDump {
                    Text(ShellDestination.debugDumpTag)
                        .font(Theme.tagFont)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.red, in: Capsule())
                        .fixedSize()
                }
                if !state.opensSettings {
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: ShellDestinationIndicator.maximumWidth, alignment: .leading)
        }
        .help(state.help)
        .accessibilityLabel(Text("Destination: " + state.text + (state.debugDump ? ", " + ShellDestination.debugDumpTag : "")))
    }

    static func color(_ tint: ShellDestinationState.Tint) -> Color {
        switch tint {
        case .green: return .green
        case .orange: return .orange
        case .grey: return .secondary
        case .red: return .red
        }
    }
}

/// A row of the destination menu that the keyboard can reach (D24): a provider, or one of the models under it.
enum ShellMenuRowID: Hashable {
    case provider(ProviderID)
    case model(ProviderRef)
}

/// The destination menu (section 9.7), drawn in the window rather than as a menu or popover so that the snapshot mode
/// can capture it: the enabled providers to choose from (stored as `session.preferredProvider`, for the review, chat
/// and report of the paper), each with its models (the chosen provider's listed at first, any other's behind its
/// chevron), what a review sends as a grid of facts with the retention note (D24), where chat and the report go when
/// that is elsewhere (D4), what was sent so far (D34), the "Local only" switch, "Provider Settings…" and "Privacy
/// Settings…". ↑ and ↓ move a highlight over the providers and the models listed, → and ← show and hide a provider's
/// models, and Return chooses (D24). Opening it asks a local provider for its status again (D13); remote ones are
/// never asked from here, and the models come from the list Settings keeps, so nothing else is asked either.
struct ShellDestinationMenu: View {
    let model: ReviewSessionModel
    let windowState: ShellReviewWindowState
    let services: ShellWindowServices
    @State private var highlighted: ShellMenuRowID?
    @State private var expanded: ProviderID?
    @FocusState private var focused: Bool

    static let caption = "For the review, chat and report of this paper."
    static let providerSettings = "Provider Settings…"
    static let privacySettings = "Privacy Settings…"

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }                              // a short window: the menu scrolls instead of being cut off
        }
        .padding(.vertical, 8)
        .frame(minWidth: 0, maxWidth: 420)                     // narrower than 420 in a narrow column, never clipped
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
        .padding(.horizontal, 10)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.upArrow) { moveHighlight(by: -1) }
        .onKeyPress(.downArrow) { moveHighlight(by: 1) }
        .onKeyPress(.rightArrow) { showModels(true) }
        .onKeyPress(.leftArrow) { showModels(false) }
        .onKeyPress(.return) { chooseHighlighted() }
        .onAppear {
            expanded = model.activeProvider?.id
            highlighted = model.activeProvider.map { .provider($0.id) }
            focused = true
            model.refreshActiveAvailability()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Destination")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Send this document to")
            Text(ShellDestinationMenu.caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 4)
            let providers = model.selectableProviders
            if providers.isEmpty {
                Text(model.settings.privacy.localOnly ? "No local provider is enabled." : "No provider is enabled.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
            ForEach(providers, id: \.id) { provider in
                providerRow(provider)
                if expanded == provider.id { modelRows(provider) }
            }
            Divider().padding(.vertical, 6)
            planSection
            Divider().padding(.vertical, 6)
            sentSoFarSection
            Divider().padding(.vertical, 6)
            HStack {
                Text("Local only")
                Spacer()
                Toggle("Local only", isOn: localOnly)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 2)
            Text("Only providers that run on this Mac can be chosen.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
            settingsRow(ShellDestinationMenu.providerSettings, tab: .providers)
                .padding(.top, 4)
            settingsRow(ShellDestinationMenu.privacySettings, tab: .privacy)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
    }

    private func settingsRow(_ title: String, tab: ShellSettingsTab) -> some View {
        Button {
            windowState.destinationMenuOpen = false
            services.openSettings(tab)
        } label: {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(ShellMenuRowButtonStyle())
    }

    // ---- providers and their models ----

    /// Where the name of a provider starts in its row: past the row's margin, the check mark and the symbol.
    private static let nameIndent: CGFloat = 14 + 12 + 8 + 18 + 8

    private func providerRow(_ provider: ProviderDescriptor) -> some View {
        let chosen = model.activeProvider?.id == provider.id
        let entry = model.settings.providers[provider.id]
        let shown = ShellDestination.state(provider: provider, model: chosen ? model.activeModel : entry?.model, plan: nil,
                                           verifiedAt: entry?.verifiedAt, localOnly: false, debugDump: false)
        let modelID = chosen ? model.activeModel : entry?.model
        let modelName = modelID.map { ShellModelChoices.name(of: $0, in: entry?.cachedModels ?? []) } ?? "default"
        let open = expanded == provider.id
        // D13: the chosen local provider's status, when it says the provider cannot run now.
        let problem = chosen && provider.isLocal ? model.activeAvailability.flatMap(ShellDestination.problem(of:)) : nil
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    choose(ProviderRef(providerID: provider.id, model: nil))
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .opacity(chosen ? 1 : 0)
                            .frame(width: 12)
                        Image(systemName: problem == nil ? shown.symbol : "exclamationmark.triangle.fill")
                            .foregroundStyle(ShellDestinationIndicator.color(problem.map { $0.unavailable ? .red : .orange } ?? shown.tint))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(provider.displayName)
                            Text(provider.isLocal ? "On this Mac · \(modelName)" : "\(provider.destination) · \(modelName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(ShellMenuRowButtonStyle(highlighted: highlighted == .provider(provider.id)))
                .accessibilityAddTraits(chosen ? .isSelected : [])
                Button {
                    expanded = open ? nil : provider.id
                } label: {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                .help(open ? "Hide the models of \(provider.displayName)" : "Choose a model of \(provider.displayName)")
                .accessibilityLabel(Text(open ? "Hide the models of \(provider.displayName)" : "Show the models of \(provider.displayName)"))
            }
            if let problem {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(problem.reason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Check Again") { model.refreshActiveAvailability() }
                        .controlSize(.small)
                        .help(problem.tooltip)
                }
                .padding(.leading, Self.nameIndent)
                .padding(.trailing, 14)
                .padding(.bottom, 4)
            }
        }
    }

    /// The models of a provider, under its row: "Default model (…)", then its listed models, at most eight, the one in
    /// force for this paper checked; "Choose in Settings…" when Settings has no list yet, "More in Settings…" when the
    /// list is longer.
    @ViewBuilder private func modelRows(_ provider: ProviderDescriptor) -> some View {
        let current = Self.appliedRef(model)
        let menu = ShellModelChoices.menu(for: provider.id, settings: model.settings, current: current)
        ForEach(menu.choices, id: \.self) { choice in
            Button {
                choose(choice.ref)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                        .opacity(current == choice.ref ? 1 : 0)
                        .frame(width: 12)
                    Text(choice.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .font(.callout)
                .padding(.leading, Self.nameIndent - 14 - 18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(ShellMenuRowButtonStyle(highlighted: highlighted == .model(choice.ref), compact: true))
            .accessibilityAddTraits(current == choice.ref ? .isSelected : [])
        }
        if let row = menu.settingsRow {
            Button {
                windowState.destinationMenuOpen = false
                services.openProviderSettings(provider.id)
            } label: {
                Text(row)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, Self.nameIndent - 14 - 18 + 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(ShellMenuRowButtonStyle(compact: true))
        }
    }

    /// The reference in force for this paper's review: its own choice, else the review default, when it names the
    /// active provider. nil when no provider is active.
    @MainActor static func appliedRef(_ model: ReviewSessionModel) -> ProviderRef? {
        guard let active = model.activeProvider, let ref = model.session?.preferredProvider ?? model.settings.defaults.review,
              ref.providerID == active.id else { return nil }
        return ref
    }

    /// A provider and model chosen in the menu: the paper's choice from now on (`setActiveProvider`), and the menu closes.
    @MainActor static func choose(_ ref: ProviderRef, in model: ReviewSessionModel, windowState: ShellReviewWindowState) {
        model.setActiveProvider(ref)
        windowState.destinationMenuOpen = false
    }

    private func choose(_ ref: ProviderRef) {
        Self.choose(ref, in: model, windowState: windowState)
    }

    /// The rows the keyboard walks, in order: every provider, and the models of the one whose models are shown.
    static func keyboardRows(providers: [ProviderDescriptor], expanded: ProviderID?, settings: AppSettings,
                             current: ProviderRef?) -> [ShellMenuRowID] {
        providers.flatMap { provider -> [ShellMenuRowID] in
            guard provider.id == expanded else { return [.provider(provider.id)] }
            return [.provider(provider.id)]
                + ShellModelChoices.menu(for: provider.id, settings: settings, current: current).choices.map { .model($0.ref) }
        }
    }

    /// ↑ and ↓ (D24): the highlight moves over the rows, from the chosen provider, and stops at either end.
    private func moveHighlight(by step: Int) -> KeyPress.Result {
        let rows = Self.keyboardRows(providers: model.selectableProviders, expanded: expanded, settings: model.settings,
                                     current: Self.appliedRef(model))
        guard !rows.isEmpty else { return .ignored }
        let start = highlighted.flatMap { rows.firstIndex(of: $0) } ?? (step > 0 ? -1 : rows.count)
        highlighted = rows[min(max(start + step, 0), rows.count - 1)]
        return .handled
    }

    /// → shows the highlighted provider's models, ← hides them and goes back to the provider.
    private func showModels(_ show: Bool) -> KeyPress.Result {
        switch highlighted {
        case .provider(let id)?:
            expanded = show ? id : (expanded == id ? nil : expanded)
        case .model(let ref)?:
            guard !show else { return .ignored }
            expanded = nil
            highlighted = .provider(ref.providerID)
        case nil:
            return .ignored
        }
        return .handled
    }

    /// Return (D24): the highlighted provider (with its default model), or the highlighted model, becomes this paper's.
    private func chooseHighlighted() -> KeyPress.Result {
        switch highlighted {
        case .provider(let id)?:
            guard model.selectableProviders.contains(where: { $0.id == id }) else { return .ignored }
            choose(ProviderRef(providerID: id, model: nil))
        case .model(let ref)?:
            choose(ref)
        case nil:
            return .ignored
        }
        return .handled
    }

    // ---- what a review sends ----

    @ViewBuilder private var planSection: some View {
        sectionTitle("What a review sends")
        Group {
            if let provider = model.activeProvider, let plan = model.sendPlan {
                let summary = ShellPlanText.menuSummary(plan: plan, descriptor: provider, pageCount: model.paper?.ref.pageCount ?? 0,
                                                        byteCount: model.paper?.ref.byteCount ?? model.paper?.data.count ?? 0)
                VStack(alignment: .leading, spacing: 6) {
                    if let blocking = summary.blockingReason {
                        Text(blocking)
                            .foregroundStyle(.red)
                    } else {
                        ShellFactsGrid(facts: summary.facts, valueFont: .callout)
                        ForEach(summary.warnings, id: \.self) { warning in
                            Text(warning)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(provider.retentionNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if model.activeProvider != nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(model.paper == nil ? "Open a PDF to see what a review would send." : "Working out what a review would send…")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No AI provider is chosen for this document.")
                    .foregroundStyle(.secondary)
            }
            ForEach(ShellDestinationMenu.otherJobLines(model), id: \.self) { line in
                Text(line)
                    .padding(.top, 4)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 14)
    }

    /// D4: "Chat questions go to Claude Code (subscription) (claude)." and "The report is written by …", for a job whose
    /// provider is not the review's.
    @MainActor static func otherJobLines(_ model: ReviewSessionModel) -> [String] {
        otherJobLines(review: model.activeProvider, chat: model.chatProvider, report: model.reportProvider)
    }

    static func otherJobLines(review: ProviderDescriptor?, chat: ProviderDescriptor?, report: ProviderDescriptor?) -> [String] {
        var lines: [String] = []
        if let chat, chat.id != review?.id { lines.append("Chat questions go to \(chat.displayName) (\(chat.destination)).") }
        if let report, report.id != review?.id { lines.append("The report is written by \(report.displayName) (\(report.destination)).") }
        return lines
    }

    // ---- what was sent so far (D34) ----

    @ViewBuilder private var sentSoFarSection: some View {
        sectionTitle("Sent so far")
        let lines = ShellDestinationMenu.sentSoFar(model, services: services)
        VStack(alignment: .leading, spacing: 3) {
            if lines.isEmpty {
                Text(ShellPlanText.nothingSent)
                    .foregroundStyle(.secondary)
            }
            ForEach(lines, id: \.self) { line in
                Text(line)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 14)
    }

    /// The lines of "Sent so far" for this document: every run the session recorded, by provider, named as the app's
    /// registry names them (a provider no longer registered by its id).
    @MainActor static func sentSoFar(_ model: ReviewSessionModel, services: ShellWindowServices) -> [String] {
        let known = (services.settings?.providers ?? []) + model.selectableProviders
            + [model.activeProvider, model.chatProvider, model.reportProvider].compactMap { $0 }
        return ShellPlanText.sentSoFar(model.session?.runs ?? [], name: { id in known.first { $0.id == id }?.displayName ?? id },
                                       date: { $0.formatted(date: .abbreviated, time: .shortened) })
    }

    /// Local only is a setting of the whole app: through the app's settings model, which tells every window. Without
    /// one (the snapshot mode) only this window's copy changes.
    private var localOnly: Binding<Bool> {
        Binding(get: { model.settings.privacy.localOnly }, set: { value in
            if let settings = services.settings {
                settings.update { $0.privacy.localOnly = value }
            } else {
                var copy = model.settings
                copy.privacy.localOnly = value
                model.reloadSettings(copy)
            }
        })
    }
}

/// A full-width row that highlights under the pointer, as a menu item does, or while the keyboard is on it. A compact
/// row (the models under a provider) is lower.
struct ShellMenuRowButtonStyle: ButtonStyle {
    var highlighted = false
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        ShellMenuRow(configuration: configuration, highlighted: highlighted, compact: compact)
    }

    private struct ShellMenuRow: View {
        let configuration: ButtonStyle.Configuration
        let highlighted: Bool
        let compact: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .padding(.horizontal, 14)
                .padding(.vertical, compact ? 2 : 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((hovering || highlighted) && isEnabled ? Color.accentColor.opacity(configuration.isPressed ? 0.3 : 0.15) : Color.clear)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .opacity(isEnabled ? 1 : 0.5)
        }
    }
}
