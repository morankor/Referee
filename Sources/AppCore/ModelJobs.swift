import Foundation
import RefereeCore

// The jobs of ReviewSessionModel (plan.md sections 2.3 and 9.7). Every job runs in one of two lanes, gets its
// provider from one of the three task defaults, and passes the one gate `authorize(job:)` before anything is sent.

/// At most one job runs in each lane (section 2.3).
enum ModelLane: Sendable, Equatable {
    case review     // review, report, voice revision
    case reply      // discussion, question
}

/// Which default of Settings ▸ Providers a job's provider comes from (section 9.6: Review, Chat, Report).
enum ModelTask: Sendable, Equatable {
    case review, chat, report
}

enum ModelJob: Sendable, Equatable {
    case review
    case report
    case reviseVoice
    /// `sentMessageID` is set when the referee's message is already in the thread (a retry of a failed reply).
    case discussion(commentID: UUID, message: String, sentMessageID: UUID?)
    /// `conversationID` nil = a new conversation, anchored to `selection` (nil = about the whole paper).
    /// `sentMessageID` is set when the question is already in the conversation (a retry of a failed reply).
    case question(conversationID: UUID?, selection: SelectionInfo?, question: String, sentMessageID: UUID?)

    var lane: ModelLane {
        switch self {
        case .review, .report, .reviseVoice: return .review
        case .discussion, .question: return .reply
        }
    }

    var task: ModelTask {
        switch self {
        case .review: return .review
        case .report, .reviseVoice: return .report
        case .discussion, .question: return .chat
        }
    }

    var runKind: RunKind {
        switch self {
        case .review: return .review
        case .report: return .report
        case .reviseVoice: return .revise
        case .discussion: return .discussion
        case .question: return .question
        }
    }
}

/// The provider a job goes to, and everything the engine gets besides the paper.
struct JobTarget: Sendable, Equatable {
    var descriptor: ProviderDescriptor
    var context: EngineContext
    var ref: ProviderRef { context.provider }       // provider id and the chosen model id (nil = the provider's default)
}

/// A job whose provider is known, on its way through `authorize(job:)`.
struct PendingJob: Sendable, Equatable {
    var job: ModelJob
    var target: JobTarget
}

/// What a run told the model, kept while its stream is read.
struct RunProgress: Sendable, Equatable {
    var started: RunRecord?
    var finished: RunRecord?
    var phase: ReviewPhase?
    var startedAt: Date
}

/// Whose anchor a background task fills in.
enum AnchorOwner: Sendable, Equatable {
    case comment(UUID)
    case conversation(UUID)
}
