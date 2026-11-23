import AppKit
import SwiftUI
import Testing
import RefereeCore
import AppCore
import TestSupport
@testable import RefereeUI

/// No pane declares a minimum size (plan.md section 9.2): each tab of the sidebar, with content, must fit the
/// inspector's narrowest width of 320 points and the height left under the toolbar of the smallest window (640 points
/// less about 52), or the window would grow. SwiftUI reports the smallest size a view accepts when it is offered none,
/// and the window's minimum height is measured that way, at a width of zero: a text that keeps its full height
/// (`.fixedSize(horizontal: false, vertical: true)`) outside a scroll view stands one word per line there. That made
/// the empty Chat tab ask for 628 points and the window grow in the snapshot at 1000 × 640.
@Suite struct SidebarHostingTests {
    typealias Sample = SidebarTestData

    /// The tallest minimum the sidebar may have: 640 points of window, less the toolbar, less a margin.
    static let tallestMinimum: CGFloat = 540

    @MainActor private func narrowestWidth(of model: ReviewSessionModel) -> CGFloat {
        let controller = NSHostingController(rootView: ReviewSidebar(model: model))
        return controller.sizeThatFits(in: CGSize(width: 0, height: 748)).width
    }

    @MainActor private func smallestHeight(of model: ReviewSessionModel) -> CGFloat {
        NSHostingController(rootView: ReviewSidebar(model: model)).sizeThatFits(in: .zero).height
    }

    @Test @MainActor func everyTabFitsUnderTheToolbarOfTheSmallestWindow() async throws {
        let empty = try await SidebarTestHarness.open(comments: [])
        for tab in SidebarTab.allCases {
            empty.model.sidebarTab = tab
            let height = smallestHeight(of: empty.model)
            #expect(height <= Self.tallestMinimum, "the empty \(tab.rawValue) tab needs \(height) points")
        }

        let long = String(repeating: "A long sentence that has to wrap. ", count: 10)
        let answer = ThreadMessage(id: UUID(), role: .assistant, text: long, createdAt: Sample.created)
        let conversation = Conversation(id: UUID(), anchor: Sample.exact, messages: [answer], createdAt: Sample.created)
        let report = ReportDraft(markdown: "## Summary assessment\n\n" + long, recommendation: .majorRevision, userEdited: true)   // mismatch shown
        let findings = (1...6).map { LintFinding(id: $0, range: TextRange(location: 0, length: 7), rule: "missing-section", message: long) }
        let full = try await SidebarTestHarness.open(comments: [Sample.comment(body: long)], conversations: [conversation], report: report,
                                                     engine: ScriptedReviewEngine(plan: Sample.plan, lint: findings))
        for tab in SidebarTab.allCases {
            full.model.sidebarTab = tab
            let height = smallestHeight(of: full.model)
            #expect(height <= Self.tallestMinimum, "the \(tab.rawValue) tab with content needs \(height) points")
        }
    }

    @Test @MainActor func everyTabFitsTheInspectorsNarrowestWidth() async throws {
        let long = String(repeating: "A long sentence that has to wrap inside the card. ", count: 12)
        // Every card names a provider and a long model (step 5b), in every form: full, compact with its facts, similar,
        // rejected.
        let run = Sample.run("antigravity-cli", model: "example-extended-context-preview-with-a-very-long-name")
        let ai = CommentOrigin.ai(runID: run.id)
        let message = ThreadMessage(id: UUID(), role: .assistant, text: long, createdAt: Sample.created,
                                    provider: ProviderRef(providerID: "antigravity-cli", model: "example-extended-context-preview-with-a-very-long-name"))
        let other = Sample.comment(origin: ai, title: "The other comment", body: long, suggestion: long, thread: [message])
        let comments = [
            other,
            Sample.comment(origin: ai, status: .approved, kind: .minor, category: "assumptions", title: long, body: long, suggestion: long),
            Sample.comment(origin: ai, kind: .major, title: "Similar", similarTo: other.id),
            Sample.comment(origin: ai, status: .rejected, kind: .strength, title: long),
            Sample.comment(origin: ai, kind: .question, category: "literature", anchor: Sample.unanchored),
            Sample.comment(origin: ai, kind: .minor, anchor: Sample.pageOnly, thread: [message],
                           proposal: CommentRevision(kind: .minor, title: long, body: long, withdraw: false)),
        ]
        let answer = ThreadMessage(id: UUID(), role: .assistant, text: long, createdAt: Sample.created, provider: message.provider)
        let question = ThreadMessage(id: UUID(), role: .user, text: "Is this claim supported by the evidence in the paper?", createdAt: Sample.created)
        let conversation = Conversation(id: UUID(), anchor: Sample.exact, messages: [question, answer], createdAt: Sample.created)
        let report = ReportDraft(markdown: "## Summary assessment\n\n" + long + "\n\n## Major concerns\n\n1. " + long, recommendation: .accept,
                                 userEdited: true)
        let findings = [LintFinding(id: 1, range: TextRange(location: 0, length: 7), rule: "missing-section",
                                    message: "Section 'Recommendation' is missing.")]
        let engine = ScriptedReviewEngine(plan: SidebarTestData.plan, lint: findings)
        let harness = try await SidebarTestHarness.open(comments: comments, conversations: [conversation], report: report, runs: [run],
                                                        engine: engine)
        let model = harness.model
        #expect(SidebarCardInputs(model: model).sources.count == comments.count)
        model.openThreadCommentID = other.id

        for tab in SidebarTab.allCases {
            model.sidebarTab = tab
            let width = narrowestWidth(of: model)
            #expect(width <= 320, "the \(tab.rawValue) tab needs \(width) points")
        }
        model.sidebarTab = .comments
        model.openThreadCommentID = nil                                      // every card but the selected one compact
        let compact = narrowestWidth(of: model)
        #expect(compact <= 320, "the compact cards need \(compact) points")
        model.editingCommentID = other.id
        model.beginComposingComment()
        let editing = narrowestWidth(of: model)
        #expect(editing <= 320, "the editors need \(editing) points")
    }

    @Test @MainActor func theSidebarWithoutADocumentFitsToo() throws {
        let paper = try makeSamplePaper()
        let dependencies = AppDependencies(paperService: FakePaperService(paper: paper),
                                           matcherFactory: { FakeQuoteMatcher(paper: $0) }, citationIndexer: FakeCitationIndexer(),
                                           engine: ScriptedReviewEngine(plan: SidebarTestData.plan), resolver: FakeResolver(),
                                           sessions: InMemorySessionStore(), settings: InMemorySettingsStore(),
                                           providers: ProviderRegistry([]), secrets: InMemorySecretStore())
        let model = ReviewSessionModel(dependencies: dependencies, settings: DefaultSettings.make())
        #expect(narrowestWidth(of: model) <= 320)
    }
}
