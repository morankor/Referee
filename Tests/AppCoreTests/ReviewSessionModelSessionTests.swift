import Foundation
import Testing
import RefereeCore
@testable import AppCore
import TestSupport

/// Acceptance rows "citations", "delete" and "autosave" (plan.md section 11.4, WP8b; sections 4.5, 8.6), and the
/// question threads of section 6.9.
@Suite struct ReviewSessionModelSessionTests {
    static let entries = [
        BibEntry(id: 0, rawText: "Acemoglu, D., Dahleh, M. A., Lobel, I., and Ozdaglar, A. (2011). Bayesian learning in social networks.",
                 parsed: ParsedReference(authorSurnames: ["Acemoglu", "Dahleh", "Lobel", "Ozdaglar"], year: 2011)),
        BibEntry(id: 1, rawText: "Acemoglu, D. and Ozdaglar, A. (2011). Opinion dynamics and learning in social networks.",
                 parsed: ParsedReference(authorSurnames: ["Acemoglu", "Ozdaglar"], year: 2011)),
        BibEntry(id: 2, rawText: "Lee, J. (2021). Observational learning with heterogeneous priors.",
                 parsed: ParsedReference(authorSurnames: ["Lee"], year: 2021)),
    ]
    static let index = CitationIndex(style: .authorYear, entries: entries, mentions: [
        CitationMention(id: 0, pageIndex: 0, text: "Acemoglu et al. (2011)", rects: [PageRect(pageIndex: 0, x: 120, y: 500, width: 90, height: 10)],
                        entryIDs: [0, 1], source: .linkAnnotation),
        CitationMention(id: 1, pageIndex: 1, text: "unknown (1999)", rects: [PageRect(pageIndex: 1, x: 120, y: 500, width: 90, height: 10)],
                        entryIDs: [], source: .textPattern),
    ])

    // ---- citations ----

    @Test @MainActor func lookingUpAMentionResolvesEveryCandidate() async throws {
        let harness = try await makeModelHarness(index: Self.index)
        await harness.open()
        let model = harness.model
        model.lookUpCitation(mentionID: 0)
        #expect(model.citationLookup == .resolving(target: .mention(0)))
        await model.waitForBackgroundWork()
        guard case .resolved(let target, let entries, let references) = model.citationLookup else {
            Issue.record("not resolved: \(model.citationLookup)")
            return
        }
        #expect(target == .mention(0))
        #expect(entries == [Self.entries[0], Self.entries[1]])
        #expect(references.map(\.entryID) == [0, 1])
        #expect(references.allSatisfy { $0.status == .resolved })
        #expect(references.first?.title == "Resolved: " + String(Self.entries[0].rawText.prefix(30)))
    }

    @Test @MainActor func lookingUpAnEntryResolvesThatEntry() async throws {
        let harness = try await makeModelHarness(index: Self.index)
        await harness.open()
        harness.model.lookUpEntry(entryID: 2)
        #expect(harness.model.citationLookup == .resolving(target: .entry(2)))
        await harness.model.waitForBackgroundWork()
        let expected = await harness.resolver.resolve(Self.entries[2], documentSHA256: harness.paper.ref.sha256)
        #expect(harness.model.citationLookup == .resolved(target: .entry(2), entries: [Self.entries[2]], references: [expected]))
    }

    @Test @MainActor func aClickInThePDFLooksTheMentionUp() async throws {
        let harness = try await makeModelHarness(index: Self.index)
        await harness.open()
        harness.model.readerClickedCitation(mentionID: 1)                // a mention without candidates
        await harness.model.waitForBackgroundWork()
        #expect(harness.model.citationLookup == .resolved(target: .mention(1), entries: [], references: []))
        harness.model.readerClickedCitation(mentionID: 99)               // no such mention: nothing changes
        #expect(harness.model.citationLookup == .resolved(target: .mention(1), entries: [], references: []))
        harness.model.lookUpCitation(mentionID: 0)
        harness.model.lookUpEntry(entryID: 2)                            // the later lookup wins
        await harness.model.waitForBackgroundWork()
        if case .resolved(target: .entry(2), _, _) = harness.model.citationLookup {} else {
            Issue.record("the later lookup did not win: \(harness.model.citationLookup)")
        }
    }

