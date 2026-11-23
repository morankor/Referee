import Foundation
import RefereeCore
import AppCore
import TestSupport
@testable import RefereeUI

/// Comments, anchors and a model on fakes for the sidebar's tests. Swift literals only (plan.md section 3.7).
enum SidebarTestData {
    static let created = Date(timeIntervalSince1970: 1_795_000_000)
    static let rubric = DefaultSettings.make().rubric
    static let plan = SendPlan(sendsPDF: false, requestCount: 1, estimatedInputTokens: 900, destination: "this Mac", isLocal: true)

    static func comment(id: UUID = UUID(), origin: CommentOrigin = .ai(runID: UUID()), status: CommentStatus = .pending,
                        kind: CommentKind = .major, category: String = "claims", title: String = "The interval includes one",
                        body: String = "The reported interval crosses one.", suggestion: String? = nil, anchor: Anchor = exact,
                        similarTo: UUID? = nil, proposal: CommentRevision? = nil, includeInReport: Bool = true,
                        createdAt: Date = created) -> ReviewComment {
        ReviewComment(id: id, origin: origin, status: status, kind: kind, category: category, title: title, body: body,
                      suggestion: suggestion, anchor: anchor, proposedRevision: proposal, includeInReport: includeInReport,
                      similarTo: similarTo, createdAt: createdAt, updatedAt: createdAt)
    }

    static var exact: Anchor {
        Anchor(quote: "The effect is statistically significant", spans: [TextSpan(pageIndex: 0, range: TextRange(location: 230, length: 40))],
               pageIndex: 0, confidence: .exact, locationLabel: "p. 1, lines 13–14")
    }
    static var fuzzy: Anchor {
        Anchor(quote: "Our strategy uses the rollout", spans: [TextSpan(pageIndex: 0, range: TextRange(location: 90, length: 60))],
               pageIndex: 0, confidence: .fuzzy(score: 0.91), locationLabel: "p. 1, lines 5–7")
    }
    static var pageOnly: Anchor {
        Anchor(quote: "The standard errors are clustered.", pageIndex: 2, confidence: .pageOnly, locationLabel: "p. 3")
    }
    static var unanchored: Anchor {
        Anchor(quote: "Related work is discussed in Section 5.", confidence: .none, locationLabel: "")
    }
    static var noPassage: Anchor {
        Anchor(quote: "", confidence: .none, locationLabel: "")
    }

    static func inputs(selected: UUID? = nil, editing: UUID? = nil, thread: UUID? = nil, streaming: UUID? = nil,
                       failure: ReplyFailure? = nil, hasSelection: Bool = false, titles: [UUID: String] = [:]) -> SidebarCardInputs {
        SidebarCardInputs(selectedCommentID: selected, editingCommentID: editing, openThreadCommentID: thread, streamingTargetID: streaming,
                          replyFailure: failure, hasSelection: hasSelection, rubric: rubric, titles: titles)
    }
}

/// A review model on the fakes of TestSupport, opened on ay_round_nolinks with a stored session of the given comments.
@MainActor struct SidebarTestHarness {
    let model: ReviewSessionModel
    let paper: LoadedPaper

    static func open(comments: [ReviewComment], conversations: [Conversation] = [], report: ReportDraft? = nil,
                     engine: ScriptedReviewEngine = ScriptedReviewEngine(plan: SidebarTestData.plan)) async throws -> SidebarTestHarness {
        let paper = try makeSamplePaper()
        let store = InMemorySessionStore()
        try await store.save(ReviewSession(schemaVersion: 1, id: UUID(), document: paper.ref, meta: ManuscriptMeta(reviewerNotes: ""),
                                           comments: comments, conversations: conversations, report: report,
                                           createdAt: SidebarTestData.created, updatedAt: SidebarTestData.created))
        let dependencies = AppDependencies(paperService: FakePaperService(paper: paper), matcherFactory: { FakeQuoteMatcher(paper: $0) },
                                           citationIndexer: FakeCitationIndexer(), engine: engine, resolver: FakeResolver(),
                                           sessions: store, settings: InMemorySettingsStore(), providers: ProviderRegistry([MockLLMProvider()]),
                                           secrets: InMemorySecretStore())
        let model = ReviewSessionModel(dependencies: dependencies, settings: SnapshotSupport.settings())
        await model.open(url: Fixtures.url("pdf/ay_round_nolinks.pdf"))
        return SidebarTestHarness(model: model, paper: paper)
    }

    /// Lets the main actor run until the condition holds or ten seconds have passed.
    func wait(until condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while !condition(), clock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func state(of id: UUID, isExpanded: Bool = false, isHovered: Bool = false) -> SidebarCardState? {
        guard let comment = model.session?.comments.first(where: { $0.id == id }) else { return nil }
        return SidebarCardState.make(for: comment, inputs: SidebarCardInputs(model: model), isExpanded: isExpanded, isHovered: isHovered)
    }
}
