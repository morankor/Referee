import Foundation

public enum InputMode: String, Codable, Sendable { case auto, text, pdf }

public struct RubricCategory: Codable, Sendable, Equatable, Identifiable {
    public var id: String                    // slug used in the model output, e.g. "claims"
    public var name: String                  // "Claims vs. evidence"
    public var guidance: String              // one or two sentences inserted into the review prompt
    public var enabled: Bool
    public init(id: String, name: String, guidance: String, enabled: Bool) { self.id = id; self.name = name; self.guidance = guidance; self.enabled = enabled }
}

public struct PromptSet: Codable, Sendable, Equatable {
    public var reviewSystem: String          // rubric and referee stance (editable)
    public var discussionSystem: String
    public var questionSystem: String
    public var reportSystem: String          // voice and rules for the final report
    public var reportTemplate: String        // Markdown skeleton with the section headings
    public var voiceRevisionSystem: String
    public var quickQuestions: [String]      // presets in the selection popover
    public init(reviewSystem: String, discussionSystem: String, questionSystem: String, reportSystem: String, reportTemplate: String,
                voiceRevisionSystem: String, quickQuestions: [String] = []) {
        self.reviewSystem = reviewSystem; self.discussionSystem = discussionSystem; self.questionSystem = questionSystem; self.reportSystem = reportSystem
        self.reportTemplate = reportTemplate; self.voiceRevisionSystem = voiceRevisionSystem; self.quickQuestions = quickQuestions
    }
}

public struct ProviderSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var model: String?                // nil = provider default / not chosen yet
    public var baseURL: String?              // override, e.g. a remote Ollama host
    public var executablePath: String?       // CLI providers: explicit binary path
    public var contextWindowOverride: Int?   // tokens
    public var maxOutputTokens: Int?
    public var inputMode: InputMode
    public var extraArguments: [String]      // CLI providers: appended verbatim
    public var extraBodyJSON: String?        // HTTP providers: JSON object whose top-level keys are merged into the request body
    public var cachedModels: [ModelInfo]     // last result of listModels(); the source of EngineContext.model
    public var cachedModelsAt: Date?
    public var verifiedAt: Date?             // last successful "Send test prompt"; experimental providers show a warning until it is set
    public init(enabled: Bool, model: String? = nil, baseURL: String? = nil, executablePath: String? = nil, contextWindowOverride: Int? = nil,
                maxOutputTokens: Int? = nil, inputMode: InputMode, extraArguments: [String] = [], extraBodyJSON: String? = nil, cachedModels: [ModelInfo] = [],
                cachedModelsAt: Date? = nil, verifiedAt: Date? = nil) {
        self.enabled = enabled; self.model = model; self.baseURL = baseURL; self.executablePath = executablePath
        self.contextWindowOverride = contextWindowOverride; self.maxOutputTokens = maxOutputTokens; self.inputMode = inputMode
        self.extraArguments = extraArguments; self.extraBodyJSON = extraBodyJSON; self.cachedModels = cachedModels; self.cachedModelsAt = cachedModelsAt
        self.verifiedAt = verifiedAt
    }
}

public struct TaskDefaults: Codable, Sendable, Equatable {
    public var review: ProviderRef?
    public var chat: ProviderRef?            // nil = same as review
    public var report: ProviderRef?          // nil = same as review
    public init(review: ProviderRef? = nil, chat: ProviderRef? = nil, report: ProviderRef? = nil) { self.review = review; self.chat = chat; self.report = report }
}

public struct PrivacySettings: Codable, Sendable, Equatable {
    public var localOnly: Bool               // true = every non-local provider is disabled
    public var confirmFirstSendPerDocument: Bool
    public var resolveReferencesInBackground: Bool   // false = look references up only when clicked
    public init(localOnly: Bool, confirmFirstSendPerDocument: Bool, resolveReferencesInBackground: Bool) {
        self.localOnly = localOnly; self.confirmFirstSendPerDocument = confirmFirstSendPerDocument
        self.resolveReferencesInBackground = resolveReferencesInBackground
    }
}