    @Test @MainActor func theReferencePDFComesFromTheResolver() async throws {
        let harness = try await makeModelHarness(index: Self.index)
        await harness.open()
        let reference = await harness.resolver.resolve(Self.entries[2], documentSHA256: harness.paper.ref.sha256)
        let file = try await harness.model.fetchReferencePDF(reference)
        #expect(file.lastPathComponent == "num_twocol_links.pdf")
    }

    // ---- delete ----

    @Test @MainActor func deletingReviewDataRemovesTheSessionAndTheLookupCache() async throws {
        let paper = try makeSamplePaper()
        let harness = try await makeModelHarness(paper: paper, seed: ModelSample.session(for: paper, comments: [ModelSample.comment("Gone", page: nil)]))
        await harness.open()
        harness.model.updateMeta(ManuscriptMeta(title: "Unsaved change", reviewerNotes: ""))   // pending: must not be written afterwards
        #expect(try await harness.store.loadSession(sha256: paper.ref.sha256) != nil)
        await harness.model.deleteReviewData()
        #expect(try await harness.store.loadSession(sha256: paper.ref.sha256) == nil)
        #expect(harness.resolver.forgottenDocuments == [paper.ref.sha256])
        #expect(harness.model.phase == .empty)
        #expect(harness.model.session == nil)
        let saves = harness.store.saveCount
        harness.clock.advance(by: 5)
        try await Task.sleep(for: .milliseconds(20))
        #expect(harness.store.saveCount == saves)
        #expect(try await harness.store.loadSession(sha256: paper.ref.sha256) == nil)
    }

    @Test @MainActor func deletingCancelsARunningJob() async throws {
        let paper = try makeSamplePaper()
        let review: [ReviewEvent] = [.started(ModelSample.run(.review, .running)), .comment(ModelSample.comment("Late", page: nil), replacesDraft: UUID()),
                                     .finished(ModelSample.run(.review, .completed))]
        let harness = try await makeModelHarness(paper: paper, engine: ScriptedReviewEngine(plan: ModelSample.localPlan, review: review, delayPerEvent: .seconds(1)))
        await harness.open()
        harness.model.startReview()
        #expect(await waitForModel { harness.calls(of: "review") == 1 })
        await harness.model.deleteReviewData()
        #expect(harness.model.runState == .idle)
        #expect(harness.model.reviewLaneTask == nil)
        #expect(try await harness.store.loadSession(sha256: paper.ref.sha256) == nil)
        #expect(harness.resolver.forgottenDocuments == [paper.ref.sha256])
    }

    // ---- autosave ----

    @Test @MainActor func severalChangesWithinTheDebounceGiveOneSave() async throws {
        let paper = try makeSamplePaper()
        let comment = ModelSample.comment("Edited", page: nil)
        let harness = try await makeModelHarness(paper: paper, seed: ModelSample.session(for: paper, comments: [comment]))
        await harness.open()
        await harness.model.flushPendingSave()                           // the new file path, written once
        let start = harness.store.saveCount
        let model = harness.model

        model.setKind(.major, for: comment.id)
        harness.clock.advance(by: 0.6)
        model.updateMeta(ManuscriptMeta(title: "Retitled", reviewerNotes: "Notes"))
        harness.clock.advance(by: 0.6)
        model.setIncludeInReport(false, for: comment.id)
        harness.clock.advance(by: 0.6)                                   // 0.6 s after the last change: not yet
        await Task.yield()
        #expect(harness.store.saveCount == start)
        #expect(model.session?.updatedAt == harness.clock.now().addingTimeInterval(-0.6))   // every change bumps updatedAt

        let pending = model.autosaveTask
        harness.clock.advance(by: 0.5)                                   // 1.1 s after the last change
        await pending?.value
        #expect(harness.store.saveCount == start + 1)
        let saved = try #require(try await harness.store.loadSession(sha256: paper.ref.sha256))
        #expect(saved == model.session)
        #expect(saved.meta.title == "Retitled")
        #expect(saved.comments.first?.kind == .major)
        #expect(saved.comments.first?.includeInReport == false)
    }

