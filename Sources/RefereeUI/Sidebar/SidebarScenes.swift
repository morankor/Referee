import SwiftUI
import RefereeCore
import AppCore

// The sidebar's seven snapshot scenes (plan.md section 10.1). Each drives the model through its public API only and
// checks in `verify` that the model reached the state the picture is meant to show, so that a scene cannot pass with
// the wrong content. The pictures themselves are looked at by a person (WP10, docs/contract-notes/wp10-sidebar.md).
//
// - sidebar-pending, sidebar-streaming: a review by the mock providers on ay_round_nolinks.pdf (six comments; or two
//   comments and a third still being written, from "mock-stall").
// - sidebar-states: Fixtures/sessions/sidebar-states.json on ay_nolinks.pdf, five short invented comments that show
//   the six states: approved with a fuzzy anchor (as sample.json's own approved comment is), similar, rejected,
//   page-only, unanchored. sample.json has every state too, but its seven long cards do not fit in one window, and
//   six cards do not fit under the toolbar of the finished window (748 points).
// - sidebar-discussion, sidebar-editing, sidebar-report: Fixtures/sessions/sample.json on ay_nolinks.pdf.
// - sidebar-chat: a question about the abstract's last sentence of ay_nolinks.pdf, answered by the mock.

@MainActor public enum SidebarScenes {
    public static var all: [SnapshotScene] {
        [pending, streaming, states, discussion, editing, chat, report] + SidebarDesignScenes.all
    }

    /// sample.json: the comment with a two-message thread and a proposed revision.
    static let discussedComment = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    /// sample.json: the approved comment that comes first in the list.
    static let editedComment = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    /// ay_nolinks.pdf, page 1: the abstract's last sentence, on one line of the page.
    static let chatPassage = "The effect is statistically significant but economically small."
    static let chatQuestion = "Is this claim supported by the evidence in the paper?"

    // ---- sidebar-pending: six comments, one selected, mixed kinds ----

    static var pending: SnapshotScene {
        SnapshotScene(name: "sidebar-pending", kind: .review, fixturePDF: "ay_round_nolinks.pdf", prepare: { context in
            guard let model = context.model else { return }
            model.startReview()
            await SidebarSceneSupport.wait { model.runState == .idle && (model.session?.comments.count ?? 0) >= 6 }
            let visible = model.visibleComments
            guard visible.count > 1 else { return }
            model.selectedCommentID = visible[1].id
            model.revealSelectedCommentInPDF()
        }, verify: { context in
            guard let model = context.model else { return ["the scene has no model"] }
            let comments = model.session?.comments ?? []
            var failures: [String] = []
            if comments.count != 6 { failures.append("expected 6 comments, found \(comments.count)") }
            if comments.contains(where: { $0.status != .pending }) { failures.append("expected every comment to be pending") }
            if Set(comments.map(\.kind)).count < 3 { failures.append("expected at least three kinds of comment") }
            if model.selectedCommentID == nil { failures.append("expected a selected comment") }
            if model.sidebarTab != .comments { failures.append("expected the Comments tab") }
            return failures
        })
    }

    // ---- sidebar-streaming: two finished cards and one draft still being written ----

    static var streaming: SnapshotScene {
        SnapshotScene(name: "sidebar-streaming", kind: .review, fixturePDF: "ay_round_nolinks.pdf", prepare: { context in
            guard let model = context.model else { return }
            model.setActiveProvider(ProviderRef(providerID: "mock-stall", model: nil))
            await SidebarSceneSupport.wait { model.activeProvider?.id == "mock-stall" && model.canStartReview }
            model.startReview()
            await SidebarSceneSupport.wait {
                (model.session?.comments.count ?? 0) >= 2 && model.drafts.count == 1 && model.drafts.first?.quote != nil
            }
        }, verify: { context in
            guard let model = context.model else { return ["the scene has no model"] }
            var failures: [String] = []
            let comments = model.session?.comments.count ?? 0
            if comments != 2 { failures.append("expected 2 finished comments, found \(comments)") }
            if model.drafts.count != 1 { failures.append("expected 1 draft, found \(model.drafts.count)") }
            if case .idle = model.runState { failures.append("expected the review to be still running") }
            model.cancelRun()          // "mock-stall" would otherwise wait for an hour
            return failures
        })
    }

    // ---- sidebar-states: approved, rejected, similar, fuzzy, page-only and unanchored cards ----

