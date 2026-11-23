import AppKit
import SwiftUI
import Testing
import RefereeCore
import TestSupport
@testable import RefereeUI

/// The brand of step 5 (docs/brand/brand.md): the name's forms, the tagline, the wordmark, the mark's colours and
/// geometry, and the icon script drawing the same mark.
@Suite struct CommonBrandTests {
    // ---- the name ----

    @Test func theNameHasItsDisplayFormAndAFormWithoutSpaces() {
        #expect(CommonBrand.name == "Human in the Loop")
        #expect(CommonBrand.token == "HumanInTheLoop")
        // The token is the name's words, capitalised and joined: never a different name.
        let joined = CommonBrand.name.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        #expect(CommonBrand.token == joined)
        // An HTTP product token (RFC 9110 tchar), so that "HumanInTheLoop/0.1.0" is a valid User-Agent product.
        let tchar = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        #expect(CommonBrand.token.unicodeScalars.allSatisfy { tchar.contains($0) })
        #expect(CommonBrand.formerName == "Referee")
    }

    @Test func theMenusAndWindowsCarryTheNameAsMacOSDoes() {
        #expect(CommonBrand.aboutItemTitle == "About Human in the Loop")
        #expect(CommonBrand.hideItemTitle == "Hide Human in the Loop")
        #expect(CommonBrand.quitItemTitle == "Quit Human in the Loop")
        #expect(CommonBrand.helpItemTitle == "Human in the Loop Help")
        #expect(CommonBrand.welcomeItemTitle == "Welcome to Human in the Loop")
    }

    /// One short line that says who does what, with "referee" as the role word, not as the app's old name.
    @Test func theTaglineIsOneShortLineWithTheRoleWord() {
        #expect(CommonBrand.tagline == "AI drafts. You referee.")
        #expect(!CommonBrand.tagline.contains("\n"))
        #expect(CommonBrand.tagline.count <= 32)
        #expect(CommonBrand.tagline.contains("referee"))
        #expect(!CommonBrand.tagline.contains(CommonBrand.formerName))
        #expect(CommonBrand.descriptor == "A PDF reader for refereeing papers with AI")
    }

    // ---- the wordmark ----

    @Test func theWordmarkSetsTheNounsInSFProAndTheConnectiveInNewYorkItalic() {
        let mark = CommonBrand.wordmark(size: 24)
        #expect(String(mark.characters) == "Human in the Loop")
        let runs = Array(mark.runs)
        #expect(runs.count == 3)
        guard runs.count == 3 else { return }
        #expect(String(mark[runs[0].range].characters) == "Human ")
        #expect(String(mark[runs[1].range].characters) == "in the ")
        #expect(String(mark[runs[2].range].characters) == "Loop")
        typealias SwiftUIKeys = AttributeScopes.SwiftUIAttributes
        for noun in [runs[0], runs[2]] {
            #expect(noun[SwiftUIKeys.FontAttribute.self] == .system(size: 24, weight: .semibold))
            #expect(abs((noun[SwiftUIKeys.TrackingAttribute.self] ?? 0) + 0.24) < 1e-9)       // 1% tighter
            #expect(noun[SwiftUIKeys.ForegroundColorAttribute.self] == .primary)
        }
        #expect(runs[1][SwiftUIKeys.FontAttribute.self] == .system(size: 24 * 1.04, weight: .regular, design: .serif).italic())
        #expect(runs[1][SwiftUIKeys.TrackingAttribute.self] == nil)
        #expect(runs[1][SwiftUIKeys.ForegroundColorAttribute.self] == .secondary)
        #expect(CommonBrand.minimumWordmarkSize == 20)
    }

    /// The welcome window's left column is 250 points with 20 points of padding: the 24-point wordmark must fit in 210.
    @Test @MainActor func theWordmarkFitsTheWelcomeWindowsColumn() {
        let roomy = CGSize(width: 1_000, height: 1_000)
        let size = NSHostingController(rootView: Text(CommonBrand.wordmark(size: 24)).fixedSize()).sizeThatFits(in: roomy)
        #expect(size.width > 150, "the wordmark measured \(size.width) points: not laid out?")
        #expect(size.width <= 210, "the wordmark is \(size.width) points wide; the column has 210")
    }

