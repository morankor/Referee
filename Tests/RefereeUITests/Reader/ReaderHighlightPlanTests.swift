import Foundation
import Testing
import RefereeCore
import AppCore
@testable import RefereeUI

/// The desired-highlight computation of WP9 (plan.md section 7.3): comments, filter and selection in; rectangles with
/// their colour, alpha and id out.
@Suite struct ReaderHighlightPlanTests {
    private func rect(_ page: Int = 0, x: Double = 110, y: Double, width: Double = 200) -> PageRect {
        PageRect(pageIndex: page, x: x, y: y, width: width, height: 10.6)
    }

    private func plan(_ comments: [ReviewComment], conversations: [Conversation] = [], filter: CommentFilter = .all, selected: UUID? = nil,
                      showRejected: Bool = false, dimmed: Bool = false) -> [ReaderHighlight] {
        ReaderHighlightPlan.highlights(comments: comments, conversations: conversations, filter: filter, selectedCommentID: selected,
                                       showRejected: showRejected, dimmed: dimmed)
    }

    /// Design review D29: while the find bar is shown every highlight keeps 40% of its alpha, the fuzzy frame included.
    @Test @MainActor func findDimsEveryHighlightToFortyPercent() throws {
        let pending = ReaderTestSupport.comment(status: .pending, rects: [rect(y: 600)])
        let selected = ReaderTestSupport.comment(status: .approved, rects: [rect(y: 560)], confidence: .fuzzy(score: 0.9))
        let question = ReaderTestSupport.conversation(rects: [rect(y: 520)])
        let normal = plan([pending, selected], conversations: [question], selected: selected.id)
        let dimmed = plan([pending, selected], conversations: [question], selected: selected.id, dimmed: true)
        #expect(normal.allSatisfy { !$0.isDimmed })
        #expect(dimmed.allSatisfy { $0.isDimmed })
        #expect(dimmed.map(\.ownerID) == normal.map(\.ownerID))                     // the same highlights, only fainter
        for (plain, faint) in zip(normal, dimmed) {
            #expect(abs(faint.alpha - plain.alpha * 0.4) < 0.0001)
            #expect(abs(faint.color.alphaComponent - plain.alpha * 0.4) < 0.0001)
        }
        let frame = try #require(dimmed.first { $0.isFuzzy })
        #expect(abs(frame.frameColor.alphaComponent - 0.4) < 0.0001)
        #expect(try #require(normal.first { $0.isFuzzy }).frameColor.alphaComponent == 1)
        #expect(abs((dimmed.first { $0.ownerID == pending.id }?.alpha ?? 0) - 0.14) < 0.0001)   // pending 0.35 → 0.14
    }

