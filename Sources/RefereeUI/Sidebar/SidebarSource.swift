import Foundation
import RefereeCore
import AppCore

// Which provider and model wrote an AI comment or an assistant's answer (step 5b, the user's requirement): every AI
// comment card, folded or not, and every answer in a discussion or the Chat tab carries a small label, "Claude Code ·
// Sonnet", "OpenAI API · gpt-5.1", "Codex · default model", so that the comments of reviews by different providers can
// be told apart in one list.
//
// Where the names come from, in this order:
// - The provider: a descriptor the model has now (the enabled providers, the active one, chat's and the report's),
//   shortened like the destination indicator ("Claude Code (subscription)" → "Claude Code"); else the name of one of
//   the nine providers of plan.md section 5.2 from `knownProviders` (a provider switched off since its review has no
//   public descriptor: docs/contract-notes/step5-sidebar.md, "Contract problems"); else its id.
// - The model: the id the run asked for (`RunRecord.provider.model`, `ThreadMessage.provider.model`), shown by its
//   display name when the provider's cached model list has it; nil reads "default model" (a CLI's own default).
//
// The model a provider reports it actually used is not recorded yet; when it is, `SidebarSource.reportedModel` takes
// it and wins over the requested one.

/// The label of one comment or answer.
struct SidebarSource: Equatable {
    var providerID: ProviderID?              // nil: an AI comment whose run the session does not record
    var providerName: String                 // "Claude Code"
    var model: String?                       // the model the run asked for; nil = the provider's own default
    var modelName: String?                   // its display name in the provider's cached model list
    var reportedModel: String?               // the model the provider said it used, once that is recorded (not yet)

    static let defaultModelText = "default model"
    static let unrecordedText = "Model not recorded"

    /// An AI comment whose run is missing from the session (a review the app did not see to its end).
    static let unrecorded = SidebarSource(providerID: nil, providerName: unrecordedText, model: nil, modelName: nil)

    /// "Sonnet", "gpt-5.1", "default model".
    var modelText: String { reportedModel ?? modelName ?? model ?? Self.defaultModelText }

    /// "Claude Code · Sonnet".
    var text: String { providerID == nil ? providerName : providerName + " · " + modelText }

    /// The tooltip, with the full ids: "Written by claude-cli, model sonnet".
    var help: String {
        guard let providerID else { return "The run that wrote this comment is not recorded in this review." }
        return "Written by \(providerID), model " + (reportedModel ?? model ?? "not named (the provider's default)")
    }

    /// For VoiceOver: "Written by Claude Code, model Sonnet".
    var spoken: String {
        providerID == nil ? Self.unrecordedText : "Written by \(providerName), model \(modelText)"
    }
}

/// Names the sources of a session's comments and answers from what the window knows. Pure once made.
struct SidebarSourceNames: Equatable {
    /// The review that is running. The comments it has delivered are not in `session.runs` yet: the model records a run
    /// when it ends. Its provider is the active one, the model the active model (what the review asked for).
    struct Running: Equatable {
        var since: Date
        var ref: ProviderRef
    }

    var descriptors: [ProviderDescriptor]
    var cachedModels: [ProviderID: [ModelInfo]]
    var runs: [RunRecord]
    var running: Running?

    /// The nine providers of plan.md section 5.2, by the name their descriptors give, shortened: the name of a provider
    /// whose descriptor the window no longer has (switched off since its review, or left out by Local only).
    static let knownProviders: [ProviderID: String] = [
        "anthropic-api": "Anthropic API",
        "openai-api": "OpenAI API",
        "gemini-api": "Gemini API",
        "xai-api": "xAI API",
        "ollama": "Ollama",
        "claude-cli": "Claude Code",
        "codex-cli": "Codex",
        "antigravity-cli": "Antigravity",
        "grok-cli": "Grok Build",
    ]

    init(descriptors: [ProviderDescriptor] = [], cachedModels: [ProviderID: [ModelInfo]] = [:], runs: [RunRecord] = [], running: Running? = nil) {
        self.descriptors = descriptors
        self.cachedModels = cachedModels
        self.runs = runs
        self.running = running
    }

    /// What the model knows now.
    @MainActor init(model: ReviewSessionModel) {
        var descriptors = model.selectableProviders
        for extra in [model.activeProvider, model.chatProvider, model.reportProvider].compactMap({ $0 })
        where !descriptors.contains(where: { $0.id == extra.id }) {
            descriptors.append(extra)
        }
        var running: Running?
        if case .running(.review, _, let since) = model.runState, let provider = model.activeProvider {
            running = Running(since: since, ref: ProviderRef(providerID: provider.id, model: model.activeModel))
        }
        self.init(descriptors: descriptors, cachedModels: model.settings.providers.mapValues(\.cachedModels),
                  runs: model.session?.runs ?? [], running: running)
    }

    /// The label of a provider and the model asked of it.
    func source(of ref: ProviderRef) -> SidebarSource {
        let name = descriptors.first { $0.id == ref.providerID }.map(Self.shortName) ?? Self.knownProviders[ref.providerID] ?? ref.providerID
        let modelName = ref.model.flatMap { id in cachedModels[ref.providerID]?.first { $0.id == id }?.displayName }
        return SidebarSource(providerID: ref.providerID, providerName: name, model: ref.model,
                             modelName: modelName == ref.model ? nil : modelName)
    }

    /// The label of a comment: its run's provider and model; nil for the referee's own comment.
    func source(of comment: ReviewComment) -> SidebarSource? {
        guard case .ai(let runID) = comment.origin else { return nil }
        if let run = runs.first(where: { $0.id == runID }) { return source(of: run.provider) }
        if let running, comment.createdAt >= running.since { return source(of: running.ref) }
        return .unrecorded
    }

    /// The label of a message: an assistant's answer names its provider; the referee's messages and answers without a
    /// recorded provider have none.
    func source(of message: ThreadMessage) -> SidebarSource? {
        guard message.role == .assistant, let ref = message.provider else { return nil }
        return source(of: ref)
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
