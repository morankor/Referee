import Foundation
import RefereeCore

// The value types of plan.md Appendix A.9, as printed there.

public enum DocumentPhase: Sendable, Equatable { case empty, loading(fileName: String), ready, failed(message: String) }

public enum RunState: Sendable, Equatable {
    case idle
    case running(kind: RunKind, phase: ReviewPhase?, startedAt: Date)
}

public struct Banner: Sendable, Equatable, Identifiable {
    public enum Style: Sendable, Equatable { case info, warning, error }
    public enum Action: Sendable, Equatable { case retry, openSettings }
    public var id: UUID
    public var style: Style
    public var message: String
    public var action: Action?               // .retry -> model.retryLastFailedJob(); .openSettings is handled by the window
}

public struct ConsentRequest: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var provider: ProviderDescriptor
    public var model: String?
    public var plan: SendPlan
}

/// An own comment being written (N key, "+" button, or "Comment" in the selection bar).
public struct ComposingComment: Sendable, Equatable {
    public var selection: SelectionInfo?     // the passage it will be anchored to, captured when composing began
}

public enum CommentFilter: Sendable, Equatable { case all, pending, approved, rejected, kind(CommentKind) }
public enum SidebarTab: String, Sendable, CaseIterable { case comments, chat, report }
public enum ExportFormat: String, Sendable, CaseIterable { case markdown, plainText, docx, pdf }

/// Model -> PDF view. Find and zoom are not here: the menu calls ReaderController directly (plan section 7.4).
public enum ReaderCommand: Sendable, Equatable {
    case reveal(rects: [PageRect], flash: Bool)
    case goToPage(Int)
    case clearSelection
}

public enum CitationLookup: Sendable, Equatable {
    public enum Target: Sendable, Equatable {
        case mention(Int)                    // clicked in the PDF: the card is placed next to the mention
        case entry(Int)                      // chosen in the References list: the card is placed at the top of the PDF pane
    }
    case idle
    case resolving(target: Target)
    case resolved(target: Target, entries: [BibEntry], references: [ResolvedReference])
}
