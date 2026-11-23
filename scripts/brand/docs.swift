// The brand's files in docs/brand, made from the same numbers as scripts/make-icon.sh and CommonBrandMark
// (docs/brand/brand.md): logo.svg, wordmark.svg, app-icon.svg, icon-sizes.png (the images of the built iconset, as
// they are) and the README hero in light and dark. Usage: swift scripts/brand/docs.swift <iconset folder> <output folder>
// (scripts/brand/render.sh runs it after scripts/make-icon.sh).
import Foundation
import AppKit
import CoreGraphics
import CoreText
import ImageIO

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("docs.swift: \(message)\n".utf8))
    exit(1)
}
guard CommandLine.arguments.count == 3 else { fail("usage: swift scripts/brand/docs.swift <iconset folder> <output folder>") }
let iconset = CommandLine.arguments[1], out = CommandLine.arguments[2]

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
func rad(_ degrees: CGFloat) -> CGFloat { degrees * .pi / 180 }
func bitmap(_ width: Int, _ height: Int) -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
func save(_ image: CGImage, _ path: String) {
    guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
    else { fail("could not create \(path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("could not write \(path)") }
}
func load(_ name: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: "\(iconset)/\(name)") as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("no \(iconset)/\(name): run scripts/make-icon.sh first") }
    return image
}
func write(_ text: String, _ path: String) {
    do { try text.write(toFile: path, atomically: true, encoding: .utf8) } catch { fail("could not write \(path)") }
}
func n(_ value: CGFloat) -> String { String(format: "%.2f", Double(value)).replacingOccurrences(of: ".00", with: "") }

// ---- brand.md's numbers ----

let ink: UInt32 = 0x23285E, paper: UInt32 = 0xF4F1EA
struct Mark { let radius, stroke, dot, clearance: CGFloat }
let regular = Mark(radius: 250, stroke: 92, dot: 136, clearance: 28)
let gap: CGFloat = -45
var halfGap: CGFloat { (regular.dot / 2 + regular.clearance + regular.stroke / 2) / regular.radius }

/// The loop's path data round `centre`, and the dot's centre (y down, as SVG draws).
func loopPath(centre: CGPoint) -> (path: String, dot: CGPoint) {
    let start = rad(gap) + halfGap, end = rad(gap) - halfGap + 2 * .pi
    let from = CGPoint(x: centre.x + regular.radius * cos(start), y: centre.y + regular.radius * sin(start))
    let to = CGPoint(x: centre.x + regular.radius * cos(end), y: centre.y + regular.radius * sin(end))
    let r = n(regular.radius)
    let dot = CGPoint(x: centre.x + regular.radius * cos(rad(gap)), y: centre.y + regular.radius * sin(rad(gap)))
    return ("M\(n(from.x)) \(n(from.y))A\(r) \(r) 0 1 1 \(n(to.x)) \(n(to.y))", dot)
}

