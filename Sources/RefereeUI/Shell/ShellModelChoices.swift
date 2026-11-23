import Foundation
import RefereeCore

/// One model a provider can be chosen with: "Default model (gemma4:e4b)", whose reference has no model (the provider's
/// own choice in Settings, or a CLI's default), or one model of the provider's list.
struct ShellModelChoice: Equatable, Hashable {
    var title: String
    var ref: ProviderRef
}

/// The models offered for one provider: in the destination menu, under the provider's row; in Settings ▸ Providers,
/// in the default bar's menu of each job (step 5b, the user's request "let me also choose a model").
struct ShellModelMenu: Equatable {
    var choices: [ShellModelChoice]   // "Default model …" first, then the models
    var settingsRow: String?          // "Choose in Settings…" with an empty list, "More in Settings…" when models were left out
}

/// Which models a provider is offered with. Only the list Settings keeps (`ProviderSettings.cachedModels`, filled
/// when Settings fetches it) is read, so offering models makes no request and starts no process.
enum ShellModelChoices {
    static let defaultModel = "Default model"
    static let chooseInSettings = "Choose in Settings…"
    static let moreInSettings = "More in Settings…"
    /// The destination menu shows at most this many models of a provider, so that it stays usable at 1,000 × 640.
    static let menuLimit = 8

    /// A model by its display name where it has one other than its id, else by its id.
    static func name(of modelID: String, in list: [ModelInfo]) -> String {
        guard let info = list.first(where: { $0.id == modelID }), !info.displayName.isEmpty else { return modelID }
        return info.displayName
    }

    /// "Default model (Example Large)": what a reference without a model resolves to, when Settings has chosen one for
    /// the provider; plain "Default model" when it has not (a CLI then uses its own default).
    static func defaultTitle(for providerID: ProviderID, settings: AppSettings) -> String {
        guard let entry = settings.providers[providerID], let chosen = entry.model, !chosen.isEmpty else { return defaultModel }
        return "\(defaultModel) (\(name(of: chosen, in: entry.cachedModels)))"
    }

    /// The choices for `providerID`: "Default model …", then its listed models, at most `limit` of them (all when nil).
    /// `current` is the reference in force (the paper's, or a job default): when it names a model of this provider
    /// that the shortened list leaves out, or that is not listed at all, that model is added, so that the choice in
    /// force can always be seen. With an empty list the last row is "Choose in Settings…", with models left out
    /// "More in Settings…".
    static func menu(for providerID: ProviderID, settings: AppSettings, current: ProviderRef?, limit: Int? = menuLimit) -> ShellModelMenu {
        let list = settings.providers[providerID]?.cachedModels ?? []
        let shown = limit.map { Array(list.prefix($0)) } ?? list
        var choices = [ShellModelChoice(title: defaultTitle(for: providerID, settings: settings), ref: ProviderRef(providerID: providerID, model: nil))]
        choices += shown.map { ShellModelChoice(title: name(of: $0.id, in: list), ref: ProviderRef(providerID: providerID, model: $0.id)) }
        if let current, current.providerID == providerID, let model = current.model, !model.isEmpty, !shown.contains(where: { $0.id == model }) {
            choices.append(ShellModelChoice(title: name(of: model, in: list), ref: current))
        }
        let settingsRow: String? = list.isEmpty ? chooseInSettings : (shown.count < list.count ? moreInSettings : nil)
        return ShellModelMenu(choices: choices, settingsRow: settingsRow)
    }

    /// How a provider's chosen model reads under its name in Settings ▸ Providers: "Example Large", "gemma4:e4b";
    /// "CLI default" for a CLI without one, "Not chosen" for any other provider.
    static func chosenModelLine(_ descriptor: ProviderDescriptor, entry: ProviderSettings?, listed: [ModelInfo]) -> String {
        guard let chosen = entry?.model, !chosen.isEmpty else { return descriptor.authMode == .subscriptionCLI ? "CLI default" : "Not chosen" }
        return name(of: chosen, in: listed.isEmpty ? (entry?.cachedModels ?? []) : listed)
    }
}
