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
// - design-report-streaming (step 5): the report half written, from the snapshot registry's slow stand-in `mock-slow`
//   (step 5a, O3), on sample.json.
// - design-two-models (step 5b, the user's requirement): Fixtures/sessions/design-sidebar-two-models.json on
//   ay_nolinks.pdf, the comments of two reviews, Claude Code asked for "sonnet" (which reported "claude-sonnet-4-6",
//   step 5c) and Codex with its default model (Codex reports none), interleaved in paper order, one of each run on the
//   same passage folded as similar, and one comment of the referee's own.
// - design-report-conference (step 5, G.9): Fixtures/sessions/design-sidebar-conference.json on ay_nolinks.pdf, a paper
//   reviewed for EC with its report: the recommendation on the venue's scale ("Weak reject"), "Chance of acceptance".
//
// Step 5 extended the checks with what the review's items make checkable: one card in full (D1), the Kind menu's items
// (D11), "All 25 decided" (D6), the cursor in the comment (D2), the proposal before the failed reply (D18), and the room
// the report editor gets while it streams (D8).

@MainActor enum SidebarDesignScenes {
    static var all: [SnapshotScene] {
        [triage, triageDone, composeFromSelection, replyFailed, reportEmpty, chatEmpty, reportStreaming, twoModels, reportConference]
    }

    /// What design-triage.json holds; the triage scenes check these counts.
    static let triageComments = 25
    static let triagePending = 12
    /// The Kind menu's items for design-triage.json (D11).
    static let triageKindItems = ["Major (7)", "Minor (11)", "Questions (5)", "Strengths (2)"]

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
            // D1: the selected card alone in full; every card that is not collapsed is compact.
            let full = states.filter { $0.layout == .full }
            if full.count != 1 || full.first?.isSelected != true { failures.append("expected the selected card alone in full, found \(full.count) full cards") }
            if states.filter({ $0.layout == .compact }).count < 3 { failures.append("expected compact cards around the selected one") }
            // D11: four status chips, then the Kind menu with Strengths.
            let chips = SidebarFilterChip.chips(for: comments).map(\.title)
            if chips != ["All", "Pending", "Approved", "Rejected"] { failures.append("the chips are \(chips)") }
            let kinds = SidebarFilterChip.kindItems(for: comments).map(\.menuTitle)
            if kinds != triageKindItems { failures.append("the Kind menu lists \(kinds), expected \(triageKindItems)") }
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
            // D6: the progress row says so and leads to the report.
            if !SidebarFilterChip.isAllDecided(decided: triage.decided, total: triage.total) { failures.append("the progress row does not show \"All decided\"") }
            let text = SidebarFilterChip.allDecidedText(total: triage.total)
            if text != "All 25 decided" { failures.append("the progress row reads \"\(text)\"") }
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
            // D2: N puts the cursor in the comment, which is still empty.
            if let problem = SidebarSceneSupport.keyboardProblem(in: context.window, expectedText: "") { failures.append(problem) }
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
            // D18: the proposal waits in the thread, above the failed reply and the reply field.
            let state = SidebarSceneSupport.cardStates(model).first { $0.isThreadOpen }
            if state?.proposal == nil { failures.append("expected the proposed revision in the open thread") }
            if state?.layout != .full { failures.append("expected the discussed card in full") }
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
            // D8: with nothing approved the tab offers Show Pending Comments.
            if !SidebarReportFacts.reportComments(model.session?.comments ?? []).isEmpty { failures.append("expected no approved comment") }
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

    // ---- design-report-conference (step 5, G.9) ----

    /// A paper reviewed for EC, a conference, with its report: "Venue and notes · EC" folded, the picker on the venue's
    /// scale reading "Weak reject", no journal recommendation, "Chance of acceptance" in the text, nothing for the style
    /// check to flag (the report has the conference template's six headings and a label that agrees with its concern).
    static var reportConference: SnapshotScene {
        SnapshotScene(name: "design-report-conference", kind: .review, fixturePDF: "ay_nolinks.pdf",
                      fixtureSession: "design-sidebar-conference.json", prepare: { context in
            guard let model = context.model else { return }
            model.sidebarTab = .report
            await SidebarSceneSupport.wait { model.session?.report != nil && model.currentVenue.id == "ec" }
        }, verify: { context in
            guard let model = context.model else { return ["the scene has no model"] }
            var failures: [String] = []
            if model.sidebarTab != .report { failures.append("expected the Report tab") }
            if model.currentVenue.id != "ec" { failures.append("the paper is on \(model.currentVenue.id), expected EC") }
            if model.recommendationScale != DefaultSettings.conferenceScale { failures.append("the scale is \(model.recommendationScale)") }
            if model.recommendationLabel != "Weak reject" { failures.append("the picker reads \(model.recommendationLabel ?? "Not set")") }
            guard let report = model.session?.report else { return failures + ["expected the fixture's report"] }
            if report.recommendation != nil { failures.append("a conference's report has a journal recommendation") }
            if !model.lintFindings.isEmpty { failures.append("the style check flags \(model.lintFindings.map(\.rule))") }
            if SidebarReportFacts.recommendationMismatch(label: model.recommendationLabel, venue: model.currentVenue, markdown: report.markdown) {
                failures.append("the picker's label disagrees with the concerns")
            }
            // The confidential copy holds "Chance of acceptance", the authors' copy does not.
            if !SidebarReportFacts.editorMarkdown(report.markdown).contains("## Chance of acceptance") { failures.append("the committee's copy lacks the chance") }
            if SidebarReportFacts.authorsMarkdown(report.markdown).contains("Chance of acceptance") { failures.append("the authors' copy holds the chance") }
            if SidebarReportFacts.venueShortName(model.currentVenue) != "EC" { failures.append("the folded group names \(SidebarReportFacts.venueShortName(model.currentVenue))") }
            if let problem = SidebarSceneSupport.reportEditorProblem(in: context.window) { failures.append(problem) }
            return failures
        })
    }

