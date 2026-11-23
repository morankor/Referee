import Foundation
import RefereeCore
import AppCore

/// What the destination indicator in the toolbar shows (plan.md section 9.7).
struct ShellDestinationState: Equatable {
    enum Tint: Equatable { case green, orange, grey, red }
    var symbol: String          // SF Symbol
    var text: String            // "Local · gemma4:e4b", "Anthropic API · example-large · text only"
    var tint: Tint
    var opensSettings: Bool     // "No AI provider": a click opens Settings instead of the menu
    var debugDump: Bool         // REFEREE_DEBUG_DUMP is set: the red "debug dump on" tag (section 10.5)
}

/// The rules of the table in plan.md section 9.7, and the names the indicator and the welcome window use.
enum ShellDestination {
    static let noProvider = "No AI provider"
    static let remoteBlocked = "Remote blocked (Local only)"
    static let debugDumpTag = "debug dump on"

    /// - nothing usable: slashed circle, "No AI provider", grey; a click opens Settings.
    /// - Local only on and a remote provider chosen: lock, "Remote blocked (Local only)", red.
    /// - a local provider: laptop, "Local · <model>", green.
    /// - a subscription CLI: terminal, "<short name> · <model or default>", orange; any other remote provider: cloud,
    ///   "<display name> · <model or default>", orange.
    /// - " · text only" when a remote provider's plan sends extracted text (unknown until the plan is there), and
    ///   " · experimental" for an experimental provider without a successful test prompt.
    static func state(provider: ProviderDescriptor?, model: String?, plan: SendPlan?, verifiedAt: Date?, localOnly: Bool,
                      debugDump: Bool) -> ShellDestinationState {
        guard let provider else {
            return ShellDestinationState(symbol: "nosign", text: noProvider, tint: .grey, opensSettings: true, debugDump: debugDump)
        }
        if localOnly && !provider.isLocal {
            return ShellDestinationState(symbol: "lock.fill", text: remoteBlocked, tint: .red, opensSettings: false, debugDump: debugDump)
        }
        let modelName = model.flatMap { $0.isEmpty ? nil : $0 } ?? "default"
        var text: String
        let symbol: String
        let tint: ShellDestinationState.Tint
        if provider.isLocal {
            text = "Local · \(modelName)"
            symbol = "laptopcomputer"
            tint = .green
        } else if provider.authMode == .subscriptionCLI {
            text = "\(shortName(provider)) · \(modelName)"
            symbol = "terminal"
            tint = .orange
        } else {
            text = "\(provider.displayName) · \(modelName)"
            symbol = "cloud"
            tint = .orange
        }
        if !provider.isLocal, let plan, !plan.sendsPDF { text += " · text only" }
        if provider.isExperimental && verifiedAt == nil { text += " · experimental" }
        return ShellDestinationState(symbol: symbol, text: text, tint: tint, opensSettings: false, debugDump: debugDump)
    }

    /// The indicator of a review window, from its model.
    @MainActor static func state(of model: ReviewSessionModel,
                                 environment: [String: String] = ProcessInfo.processInfo.environment) -> ShellDestinationState {
        let provider = model.activeProvider
        return state(provider: provider, model: model.activeModel, plan: model.sendPlan,
                     verifiedAt: provider.flatMap { model.settings.providers[$0.id]?.verifiedAt },
                     localOnly: model.settings.privacy.localOnly, debugDump: debugDumpIsOn(environment))
    }

    /// `REFEREE_DEBUG_DUMP` set to a folder (section 10.5). In the app the environment `LiveDependencies` reads is the
    /// process environment, so the Shell reads the same variable there.
    static func debugDumpIsOn(_ environment: [String: String]) -> Bool {
        !(environment["REFEREE_DEBUG_DUMP"] ?? "").isEmpty
    }

    /// The name without its bracketed plan: "Claude Code (subscription)" -> "Claude Code", "Codex (ChatGPT plan)" -> "Codex".
    static func shortName(_ provider: ProviderDescriptor) -> String {
        let name = provider.displayName
        guard name.hasSuffix(")"), let open = name.lastIndex(of: "(") else { return name }
        let short = name[..<open].trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? name : short
    }

    /// The welcome window's provider line (section 9.1): the review default, if it is registered and enabled.
    /// "AI: Local · gemma4:e4b", or "not set up".
    static func welcomeLine(settings: AppSettings, providers: [ProviderDescriptor]) -> ShellWelcomeProvider {
        guard let ref = settings.defaults.review, let entry = settings.providers[ref.providerID], entry.enabled,
              let provider = providers.first(where: { $0.id == ref.providerID }) else { return .notSetUp }
        let shown = state(provider: provider, model: ref.model ?? entry.model, plan: nil, verifiedAt: entry.verifiedAt,
                          localOnly: settings.privacy.localOnly, debugDump: false)
        return .configured("AI: " + shown.text, isLocal: shown.tint == .green)
    }
}