    // ---- colour ----

    @Test func theMarkIsInkInTheLightAppearanceAndPaperInTheDark() throws {
        var light = EnvironmentValues()
        light.colorScheme = .light
        var dark = EnvironmentValues()
        dark.colorScheme = .dark
        #expect(CommonBrand.mark.resolve(in: light) == CommonBrand.ink)
        #expect(CommonBrand.mark.resolve(in: dark) == CommonBrand.paper)
        try expectColor(CommonBrand.ink, hex: 0x23285E)
        try expectColor(CommonBrand.paper, hex: 0xF4F1EA)
        try expectColor(CommonBrand.indigoTop, hex: 0x454CC2)
        try expectColor(CommonBrand.indigoBottom, hex: 0x1E2266)
        try expectColor(CommonBrand.tileDot, hex: 0xFFF5E8)
        try expectColor(CommonBrand.tileLoop, hex: 0xE8EBFF, alpha: 0.92)
    }

    /// The mark reads on the window: at least 7:1 against the light and dark window backgrounds (WCAG AAA).
    @Test @MainActor func theMarkContrastsWithTheWindowInBothAppearances() throws {
        for (appearance, colour) in [(NSAppearance.Name.aqua, CommonBrand.ink), (.darkAqua, CommonBrand.paper)] {
            let window = try #require(resolved(NSColor.windowBackgroundColor, in: appearance))
            let mark = try #require(NSColor(colour).usingColorSpace(.sRGB))
            #expect(contrast(mark, window) >= 7, "\(appearance.rawValue): \(contrast(mark, window)):1")
        }
    }

