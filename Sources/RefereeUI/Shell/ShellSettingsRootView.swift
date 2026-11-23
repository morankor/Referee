import SwiftUI
import AppKit
import RefereeCore
import AppCore

/// The settings window (plan.md section 9.6): 780 × 560 points, five tabs, every control bound to the app's one
/// `SettingsModel`. The size is fixed: the window is not resizable, and a fixed frame keeps every pane inside it.
///
/// `SettingsRootView(model:)` starts on Providers. The window manager passes its own navigation, so that "Privacy
/// settings…" in a review window can open the window on Privacy; a settings scene of the snapshot mode reaches the
/// same object through the hosting controller's root view.
public struct SettingsRootView: View {
    let model: SettingsModel
    let navigation: ShellSettingsNavigation
    let services: ShellSettingsServices

    public init(model: SettingsModel) {
        self.init(model: model, navigation: ShellSettingsNavigation(), services: ShellSettingsServices())
    }

    init(model: SettingsModel, navigation: ShellSettingsNavigation, services: ShellSettingsServices) {
        self.model = model
        self.navigation = navigation
        self.services = services
    }

    static let size = CGSize(width: 780, height: 560)

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(ShellSettingsTab.allCases) { tab in
                    ShellSettingsTabButton(tab: tab, selected: navigation.tab == tab) { navigation.tab = tab }
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            Group {
                switch navigation.tab {
                case .providers: ShellProvidersPane(model: model, navigation: navigation)
                case .prompts: ShellPromptsPane(model: model, navigation: navigation)
                case .privacy: ShellPrivacyPane(model: model, services: services)
                case .references: ShellReferencesPane(model: model)
                case .advanced: ShellAdvancedPane(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .task { await model.refreshAvailability(of: nil) }
    }
}

/// One tab of the settings window: icon over title, as in a preferences toolbar.
struct ShellSettingsTabButton: View {
    let tab: ShellSettingsTab
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 3) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 18))
                    .frame(height: 22)
                Text(tab.title)
                    .font(.caption)
            }
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .frame(width: 84, height: 48)
            .background(selected ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

// ---- small controls the panes share ----

/// A text field that edits a draft and hands it on when the user presses Return or leaves the field, so that a
/// setting is not saved (and every window told) on each keystroke.
struct ShellCommitField: View {
    let placeholder: String
    let value: String
    var monospaced = false
    let commit: (String) -> Void
    @State private var draft: String
    @FocusState private var focused: Bool

    init(_ placeholder: String, value: String, monospaced: Bool = false, commit: @escaping (String) -> Void) {
        self.placeholder = placeholder
        self.value = value
        self.monospaced = monospaced
        self.commit = commit
        _draft = State(initialValue: value)
    }

    var body: some View {
        TextField(placeholder, text: $draft, prompt: Text(placeholder))
            .labelsHidden()                             // in a Form the title would otherwise be drawn as a label beside the field
            .textFieldStyle(.roundedBorder)
            .font(monospaced ? .system(.body, design: .monospaced) : .body)
            .focused($focused)
            .onSubmit(send)
            .onChange(of: focused) { _, isFocused in if !isFocused { send() } }
            .onChange(of: value) { _, newValue in if !focused { draft = newValue } }
            .onDisappear(perform: send)
    }

    private func send() {
        if draft != value { commit(draft) }
    }
}

/// A long text edited in place (the prompts): the draft is handed on half a second after the last keystroke, and at
/// once when the editor loses the keyboard or goes away.
struct ShellLongTextEditor: View {
    let value: String
    var monospaced = false
    let commit: (String) -> Void
    @State private var draft: String
    @State private var pending: Task<Void, Never>?
    @FocusState private var focused: Bool

    init(value: String, monospaced: Bool = false, commit: @escaping (String) -> Void) {
        self.value = value
        self.monospaced = monospaced
        self.commit = commit
        _draft = State(initialValue: value)
    }

    var body: some View {
        TextEditor(text: $draft)
            .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 13))
            .focused($focused)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            .onChange(of: draft) { _, text in schedule(text) }
            .onChange(of: value) { _, newValue in if pending == nil, newValue != draft { draft = newValue } }
            .onChange(of: focused) { _, isFocused in if !isFocused { flush() } }
            .onDisappear(perform: flush)
    }

    /// Hands the draft on now.
    private func flush() {
        pending?.cancel()
        pending = nil
        if draft != value { commit(draft) }
    }

    private func schedule(_ text: String) {
        pending?.cancel()
        guard text != value else {
            pending = nil
            return
        }
        pending = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            pending = nil
            commit(text)
        }
    }
}

/// A command to run in Terminal, with a Copy button (section 9.6: install and sign-in commands). After a copy the button
/// reads "Copied" for `Theme.feedbackDuration`, as the other Copy buttons of step 5 do (design review D16).
struct ShellCommandBox: View {
    let command: String
    @State private var copies = 0

    var body: some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copies += 1
            } label: {
                if copies > 0 {
                    Label("Copied", systemImage: "checkmark")
                } else {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
            .controlSize(.small)
            .help("Copy the command")
            .task(id: copies) {
                guard copies > 0 else { return }
                try? await Task.sleep(for: Theme.feedbackDuration)
                if !Task.isCancelled { copies = 0 }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// A status light.
struct ShellStatusDot: View {
    let light: ShellProviderStatus.Light

    var body: some View {
        Circle()
            .fill(ShellStatusDot.color(light))
            .frame(width: 9, height: 9)
            .accessibilityHidden(true)
    }

    static func color(_ light: ShellProviderStatus.Light) -> Color {
        switch light {
        case .green: return .green
        case .yellow: return .yellow
        case .red: return .red
        case .grey: return .gray
        }
    }
}