    @Test @MainActor func flushSavesAtOnce() async throws {
        let harness = try await makeModelHarness()
        await harness.open()
        await harness.model.flushPendingSave()
        let start = harness.store.saveCount
        harness.model.updateMeta(ManuscriptMeta(title: "Now", reviewerNotes: ""))
        await harness.model.flushPendingSave()
        #expect(harness.store.saveCount == start + 1)
        #expect(try await harness.store.loadSession(sha256: harness.paper.ref.sha256)?.meta.title == "Now")
        await harness.model.flushPendingSave()                           // nothing pending: no save
        harness.clock.advance(by: 2)
        try await Task.sleep(for: .milliseconds(20))
        #expect(harness.store.saveCount == start + 1)
    }

    @Test @MainActor func aChangeThatChangesNothingIsNotSaved() async throws {
        let harness = try await makeModelHarness()
        await harness.open()
        await harness.model.flushPendingSave()
        let start = harness.store.saveCount
        let before = harness.model.session
        harness.model.updateMeta(try #require(before?.meta))
        harness.model.setRecommendation(.accept)                          // there is no report: nothing to set
        await harness.model.flushPendingSave()
        #expect(harness.store.saveCount == start)
        #expect(harness.model.session == before)
    }

    // ---- questions ----

    @Test @MainActor func aQuestionAboutASelectionStartsAnAnchoredConversation() async throws {
        let paper = SyntheticPaper.lineNumbered
        let answer = ThreadMessage(id: UUID(), role: .assistant, text: "The interval crosses one, so the effect is not robust.", createdAt: ModelSample.start)
        let replies: [ReplyEvent] = [.started(ModelSample.run(.question, .running)), .textDelta("The interval"),
                                     .finished(reply: answer, proposal: nil, run: ModelSample.run(.question, .completed))]
        let harness = try await makeModelHarness(paper: paper, engine: ScriptedReviewEngine(plan: ModelSample.localPlan, reply: replies))
        await harness.open()
        let model = harness.model
        model.readerSelectionChanged(SelectionNormalizerTests.twoLineRawSelection)
        await model.waitForBackgroundWork()
        model.ask("Is this supported?", about: model.selection, in: nil)
        #expect(model.sidebarTab == .chat)
        await harness.finishJobs()
        let conversation = try #require(model.session?.conversations.first)
        #expect(conversation.anchor?.quote == "As shown by Acemoglu et al. [2011], network structure determines wheth")
        #expect(conversation.anchor?.confidence == .exact)
        #expect(conversation.anchor?.rects.count == 2)
        #expect(conversation.anchor?.locationLabel == "p. 1")
        #expect(conversation.messages.map(\.role) == [.user, .assistant])
        #expect(conversation.messages.first?.text == "Is this supported?")
        #expect(harness.calls(of: "ask") == 1)
        #expect(model.session?.runs.last?.kind == .question)

        // A follow-up stays in the same conversation; a general question starts one without an anchor.
        model.ask("And the table?", about: nil, in: conversation.id)
        await harness.finishJobs()
        #expect(model.session?.conversations.count == 1)
        #expect(model.session?.conversations.first?.messages.count == 4)
        model.ask("What is the paper's main claim?", about: nil, in: nil)
        await harness.finishJobs()
        #expect(model.session?.conversations.count == 2)
        #expect(model.session?.conversations.last?.anchor == nil)

        // An answer becomes a pending own comment on the same passage.
        model.convertReplyToComment(conversationID: conversation.id, messageID: answer.id, kind: .major)
        let converted = try #require(model.session?.comments.last)
        #expect(converted.origin == .user)
        #expect(converted.status == .pending)
        #expect(converted.kind == .major)
        #expect(converted.category == "other")
        #expect(converted.body == answer.text)
        #expect(converted.title == "The interval crosses one, so the effect is not robust.")
        #expect(converted.anchor == model.session?.conversations.first?.anchor)

        model.deleteConversation(conversation.id)
        #expect(model.session?.conversations.count == 1)
    }

    @Test @MainActor func aQuestionCanBeStoppedAndRetried() async throws {
        let answer = ThreadMessage(id: UUID(), role: .assistant, text: "Slow answer.", createdAt: ModelSample.start)
        let replies: [ReplyEvent] = [.started(ModelSample.run(.question, .running)), .textDelta("Slow"),
                                     .finished(reply: answer, proposal: nil, run: ModelSample.run(.question, .completed))]
        let harness = try await makeModelHarness(engine: ScriptedReviewEngine(plan: ModelSample.localPlan, reply: replies, delayPerEvent: .milliseconds(300)))
        await harness.open()
        let model = harness.model
        model.ask("What is the main claim?", about: nil, in: nil)
        #expect(await waitForModel { model.streamingReplyText == "Slow" })
        let conversation = try #require(model.session?.conversations.first)
        #expect(model.streamingTargetID == conversation.id)
        model.cancelReply()
        await harness.finishJobs()
        #expect(model.streamingTargetID == nil)
        #expect(model.session?.conversations.first?.messages.map(\.role) == [.user])
        #expect(model.session?.runs.last?.status == .cancelled)
        #expect(model.banner == nil)

        // Deleting the conversation while its answer streams stops the answer.
        model.ask("Again?", about: nil, in: conversation.id)
        #expect(await waitForModel { model.streamingTargetID == conversation.id })
        model.deleteConversation(conversation.id)
        await harness.finishJobs()
        #expect(model.session?.conversations.isEmpty == true)
        #expect(model.streamingTargetID == nil)
    }

    @Test @MainActor func aConversationsPassageCanBeRevealed() async throws {
        let paper = SyntheticPaper.lineNumbered
        let harness = try await makeModelHarness(paper: paper, engine: ScriptedReviewEngine(plan: ModelSample.localPlan))
        await harness.open()
        let model = harness.model
        model.readerSelectionChanged(SelectionNormalizerTests.twoLineRawSelection)
        await model.waitForBackgroundWork()
        model.ask("Why?", about: model.selection, in: nil)
        await harness.finishJobs()
        let conversation = try #require(model.session?.conversations.first)
        model.revealConversationInPDF(conversation.id)
        #expect(model.readerCommand?.command == .reveal(rects: conversation.anchor?.rects ?? [], flash: true))
        #expect(conversation.anchor?.rects.isEmpty == false)
        // A conversation's id is not a comment's: revealing the "selected comment" does nothing with it (Gate 1).
        let serial = model.readerCommand?.serial
        model.selectedCommentID = conversation.id
        model.revealSelectedCommentInPDF()
        #expect(model.readerCommand?.serial == serial)
    }

    @Test @MainActor func theReviewerNotesAndVenueAreKept() async throws {
        let harness = try await makeModelHarness()
        await harness.open()
        let meta = ManuscriptMeta(title: "Title", targetVenue: "Journal of Examples", manuscriptID: "JOE-2026-001", reviewerNotes: "Be brief.")
        harness.model.updateMeta(meta)
        #expect(harness.model.session?.meta == meta)
        harness.model.startReview()
        await harness.finishJobs()
        #expect(harness.lastContext(of: "review")?.meta == meta)
    }
}
