import SwiftUI
import AppKit
import RefereeCore
import AppCore

/// The destination indicator in the toolbar (plan.md section 9.7): where a review of this document would go. A click
/// opens the destination menu, or Settings when no provider is set up.
struct ShellDestinationIndicator: View {
    let model: ReviewSessionModel
    let windowState: ShellReviewWindowState
    let services: ShellWindowServices

    var body: some View {
        let state = ShellDestination.state(of: model)
        Button {
            if state.opensSettings {
                windowState.destinationMenuOpen = false
                services.openSettings(.providers)
            } else {
                windowState.destinationMenuOpen.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: state.symbol)
                    .foregroundStyle(ShellDestinationIndicator.color(state.tint))
                Text(state.text)
                    .foregroundStyle(ShellDestinationIndicator.color(state.tint))
                    .lineLimit(1)
                if state.debugDump {
                    Text(ShellDestination.debugDumpTag)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.red, in: Capsule())
                }
                if !state.opensSettings {
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
        }
        .help(state.opensSettings ? "Set up an AI provider in Settings" : "Where this document is sent, and with which provider")
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

/// The destination menu (section 9.7), drawn in the window rather than as a menu or popover so that the snapshot mode
/// can capture it: the enabled providers to choose from (stored as `session.preferredProvider`), the current plan in
/// words, the provider's retention note, the "Local only" switch and "Privacy settings…".
struct ShellDestinationMenu: View {
    let model: ReviewSessionModel
    let windowState: ShellReviewWindowState
    let services: ShellWindowServices

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Send this document to")
            let providers = model.selectableProviders
            if providers.isEmpty {
                Text(model.settings.privacy.localOnly ? "No local provider is enabled." : "No provider is enabled.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
            ForEach(providers, id: \.id) { provider in
                providerRow(provider)
            }
            Divider().padding(.vertical, 6)
            planSection
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
            Button {
                windowState.destinationMenuOpen = false
                services.openSettings(.privacy)
            } label: {
                Text("Privacy Settings…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(ShellMenuRowButtonStyle())
            .padding(.top, 4)
        }
        .padding(.vertical, 8)
        .frame(minWidth: 0, maxWidth: 420)                     // narrower than 420 in a narrow column, never clipped
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
        .padding(.horizontal, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Destination")
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
    }

    private func providerRow(_ provider: ProviderDescriptor) -> some View {
        let chosen = model.activeProvider?.id == provider.id
        let entry = model.settings.providers[provider.id]
        let shown = ShellDestination.state(provider: provider, model: chosen ? model.activeModel : entry?.model, plan: nil,
                                           verifiedAt: entry?.verifiedAt, localOnly: false, debugDump: false)
        return Button {
            model.setActiveProvider(ProviderRef(providerID: provider.id, model: nil))
            windowState.destinationMenuOpen = false
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .opacity(chosen ? 1 : 0)
                    .frame(width: 12)
                Image(systemName: shown.symbol)
                    .foregroundStyle(ShellDestinationIndicator.color(shown.tint))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.displayName)
                    Text(provider.isLocal ? "On this Mac · \(entry?.model ?? "default")"
                                          : "\(provider.destination) · \(entry?.model ?? "default")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(ShellMenuRowButtonStyle())
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    @ViewBuilder private var planSection: some View {
        sectionTitle("What a review sends")
        Group {
            if let provider = model.activeProvider, let plan = model.sendPlan {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(ShellPlanText.menuLines(plan: plan, descriptor: provider).enumerated()), id: \.offset) { _, line in
                        Text(line.text)
                            .foregroundStyle(line.style == .blocking ? Color.red : line.style == .warning ? Color.secondary : Color.primary)
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
                Text("No AI provider is set up.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 14)
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

/// A full-width row that highlights under the pointer, as a menu item does.
struct ShellMenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ShellMenuRow(configuration: configuration)
    }

    private struct ShellMenuRow: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hovering && isEnabled ? Color.accentColor.opacity(configuration.isPressed ? 0.3 : 0.15) : Color.clear)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .opacity(isEnabled ? 1 : 0.5)
        }
    }
}
