import Foundation

public enum CommentKind: String, Codable, Sendable, CaseIterable { case major, minor, question, strength }
public enum CommentStatus: String, Codable, Sendable { case pending, approved, rejected }
public enum CommentOrigin: Codable, Sendable, Equatable { case ai(runID: UUID), user }

public struct Anchor: Codable, Sendable, Equatable {
    public var quote: String                 // exactly as written by the model or selected by the user
    public var spans: [TextSpan]             // one per text line touched; empty for .pageOnly and .none
    public var rects: [PageRect]             // highlight rectangles (cached; derived from spans)
    public var pageIndex: Int?               // 0-based; set for everything except .none
    public var confidence: AnchorConfidence
    public var locationLabel: String         // "p. 4, lines 14–16" (en dash); "" when unanchored
    public init(quote: String, spans: [TextSpan] = [], rects: [PageRect] = [], pageIndex: Int? = nil, confidence: AnchorConfidence, locationLabel: String) {
        self.quote = quote; self.spans = spans; self.rects = rects; self.pageIndex = pageIndex; self.confidence = confidence; self.locationLabel = locationLabel
    }
}

public enum MessageRole: String, Codable, Sendable { case user, assistant }

public struct ThreadMessage: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var role: MessageRole
    public var text: String
    public var createdAt: Date
    public var provider: ProviderRef?        // set on assistant messages: the provider and the model asked for
    public var reportedModel: String?        // the model the provider's stream named for the answer (LLMEvent.model); nil = it named none (step 5c)
    public init(id: UUID, role: MessageRole, text: String, createdAt: Date, provider: ProviderRef? = nil, reportedModel: String? = nil) {
        self.id = id; self.role = role; self.text = text; self.createdAt = createdAt; self.provider = provider; self.reportedModel = reportedModel
    }
}

public struct CommentRevision: Codable, Sendable, Equatable {
    public var kind: CommentKind
    public var title: String
    public var body: String
    public var suggestion: String?
    public var withdraw: Bool                // true = the assistant proposes dropping the comment
    public init(kind: CommentKind, title: String, body: String, suggestion: String? = nil, withdraw: Bool) {
        self.kind = kind; self.title = title; self.body = body; self.suggestion = suggestion; self.withdraw = withdraw
    }
}

public struct ReviewComment: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var origin: CommentOrigin
    public var status: CommentStatus
    public var kind: CommentKind
    public var category: String              // RubricCategory.id; unknown ids display as "Other"
    public var title: String
    public var body: String
    public var suggestion: String?
    public var anchor: Anchor
    public var thread: [ThreadMessage]
    public var proposedRevision: CommentRevision?
    public var previousVersions: [CommentRevision]   // pushed on each accepted revision or manual edit (max 20)
    public var includeInReport: Bool
    public var similarTo: UUID?              // set by the engine: an earlier comment of the same kind on the same passage; the card starts collapsed
    public var createdAt: Date
    public var updatedAt: Date
    public init(id: UUID, origin: CommentOrigin, status: CommentStatus, kind: CommentKind, category: String, title: String, body: String,
                suggestion: String? = nil, anchor: Anchor, thread: [ThreadMessage] = [], proposedRevision: CommentRevision? = nil,
                previousVersions: [CommentRevision] = [], includeInReport: Bool, similarTo: UUID? = nil, createdAt: Date, updatedAt: Date) {
        self.id = id; self.origin = origin; self.status = status; self.kind = kind; self.category = category; self.title = title; self.body = body
        self.suggestion = suggestion; self.anchor = anchor; self.thread = thread; self.proposedRevision = proposedRevision
        self.previousVersions = previousVersions; self.includeInReport = includeInReport; self.similarTo = similarTo; self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A comment while the model is still writing it. Fields fill in as lines arrive.
public struct DraftComment: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: CommentKind?
    public var category: String?
    public var page: Int?                    // 1-based, as written by the model
    public var quote: String?
    public var title: String?
    public var body: String
    public var suggestion: String?
    public init(id: UUID, kind: CommentKind? = nil, category: String? = nil, page: Int? = nil, quote: String? = nil, title: String? = nil, body: String,
                suggestion: String? = nil) {
        self.id = id; self.kind = kind; self.category = category; self.page = page; self.quote = quote; self.title = title; self.body = body
        self.suggestion = suggestion
    }
}

public struct Conversation: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var anchor: Anchor?               // the selection it started from; nil = question about the whole paper
    public var messages: [ThreadMessage]
    public var createdAt: Date
    public init(id: UUID, anchor: Anchor? = nil, messages: [ThreadMessage] = [], createdAt: Date) {
        self.id = id; self.anchor = anchor; self.messages = messages; self.createdAt = createdAt
    }
}

public enum Recommendation: String, Codable, Sendable, CaseIterable { case accept, minorRevision, majorRevision, reject }

public struct ReportVersion: Codable, Sendable, Equatable {
    public var markdown: String
    public var savedAt: Date
    public var note: String                  // "generated", "before regenerate", "before voice revision"
    public init(markdown: String, savedAt: Date, note: String) { self.markdown = markdown; self.savedAt = savedAt; self.note = note }
}

