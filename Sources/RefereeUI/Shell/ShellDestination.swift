import Foundation
import RefereeCore
import AppCore

/// What the destination indicator in the toolbar shows (plan.md section 9.7; design review D3, D4, D5, D13): a symbol,
/// a title over a detail line, a tint and a tooltip.
struct ShellDestinationState: Equatable {
    enum Tint: Equatable { case green, orange, grey, red }
    var symbol: String          // SF Symbol
    var title: String           // "Local", "Claude Code", "Anthropic API", "No AI provider", "Choose AI provider", "Remote blocked"
    var detail: String?         // "gemma4:e4b", "default · text only · experimental", "Ollama is not running", "Local only is on"
    var tint: Tint
    var opensSettings: Bool     // "No AI provider": a click opens Settings instead of the menu
    var debugDump: Bool         // REFEREE_DEBUG_DUMP is set: the red "debug dump on" tag (section 10.5)
    var help: String            // the tooltip, in which a truncated detail can be read in full

    /// The title, then " · " and the detail when there is one: "Local · gemma4:e4b". The welcome line, the
    /// accessibility label and the tests read this.
    var text: String { detail.map { "\(title) · \($0)" } ?? title }
}

/// The rules of the table in plan.md section 9.7 as the design review refined them, and the names the indicator and
/// the welcome window use.
enum ShellDestination {
    static let noProvider = "No AI provider"
    static let chooseProvider = "Choose AI provider"
    static let remoteBlocked = "Remote blocked"
    static let localOnlyIsOn = "Local only is on"
    static let debugDumpTag = "debug dump on"

    /// - nothing usable: slashed circle, "No AI provider", grey; a click opens Settings. With providers switched on but
    ///   none chosen for this document (D5): question mark, "Choose AI provider", grey; a click opens the menu.
    /// - Local only on and a remote provider chosen: lock, "Remote blocked" over "Local only is on", red.
    /// - a local provider: laptop, "Local" over the model, green. When its status says it cannot run (D13): a warning
    ///   triangle, orange (red when it is unavailable), "Local" over the reason, and the reason and the hint as tooltip.
    /// - a subscription CLI: terminal, its short name; any other remote provider: cloud, its display name; both orange,
    ///   over "<model or default>", " · text only" when its plan sends extracted text (unknown until the plan is
    ///   there), and " · experimental" for an experimental provider without a successful test prompt.
    /// - D4: when chat or the report goes to another provider than the review, the detail ends with " · chat: <name>",
    ///   " · report: <name>" or " · chat and report: <name>", the name being "Local" for a local provider, else its
    ///   short name; the tint is green only when every one of them is local. A job whose provider is not set up (nil)
    ///   sends nothing, so it is not named.
    /// - `availability` is used for a local provider only: a remote one is never checked from the window (D13).
    static func state(provider: ProviderDescriptor?, model: String?, plan: SendPlan?, verifiedAt: Date?, localOnly: Bool,
                      debugDump: Bool, chatProvider: ProviderDescriptor? = nil, reportProvider: ProviderDescriptor? = nil,
                      hasChoices: Bool = false, availability: ProviderAvailability? = nil) -> ShellDestinationState {
        let jobs = otherJobs(review: provider, chat: chatProvider, report: reportProvider)
        let othersAreRemote = jobs.contains { !$0.provider.isLocal }
        func detail(_ parts: [String]) -> String? {
            let all = parts + jobs.map { "\($0.label): \(jobName($0.provider))" }
            return all.isEmpty ? nil : all.joined(separator: " · ")
        }
        func made(symbol: String, title: String, detail: String?, tint: ShellDestinationState.Tint, opensSettings: Bool,
                  help: String? = nil) -> ShellDestinationState {
            var state = ShellDestinationState(symbol: symbol, title: title, detail: detail, tint: tint, opensSettings: opensSettings,
                                              debugDump: debugDump, help: "")
            state.help = help ?? "Where this document is sent: \(state.text)"
            return state
        }

        guard let provider else {
            let tint: ShellDestinationState.Tint = othersAreRemote ? .orange : .grey
            if hasChoices {
                return made(symbol: "questionmark.circle", title: chooseProvider, detail: detail([]), tint: tint, opensSettings: false)
            }
            return made(symbol: "nosign", title: noProvider, detail: detail([]), tint: tint, opensSettings: true)
        }
        if localOnly && !provider.isLocal {
            return made(symbol: "lock.fill", title: remoteBlocked, detail: detail([localOnlyIsOn]), tint: .red, opensSettings: false)
        }
        if provider.isLocal, let problem = availability.flatMap(problem(of:)) {
            return made(symbol: "exclamationmark.triangle.fill", title: "Local", detail: detail([problem.reason]),
                        tint: problem.unavailable ? .red : .orange, opensSettings: false, help: problem.tooltip)
        }
        var parts = [model.flatMap { $0.isEmpty ? nil : $0 } ?? "default"]
        if !provider.isLocal, let plan, !plan.sendsPDF { parts.append("text only") }
        if provider.isExperimental && verifiedAt == nil { parts.append("experimental") }
        if provider.isLocal {
            return made(symbol: "laptopcomputer", title: "Local", detail: detail(parts), tint: othersAreRemote ? .orange : .green,
                        opensSettings: false)
        }
        if provider.authMode == .subscriptionCLI {
            return made(symbol: "terminal", title: shortName(provider), detail: detail(parts), tint: .orange, opensSettings: false)
        }
        return made(symbol: "cloud", title: provider.displayName, detail: detail(parts), tint: .orange, opensSettings: false)
    }

