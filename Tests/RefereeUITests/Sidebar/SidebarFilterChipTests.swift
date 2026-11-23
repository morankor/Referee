import Foundation
import Testing
import RefereeCore
import AppCore
@testable import RefereeUI

/// The filters of the Comments tab (plan.md section 9.3; step 5, D11: four chips and a Kind menu) and their counts, and
/// what the tab says about a review and the document (D6).
@Suite struct SidebarFilterChipTests {
    typealias Sample = SidebarTestData

    static let comments: [ReviewComment] = [
        Sample.comment(status: .pending, kind: .major),
        Sample.comment(status: .pending, kind: .minor),
        Sample.comment(status: .approved, kind: .major),
        Sample.comment(origin: .user, status: .approved, kind: .minor, category: "other"),
        Sample.comment(status: .rejected, kind: .strength),
        Sample.comment(status: .pending, kind: .question),
        Sample.comment(status: .rejected, kind: .question),
    ]

    @Test func fourStatusChipsWithTheirCounts() {
        let chips = SidebarFilterChip.chips(for: Self.comments)
        #expect(chips.map(\.title) == ["All", "Pending", "Approved", "Rejected"])
        #expect(chips.map(\.count) == [7, 3, 2, 2])
        #expect(chips.map(\.filter) == [.all, .pending, .approved, .rejected])
    }

    /// D11: the Kind menu lists the four kinds, Strengths included, with their counts.
    @Test func theKindMenuListsEveryKindWithItsCount() {
        let items = SidebarFilterChip.kindItems(for: Self.comments)
        #expect(items.map(\.menuTitle) == ["Major (2)", "Minor (2)", "Questions (2)", "Strengths (1)"])
        #expect(items.map(\.filter) == [.kind(.major), .kind(.minor), .kind(.question), .kind(.strength)])
    }

    /// "Kind ▾" while no kind is filtered; else the kind and its count. Choosing the kind in force again shows all.
    @Test func theKindChipShowsTheKindInForceAndChoosingItAgainShowsAll() {
        #expect(SidebarFilterChip.kindInForce(.all, comments: Self.comments) == nil)
        #expect(SidebarFilterChip.kindInForce(.pending, comments: Self.comments) == nil)
        let strengths = SidebarFilterChip.kindInForce(.kind(.strength), comments: Self.comments)
        #expect(strengths?.title == "Strengths")
        #expect(strengths?.count == 1)
        #expect(SidebarFilterChip.filter(choosing: .minor, current: .all) == .kind(.minor))
        #expect(SidebarFilterChip.filter(choosing: .minor, current: .kind(.major)) == .kind(.minor))
        #expect(SidebarFilterChip.filter(choosing: .minor, current: .kind(.minor)) == .all)
        #expect(SidebarFilterChip.filter(choosing: .strength, current: .pending) == .kind(.strength))
    }

    @Test func noCommentsGiveZeroEverywhere() {
        #expect(SidebarFilterChip.chips(for: []).map(\.count) == [0, 0, 0, 0])
        #expect(SidebarFilterChip.kindItems(for: []).map(\.count) == [0, 0, 0, 0])
    }

    @Test func theTriageText() {
        #expect(SidebarFilterChip.triageText(decided: 12, total: 31) == "12 of 31 decided")
        #expect(SidebarFilterChip.triageText(decided: 0, total: 1) == "0 of 1 decided")
    }

    /// D6: "All 25 decided" once every comment is decided, and only then.
    @Test func everyCommentDecided() {
        #expect(SidebarFilterChip.allDecidedText(total: 25) == "All 25 decided")
        #expect(SidebarFilterChip.isAllDecided(decided: 25, total: 25))
        #expect(!SidebarFilterChip.isAllDecided(decided: 24, total: 25))
        #expect(!SidebarFilterChip.isAllDecided(decided: 0, total: 0))
    }

    /// Each chip's and each kind's count is what `visibleComments` shows when the model's filter is that one,
    /// whatever the filter was before (the counts are taken over all comments).
    @Test @MainActor func eachFilterCountsWhatTheModelShowsUnderIt() async throws {
        let harness = try await SidebarTestHarness.open(comments: Self.comments)
        let model = harness.model
        model.filter = .kind(.question)
        let comments = model.session?.comments ?? []
        for chip in SidebarFilterChip.chips(for: comments) + SidebarFilterChip.kindItems(for: comments) {
            model.filter = chip.filter
            #expect(model.visibleComments.count == chip.count, "\(chip.title)")
            #expect(model.visibleComments.allSatisfy { SidebarFilterChip.matches($0, chip.filter) })
        }
        #expect(SidebarFilterChip.triageText(decided: model.triage.decided, total: model.triage.total) == "4 of 7 decided")
    }

    // ---- D6: what the Comments tab says ----

    @Test func theDocumentFactsLine() {
        #expect(SidebarCommentsFacts.documentFacts(pageCount: 4, referenceCount: 9, hasTextLayer: true, hasMarginLineNumbers: false)
                == "4 pages · 9 references · no margin line numbers")
        #expect(SidebarCommentsFacts.documentFacts(pageCount: 1, referenceCount: 1, hasTextLayer: true, hasMarginLineNumbers: true)
                == "1 page · 1 reference · margin line numbers found")
        #expect(SidebarCommentsFacts.documentFacts(pageCount: 12, referenceCount: 0, hasTextLayer: true, hasMarginLineNumbers: true)
                == "12 pages · no reference list found · margin line numbers found")
        #expect(SidebarCommentsFacts.documentFacts(pageCount: 3, referenceCount: nil, hasTextLayer: true, hasMarginLineNumbers: false)
                == "3 pages · no margin line numbers")
        #expect(SidebarCommentsFacts.documentFacts(pageCount: 2, referenceCount: 0, hasTextLayer: false, hasMarginLineNumbers: false)
                == "2 pages · no text layer: comments can be tied to pages only")
    }

    /// The facts of an opened paper (the fake citation index has no reference list).
    @Test @MainActor func theFactsOfTheOpenPaper() async throws {
        let harness = try await SidebarTestHarness.open(comments: [])
        let text = harness.paper.text
        #expect(SidebarCommentsFacts.documentFacts(of: harness.model)
                == SidebarCommentsFacts.documentFacts(pageCount: harness.paper.ref.pageCount, referenceCount: 0,
                                                      hasTextLayer: text.hasTextLayer, hasMarginLineNumbers: text.hasMarginLineNumbers))
        #expect(SidebarCommentsFacts.documentFacts(of: harness.model)?.hasPrefix("4 pages · no reference list found") == true)
    }

    /// "Writing… · 2 received": the AI comments of the running review, those created since it started.
    @Test func theCommentsAReviewHasDelivered() {
        let start = Sample.created
        let comments = [
            Sample.comment(createdAt: start.addingTimeInterval(-60)),                   // an earlier review's
            Sample.comment(createdAt: start),
            Sample.comment(createdAt: start.addingTimeInterval(30)),
            Sample.comment(origin: .user, createdAt: start.addingTimeInterval(40)),     // the referee's own
        ]
        #expect(SidebarCommentsFacts.receivedCount(of: comments, since: start) == 2)
        #expect(SidebarCommentsFacts.writingLabel(received: 2) == "Writing… · 2 received")
        #expect(SidebarCommentsFacts.writingLabel(received: 0) == "Writing…")
    }
}