    static var states: SnapshotScene {
        SnapshotScene(name: "sidebar-states", kind: .review, fixturePDF: "ay_nolinks.pdf", fixtureSession: "sidebar-states.json", prepare: { context in
            guard let model = context.model else { return }
            await SidebarSceneSupport.wait { model.session != nil }
        }, verify: { context in
            guard let model = context.model else { return ["the scene has no model"] }
            let states = SidebarSceneSupport.cardStates(model)
            var failures: [String] = []
            if states.count != 5 { failures.append("expected 5 cards, found \(states.count)") }
            if !states.contains(where: { $0.layout == .full && $0.bar == .approved }) { failures.append("no approved card") }
            if !states.contains(where: { $0.layout == .collapsedRejected }) { failures.append("no rejected card") }
            if !states.contains(where: { $0.layout == .collapsedSimilar }) { failures.append("no collapsed similar card") }
            if !states.contains(where: { if case .fuzzy = $0.location { return $0.layout == .full }; return false }) {
                failures.append("no card with a fuzzy anchor")
            }
            if !states.contains(where: { if case .pageOnly = $0.location { return $0.layout == .full }; return false }) {
                failures.append("no card with a page-only anchor")
            }
            if !states.contains(where: { $0.location == .notFound && $0.layout == .full }) { failures.append("no unanchored card") }
            return failures
        })
    }

    // ---- sidebar-discussion: an open thread with two messages and a proposed revision ----

    static var discussion: SnapshotScene {
        SnapshotScene(name: "sidebar-discussion", kind: .review, fixturePDF: "ay_nolinks.pdf", fixtureSession: "sample.json", prepare: { context in
            guard let model = context.model else { return }
            let id = SidebarSceneSupport.id(discussedComment)
            model.selectedCommentID = id
            model.openThreadCommentID = id
        }, verify: { context in
            guard let model = context.model else { return ["the scene has no model"] }
            let id = SidebarSceneSupport.id(discussedComment)
            guard let comment = model.session?.comments.first(where: { $0.id == id }) else { return ["the discussed comment is missing"] }
            var failures: [String] = []
            if comment.thread.count != 2 { failures.append("expected 2 messages in the thread, found \(comment.thread.count)") }
            if comment.proposedRevision == nil { failures.append("expected a proposed revision") }
            if model.openThreadCommentID != id { failures.append("expected the thread to be open") }
            return failures
        })
    }

    // ---- sidebar-editing: a card in edit mode ----

    static var editing: SnapshotScene {
        SnapshotScene(name: "sidebar-editing", kind: .review, fixturePDF: "ay_nolinks.pdf", fixtureSession: "sample.json", prepare: { context in
            guard let model = context.model else { return }
            let id = SidebarSceneSupport.id(editedComment)
            model.selectedCommentID = id
            model.editingCommentID = id
        }, verify: { context in
            guard let model = context.model else { return ["the scene has no model"] }
            let id = SidebarSceneSupport.id(editedComment)
            var failures: [String] = []
            if model.session?.comments.contains(where: { $0.id == id }) != true { failures.append("the edited comment is missing") }
            if model.editingCommentID != id { failures.append("expected the comment to be in edit mode") }
            return failures
        })
    }

    // ---- sidebar-chat: the Chat tab with one conversation ----

    static var chat: SnapshotScene {
        SnapshotScene(name: "sidebar-chat", kind: .review, fixturePDF: "ay_nolinks.pdf", prepare: { context in
            guard let model = context.model,
                  let selection = SidebarSceneSupport.selection(of: chatPassage, onPage: 0, in: model) else { return }
            model.readerSelectionChanged(selection)
            await SidebarSceneSupport.wait { model.selection?.rects.isEmpty == false }
            model.ask(chatQuestion, about: model.selection, in: nil)
            await SidebarSceneSupport.wait {
                model.streamingTargetID == nil && model.session?.conversations.first?.messages.count == 2
            }
        }, verify: { context in
            guard let model = context.model else { return ["the scene has no model"] }
            let conversations = model.session?.conversations ?? []
            var failures: [String] = []
            if conversations.count != 1 { failures.append("expected 1 conversation, found \(conversations.count)") }
            if let conversation = conversations.first {
                if conversation.messages.count != 2 { failures.append("expected a question and an answer, found \(conversation.messages.count) messages") }
                if conversation.anchor?.quote != chatPassage { failures.append("expected the conversation to quote the abstract's sentence") }
            }
            if model.sidebarTab != .chat { failures.append("expected the Chat tab") }
            return failures
        })
    }

    // ---- sidebar-report: the Report tab with generated text and three lint findings ----

    static var report: SnapshotScene {
        SnapshotScene(name: "sidebar-report", kind: .review, fixturePDF: "ay_nolinks.pdf", fixtureSession: "sample.json", prepare: { context in
            guard let model = context.model else { return }
            model.sidebarTab = .report
            model.generateReport()
            await SidebarSceneSupport.wait {
                model.runState == .idle && model.session?.report != nil && model.lintFindings.count >= 3
            }
        }, verify: { context in
            guard let model = context.model else { return ["the scene has no model"] }
            var failures: [String] = []
            if (model.session?.report?.markdown ?? "").isEmpty { failures.append("expected a generated report") }
            if model.lintFindings.count != 3 { failures.append("expected 3 lint findings, found \(model.lintFindings.count)") }
            if model.sidebarTab != .report { failures.append("expected the Report tab") }
            return failures
        })
    }
}
