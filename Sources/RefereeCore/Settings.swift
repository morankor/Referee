import Foundation

public enum InputMode: String, Codable, Sendable { case auto, text, pdf }

public struct RubricCategory: Codable, Sendable, Equatable, Identifiable {
    public var id: String                    // slug used in the model output, e.g. "claims"
    public var name: String                  // "Claims vs. evidence"
    public var guidance: String              // one or two sentences inserted into the review prompt
    public var enabled: Bool
    public init(id: String, name: String, guidance: String, enabled: Bool) { self.id = id; self.name = name; self.guidance = guidance; self.enabled = enabled }
}

public enum VenueKind: String, Codable, Sendable, CaseIterable { case journal, conference }

/// Where a paper is reviewed for (Settings ▸ Venues; plan.md Appendix G.9). The prompts name it and carry its guidance; a
/// conference's report takes its recommendation from `recommendationScale`. The built-ins (`DefaultSettings.venues`,
/// Appendix B.8) can be edited and reset, not deleted.
public struct VenueProfile: Codable, Sendable, Equatable, Identifiable {
    public var id: String                    // "jet"; a built-in's id is fixed, an added venue's is a new UUID string
    public var shortName: String             // "JET"
    public var fullName: String              // "Journal of Economic Theory"
    public var kind: VenueKind
    public var guidance: String              // what a review for this venue should weigh, inserted into the prompts; "" = nothing
    public var reportInstructions: String?   // more instructions, inserted into the report's request only
    public var recommendationScale: [String] // a conference's labels, most favourable first; a journal uses Recommendation
    public init(id: String, shortName: String, fullName: String, kind: VenueKind, guidance: String, reportInstructions: String? = nil,
                recommendationScale: [String] = []) {
        self.id = id; self.shortName = shortName; self.fullName = fullName; self.kind = kind; self.guidance = guidance
        self.reportInstructions = reportInstructions; self.recommendationScale = recommendationScale
    }
}

public struct PromptSet: Codable, Sendable, Equatable {
    public var reviewSystem: String          // rubric and referee stance (editable)
    public var discussionSystem: String
    public var questionSystem: String
    public var reportSystem: String          // voice and rules for the final report
    public var reportTemplate: String        // Markdown skeleton with the section headings
    public var voiceRevisionSystem: String
    public var quickQuestions: [String]      // presets in the selection popover
    public var conferenceReportSystem: String?   // reportSystem for a conference; nil = the default (settings written before venues)
    public var conferenceReportTemplate: String? // reportTemplate for a conference; nil = the default
    public init(reviewSystem: String, discussionSystem: String, questionSystem: String, reportSystem: String, reportTemplate: String,
                voiceRevisionSystem: String, quickQuestions: [String] = [], conferenceReportSystem: String? = nil, conferenceReportTemplate: String? = nil) {
        self.reviewSystem = reviewSystem; self.discussionSystem = discussionSystem; self.questionSystem = questionSystem; self.reportSystem = reportSystem
        self.reportTemplate = reportTemplate; self.voiceRevisionSystem = voiceRevisionSystem; self.quickQuestions = quickQuestions
        self.conferenceReportSystem = conferenceReportSystem; self.conferenceReportTemplate = conferenceReportTemplate
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
    public var venueProfiles: [VenueProfile]?   // Settings ▸ Venues as stored; nil = the built-ins as shipped. Read and write `venues`
    public var defaultVenueID: String?          // the venue of a new paper; nil = Journal (unspecified)
    public init(schemaVersion: Int, providers: [ProviderID: ProviderSettings] = [:], defaults: TaskDefaults, prompts: PromptSet, rubric: [RubricCategory] = [],
                privacy: PrivacySettings, references: ReferenceSettings, ui: UISettings, venueProfiles: [VenueProfile]? = nil, defaultVenueID: String? = nil) {
        self.schemaVersion = schemaVersion; self.providers = providers; self.defaults = defaults; self.prompts = prompts; self.rubric = rubric
        self.privacy = privacy; self.references = references; self.ui = ui; self.venueProfiles = venueProfiles; self.defaultVenueID = defaultVenueID
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

// ---- venues (Appendix G.9) ----

extension VenueProfile {
    public static let journalID = "journal"
    public static let conferenceID = "conference"
    /// "Journal (unspecified)", the venue of a session saved before venues existed: with it every prompt is what it was then.
    public static let unspecifiedJournal = VenueProfile(id: journalID, shortName: "Journal", fullName: "Journal (unspecified)", kind: .journal,
                                                        guidance: "")

    /// One of `DefaultSettings.venues`: it can be edited and reset, not deleted.
    public var isBuiltIn: Bool { DefaultSettings.venues.contains { $0.id == id } }

    /// "Journal (unspecified)" or "Conference (unspecified)": no venue is named, so the prompts name the paper's own
    /// `ManuscriptMeta.targetVenue`, if any.
    public var isUnspecified: Bool { id == Self.journalID || id == Self.conferenceID }

    /// "Journal of Economic Theory (JET)": how the prompts name a venue, and what `ManuscriptMeta.targetVenue` holds. The full
    /// name alone when the short name is empty or the same, or when the venue is unspecified; the short name alone when the
    /// full name is empty.
    public var displayName: String {
        let full = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        let short = shortName.trimmingCharacters(in: .whitespacesAndNewlines)
        if full.isEmpty { return short }
        if isUnspecified || short.isEmpty || short.caseInsensitiveCompare(full) == .orderedSame { return full }
        return "\(full) (\(short))"
    }

    /// The labels a recommendation is chosen from, most favourable first. A journal's are those of `Recommendation`; a
    /// conference's are `recommendationScale` without blank or repeated labels (ignoring case), or
    /// `DefaultSettings.conferenceScale` when none is left.
    public var scale: [String] {
        guard kind == .conference else { return Recommendation.allCases.map(\.label) }
        var labels: [String] = []
        for label in recommendationScale {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || labels.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) { continue }
            labels.append(trimmed)
        }
        return labels.isEmpty ? DefaultSettings.conferenceScale : labels
    }

    /// The label of `scale` that `text` names, as `scale` spells it: of the labels it contains as whole words (ignoring case,
    /// emphasis marks, and hyphens against spaces), the one that starts first, and of two that start together the longer
    /// ("Weak accept", not "Accept"). nil when it names none.
    public func scaleLabel(in text: String) -> String? {
        let haystack = Self.folded(text)
        var best: (start: Int, length: Int, label: String)?
        for label in scale {
            let needle = Self.folded(label)
            guard !needle.isEmpty, let start = Self.firstWholeWord(needle, in: haystack) else { continue }
            if let current = best, current.start < start || (current.start == start && current.length >= needle.count) { continue }
            best = (start, needle.count, label)
        }
        return best?.label
    }

    /// Rule `recommendation-mismatch` of Appendix B.7 on this venue's scale: `label` disagrees with a report that lists
    /// `majorConcerns` numbered major concerns when it lies in the more favourable half of `scale` and there is one, or in
    /// the less favourable half and there is none. The middle label of a scale of odd length, and a label not on the
    /// scale, never disagree. For a journal this is the rule as it was: accept or minor revision with a major concern,
    /// major revision or reject without one.
    public func recommendationMismatch(label: String, majorConcerns: Int) -> Bool {
        let labels = scale
        let wanted = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let position = labels.firstIndex(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame }) else { return false }
        let half = labels.count / 2
        if position < half { return majorConcerns > 0 }
        if position >= labels.count - half { return majorConcerns == 0 }
        return false
    }

    /// Lower case, without emphasis marks, hyphens and underscores read as spaces, every run of white space one space.
    private static func folded(_ text: String) -> [Character] {
        var result: [Character] = []
        for character in text.lowercased() where character != "*" && character != "`" {
            if character.isWhitespace || character == "-" || character == "_" || character == "\u{2010}" || character == "\u{2011}" {
                if !result.isEmpty, result.last != " " { result.append(" ") }
            } else {
                result.append(character)
            }
        }
        if result.last == " " { result.removeLast() }
        return result
    }

    /// Where `needle` first occurs in `haystack` with no letter or digit just before or just after it.
    private static func firstWholeWord(_ needle: [Character], in haystack: [Character]) -> Int? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        func isWordCharacter(_ position: Int) -> Bool { haystack[position].isLetter || haystack[position].isNumber }
        for start in 0...(haystack.count - needle.count) where haystack[start..<(start + needle.count)].elementsEqual(needle) {
            let end = start + needle.count
            if (start == 0 || !isWordCharacter(start - 1)) && (end == haystack.count || !isWordCharacter(end)) { return start }
        }
        return nil
    }
}