    @Test @MainActor func eachStateHasTheColourAndAlphaOfSection73() throws {
        let pending = ReaderTestSupport.comment(status: .pending, rects: [rect(y: 600)])
        let approved = ReaderTestSupport.comment(status: .approved, rects: [rect(y: 560)])
        let ownPending = ReaderTestSupport.comment(status: .pending, origin: .user, rects: [rect(y: 520)])
        let ownRejected = ReaderTestSupport.comment(status: .rejected, origin: .user, rects: [rect(y: 480)])
        let rejected = ReaderTestSupport.comment(status: .rejected, rects: [rect(y: 440)])
        let question = ReaderTestSupport.conversation(rects: [rect(y: 400)])
        let shown = plan([pending, approved, ownPending, ownRejected, rejected], conversations: [question])

        func only(_ id: UUID) throws -> ReaderHighlight { try #require(shown.first { $0.ownerID == id }) }
        #expect(try only(pending.id).style == .pending)
        #expect(try only(pending.id).alpha == 0.35)
        #expect(try only(approved.id).style == .approved)
        #expect(try only(approved.id).alpha == 0.30)
        #expect(try only(ownPending.id).style == .own)          // the reviewer's own: blue whatever its status
        #expect(try only(ownRejected.id).style == .own)
        #expect(try only(ownPending.id).alpha == 0.30)
        #expect(try only(question.id).style == .question)
        #expect(try only(question.id).alpha == 0.25)
        #expect(!shown.contains { $0.ownerID == rejected.id })   // "Show highlights of rejected comments" is off
        #expect(shown.allSatisfy { !$0.isSelected && !$0.isFuzzy })
        #expect(try only(approved.id).color.alphaComponent == 0.30)
        #expect(try only(question.id).hue == Theme.highlightHue(.question))
    }

    @Test @MainActor func rejectedCommentsAreGreyWhenTheSettingIsOnAndTheSelectedOneIsStronger() throws {
        let rejected = ReaderTestSupport.comment(status: .rejected, rects: [rect(y: 600)])
        let pending = ReaderTestSupport.comment(status: .pending, rects: [rect(y: 560), rect(y: 540)])
        let shown = plan([rejected, pending], selected: pending.id, showRejected: true)
        let grey = try #require(shown.first { $0.ownerID == rejected.id })
        #expect(grey.style == .rejected)
        #expect(grey.alpha == 0.15)
        let selected = shown.filter { $0.ownerID == pending.id }
        #expect(selected.count == 2)                              // one per rectangle
        #expect(selected.allSatisfy { $0.isSelected && $0.style == .pending && $0.alpha == 0.60 })
        #expect(plan([rejected], selected: rejected.id, showRejected: true).first?.alpha == 0.60)
    }

    @Test @MainActor func aFuzzyAnchorIsMarkedForItsDashedBorder() {
        let fuzzy = ReaderTestSupport.comment(status: .approved, rects: [rect(y: 600)], confidence: .fuzzy(score: 0.91))
        let exact = ReaderTestSupport.comment(status: .approved, rects: [rect(y: 560)])
        let shown = plan([fuzzy, exact])
        #expect(shown.first { $0.ownerID == fuzzy.id }?.isFuzzy == true)
        #expect(shown.first { $0.ownerID == exact.id }?.isFuzzy == false)
    }

    @Test @MainActor func theSidebarFilterDecidesWhichCommentsAreHighlighted() {
        let major = ReaderTestSupport.comment(status: .pending, kind: .major, rects: [rect(y: 600)])
        let minor = ReaderTestSupport.comment(status: .approved, kind: .minor, rects: [rect(y: 560)])
        let rejected = ReaderTestSupport.comment(status: .rejected, kind: .question, rects: [rect(y: 520)])
        let question = ReaderTestSupport.conversation(rects: [rect(y: 480)])
        func owners(_ filter: CommentFilter) -> Set<UUID> {
            Set(plan([major, minor, rejected], conversations: [question], filter: filter, showRejected: true).map(\.ownerID))
        }
        #expect(owners(.all) == [major.id, minor.id, rejected.id, question.id])
        #expect(owners(.pending) == [major.id, question.id])     // a conversation's passage is no comment: no filter applies
        #expect(owners(.approved) == [minor.id, question.id])
        #expect(owners(.rejected) == [rejected.id, question.id])
        #expect(owners(.kind(.minor)) == [minor.id, question.id])
    }

    @Test @MainActor func anchorsWithoutDrawableRectanglesGiveNothing() {
        let pageOnly = ReaderTestSupport.comment(rects: [])
        let odd = ReaderTestSupport.comment(rects: [PageRect(pageIndex: 0, x: 100, y: 100, width: 0, height: 10),
                                                    PageRect(pageIndex: -1, x: 100, y: 100, width: 50, height: 10),
                                                    PageRect(pageIndex: 0, x: .nan, y: 100, width: 50, height: 10),
                                                    PageRect(pageIndex: 0, x: 100, y: .infinity, width: 50, height: 10)])
        #expect(plan([pageOnly, odd]).isEmpty)
    }

    @Test @MainActor func twoCommentsOnOnePassageAreDrawnOnce() {
        let line = rect(y: 600)
        let first = ReaderTestSupport.comment(status: .pending, rects: [line])
        let similar = ReaderTestSupport.comment(status: .pending, rects: [line])
        #expect(plan([first, similar]).map(\.ownerID) == [first.id])              // the earlier one
        #expect(plan([first, similar], selected: similar.id).map(\.ownerID) == [similar.id])   // the selected one
        let own = ReaderTestSupport.comment(status: .approved, origin: .user, rects: [line])
        #expect(plan([first, own]).map(\.ownerID) == [own.id])                    // own before pending
        let approved = ReaderTestSupport.comment(status: .approved, rects: [line])
        #expect(plan([approved, first]).map(\.ownerID) == [first.id])             // pending before approved
        // Rectangles that merely overlap are both drawn.
        let part = ReaderTestSupport.comment(status: .approved, rects: [rect(x: 150, y: 600, width: 40)])
        #expect(plan([first, part]).count == 2)
    }

    @Test @MainActor func highlightsComeByPageThenFromTheTopDownThenFromLeftToRight() {
        let low = ReaderTestSupport.comment(rects: [rect(0, x: 110, y: 100)])
        let highRight = ReaderTestSupport.comment(rects: [rect(0, x: 300, y: 600, width: 50)])
        let highLeft = ReaderTestSupport.comment(rects: [rect(0, x: 110, y: 600, width: 50)])
        let nextPage = ReaderTestSupport.comment(rects: [rect(1, y: 700)])
        let order = plan([nextPage, low, highRight, highLeft]).map(\.ownerID)
        #expect(order == [highLeft.id, highRight.id, low.id, nextPage.id])
    }
}
