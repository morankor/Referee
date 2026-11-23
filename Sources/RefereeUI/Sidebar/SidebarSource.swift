import Foundation
import RefereeCore
import AppCore

// Which provider and model wrote an AI comment or an assistant's answer (step 5b, the user's requirement): every AI
// comment card, folded or not, and every answer in a discussion or the Chat tab carries a small label, "Claude Code ·
// Sonnet", "OpenAI API · gpt-5.1", "Codex · default model", so that the comments of reviews by different providers can
// be told apart in one list.
//
// Where the names come from, in this order:
// - The provider: its descriptor among every provider the app registers, switched on or not
//   (`ReviewSessionModel.registeredProviders`, step 5c), shortened like the destination indicator ("Claude Code
//   (subscription)" → "Claude Code"); else its id (a provider no longer registered).
// - The model: the one the provider's own stream named (`RunRecord.reportedModel`, `ThreadMessage.reportedModel`,
//   step 5c: "claude-sonnet-4-6" for a run that asked Claude Code for its default), else the one the run asked for
//   (`RunRecord.provider.model`, `ThreadMessage.provider.model`); either shown by its display name when the provider's
//   cached model list has it ("Sonnet", "Claude Sonnet 4.6"); nothing named and nothing asked reads "default model".

/// The label of one comment or answer.
struct SidebarSource: Equatable {
    var providerID: ProviderID?              // nil: an AI comment whose run the session does not record
    var providerName: String                 // "Claude Code"
    var model: String?                       // the model the run asked for; nil = the provider's own default
    var modelName: String?                   // its display name in the provider's cached model list
    var reportedModel: String?               // the model the provider's stream named (step 5c); wins over the one asked for
    var reportedModelName: String?           // its display name in the provider's cached model list

    static let defaultModelText = "default model"
    static let unrecordedText = "Model not recorded"

    /// An AI comment whose run is missing from the session: since step 5c a run is recorded when it starts, so only a
    /// review written by an earlier version that did not see it to its end has none.
    static let unrecorded = SidebarSource(providerID: nil, providerName: unrecordedText, model: nil, modelName: nil)

    /// "Sonnet", "gpt-5.1", "claude-sonnet-4-6", "default model".
    var modelText: String { reportedModelName ?? reportedModel ?? modelName ?? model ?? Self.defaultModelText }

    /// "Claude Code · Sonnet".
    var text: String { providerID == nil ? providerName : providerName + " · " + modelText }

    /// The tooltip, with the full ids: "Written by claude-cli, model sonnet"; when the provider named another model than
    /// the one asked for, both: "Written by claude-cli, model claude-sonnet-4-6 (asked for the provider's default)".
    var help: String {
        guard let providerID else { return "The run that wrote this comment is not recorded in this review." }
        guard let reportedModel else { return "Written by \(providerID), model " + (model ?? "not named (the provider's default)") }
        guard reportedModel != model else { return "Written by \(providerID), model \(reportedModel)" }
        return "Written by \(providerID), model \(reportedModel) (asked for \(model ?? "the provider's default"))"
    }

    /// For VoiceOver: "Written by Claude Code, model Sonnet".
    var spoken: String {
        providerID == nil ? Self.unrecordedText : "Written by \(providerName), model \(modelText)"
    }
}

/// Names the sources of a session's comments and answers from what the window knows. Pure once made.
struct SidebarSourceNames: Equatable {
    /// The review that is running, for the drafts it is writing. Its comments name its run like any other: the model
    /// records a run when it starts (step 5c), so they keep that run's provider and model even when the document's
    /// provider changes meanwhile. Before the run's first event, the active provider and model stand in for it.
    struct Running: Equatable {
        var since: Date
        var ref: ProviderRef
    }

    var descriptors: [ProviderDescriptor]
    var cachedModels: [ProviderID: [ModelInfo]]
    var runs: [RunRecord]
    var running: Running?

    init(descriptors: [ProviderDescriptor] = [], cachedModels: [ProviderID: [ModelInfo]] = [:], runs: [RunRecord] = [], running: Running? = nil) {
        self.descriptors = descriptors
        self.cachedModels = cachedModels
        self.runs = runs
        self.running = running
    }

    /// What the model knows now: every registered provider (step 5c), switched on or not, and the session's runs, the
    /// one under way included.
    @MainActor init(model: ReviewSessionModel) {
        let runs = model.session?.runs ?? []
        var running: Running?
        if case .running(.review, _, let since) = model.runState {
            if let run = runs.last(where: { $0.kind == .review && $0.status == .running }) {
                running = Running(since: run.startedAt, ref: run.provider)
            } else if let provider = model.activeProvider {
                running = Running(since: since, ref: ProviderRef(providerID: provider.id, model: model.activeModel))
            }
        }
        self.init(descriptors: model.registeredProviders, cachedModels: model.settings.providers.mapValues(\.cachedModels),
                  runs: runs, running: running)
    }

    /// The label of a provider, the model asked of it and the model its stream named (step 5c), each model by its
    /// display name where the provider's cached list has one.
    func source(of ref: ProviderRef, reported: String? = nil) -> SidebarSource {
        let name = descriptors.first { $0.id == ref.providerID }.map(Self.shortName) ?? ref.providerID
        let models = cachedModels[ref.providerID] ?? []
        func displayName(_ id: String?) -> String? {
            guard let id, let shown = models.first(where: { $0.id == id })?.displayName, shown != id else { return nil }
            return shown
        }
        let reported = reported.flatMap { $0.isEmpty ? nil : $0 }
        return SidebarSource(providerID: ref.providerID, providerName: name, model: ref.model, modelName: displayName(ref.model),
                             reportedModel: reported, reportedModelName: displayName(reported))
    }

    /// The label of a comment: its run's provider and model, the run under way included; nil for the referee's own
    /// comment; "Model not recorded" when the session does not have its run.
    func source(of comment: ReviewComment) -> SidebarSource? {
        guard case .ai(let runID) = comment.origin else { return nil }
        if let run = runs.first(where: { $0.id == runID }) { return source(of: run.provider, reported: run.reportedModel) }
        return .unrecorded
    }

    /// The label of a message: an assistant's answer names its provider and model; the referee's messages and answers
    /// without a recorded provider have none.
    func source(of message: ThreadMessage) -> SidebarSource? {
        guard message.role == .assistant, let ref = message.provider else { return nil }
        return source(of: ref, reported: message.reportedModel)
    }

    /// The running review's label, for the drafts it is writing.
    var runningSource: SidebarSource? { running.map { source(of: $0.ref) } }

    /// The labels of every comment of the session that has one.
    func sources(of comments: [ReviewComment]) -> [UUID: SidebarSource] {
        var result: [UUID: SidebarSource] = [:]
        for comment in comments where result[comment.id] == nil {
            if let source = source(of: comment) { result[comment.id] = source }
        }
        return result
    }

    /// A provider's name without the plan or place in brackets, as the destination indicator shows it: "Claude Code
    /// (subscription)" → "Claude Code", "Ollama (local)" → "Ollama". Built-in stand-ins keep theirs ("Mock (remote)"):
    /// there the bracket is what tells them apart.
    static func shortName(_ descriptor: ProviderDescriptor) -> String {
        let name = descriptor.displayName
        guard descriptor.authMode == .subscriptionCLI || descriptor.authMode == .local,
              name.hasSuffix(")"), let open = name.lastIndex(of: "(") else { return name }
        let short = name[..<open].trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? name : short
    }
}
