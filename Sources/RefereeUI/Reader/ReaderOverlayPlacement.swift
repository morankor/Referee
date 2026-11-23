import CoreGraphics

// Where an overlay sits over the PDF (plan.md sections 7.4 and 9.5). Pure. Input: a rectangle of the PDF view in AppKit
// coordinates (`pdfView.convert(_:from: page)`; origin at the bottom left, since `PDFView.isFlipped` is false), the
// view's size and the overlay's size. Output: the overlay's top-left origin in SwiftUI coordinates (origin at the top
// left, y = height − maxY), always inside the view with a margin when the overlay fits.

enum ReaderOverlayPlacement {
    /// The distance an overlay keeps from the edges of the PDF view.
    static let margin: CGFloat = 8
    /// The selection bar's distance above the selection (section 9.5), and the card's below the mention.
    static let gap: CGFloat = 6

    /// `rect`, given in the coordinates of a view of `height` points, in SwiftUI's top-left coordinates.
    static func topLeftRect(_ rect: CGRect, viewHeight height: CGFloat, isFlipped: Bool = false) -> CGRect {
        let rect = rect.standardized
        guard !isFlipped else { return rect }
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// An overlay of `size` whose bottom edge is `gap` above `anchor` (AppKit coordinates), its left edge at the anchor's;
    /// below the anchor when there is no room above; kept inside a view of `viewSize`.
    static func origin(above anchor: CGRect, size: CGSize, in viewSize: CGSize, isFlipped: Bool = false, gap: CGFloat = gap) -> CGPoint {
        let target = topLeftRect(anchor, viewHeight: viewSize.height, isFlipped: isFlipped)
        var y = target.minY - gap - size.height
        if y < margin { y = target.maxY + gap }
        return clamped(CGPoint(x: target.minX, y: y), size: size, in: viewSize)
    }

    /// An overlay of `size` whose top edge is `gap` below `anchor`, its left edge at the anchor's; above the anchor when
    /// there is no room below; kept inside the view.
    static func origin(below anchor: CGRect, size: CGSize, in viewSize: CGSize, isFlipped: Bool = false, gap: CGFloat = gap) -> CGPoint {
        let target = topLeftRect(anchor, viewHeight: viewSize.height, isFlipped: isFlipped)
        var y = target.maxY + gap
        if y + size.height > viewSize.height - margin, target.minY - gap - size.height >= margin { y = target.minY - gap - size.height }
        return clamped(CGPoint(x: target.minX, y: y), size: size, in: viewSize)
    }

    /// An overlay of `size` centred at the top of the view, `top` points below its upper edge.
    static func originAtTop(size: CGSize, in viewSize: CGSize, top: CGFloat = margin) -> CGPoint {
        clamped(CGPoint(x: (viewSize.width - size.width) / 2, y: top), size: size, in: viewSize)
    }

    /// `origin` moved so that an overlay of `size` stays inside the view, `margin` from its edges. An overlay that does
    /// not fit between the margins is centred in the room there is, and one larger than the view starts at its edge.
    static func clamped(_ origin: CGPoint, size: CGSize, in viewSize: CGSize) -> CGPoint {
        func clamp(_ value: CGFloat, length: CGFloat, within extent: CGFloat) -> CGFloat {
            let upper = extent - margin - length
            guard upper >= margin else { return min(margin, max(0, extent - length) / 2) }
            return min(max(value, margin), upper)
        }
        return CGPoint(x: clamp(origin.x, length: size.width, within: viewSize.width),
                       y: clamp(origin.y, length: size.height, within: viewSize.height))
    }

    /// Whether any part of `rect` (AppKit coordinates) lies inside a view of `viewSize`.
    static func isVisible(_ rect: CGRect, in viewSize: CGSize) -> Bool {
        CGRect(origin: .zero, size: viewSize).intersects(rect.standardized)
    }
}