/// SVG path data of the icon's rounded square: continuous corners as make-icon.sh draws them.
func continuousRectPath(_ rect: CGRect, radius r: CGFloat, smoothing xi: CGFloat = 0.6) -> String {
    let p = min((1 + xi) * r, min(rect.width, rect.height) / 2)
    let arcMeasure = 90 * (1 - xi)
    let arcLength = sin(rad(arcMeasure / 2)) * r * sqrt(2)
    let alpha = (90 - arcMeasure) / 2
    let c = r * tan(rad(alpha / 2)) * cos(rad(45 * xi))
    let d = c * tan(rad(45 * xi))
    let b = (p - arcLength - c - d) / 3
    let a = 2 * b
    let (x0, y0, w, h) = (rect.minX, rect.minY, rect.width, rect.height)
    func pt(_ x: CGFloat, _ y: CGFloat) -> String { "\(n(x)) \(n(y))" }
    let arc = "A\(n(r)) \(n(r)) 0 0 1 "
    return "M\(pt(x0 + p, y0))"
        + "L\(pt(x0 + w - p, y0))C\(pt(x0 + w - p + a, y0)) \(pt(x0 + w - p + a + b, y0)) \(pt(x0 + w - p + a + b + c, y0 + d))"
        + arc + pt(x0 + w - d, y0 + p - a - b - c)
        + "C\(pt(x0 + w, y0 + p - a - b)) \(pt(x0 + w, y0 + p - a)) \(pt(x0 + w, y0 + p))"
        + "L\(pt(x0 + w, y0 + h - p))C\(pt(x0 + w, y0 + h - p + a)) \(pt(x0 + w, y0 + h - p + a + b)) \(pt(x0 + w - d, y0 + h - p + a + b + c))"
        + arc + pt(x0 + w - p + a + b + c, y0 + h - d)
        + "C\(pt(x0 + w - p + a + b, y0 + h)) \(pt(x0 + w - p + a, y0 + h)) \(pt(x0 + w - p, y0 + h))"
        + "L\(pt(x0 + p, y0 + h))C\(pt(x0 + p - a, y0 + h)) \(pt(x0 + p - a - b, y0 + h)) \(pt(x0 + p - a - b - c, y0 + h - d))"
        + arc + pt(x0 + d, y0 + h - p + a + b + c)
        + "C\(pt(x0, y0 + h - p + a + b)) \(pt(x0, y0 + h - p + a)) \(pt(x0, y0 + h - p))"
        + "L\(pt(x0, y0 + p))C\(pt(x0, y0 + p - a)) \(pt(x0, y0 + p - a - b)) \(pt(x0 + d, y0 + p - a - b - c))"
        + arc + pt(x0 + p - a - b - c, y0 + d)
        + "C\(pt(x0 + p - a - b, y0)) \(pt(x0 + p - a, y0)) \(pt(x0 + p, y0))Z"
}

// ---- type: the wordmark, "Human" and "Loop" in SF Pro Semibold, "in the" in New York Italic ----

func sfPro(_ size: CGFloat) -> NSFont { NSFont.systemFont(ofSize: size, weight: .semibold) }
func newYorkItalic(_ size: CGFloat) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: .regular).fontDescriptor
    guard let serif = base.withDesign(.serif) else { fail("New York is not installed") }
    return NSFont(descriptor: serif.withSymbolicTraits(.italic), size: size) ?? NSFont.systemFont(ofSize: size)
}
func wordmark(size: CGFloat, noun: CGColor, connective: CGColor) -> NSAttributedString {
    let text = NSMutableAttributedString()
    let tracking = -0.01 * size
    text.append(NSAttributedString(string: "Human ", attributes: [.font: sfPro(size), .foregroundColor: NSColor(cgColor: noun)!, .kern: tracking]))
    text.append(NSAttributedString(string: "in the ", attributes: [.font: newYorkItalic(size * 1.04), .foregroundColor: NSColor(cgColor: connective)!]))
    text.append(NSAttributedString(string: "Loop", attributes: [.font: sfPro(size), .foregroundColor: NSColor(cgColor: noun)!, .kern: tracking]))
    return text
}
func width(of text: NSAttributedString) -> CGFloat {
    CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text), nil, nil, nil)
}

// ---- logo.svg: the mark, ink on light and paper on dark ----

let style = """
  <style>
    .ink { fill: #23285E; } .loop { fill: none; stroke: #23285E; } .soft { fill: #23285E; fill-opacity: 0.62; }
    @media (prefers-color-scheme: dark) {
      .ink { fill: #F4F1EA; } .loop { stroke: #F4F1EA; } .soft { fill: #F4F1EA; fill-opacity: 0.62; }
    }
  </style>
"""
do {
    let mark = loopPath(centre: CGPoint(x: 320, y: 320))
    write("""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 640 640" width="640" height="640" role="img" aria-labelledby="title">
      <title id="title">Human in the Loop</title>
    \(style)
      <path class="loop" d="\(mark.path)" stroke-width="\(n(regular.stroke))" stroke-linecap="round"/>
      <circle class="ink" cx="\(n(mark.dot.x))" cy="\(n(mark.dot.y))" r="\(n(regular.dot / 2))"/>
    </svg>

    """, "\(out)/logo.svg")
}

