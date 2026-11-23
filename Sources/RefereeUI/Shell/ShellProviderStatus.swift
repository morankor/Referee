import Foundation
import RefereeCore

/// How a provider row of Settings ▸ Providers shows the provider's status (plan.md sections 9.6 and 9.9).
struct ShellProviderStatus: Equatable {
    enum Light: Equatable { case green, yellow, red, grey }
    var light: Light
    var headline: String           // "Ready", "Needs setup", "Unavailable", "Checking…"
    var detail: String?            // "Key set", "Logged in · claude 2.1.330", the reason
    var hint: String?              // what to do (needs setup only)
}

/// A setup hint split into the prose to show and the commands to offer with a Copy button. The CLI providers give
/// either a bare install command ("npm install -g @openai/codex") or a sentence with commands in back quotes
/// ("Run `codex login`").
struct ShellSetupHint: Equatable {
    var text: String?
    var commands: [String]
}

/// Grouping, order and wording of the provider rows.
enum ShellProviderRows {
    static let experimentalWarning = "Experimental — not yet verified against the real CLI on this machine"
    static let testPromptNote = "sends 'Reply with exactly: OK'; uses a few tokens"

    /// The three groups of section 9.6, and the built-in stand-ins last (present only in tests and snapshots).
    enum Group: Int, CaseIterable, Identifiable {
        case apiKey, subscription, local, builtIn
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .apiKey: return "API key"
            case .subscription: return "Subscription through an installed CLI"
            case .local: return "Local"
            case .builtIn: return "Built in"
            }
        }
        init(_ mode: AuthMode) {
            switch mode {
            case .apiKey: self = .apiKey
            case .subscriptionCLI: self = .subscription
            case .local: self = .local
            case .none: self = .builtIn
            }
        }
    }

    /// A group and its providers.
    struct Section: Identifiable {
        var group: Group
        var providers: [ProviderDescriptor]
        var id: Int { group.rawValue }
    }

    /// The providers of each group, in registry order; empty groups left out.
    static func grouped(_ providers: [ProviderDescriptor]) -> [Section] {
        Group.allCases.compactMap { group in
            let members = providers.filter { Group($0.authMode) == group }
            return members.isEmpty ? nil : Section(group: group, providers: members)
        }
    }

    /// nil (not checked yet): grey "Checking…"; ready green; needs setup yellow with the hint; unavailable red with the reason.
    static func status(_ availability: ProviderAvailability?) -> ShellProviderStatus {
        switch availability {
        case nil:
            return ShellProviderStatus(light: .grey, headline: "Checking…", detail: nil, hint: nil)
        case .ready(let detail)?:
            return ShellProviderStatus(light: .green, headline: "Ready", detail: detail.isEmpty ? nil : detail, hint: nil)
        case .needsSetup(let reason, let hint)?:
            return ShellProviderStatus(light: .yellow, headline: "Needs setup", detail: reason.isEmpty ? nil : reason,
                                       hint: hint.isEmpty ? nil : hint)
        case .unavailable(let reason)?:
            return ShellProviderStatus(light: .red, headline: "Unavailable", detail: reason.isEmpty ? nil : reason, hint: nil)
        }
    }

    /// Section 9.6: shown in orange under the name of an experimental provider until a test prompt has succeeded.
    static func showsExperimentalWarning(_ descriptor: ProviderDescriptor, settings: ProviderSettings?) -> Bool {
        descriptor.isExperimental && settings?.verifiedAt == nil
    }

    /// Commands in back quotes are offered for copying, and the sentence is shown as it is. A CLI's hint without back
    /// quotes and without a full stop is itself the command (the install hint).
    static func setupHint(_ hint: String, isCLI: Bool) -> ShellSetupHint {
        let trimmed = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ShellSetupHint(text: nil, commands: []) }
        let pieces = trimmed.components(separatedBy: "`")
        if pieces.count >= 3 {
            let commands = pieces.enumerated().filter { $0.offset % 2 == 1 }.map { $0.element.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return ShellSetupHint(text: trimmed, commands: commands)
        }
        if isCLI && !trimmed.hasSuffix(".") { return ShellSetupHint(text: nil, commands: [trimmed]) }
        return ShellSetupHint(text: trimmed, commands: [])
    }

    /// The name in the list: a subscription CLI without its bracketed plan, which its group already says
    /// ("Claude Code (subscription)" -> "Claude Code"); the detail shows the full name.
    static func listName(_ descriptor: ProviderDescriptor) -> String {
        descriptor.authMode == .subscriptionCLI ? ShellDestination.shortName(descriptor) : descriptor.displayName
    }

    /// The key a provider's API key is stored under: its id (section 5.8).
    static func secretKey(for descriptor: ProviderDescriptor) -> String? {
        descriptor.authMode == .apiKey ? descriptor.id : nil
    }

    /// "Show all" applies where the model list is filtered: OpenAI and Gemini (sections 5.4.2, 5.4.4, 9.6).
    static func hasShowAll(_ descriptor: ProviderDescriptor) -> Bool {
        descriptor.id == "openai-api" || descriptor.id == "gemini-api"
    }
}