public struct ReferenceSettings: Codable, Sendable, Equatable {
    public var crossrefMailto: String        // "" = public pool; never pre-filled
    public var pdfCacheLimitMB: Int
    public init(crossrefMailto: String, pdfCacheLimitMB: Int) { self.crossrefMailto = crossrefMailto; self.pdfCacheLimitMB = pdfCacheLimitMB }
}

public struct UISettings: Codable, Sendable, Equatable {
    public var autoAdvanceAfterTriage: Bool
    public var showRejectedHighlights: Bool
    public var sidebarWidth: Double
    public var stripMarginLineNumbers: Bool  // false = never remove margin line numbers from the text
    public init(autoAdvanceAfterTriage: Bool, showRejectedHighlights: Bool, sidebarWidth: Double, stripMarginLineNumbers: Bool) {
        self.autoAdvanceAfterTriage = autoAdvanceAfterTriage; self.showRejectedHighlights = showRejectedHighlights; self.sidebarWidth = sidebarWidth
        self.stripMarginLineNumbers = stripMarginLineNumbers
    }
}

public struct AppSettings: Codable, Sendable, Equatable {
    public var schemaVersion: Int            // 1
    public var providers: [ProviderID: ProviderSettings]
    public var defaults: TaskDefaults
    public var prompts: PromptSet
    public var rubric: [RubricCategory]
    public var privacy: PrivacySettings
    public var references: ReferenceSettings
    public var ui: UISettings
    public init(schemaVersion: Int, providers: [ProviderID: ProviderSettings] = [:], defaults: TaskDefaults, prompts: PromptSet, rubric: [RubricCategory] = [],
                privacy: PrivacySettings, references: ReferenceSettings, ui: UISettings) {
        self.schemaVersion = schemaVersion; self.providers = providers; self.defaults = defaults; self.prompts = prompts; self.rubric = rubric
        self.privacy = privacy; self.references = references; self.ui = ui
    }
}

public enum StoreError: RefereeError, Equatable {
    case corrupt(path: String)
    case newerSchema(found: Int, supported: Int)
    case io(String)
    public var userMessage: String {
        switch self {
        case .corrupt(let p): return "The saved review at \(p) is damaged and has no usable backup."
        case .newerSchema(let f, let s): return "This review was saved by a newer version of Referee (format \(f); this version reads up to \(s))."
        case .io(let m): return "Could not read or write review data (\(m))."
        }
    }
    public var recoverySuggestion: String? { nil }
    public var isRetryable: Bool { false }
}

public protocol SettingsStoring: Sendable {
    func load() async -> AppSettings                  // returns defaults when the file is missing or unreadable
    func save(_ settings: AppSettings) async throws
}

public protocol SessionStoring: Sendable {
    /// Dates come back cut to the whole second (ISO 8601, section 3.7). A damaged session.json is moved aside and the
    /// backup returned in its place; .corrupt only when nothing could be read.
    func loadSession(sha256: String) async throws -> ReviewSession?
    /// What the last loadSession(sha256:) of that document repaired, as one sentence for the banner of section 4.5
    /// (the backup was loaded because session.json was damaged); nil when it repaired nothing. Default: nil.
    func recoveryNotice(sha256: String) async -> String?
    func save(_ session: ReviewSession) async throws  // atomic; keeps one .bak
    func listSessions() async -> [SessionSummary]
    func deleteSession(sha256: String) async throws
    /// Every document's folder, damaged ones and ones of a newer format included (Settings ▸ Privacy, "Delete all
    /// review data…"). Default: deleteSession for each listed session.
    func deleteAllSessions() async throws
}

extension SessionStoring {
    public func recoveryNotice(sha256: String) async -> String? { nil }
    public func deleteAllSessions() async throws {
        for summary in await listSessions() { try await deleteSession(sha256: summary.id) }
    }
}