public struct ReportDraft: Codable, Sendable, Equatable {
    public var markdown: String
    public var recommendation: Recommendation?   // a journal's; nil for a report written for a conference
    public var recommendationLabel: String?      // a conference's: one label of its VenueProfile.scale; nil for a journal's report
    public var generatedAt: Date?
    public var provider: ProviderRef?
    public var basedOnCommentIDs: [UUID]
    public var userEdited: Bool
    public var versions: [ReportVersion]     // newest last, max 10
    public init(markdown: String, recommendation: Recommendation? = nil, recommendationLabel: String? = nil, generatedAt: Date? = nil,
                provider: ProviderRef? = nil, basedOnCommentIDs: [UUID] = [], userEdited: Bool, versions: [ReportVersion] = []) {
        self.markdown = markdown; self.recommendation = recommendation; self.recommendationLabel = recommendationLabel; self.generatedAt = generatedAt
        self.provider = provider; self.basedOnCommentIDs = basedOnCommentIDs; self.userEdited = userEdited; self.versions = versions
    }
}

public enum RunKind: String, Codable, Sendable { case review, discussion, question, report, revise }
public enum RunStatus: Codable, Sendable, Equatable { case running, completed, cancelled, failed(String) }

/// Audit trail: every time manuscript content was sent to a model. The model keeps a run in `session.runs` from its start
/// (status .running) and replaces that record by how the run ended (plan.md section 6.6, step 5c).
public struct RunRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: RunKind
    public var provider: ProviderRef
    public var destination: String           // ProviderDescriptor.destination at the time
    public var sentPDF: Bool                 // true = the PDF file itself was uploaded, false = extracted text
    public var requestCount: Int
    public var startedAt: Date
    public var finishedAt: Date?
    public var status: RunStatus
    public var usage: Usage?
    public var reportedModel: String?        // the model the provider's stream named (LLMEvent.model), the last one of the run; nil = none named (step 5c)
    public init(id: UUID, kind: RunKind, provider: ProviderRef, destination: String, sentPDF: Bool, requestCount: Int, startedAt: Date,
                finishedAt: Date? = nil, status: RunStatus, usage: Usage? = nil, reportedModel: String? = nil) {
        self.id = id; self.kind = kind; self.provider = provider; self.destination = destination; self.sentPDF = sentPDF; self.requestCount = requestCount
        self.startedAt = startedAt; self.finishedAt = finishedAt; self.status = status; self.usage = usage; self.reportedModel = reportedModel
    }
}

public struct ConsentRecord: Codable, Sendable, Equatable {
    public var providerID: ProviderID
    public var grantedAt: Date
    public init(providerID: ProviderID, grantedAt: Date) { self.providerID = providerID; self.grantedAt = grantedAt }
}

public struct ManuscriptMeta: Codable, Sendable, Equatable {
    public var title: String?
    public var targetVenue: String?          // the venue's displayName; free text in a session saved before venues, which the prompts still name
    public var manuscriptID: String?
    public var reviewerNotes: String         // free text passed to review and report prompts
    public var venueID: String?              // VenueProfile.id of the venue the paper is reviewed for; nil = Journal (unspecified)
    public init(title: String? = nil, targetVenue: String? = nil, manuscriptID: String? = nil, reviewerNotes: String, venueID: String? = nil) {
        self.title = title; self.targetVenue = targetVenue; self.manuscriptID = manuscriptID; self.reviewerNotes = reviewerNotes; self.venueID = venueID
    }
}

public struct ReviewSession: Codable, Sendable, Equatable, Identifiable {
    public var schemaVersion: Int            // 1
    public var id: UUID
    public var document: DocumentRef
    public var meta: ManuscriptMeta
    public var preferredProvider: ProviderRef?   // per-document choice; nil = AppSettings.defaults.review
    public var comments: [ReviewComment]     // stored in creation order; display order is computed
    public var conversations: [Conversation]
    public var report: ReportDraft?
    public var paperDigest: String?          // notes produced by a chunked review; reused for replies and the report
    public var runs: [RunRecord]
    public var consents: [ConsentRecord]
    public var createdAt: Date
    public var updatedAt: Date
    public init(schemaVersion: Int, id: UUID, document: DocumentRef, meta: ManuscriptMeta, preferredProvider: ProviderRef? = nil,
                comments: [ReviewComment] = [], conversations: [Conversation] = [], report: ReportDraft? = nil, paperDigest: String? = nil,
                runs: [RunRecord] = [], consents: [ConsentRecord] = [], createdAt: Date, updatedAt: Date) {
        self.schemaVersion = schemaVersion; self.id = id; self.document = document; self.meta = meta; self.preferredProvider = preferredProvider
        self.comments = comments; self.conversations = conversations; self.report = report; self.paperDigest = paperDigest; self.runs = runs
        self.consents = consents; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public struct SessionSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String                    // document sha256
    public var fileName: String
    public var title: String?
    public var lastKnownPath: String?
    public var updatedAt: Date
    public var commentCount: Int
    public var pendingCount: Int
    public var hasReport: Bool
    public init(id: String, fileName: String, title: String? = nil, lastKnownPath: String? = nil, updatedAt: Date, commentCount: Int, pendingCount: Int,
                hasReport: Bool) {
        self.id = id; self.fileName = fileName; self.title = title; self.lastKnownPath = lastKnownPath; self.updatedAt = updatedAt
        self.commentCount = commentCount; self.pendingCount = pendingCount; self.hasReport = hasReport
    }
}