    /// "Never reuse a semantic hue for decoration": the brand's indigo is at least 15° of hue from every colour that
    /// carries a meaning (kinds, statuses, own comments, highlights, the destination's green and orange), in light and dark.
    @Test @MainActor func theBrandsIndigoIsNotTheHueOfAnythingThatCarriesAMeaning() throws {
        var semantic: [(String, NSColor)] = [("own", NSColor(Theme.ownColor)), ("local", NSColor(Color.green)), ("remote", NSColor(Color.orange))]
        for kind in [CommentKind.major, .minor, .question, .strength] { semantic.append(("kind \(kind)", NSColor(Theme.kindColor(kind)))) }
        for status in [CommentStatus.pending, .approved, .rejected] { semantic.append(("status \(status)", NSColor(Theme.statusColor(status)))) }
        for highlight in Theme.Highlight.allCases { semantic.append(("highlight \(highlight)", Theme.highlightHue(highlight))) }
        let brand = try [CommonBrand.ink, CommonBrand.indigoTop, CommonBrand.indigoBottom].map { try #require(NSColor($0).usingColorSpace(.sRGB)) }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for (name, colour) in semantic {
                let meaning = try #require(resolved(colour, in: appearance))
                for indigo in brand {
                    #expect(indigo.saturationComponent > 0.3, "the indigo must be a colour, not a grey")
                    // A grey (rejected) has no hue to collide with; any coloured meaning must keep its distance.
                    guard meaning.saturationComponent > 0.15 else { continue }
                    let distance = hueDistance(indigo, meaning)
                    #expect(distance >= 15, "\(name) in \(appearance.rawValue) is \(distance)° from the brand's indigo")
                }
            }
        }
    }

    // ---- the mark's geometry ----

    @Test func theGeometryIsTheOneOfBrandMD() {
        #expect(CommonBrandMark.Geometry.regular == .init(radius: 250, stroke: 92, dot: 136, clearance: 28))
        #expect(CommonBrandMark.Geometry.small == .init(radius: 236, stroke: 124, dot: 161, clearance: 68))
        #expect(CommonBrandMark.Geometry.gapAngle == .degrees(-45))
        #expect(CommonBrandMark.canvas(for: .glyph) == 640)
        #expect(CommonBrandMark.canvas(for: .tile) == 824)
        #expect(abs(CommonBrandMark.tileCornerRadius - 0.225) < 0.001)
        // Regular from 34 points (glyph) and 44 points (tile); small below.
        #expect(CommonBrandMark.geometry(size: 33, style: .glyph) == .small)
        #expect(CommonBrandMark.geometry(size: 35, style: .glyph) == .regular)
        #expect(CommonBrandMark.geometry(size: 44, style: .tile) == .small)
        #expect(CommonBrandMark.geometry(size: 45, style: .tile) == .regular)
    }

    /// Crisp from 16 points: at every size the dot keeps at least a point of space from both ends of the loop, and the
    /// loop and the dot stay inside the mark's frame.
    @Test func theDotNeverTouchesTheLoopAndNothingLeavesTheFrame() {
        for style in [CommonBrandMark.Style.glyph, .tile] {
            for size in stride(from: CGFloat(16), through: 256, by: 2) {
                let geometry = CommonBrandMark.geometry(size: size, style: style)
                let unit = size / CommonBrandMark.canvas(for: style)
                // The ends of the loop are round: each ends half a stroke past the arc, `halfGap` from the dot's centre.
                let endToDot = 2 * geometry.radius * sin(geometry.halfGap.radians / 2)          // chord, arc end to dot centre
                let space = (endToDot - geometry.stroke / 2 - geometry.dot / 2) * unit
                #expect(space >= 1, "\(style) at \(size) pt: \(space) pt between the dot and the loop")
                let half = CommonBrandMark.canvas(for: style) / 2
                #expect(geometry.radius + geometry.stroke / 2 <= half)
                let dotReach = max(abs(cos(CommonBrandMark.Geometry.gapAngle.radians)), abs(sin(CommonBrandMark.Geometry.gapAngle.radians)))
                    * geometry.radius + geometry.dot / 2
                #expect(dotReach <= half)
            }
        }
    }

    @Test @MainActor func theMarkIsExactlyTheSizeItIsGiven() {
        let roomy = CGSize(width: 1_000, height: 1_000)
        for style in [CommonBrandMark.Style.glyph, .tile] {
            for size in [CGFloat(16), 24, 32, 36, 64, 72, 128, 256] {
                let fitted = NSHostingController(rootView: CommonBrandMark(size: size, style: style)).sizeThatFits(in: roomy)
                #expect(fitted == CGSize(width: size, height: size), "\(style) at \(size) pt is \(fitted)")
            }
        }
    }

    /// Drawn: the dot in ink on light and in paper on dark; the tile's dot warm white on the indigo in both; the tile's
    /// corners clear, as an icon's are.
    @Test @MainActor func theMarkDrawsItsColoursInEachAppearance() throws {
        for (scheme, expected) in [(ColorScheme.light, 0x23285E), (.dark, 0xF4F1EA)] as [(ColorScheme, UInt32)] {
            let pixels = try render(CommonBrandMark(size: 64), scheme: scheme)
            #expect(pixels.isClose(at: dotCentre(size: 64, style: .glyph), to: expected), "glyph dot, \(scheme)")
            #expect(pixels.alpha(at: CGPoint(x: 32, y: 32)) == 0, "the middle of the loop is empty, \(scheme)")
            let tile = try render(CommonBrandMark(size: 64, style: .tile), scheme: scheme)
            #expect(tile.isClose(at: dotCentre(size: 64, style: .tile), to: 0xFFF5E8), "tile dot, \(scheme)")
            #expect(tile.alpha(at: CGPoint(x: 32, y: 32)) == 255, "the tile is opaque inside, \(scheme)")
            #expect(tile.alpha(at: CGPoint(x: 0.5, y: 0.5)) < 40, "the tile's corner is clear, \(scheme)")
        }
    }

    /// scripts/make-icon.sh draws the same mark: its two geometries are this view's.
    @Test func theIconScriptDrawsTheSameMark() throws {
        let script = try String(contentsOf: Fixtures.root.appendingPathComponent("scripts/make-icon.sh"), encoding: .utf8)
        for (name, geometry) in [("regular", CommonBrandMark.Geometry.regular), ("small", CommonBrandMark.Geometry.small)] {
            let line = "let \(name) = Mark(radius: \(Int(geometry.radius)), stroke: \(Int(geometry.stroke)), dot: \(Int(geometry.dot)), "
                + "clearance: \(Int(geometry.clearance)))"
            #expect(script.contains(line), "make-icon.sh has no line \(line)")
        }
        #expect(script.contains("let gapAngle: CGFloat = -45 * .pi / 180"))
        #expect(script.contains("let cornerRadius: CGFloat = 185.4"))
        #expect(script.contains("colour(0x454CC2), indigoBottom = colour(0x1E2266)"))
    }

    // ---- helpers ----

    private func expectColor(_ colour: Color, hex: UInt32, alpha: CGFloat = 1) throws {
        let srgb = try #require(NSColor(colour).usingColorSpace(.sRGB))
        let expected = [CGFloat((hex >> 16) & 0xFF), CGFloat((hex >> 8) & 0xFF), CGFloat(hex & 0xFF)].map { $0 / 255 }
        let actual = [srgb.redComponent, srgb.greenComponent, srgb.blueComponent]
        for (a, e) in zip(actual, expected) { #expect(abs(a - e) < 0.002, "\(colour): \(actual) is not #\(String(hex, radix: 16))") }
        #expect(abs(srgb.alphaComponent - alpha) < 0.002)
    }

    private func resolved(_ colour: NSColor, in appearance: NSAppearance.Name) -> NSColor? {
        var result: NSColor?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            result = colour.usingColorSpace(.sRGB)
        }
        return result
    }

    private func luminance(_ colour: NSColor) -> CGFloat {
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(colour.redComponent) + 0.7152 * linear(colour.greenComponent) + 0.0722 * linear(colour.blueComponent)
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    private func hueDistance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let difference = abs(a.hueComponent - b.hueComponent) * 360
        return min(difference, 360 - difference)
    }

    /// The dot's centre in points, y down, in a mark of `size` points.
    private func dotCentre(size: CGFloat, style: CommonBrandMark.Style) -> CGPoint {
        let geometry = CommonBrandMark.geometry(size: size, style: style)
        let unit = size / CommonBrandMark.canvas(for: style)
        let angle = CommonBrandMark.Geometry.gapAngle.radians
        return CGPoint(x: size / 2 + cos(angle) * geometry.radius * unit, y: size / 2 + sin(angle) * geometry.radius * unit)
    }

    /// The view drawn at 2x into RGBA bytes (sRGB).
    @MainActor private func render<V: View>(_ view: V, scheme: ColorScheme) throws -> Pixels {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        return try #require(Pixels(image, scale: 2))
    }

    /// A failed expectation prints this, not the bytes.
    private struct Pixels: CustomTestStringConvertible {
        let width: Int, height: Int, scale: CGFloat
        let bytes: [UInt8]
        var testDescription: String { "\(width) × \(height) px" }

        init?(_ image: CGImage, scale: CGFloat) {
            let (w, h) = (image.width, image.height)
            var buffer = [UInt8](repeating: 0, count: w * h * 4)
            guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
                guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard drawn else { return nil }
            (width, height, self.scale, bytes) = (w, h, scale, buffer)
        }

        /// The pixel under a point (y down), as straight RGBA.
        func rgba(at point: CGPoint) -> (r: Int, g: Int, b: Int, a: Int) {
            let x = min(width - 1, max(0, Int(point.x * scale))), y = min(height - 1, max(0, Int(point.y * scale)))
            let i = (y * width + x) * 4
            let a = Int(bytes[i + 3])
            guard a > 0 else { return (0, 0, 0, 0) }
            func straight(_ c: UInt8) -> Int { min(255, Int(c) * 255 / a) }
            return (straight(bytes[i]), straight(bytes[i + 1]), straight(bytes[i + 2]), a)
        }

        func alpha(at point: CGPoint) -> Int { rgba(at: point).a }

        func isClose(at point: CGPoint, to hex: UInt32) -> Bool {
            let p = rgba(at: point)
            let e = (Int((hex >> 16) & 0xFF), Int((hex >> 8) & 0xFF), Int(hex & 0xFF))
            return p.a > 240 && abs(p.r - e.0) <= 6 && abs(p.g - e.1) <= 6 && abs(p.b - e.2) <= 6
        }
    }
}
