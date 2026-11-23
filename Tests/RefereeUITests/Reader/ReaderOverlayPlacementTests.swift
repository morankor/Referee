import CoreGraphics
import Testing
@testable import RefereeUI

/// Overlay placement of WP9 (plan.md sections 7.4 and 9.5): a rectangle of the PDF view in AppKit coordinates (origin at
/// the bottom left) and the view's size in; the overlay's top-left origin in SwiftUI coordinates out, inside the view.
@Suite struct ReaderOverlayPlacementTests {
    private let view = CGSize(width: 700, height: 800)

    @Test func appKitRectanglesAreFlippedIntoSwiftUICoordinates() {
        #expect(ReaderOverlayPlacement.topLeftRect(CGRect(x: 10, y: 100, width: 50, height: 20), viewHeight: 500)
                == CGRect(x: 10, y: 380, width: 50, height: 20))
        #expect(ReaderOverlayPlacement.topLeftRect(CGRect(x: 10, y: 100, width: 50, height: 20), viewHeight: 500, isFlipped: true)
                == CGRect(x: 10, y: 100, width: 50, height: 20))
        #expect(ReaderOverlayPlacement.topLeftRect(CGRect(x: 60, y: 120, width: -50, height: -20), viewHeight: 500)
                == CGRect(x: 10, y: 380, width: 50, height: 20))
    }

    @Test func theSelectionBarSitsSixPointsAboveTheSelection() {
        // The selection's top edge is 400 points below the top of the view.
        let selection = CGRect(x: 311, y: 380, width: 150, height: 20)          // SwiftUI: y 400 ... 420
        let origin = ReaderOverlayPlacement.origin(above: selection, size: CGSize(width: 300, height: 30), in: view)
        #expect(origin == CGPoint(x: 311, y: 400 - 6 - 30))
    }

    @Test func withoutRoomAboveTheBarGoesBelowAndItAlwaysStaysInside() {
        let nearTop = CGRect(x: 100, y: 770, width: 150, height: 20)              // SwiftUI: y 10 ... 30
        #expect(ReaderOverlayPlacement.origin(above: nearTop, size: CGSize(width: 300, height: 30), in: view) == CGPoint(x: 100, y: 36))
        let nearRight = CGRect(x: 600, y: 380, width: 80, height: 20)
        let origin = ReaderOverlayPlacement.origin(above: nearRight, size: CGSize(width: 300, height: 30), in: view)
        #expect(origin.x == CGFloat(700 - 8 - 300))
        let leftOfView = CGRect(x: -40, y: 380, width: 80, height: 20)
        #expect(ReaderOverlayPlacement.origin(above: leftOfView, size: CGSize(width: 300, height: 30), in: view).x == 8)
    }

    @Test func theCardGoesBelowTheMentionOrAboveItWhenThereIsNoRoom() {
        let card = CGSize(width: 360, height: 220)
        let high = CGRect(x: 380, y: 600, width: 110, height: 14)                // SwiftUI: y 186 ... 200
        #expect(ReaderOverlayPlacement.origin(below: high, size: card, in: view) == CGPoint(x: 700 - 8 - 360, y: 206))
        let low = CGRect(x: 120, y: 100, width: 110, height: 14)                  // SwiftUI: y 686 ... 700
        #expect(ReaderOverlayPlacement.origin(below: low, size: card, in: view) == CGPoint(x: 120, y: 686 - 6 - 220))
        // No room either way: kept inside the view, at the bottom.
        let tall = CGSize(width: 360, height: 700)
        #expect(ReaderOverlayPlacement.origin(below: CGRect(x: 120, y: 400, width: 110, height: 14), size: tall, in: view)
                == CGPoint(x: 120, y: 800 - 8 - 700))
    }

    @Test func anOverlayAtTheTopIsCentred() {
        #expect(ReaderOverlayPlacement.originAtTop(size: CGSize(width: 360, height: 200), in: view) == CGPoint(x: 170, y: 8))
        #expect(ReaderOverlayPlacement.originAtTop(size: CGSize(width: 360, height: 200), in: view, top: 52) == CGPoint(x: 170, y: 52))
    }

    @Test func anOverlayLargerThanTheViewStartsAtItsEdge() {
        #expect(ReaderOverlayPlacement.clamped(CGPoint(x: 50, y: 50), size: CGSize(width: 800, height: 900), in: view) == .zero)
        // Too large for the margins but smaller than the view: centred in the room there is.
        #expect(ReaderOverlayPlacement.clamped(CGPoint(x: 50, y: 50), size: CGSize(width: 690, height: 100), in: view) == CGPoint(x: 5, y: 50))
    }

    @Test func visibilityIsAnyOverlapWithTheView() {
        #expect(ReaderOverlayPlacement.isVisible(CGRect(x: 10, y: 10, width: 5, height: 5), in: view))
        #expect(ReaderOverlayPlacement.isVisible(CGRect(x: -10, y: 790, width: 20, height: 20), in: view))
        #expect(!ReaderOverlayPlacement.isVisible(CGRect(x: 10, y: 801, width: 5, height: 5), in: view))
        #expect(!ReaderOverlayPlacement.isVisible(CGRect(x: -30, y: 10, width: 20, height: 5), in: view))
    }
}