// ---- wordmark.svg: the mark and the name (live text in the system fonts; Apple's font outlines are not embedded) ----

do {
    let size: CGFloat = 56, markBox: CGFloat = 72
    let scale = markBox / 640
    let mark = loopPath(centre: CGPoint(x: 320, y: 320))
    let measured = width(of: wordmark(size: size, noun: rgb(ink), connective: rgb(ink)))
    let textX = markBox + 20
    let baseline = (markBox / 2 + sfPro(size).capHeight / 2).rounded()
    let total = (textX + measured + 8).rounded(.up)
    write("""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(n(total)) \(n(markBox))" width="\(n(total))" height="\(n(markBox))" role="img" aria-labelledby="title">
      <title id="title">Human in the Loop</title>
    \(style)
      <g transform="scale(\(String(format: "%.4f", Double(scale))))">
        <path class="loop" d="\(mark.path)" stroke-width="\(n(regular.stroke))" stroke-linecap="round"/>
        <circle class="ink" cx="\(n(mark.dot.x))" cy="\(n(mark.dot.y))" r="\(n(regular.dot / 2))"/>
      </g>
      <text x="\(n(textX))" y="\(n(baseline))" font-size="\(n(size))" xml:space="preserve"><tspan class="ink" font-family="-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Helvetica Neue', Helvetica, Arial, sans-serif" font-weight="600" letter-spacing="\(n(-0.01 * size))">Human </tspan><tspan class="soft" font-family="'New York', ui-serif, 'Iowan Old Style', Georgia, serif" font-style="italic" font-size="\(n(size * 1.04))">in the </tspan><tspan class="ink" font-family="-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Helvetica Neue', Helvetica, Arial, sans-serif" font-weight="600" letter-spacing="\(n(-0.01 * size))">Loop</tspan></text>
    </svg>

    """, "\(out)/wordmark.svg")
}

// ---- app-icon.svg: the icon at 1024 units, for reference (the app ships build/AppIcon.icns) ----

do {
    let mark = loopPath(centre: CGPoint(x: 512, y: 512))
    write("""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024" role="img" aria-labelledby="title">
      <title id="title">Human in the Loop app icon</title>
      <defs>
        <linearGradient id="indigo" x1="0" y1="100" x2="0" y2="924" gradientUnits="userSpaceOnUse">
          <stop offset="0" stop-color="#454CC2"/>
          <stop offset="1" stop-color="#1E2266"/>
        </linearGradient>
      </defs>
      <path d="\(continuousRectPath(CGRect(x: 100, y: 100, width: 824, height: 824), radius: 185.4))" fill="url(#indigo)"/>
      <path d="\(mark.path)" fill="none" stroke="#E8EBFF" stroke-opacity="0.92" stroke-width="\(n(regular.stroke))" stroke-linecap="round"/>
      <circle cx="\(n(mark.dot.x))" cy="\(n(mark.dot.y))" r="\(n(regular.dot / 2))" fill="#FFF5E8"/>
    </svg>

    """, "\(out)/app-icon.svg")
}

// ---- icon-sizes.png: the images of the built iconset at their own size, and the small ones magnified ----

func label(_ cg: CGContext, _ text: String, at point: CGPoint, size: CGFloat, color: CGColor, weight: NSFont.Weight = .regular) {
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: NSColor(cgColor: color)!]
    cg.textPosition = point
    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), cg)
}