extension Recommendation {
    /// "Accept", "Minor revision", "Major revision", "Reject": a journal's scale (`VenueProfile.scale`).
    public var label: String {
        switch self {
        case .accept: return "Accept"
        case .minorRevision: return "Minor revision"
        case .majorRevision: return "Major revision"
        case .reject: return "Reject"
        }
    }

    /// The recommendation whose `label` this is, ignoring case and surrounding white space.
    public init?(label: String) {
        let wanted = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = Self.allCases.first(where: { $0.label.caseInsensitiveCompare(wanted) == .orderedSame }) else { return nil }
        self = match
    }
}

extension PromptSet {
    /// The report's system prompt for a venue of this kind: `reportSystem` for a journal; for a conference
    /// `conferenceReportSystem`, or the default of Appendix B.4 when the settings have none.
    public func reportSystem(for kind: VenueKind) -> String {
        kind == .conference ? conferenceReportSystem ?? DefaultSettings.conferenceReportSystem : reportSystem
    }

    /// The report's template for a venue of this kind, in the same way.
    public func reportTemplate(for kind: VenueKind) -> String {
        kind == .conference ? conferenceReportTemplate ?? DefaultSettings.conferenceReportTemplate : reportTemplate
    }
}

extension AppSettings {
    /// Settings ▸ Venues in menu order: `venueProfiles` without a repeated id and with every built-in it lacks put back at
    /// its place in `DefaultSettings.venues`; the built-ins themselves when `venueProfiles` is nil (a settings file written
    /// before venues). Setting it stores that list, or nil when it is the built-ins as shipped.
    public var venues: [VenueProfile] {
        get { Self.completed(venueProfiles ?? DefaultSettings.venues) }
        set {
            let list = Self.completed(newValue)
            venueProfiles = list == DefaultSettings.venues ? nil : list
        }
    }

    /// The venue of a new paper: `defaultVenueID`'s, or Journal (unspecified) when it names none.
    public var defaultVenue: VenueProfile { venue(id: defaultVenueID) }

    /// The venue with this id in `venues`; Journal (unspecified) for nil or an id that names none (a session saved before
    /// venues, or one whose venue was deleted).
    public func venue(id: String?) -> VenueProfile {
        let list = venues
        return list.first { $0.id == id } ?? list.first { $0.id == VenueProfile.journalID } ?? .unspecifiedJournal
    }

    private static func completed(_ venues: [VenueProfile]) -> [VenueProfile] {
        var list: [VenueProfile] = []
        for venue in venues where !list.contains(where: { $0.id == venue.id }) { list.append(venue) }
        for (position, builtIn) in DefaultSettings.venues.enumerated() where !list.contains(where: { $0.id == builtIn.id }) {
            list.insert(builtIn, at: min(position, list.count))
        }
        return list
    }
}
