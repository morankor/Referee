import SwiftUI

/// The brand (docs/brand/brand.md): the app's name in each of its forms, the tagline, the colours of the mark and the
/// wordmark's type. The shell's welcome window, About panel and Help window read it; nothing in a review window does.
///
/// The colours here belong to the mark and the icon only. Controls keep the system accent colour, and no brand colour
/// is used on text, tags or highlights, whose hues carry meaning (plan.md section 9.10).
enum CommonBrand {
    // ---- the name ----

    /// The app's name wherever a person reads it: the menu bar, window titles, the About panel, Finder, the README.
    static let name = "Human in the Loop"
    /// The name where a space cannot go, such as the product token of the User-Agent header ("HumanInTheLoop/0.1.0").
    static let token = "HumanInTheLoop"
    /// The name the app had until step 5. Its data folders are moved from this name once (brand.md, "Rename").
    static let formerName = "Referee"
    /// The line under the name: who does what.
    static let tagline = "AI drafts. You referee."
    /// What the app is, in the words of a subtitle: the About panel and the README's first line.
    static let descriptor = "A PDF reader for refereeing papers with AI"

    /// The application menu's items and the windows that carry the name (macOS conventions).
    static let aboutItemTitle = "About \(name)"
    static let hideItemTitle = "Hide \(name)"
    static let quitItemTitle = "Quit \(name)"
    static let helpItemTitle = "\(name) Help"
    static let welcomeItemTitle = "Welcome to \(name)"

    // ---- colour (sRGB) ----

    /// Indigo ink, #23285E: the mark on light surfaces and the wordmark in documents.
    static let ink = srgb(0x23285E)
    /// Paper, #F4F1EA: the mark on dark surfaces.
    static let paper = srgb(0xF4F1EA)
    /// The icon's rounded square, top to bottom: #454CC2 to #1E2266.
    static let indigoTop = srgb(0x454CC2)
    static let indigoBottom = srgb(0x1E2266)
    /// The mark on the icon: the loop in a cool white at 92%, the dot in a warm white, the most solid thing on it.
    static let tileLoop = srgb(0xE8EBFF, opacity: 0.92)
    static let tileDot = srgb(0xFFF5E8)

    /// The bare mark's colour: indigo ink in the light appearance, paper in the dark one.
    static let mark = MarkStyle()

    /// Resolves to `ink` or `paper` from the view's colour scheme, so the mark follows its window's appearance.
    struct MarkStyle: ShapeStyle {
        func resolve(in environment: EnvironmentValues) -> Color {
            environment.colorScheme == .dark ? CommonBrand.paper : CommonBrand.ink
        }
    }

    // ---- type ----

    /// The wordmark's tracking, in ems: SF Pro Semibold set 1% tighter.
    static let wordmarkTracking: CGFloat = -0.01
    /// "in the" in New York Italic is set 4% larger than the nouns, so that its smaller x-height matches theirs.
    static let connectiveScale: CGFloat = 1.04
    /// Below this size the name is plain text in the system font: two typefaces at a small size look fussy.
    static let minimumWordmarkSize: CGFloat = 20

    /// The wordmark: "Human" and "Loop" in SF Pro Semibold in the primary colour, "in the" in New York Italic in the
    /// secondary colour. Text built from it follows the light or dark appearance.
    ///
    ///     Text(CommonBrand.wordmark(size: 24))        // the welcome window
    static func wordmark(size: CGFloat) -> AttributedString {
        var human = AttributedString("Human ")
        var connective = AttributedString("in the ")
        var loop = AttributedString("Loop")
        human.font = .system(size: size, weight: .semibold)
        human.tracking = wordmarkTracking * size
        human.foregroundColor = .primary
        loop.font = .system(size: size, weight: .semibold)
        loop.tracking = wordmarkTracking * size
        loop.foregroundColor = .primary
        connective.font = .system(size: size * connectiveScale, weight: .regular, design: .serif).italic()
        connective.foregroundColor = .secondary
        return human + connective + loop
    }

    private static func srgb(_ hex: UInt32, opacity: Double = 1) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}