    // ---- design-report-streaming (step 5) ----

    /// sample.json's approved comments, the report written by `mock-slow` (40 ms a delta, about 6.5 s in all): the
    /// picture comes about two seconds in, the editor read-only with the text so far, "Writing the report…" and Stop.
    static var reportStreaming: SnapshotScene {
        SnapshotScene(name: "design-report-streaming", kind: .review, fixturePDF: "ay_nolinks.pdf", fixtureSession: "sample.json", prepare: { context in
            guard let model = context.model else { return }
            await SidebarSceneSupport.choose("mock-slow", model: "mock", in: model)
            model.sidebarTab = .report
            model.generateReport()
            await SidebarSceneSupport.wait { !model.streamingReportText.isEmpty }
        }, verify: { context in
            guard let model = context.model else { return ["the scene has no model"] }
            var failures: [String] = []
            if model.reportProvider?.id != "mock-slow" { failures.append("the report goes to \(model.reportProvider?.id ?? "no provider"), expected mock-slow") }
            if case .running(.report, _, _) = model.runState {} else { failures.append("expected the report to be still being written") }
            if model.streamingReportText.isEmpty { failures.append("no report text has arrived") }
            if model.session?.report != nil { failures.append("expected no finished report yet") }
            if model.sidebarTab != .report { failures.append("expected the Report tab") }
            // The text arrives in the report editor, read-only.
            if let height = SidebarSceneSupport.reportEditorHeight(in: context.window) {
                if height < 100 { failures.append("the streaming editor is \(Int(height)) points high") }
            } else {
                failures.append("the streaming editor is not in the window")
            }
            model.cancelRun()          // the rest of the stream is not needed
            return failures
        })
    }

    // ---- design-two-models (step 5b) ----

    /// The labels design-sidebar-two-models.json's runs must give their comments: the model Claude Code reported wins over
    /// the "sonnet" asked for (step 5c); Codex reports none and was asked for none.
    static let twoModelsLabels: [ProviderID: String] = ["claude-cli": "Claude Code · claude-sonnet-4-6", "codex-cli": "Codex · default model"]

    /// Both CLIs stay switched off, as after a review with each: their names come from their descriptors among the
    /// registered providers (`registeredProviders`, step 5c). Claude Code's model list is what Settings ▸ Providers keeps
    /// once it has listed the CLI's models (its documented aliases): "sonnet" would read "Sonnet", but the run's reported
    /// model, which that list does not have, is shown by its id; Codex's review asked for no model.
    static var twoModels: SnapshotScene {
        SnapshotScene(name: "design-two-models", kind: .review, fixturePDF: "ay_nolinks.pdf", fixtureSession: "design-sidebar-two-models.json",
                      prepare: { context in
            guard let model = context.model else { return }
            await SidebarSceneSupport.wait { model.session != nil }
            var settings = model.settings
            var claude = settings.providers["claude-cli"] ?? ProviderSettings(enabled: false, inputMode: .auto)
            claude.cachedModels = [("default", "Default"), ("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")]
                .map { ModelInfo(id: $0.0, displayName: $0.1) }
            settings.providers["claude-cli"] = claude
            model.reloadSettings(settings)
            model.selectedCommentID = nil
        }, verify: { context in
            guard let model = context.model else { return ["the scene has no model"] }
            var failures: [String] = []
            let comments = model.session?.comments ?? []
            let runs = model.session?.runs ?? []
            if comments.count != 7 { failures.append("expected 7 comments, found \(comments.count)") }
            if Set(runs.map(\.provider.providerID)) != ["claude-cli", "codex-cli"] { failures.append("expected a review by each CLI") }
            if model.selectableProviders.contains(where: { $0.id == "claude-cli" || $0.id == "codex-cli" }) {
                failures.append("expected both CLIs to be switched off")
            }
            // Every AI card names the provider and model of its run; the referee's own card names none.
            let inputs = SidebarCardInputs(model: model)
            for comment in model.visibleComments {
                let state = SidebarCardState.make(for: comment, inputs: inputs)
                guard case .ai(let runID) = comment.origin else {
                    if state.source != nil { failures.append("the own comment \"\(comment.title)\" names a model") }
                    continue
                }
                let providerID = runs.first { $0.id == runID }?.provider.providerID
                let expected = providerID.flatMap { twoModelsLabels[$0] }
                if state.source?.providerID != providerID || state.source?.text != expected {
                    failures.append("\"\(comment.title)\" reads \"\(state.source?.text ?? "no label")\", expected \"\(expected ?? "?")\"")
                }
            }
            // The two runs' comments are interleaved in the paper's order, and the folded card names both models.
            let order = model.visibleComments.compactMap { inputs.sources[$0.id]?.providerID }
            if order != ["claude-cli", "codex-cli", "codex-cli", "claude-cli", "claude-cli", "codex-cli"] {
                failures.append("the cards come from \(order) in paper order")
            }
            let similar = SidebarSceneSupport.cardStates(model).filter { $0.layout == .collapsedSimilar }
            if similar.count != 1 || similar.first?.source?.providerID != "codex-cli" || similar.first?.similarToSource?.providerID != "claude-cli" {
                failures.append("expected one folded card by Codex, similar to one by Claude Code")
            }
            return failures
        })
    }
}