do {
    let images: [(String, Int, String)] = [("icon_128x128@2x.png", 256, "256 px"), ("icon_128x128.png", 128, "128 px"),
                                           ("icon_32x32@2x.png", 64, "64 px"), ("icon_32x32.png", 32, "32 px"), ("icon_16x16.png", 16, "16 px")]
    let width = 1500, band = 470, header = 110
    let cg = bitmap(width, 2 * band + header)
    cg.setFillColor(rgb(0xFFFFFF))
    cg.fill(CGRect(x: 0, y: 0, width: width, height: 2 * band + header))
    label(cg, "The icon as built: build/AppIcon.iconset", at: CGPoint(x: 40, y: CGFloat(2 * band + 62)), size: 30, color: rgb(0x1D1D1F), weight: .semibold)
    label(cg, "Each image drawn at its own pixel size by scripts/make-icon.sh; 16 and 32 px with the heavier loop and wider gap.",
          at: CGPoint(x: 40, y: CGFloat(2 * band + 24)), size: 19, color: rgb(0x1D1D1F, 0.6))
    for (index, (background, text, name)) in [(0xF5F5F7, 0x1D1D1F, "light"), (0x1E1E20, 0xF2F2F7, "dark")].enumerated() {
        let y0 = CGFloat((1 - index) * band)
        cg.setFillColor(rgb(UInt32(background)))
        cg.fill(CGRect(x: 0, y: y0, width: CGFloat(width), height: CGFloat(band)))
        var x: CGFloat = 40
        let base = y0 + 64
        for (file, size, caption) in images {
            cg.draw(load(file), in: CGRect(x: x, y: base, width: CGFloat(size), height: CGFloat(size)))
            label(cg, caption, at: CGPoint(x: x, y: base - 32), size: 17, color: rgb(UInt32(text), 0.6))
            x += CGFloat(size) + (size == 16 ? 64 : 40)
        }
        for (file, size, scale) in [("icon_16x16@2x.png", 32, 8), ("icon_16x16.png", 16, 14)] {
            cg.interpolationQuality = .none
            cg.draw(load(file), in: CGRect(x: x, y: base, width: CGFloat(size * scale), height: CGFloat(size * scale)))
            cg.interpolationQuality = .default
            label(cg, "\(size) px, ×\(scale)", at: CGPoint(x: x, y: base - 32), size: 17, color: rgb(UInt32(text), 0.6))
            x += CGFloat(size * scale) + 56
        }
        let row = y0 + CGFloat(band) - 84
        cg.draw(load("icon_16x16@2x.png"), in: CGRect(x: 40, y: row, width: 32, height: 32))
        label(cg, "Human in the Loop", at: CGPoint(x: 84, y: row + 8), size: 26, color: rgb(UInt32(text)))
        label(cg, "Finder list row, 16 pt on a Retina display (\(name))", at: CGPoint(x: 330, y: row + 8), size: 17, color: rgb(UInt32(text), 0.5))
    }
    save(cg.makeImage()!, "\(out)/icon-sizes.png")
}

// ---- readme-hero.png and readme-hero-dark.png: icon, wordmark and tagline on a transparent ground (2x) ----

do {
    let icon = load("icon_512x512@2x.png")
    let iconSide: CGFloat = 360, height: CGFloat = 400
    let wordSize: CGFloat = 112, tagSize: CGFloat = 46
    for (file, noun, soft) in [("readme-hero.png", rgb(ink), rgb(ink, 0.62)), ("readme-hero-dark.png", rgb(paper), rgb(paper, 0.62))] {
        let mark = wordmark(size: wordSize, noun: noun, connective: soft)
        let tagline = NSAttributedString(string: "AI drafts. You referee.",
                                         attributes: [.font: NSFont.systemFont(ofSize: tagSize, weight: .regular), .foregroundColor: NSColor(cgColor: soft)!])
        let textX = 20 + iconSide - iconSide * 100 / 1024 + 44          // 44 px after the icon's rounded square
        let canvasWidth = Int((textX + max(width(of: mark), width(of: tagline)) + 48).rounded(.up))
        let cg = bitmap(canvasWidth, Int(height))
        cg.draw(icon, in: CGRect(x: 20, y: (height - iconSide) / 2, width: iconSide, height: iconSide))
        cg.textPosition = CGPoint(x: textX, y: 206)
        CTLineDraw(CTLineCreateWithAttributedString(mark), cg)
        cg.textPosition = CGPoint(x: textX + 4, y: 120)
        CTLineDraw(CTLineCreateWithAttributedString(tagline), cg)
        save(cg.makeImage()!, "\(out)/\(file)")
    }
}
print("Wrote logo.svg, wordmark.svg, app-icon.svg, icon-sizes.png and the README hero into \(out)")