    /// The indicator of a review window, from its model.
    @MainActor static func state(of model: ReviewSessionModel,
                                 environment: [String: String] = ProcessInfo.processInfo.environment) -> ShellDestinationState {
        let provider = model.activeProvider
        return state(provider: provider, model: model.activeModel, plan: model.sendPlan,
                     verifiedAt: provider.flatMap { model.settings.providers[$0.id]?.verifiedAt },
                     localOnly: model.settings.privacy.localOnly, debugDump: debugDumpIsOn(environment),
                     chatProvider: model.chatProvider, reportProvider: model.reportProvider,
                     hasChoices: !model.selectableProviders.isEmpty, availability: model.activeAvailability)
    }

    /// The jobs other than the review whose provider differs from the review's (D4): chat and the report, or both at
    /// once when they share one. A job without a provider is left out: it sends nothing.
    static func otherJobs(review: ProviderDescriptor?, chat: ProviderDescriptor?,
                          report: ProviderDescriptor?) -> [(label: String, provider: ProviderDescriptor)] {
        let chatDiffers = chat.map { $0.id != review?.id } ?? false
        let reportDiffers = report.map { $0.id != review?.id } ?? false
        if chatDiffers, reportDiffers, let chat, let report, chat.id == report.id { return [("chat and report", chat)] }
        var jobs: [(label: String, provider: ProviderDescriptor)] = []
        if chatDiffers, let chat { jobs.append(("chat", chat)) }
        if reportDiffers, let report { jobs.append(("report", report)) }
        return jobs
    }

    /// How the indicator names the provider of another job: "Local", or the short name ("Claude Code").
    static func jobName(_ provider: ProviderDescriptor) -> String {
        provider.isLocal ? "Local" : shortName(provider)
    }

    /// A status that says the provider cannot run now (D13): its reason, whether it is unavailable (red) rather than
    /// waiting for setup (orange), and the tooltip "<reason>. <hint>" without back quotes.
    static func problem(of availability: ProviderAvailability) -> (reason: String, unavailable: Bool, tooltip: String)? {
        switch availability {
        case .ready:
            return nil
        case .needsSetup(let reason, let hint):
            return (reason, false, tooltip(reason: reason, hint: hint))
        case .unavailable(let reason):
            return (reason, true, tooltip(reason: reason, hint: ""))
        }
    }

    /// "Ollama is not running. Start the Ollama app or run ollama serve."
    static func tooltip(reason: String, hint: String) -> String {
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let hint = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        var sentence = reason.isEmpty || reason.hasSuffix(".") ? reason : reason + "."
        if !hint.isEmpty { sentence += (sentence.isEmpty ? "" : " ") + hint }
        return sentence.replacingOccurrences(of: "`", with: "")
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
