import SwiftUI
import RefereeCore
import AppCore

// The sidebar's scenes of the design review (docs/design-review.md, step 4): states of the Comments, Chat and Report
// tabs that the scenes of plan.md section 10.1 do not show. They stay in the repository as the verification scenes of
// the changes the review proposes (step 5). Each drives the model through its public API only.
//
// - design-triage-25: Fixtures/sessions/design-triage.json on ay_long.pdf, 25 comments in every state (12 pending,
//   9 approved, 4 rejected; a similar pair, a proposed revision, a long title, one page-only, one unanchored, one own,
//   one approved but left out of the report), the tenth in document order selected.
// - design-triage-done: the same session with every pending comment approved, nothing selected.
// - design-compose-from-selection: a passage selected in the PDF, then N: the new comment's card at the top.
// - design-reply-failed: a discussion whose reply failed, shown inline with Retry.
// - design-report-empty: the Report tab before any comment is approved.
// - design-chat-empty: the Chat tab before any question.

@MainActor enum SidebarDesignScenes {
    static var all: [SnapshotScene] {
        [triage, triageDone, composeFromSelection, replyFailed, reportEmpty, chatEmpty]
    }

    /// What design-triage.json holds; the triage scenes check these counts.
    static let triageComments = 25
    static let triagePending = 12

    // ---- design-triage-25 ----

    static var triage: SnapshotScene {
        SnapshotScene(name: "design-triage-25", kind: .review, fixturePDF: "ay_long.pdf", fixtureSession: "design-triage.json", prepare: { context in
            guard let model = context.model else { return }
            await SidebarSceneSupport.wait { model.session != nil }
            let visible = model.visibleComments
            guard visible.count > 9 else { return }
            model.selectedCommentID = visible[9].id
            model.revealSelectedCommentInPDF()
        }, verify: { context in
            guard let model = context.model else { return ["the scene has no model"] }
            var failures: [String] = []
            let comments = model.session?.comments ?? []
            if comments.count != triageComments { failures.append("expected \(triageComments) comments, found \(comments.count)") }
            let pending = comments.filter { $0.status == .pending }.count
            if pending != triagePending { failures.append("expected \(triagePending) pending comments, found \(pending)") }
            if model.selectedCommentID == nil { failures.append("expected a selected comment") }
            if !comments.contains(where: { $0.status == .approved && !$0.includeInReport }) {
                failures.append("no approved comment left out of the report")
            }
            let states = SidebarSceneSupport.cardStates(model)
            if !states.contains(where: { $0.layout == .collapsedSimilar }) { failures.append("no collapsed similar card") }
            if !states.contains(where: { $0.location == .notFound }) { failures.append("no unanchored card") }
            if !states.contains(where: { if case .pageOnly = $0.location { return true }; return false }) { failures.append("no page-only card") }
            return failures
        })
    }

    // ---- design-triage-done ----

    static var triageDone: SnapshotScene {
        SnapshotScene(name: "design-triage-done", kind: .review, fixturePDF: "ay_long.pdf", fixtureSession: "design-triage.json", prepare: { context in
            guard let model = context.model else { return }
            await SidebarSceneSupport.wait { model.session != nil }
            for comment in model.session?.comments ?? [] where comment.status == .pending {
                model.setStatus(.approved, for: comment.id)
            }
            model.selectedCommentID = nil
        }, verify: { context in
            guard let model = context.model else { return ["the scene has no model"] }
            let triage = model.triage
            var failures: [String] = []
            if triage.total != triageComments { failures.append("expected \(triageComments) comments, found \(triage.total)") }
            if triage.decided != triage.total { failures.append("\(triage.decided) of \(triage.total) decided, expected all") }
            return failures
        })
    }

    // ---- design-compose-from-selection ----

    static var composeFromSelection: SnapshotScene {
        SnapshotScene(name: "design-compose-from-selection", kind: .review, fixturePDF: "ay_nolinks.pdf", prepare: { context in
            guard let model = context.model,
                  let selection = SidebarSceneSupport.selection(of: SidebarScenes.chatPassage, onPage: 0, in: model) else { return }
            model.readerSelectionChanged(selection)
            await SidebarSceneSupport.wait { model.selection?.rects.isEmpty == false }
            model.beginComposingComment()
        }, verify: { context in
            guard let model = context.model else { return ["the scene has no model"] }
            var failures: [String] = []
            if model.composing?.selection?.text != SidebarScenes.chatPassage { failures.append("the new comment is not on the selected passage") }
            if model.sidebarTab != .comments { failures.append("expected the Comments tab") }
            return failures
        })
    }

    // ---- design-reply-failed ----

    /// The discussion of sample.json's comment A, through the snapshot graph's Ollama stand-in, which can only report a
    /// status: the message joins the thread and its reply fails at once.
    static var replyFailed: SnapshotScene {
        SnapshotScene(name: "design-reply-failed", kind: .review, fixturePDF: "ay_nolinks.pdf", fixtureSession: "sample.json", prepare: { context in
            guard let model = context.model else { return }
            var settings = model.settings
            settings.providers["ollama"] = ProviderSettings(enabled: true, model: "gemma4:e4b", inputMode: .auto)
            model.reloadSettings(settings)
            model.setActiveProvider(ProviderRef(providerID: "ollama", model: nil))
            await SidebarSceneSupport.wait { model.activeProvider?.id == "ollama" && model.sendPlan != nil }
            let id = SidebarSceneSupport.id(SidebarScenes.discussedComment)
            model.selectedCommentID = id
            model.openThreadCommentID = id
            model.sendDiscussionMessage("Is the interval also given in the text?", commentID: id)
            await SidebarSceneSupport.wait { model.replyFailure != nil }
        }, verify: { context in
            guard let model = context.model else { return ["the scene has no model"] }
            let id = SidebarSceneSupport.id(SidebarScenes.discussedComment)
            var failures: [String] = []
            if model.replyFailure?.targetID != id { failures.append("no failed reply on the discussed comment") }
            if model.openThreadCommentID != id { failures.append("expected the thread to be open") }
            return failures
        })
    }

    // ---- empty tabs ----

    static var reportEmpty: SnapshotScene {
        SnapshotScene(name: "design-report-empty", kind: .review, fixturePDF: "ay_round_nolinks.pdf", prepare: { context in
            context.model?.sidebarTab = .report
        }, verify: { context in
            guard let model = context.model else { return ["the scene has no model"] }
            var failures: [String] = []
            if model.sidebarTab != .report { failures.append("expected the Report tab") }
            if model.session?.report != nil { failures.append("expected no report") }
            return failures
        })
    }

    static var chatEmpty: SnapshotScene {
        SnapshotScene(name: "design-chat-empty", kind: .review, fixturePDF: "ay_round_nolinks.pdf", prepare: { context in
            context.model?.sidebarTab = .chat
        }, verify: { context in
            guard let model = context.model else { return ["the scene has no model"] }
            var failures: [String] = []
            if model.sidebarTab != .chat { failures.append("expected the Chat tab") }
            if model.session?.conversations.isEmpty != true { failures.append("expected no conversation") }
            return failures
        })
    }
}
