import SwiftUI

/// The logo mark (docs/brand/brand.md): a loop, open at the upper right, closed by a dot. The AI's loop is not
/// complete until the human is in it. Drawn as vectors, from 16 to 256 points and beyond.
///
/// `.glyph` is the bare mark in indigo ink, or in paper in the dark appearance. `.tile` is the app icon's rounded
/// square with the mark on it, the same in both appearances because it carries its own background; it stands where
/// the icon would, in the welcome window. The mark is decorative: the name is always next to it, so VoiceOver skips it.
///
///     CommonBrandMark(size: 36)                   // the Help window's header
///     CommonBrandMark(size: 72, style: .tile)     // the welcome window
struct CommonBrandMark: View {
    enum Style: Sendable, Equatable {
        case glyph, tile
    }

    let size: CGFloat
    let style: Style

    init(size: CGFloat, style: Style = .glyph) {
        self.size = size
        self.style = style
    }

    /// The mark's measurements, in units of its canvas (`canvas(for:)`), as scripts/make-icon.sh draws the icon.
    struct Geometry: Sendable, Equatable {
        var radius: CGFloat         // the loop's centre line
        var stroke: CGFloat         // the loop's width; its ends are round
        var dot: CGFloat            // the dot's diameter
        var clearance: CGFloat      // between the dot and either end of the loop

        /// From 34 points (glyph) or 44 points (tile) up, and in the icon from 64 pixels up.
        static let regular = Geometry(radius: 250, stroke: 92, dot: 136, clearance: 28)
        /// Smaller sizes: a heavier loop and a wider gap, so that the dot stays apart from the loop at 16 points.
        static let small = Geometry(radius: 236, stroke: 124, dot: 161, clearance: 68)

        /// The gap is centred on the upper right (y-down angles, as SwiftUI draws).
        static let gapAngle = Angle.degrees(-45)

        /// Half of the angle the gap takes out of the loop: the dot, the clearance either side and a round end.
        var halfGap: Angle { .radians(Double((dot / 2 + clearance + stroke / 2) / radius)) }
    }

    /// The glyph's canvas is 640 units: the loop (296 units from its centre to its outer edge) and a margin. The tile's
    /// is 824, the icon's rounded square: the icon's 1024-unit canvas has 100 units of margin on each side.
    static func canvas(for style: Style) -> CGFloat {
        style == .glyph ? 640 : 824
    }

    /// The tile's corner radius as a fraction of its side: 185.4 of 824, the macOS icon template's, with continuous corners.
    static let tileCornerRadius: CGFloat = 185.4 / 824

    /// The small geometry wherever the regular one would leave less than 1.5 points between the dot and the loop.
    static func geometry(size: CGFloat, style: Style) -> Geometry {
        Geometry.regular.clearance * size / canvas(for: style) < 1.5 ? .small : .regular
    }

    var body: some View {
        let geometry = Self.geometry(size: size, style: style)
        let unit = size / Self.canvas(for: style)
        let gap = Geometry.gapAngle.radians
        ZStack {
            if style == .tile {
                RoundedRectangle(cornerRadius: size * Self.tileCornerRadius, style: .continuous)
                    .fill(LinearGradient(colors: [CommonBrand.indigoTop, CommonBrand.indigoBottom], startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.18), radius: size * 0.03, y: size * 0.015)
            }
            Loop(geometry: geometry, unit: unit)
                .stroke(style == .tile ? AnyShapeStyle(CommonBrand.tileLoop) : AnyShapeStyle(CommonBrand.mark),
                        style: StrokeStyle(lineWidth: geometry.stroke * unit, lineCap: .round))
            Circle()
                .fill(style == .tile ? AnyShapeStyle(CommonBrand.tileDot) : AnyShapeStyle(CommonBrand.mark))
                .frame(width: geometry.dot * unit, height: geometry.dot * unit)
                .offset(x: cos(gap) * geometry.radius * unit, y: sin(gap) * geometry.radius * unit)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// The loop: an arc round the centre from the far side of the gap, clockwise on screen, to its near side.
    struct Loop: Shape {
        var geometry: Geometry
        var unit: CGFloat

        func path(in rect: CGRect) -> Path {
            let gap = Geometry.gapAngle
            var path = Path()
            path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: geometry.radius * unit,
                        startAngle: gap + geometry.halfGap, endAngle: gap - geometry.halfGap + .degrees(360), clockwise: false)
            return path
        }
    }
}
