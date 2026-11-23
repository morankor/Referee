import Foundation
import CoreGraphics
import Testing
import RefereeCore
@testable import RefereeUI

/// Hit-testing of WP9 (plan.md sections 7.5 and 8.6): a point and the rectangles of its page in, a comment id or a
/// mention id out; the smallest rectangle wins; a mention's rectangles count 2 points larger.
@Suite struct ReaderHitTestingTests {
    private func highlight(_ id: UUID, page: Int = 0, x: Double, y: Double, width: Double, height: Double = 10) -> ReaderHighlight {
        ReaderHighlight(ownerID: id, rect: PageRect(pageIndex: page, x: x, y: y, width: width, height: height), style: .pending,
                        isSelected: false, isFuzzy: false)
    }

    private func mention(_ id: Int, rects: [PageRect]) -> CitationMention {
        CitationMention(id: id, pageIndex: rects.first?.pageIndex ?? 0, text: "Kogan [2020", rects: rects, entryIDs: [5], source: .linkAnnotation)
    }

    @Test func theSmallestHighlightUnderThePointWins() {
        let sentence = UUID()
        let phrase = UUID()
        let highlights = [highlight(sentence, x: 110, y: 500, width: 380), highlight(phrase, x: 200, y: 500, width: 60)]
        #expect(ReaderHitTesting.target(at: CGPoint(x: 220, y: 505), pageIndex: 0, highlights: highlights, mentions: []) == .comment(phrase))
        #expect(ReaderHitTesting.target(at: CGPoint(x: 120, y: 505), pageIndex: 0, highlights: highlights, mentions: []) == .comment(sentence))
        #expect(ReaderHitTesting.target(at: CGPoint(x: 120, y: 520), pageIndex: 0, highlights: highlights, mentions: []) == nil)
    }

    @Test func aCitationInsideAHighlightedPassageIsTheCitation() {
        let passage = UUID()
        let highlights = [highlight(passage, x: 110, y: 500, width: 380)]
        let mentions = [mention(6, rects: [PageRect(pageIndex: 0, x: 273, y: 499, width: 34.8, height: 13.9)])]
        #expect(ReaderHitTesting.target(at: CGPoint(x: 290, y: 505), pageIndex: 0, highlights: highlights, mentions: mentions) == .mention(6))
        #expect(ReaderHitTesting.target(at: CGPoint(x: 400, y: 505), pageIndex: 0, highlights: highlights, mentions: mentions) == .comment(passage))
    }

    @Test func aMentionIsClickableTwoPointsAroundItsRectangles() {
        let mentions = [mention(3, rects: [PageRect(pageIndex: 1, x: 100, y: 200, width: 50, height: 10),
                                           PageRect(pageIndex: 1, x: 110, y: 180, width: 20, height: 10)])]
        func hit(_ x: Double, _ y: Double, page: Int = 1) -> ReaderHitTarget? {
            ReaderHitTesting.target(at: CGPoint(x: x, y: y), pageIndex: page, highlights: [], mentions: mentions)
        }
        #expect(hit(125, 205) == .mention(3))
        #expect(hit(98.5, 205) == .mention(3))           // 1.5 pt left of the drawn rectangle
        #expect(hit(151.5, 211.5) == .mention(3))
        #expect(hit(97.5, 205) == nil)                   // 2.5 pt away
        #expect(hit(120, 185) == .mention(3))            // its second rectangle
        #expect(hit(125, 205, page: 0) == nil)           // another page
        #expect(ReaderHitTesting.mention(at: CGPoint(x: 125, y: 205), pageIndex: 1, mentions: mentions) == 3)
        #expect(ReaderHitTesting.clickRect(of: PageRect(pageIndex: 0, x: 10, y: 20, width: 30, height: 40)) == CGRect(x: 8, y: 18, width: 34, height: 44))
    }

    @Test func onEqualAreasAMentionWinsAndOtherwiseTheFirst() {
        let first = UUID()
        let second = UUID()
        // A highlight exactly as large as the mention's click rectangle (2 pt larger than drawn).
        let mentions = [mention(1, rects: [PageRect(pageIndex: 0, x: 102, y: 102, width: 46, height: 6)])]
        let highlights = [highlight(first, x: 100, y: 100, width: 50, height: 10), highlight(second, x: 100, y: 100, width: 50, height: 10)]
        #expect(ReaderHitTesting.target(at: CGPoint(x: 120, y: 105), pageIndex: 0, highlights: highlights, mentions: mentions) == .mention(1))
        #expect(ReaderHitTesting.target(at: CGPoint(x: 120, y: 105), pageIndex: 0, highlights: highlights, mentions: []) == .comment(first))
        // `mention(at:)` sees mentions only.
        #expect(ReaderHitTesting.mention(at: CGPoint(x: 120, y: 105), pageIndex: 0, mentions: []) == nil)
    }

    @Test func aHighlightGivenUpsideDownStillCounts() {
        let id = UUID()
        let flipped = ReaderHighlight(ownerID: id, rect: PageRect(pageIndex: 0, x: 150, y: 110, width: -50, height: -10), style: .own,
                                      isSelected: false, isFuzzy: false)
        #expect(ReaderHitTesting.target(at: CGPoint(x: 120, y: 105), pageIndex: 0, highlights: [flipped], mentions: []) == .comment(id))
    }
}
