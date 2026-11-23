// The three logo concepts explored for Human in the Loop (docs/brand/brand.md, "Concepts"), each drawn as a macOS
// icon at 1024 pixels and shown at 256, 128, 64, 32 and 16 pixels on a light and a dark background, with the 32- and
// 16-pixel images magnified pixel for pixel. Usage: swift scripts/brand/concepts.swift <output folder>
// (scripts/brand/render.sh runs it). Concept A is the one chosen; scripts/make-icon.sh draws its final form.
import Foundation
import AppKit
import CoreGraphics
import CoreText
import ImageIO

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
    let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    if !CGImageDestinationFinalize(destination) { print("concepts.swift: could not write \(path)") }
}

// ---- the tile all three share: the macOS rounded square (824 of 1024 units, continuous corners), indigo ----

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let indigoTop: UInt32 = 0x454CC2, indigoBottom: UInt32 = 0x1E2266
let coolWhite: UInt32 = 0xE8EBFF, warmWhite: UInt32 = 0xFFF5E8, ink: UInt32 = 0x23285E

func continuousRect(_ rect: CGRect, radius r: CGFloat, smoothing xi: CGFloat = 0.6) -> CGPath {
    let p = min((1 + xi) * r, min(rect.width, rect.height) / 2)
    let arcMeasure = 90 * (1 - xi)
    let arcLength = sin(rad(arcMeasure / 2)) * r * sqrt(2)
    let alpha = (90 - arcMeasure) / 2
    let c = r * tan(rad(alpha / 2)) * cos(rad(45 * xi))
    let d = c * tan(rad(45 * xi))
    let b = (p - arcLength - c - d) / 3
    let a = 2 * b
    let (x0, y0, w, h) = (rect.minX, rect.minY, rect.width, rect.height)
    let path = CGMutablePath()
    path.move(to: CGPoint(x: x0 + p, y: y0))
    path.addLine(to: CGPoint(x: x0 + w - p, y: y0))
    path.addCurve(to: CGPoint(x: x0 + w - p + a + b + c, y: y0 + d), control1: CGPoint(x: x0 + w - p + a, y: y0), control2: CGPoint(x: x0 + w - p + a + b, y: y0))
    path.addArc(center: CGPoint(x: x0 + w - r, y: y0 + r), radius: r, startAngle: rad(alpha - 90), endAngle: rad(-alpha), clockwise: false)
    path.addCurve(to: CGPoint(x: x0 + w, y: y0 + p), control1: CGPoint(x: x0 + w, y: y0 + p - a - b), control2: CGPoint(x: x0 + w, y: y0 + p - a))
    path.addLine(to: CGPoint(x: x0 + w, y: y0 + h - p))
    path.addCurve(to: CGPoint(x: x0 + w - d, y: y0 + h - p + a + b + c), control1: CGPoint(x: x0 + w, y: y0 + h - p + a), control2: CGPoint(x: x0 + w, y: y0 + h - p + a + b))
    path.addArc(center: CGPoint(x: x0 + w - r, y: y0 + h - r), radius: r, startAngle: rad(alpha), endAngle: rad(90 - alpha), clockwise: false)
    path.addCurve(to: CGPoint(x: x0 + w - p, y: y0 + h), control1: CGPoint(x: x0 + w - p + a + b, y: y0 + h), control2: CGPoint(x: x0 + w - p + a, y: y0 + h))
    path.addLine(to: CGPoint(x: x0 + p, y: y0 + h))
    path.addCurve(to: CGPoint(x: x0 + p - a - b - c, y: y0 + h - d), control1: CGPoint(x: x0 + p - a, y: y0 + h), control2: CGPoint(x: x0 + p - a - b, y: y0 + h))
    path.addArc(center: CGPoint(x: x0 + r, y: y0 + h - r), radius: r, startAngle: rad(90 + alpha), endAngle: rad(180 - alpha), clockwise: false)
    path.addCurve(to: CGPoint(x: x0, y: y0 + h - p), control1: CGPoint(x: x0, y: y0 + h - p + a + b), control2: CGPoint(x: x0, y: y0 + h - p + a))
    path.addLine(to: CGPoint(x: x0, y: y0 + p))
    path.addCurve(to: CGPoint(x: x0 + d, y: y0 + p - a - b - c), control1: CGPoint(x: x0, y: y0 + p - a), control2: CGPoint(x: x0, y: y0 + p - a - b))
    path.addArc(center: CGPoint(x: x0 + r, y: y0 + r), radius: r, startAngle: rad(180 + alpha), endAngle: rad(270 - alpha), clockwise: false)
    path.addCurve(to: CGPoint(x: x0 + p, y: y0), control1: CGPoint(x: x0 + p - a - b, y: y0), control2: CGPoint(x: x0 + p - a, y: y0))
    path.closeSubpath()
    return path
}

func drawTile(_ cg: CGContext) {
    cg.saveGState()
    cg.addPath(continuousRect(body, radius: 185.4))
    cg.clip()
    let gradient = CGGradient(colorsSpace: sRGB, colors: [rgb(indigoTop), rgb(indigoBottom)] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY), options: [])
    cg.restoreGState()
}

/// A loop round the canvas's centre, open at `gap` degrees (y down: -45 is the upper right), `halfGap` radians either side.
func strokeLoop(_ cg: CGContext, radius: CGFloat, stroke: CGFloat, gap: CGFloat, halfGap: CGFloat) {
    let path = CGMutablePath()
    path.addArc(center: CGPoint(x: 512, y: 512), radius: radius, startAngle: rad(gap) + halfGap, endAngle: rad(gap) - halfGap + 2 * .pi, clockwise: false)
    cg.setStrokeColor(rgb(coolWhite, 0.92))
    cg.setLineWidth(stroke)
    cg.setLineCap(.round)
    cg.addPath(path)
    cg.strokePath()
}

// ---- concept A: the bead, a loop with a human mark (chosen) ----

func conceptA(_ cg: CGContext, pixels: Int, gap: CGFloat = -45) {
    drawTile(cg)
    let (radius, stroke, dot, clearance): (CGFloat, CGFloat, CGFloat, CGFloat) = pixels <= 32 ? (236, 124, 161, 68) : (250, 92, 136, 28)
    strokeLoop(cg, radius: radius, stroke: stroke, gap: gap, halfGap: (dot / 2 + clearance + stroke / 2) / radius)
    let centre = CGPoint(x: 512 + radius * cos(rad(gap)), y: 512 + radius * sin(rad(gap)))
    cg.setFillColor(rgb(warmWhite))
    cg.fillEllipse(in: CGRect(x: centre.x - dot / 2, y: centre.y - dot / 2, width: dot, height: dot))
}

// ---- concept B: the margin loop, a page with a passage circled ----

/// One stroke a little over a full turn whose end drifts outwards, as a pen circles a phrase.
func handLoop(center: CGPoint, rx: CGFloat, ry: CGFloat, tilt: CGFloat) -> CGPath {
    let path = CGMutablePath()
    for i in 0...240 {
        let t = CGFloat(i) / 240
        let angle = rad(200 + 395 * t)
        let grow = 1 + 0.10 * t
        let x = rx * grow * cos(angle), y = ry * grow * sin(angle)
        let point = CGPoint(x: center.x + x * cos(rad(tilt)) - y * sin(rad(tilt)), y: center.y + x * sin(rad(tilt)) + y * cos(rad(tilt)))
        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    return path
}

func conceptB(_ cg: CGContext, pixels: Int) {
    drawTile(cg)
    let small = pixels <= 32
    let page = CGRect(x: 262, y: 196, width: 500, height: 632)
    let fold: CGFloat = small ? 0 : 128
    let sheet = CGMutablePath()
    sheet.move(to: CGPoint(x: page.minX, y: page.minY))
    sheet.addLine(to: CGPoint(x: page.maxX - fold, y: page.minY))
    sheet.addLine(to: CGPoint(x: page.maxX, y: page.minY + fold))
    sheet.addLine(to: CGPoint(x: page.maxX, y: page.maxY))
    sheet.addLine(to: CGPoint(x: page.minX, y: page.maxY))
    sheet.closeSubpath()
    cg.setFillColor(rgb(0xFBF8F1))
    cg.addPath(sheet)
    cg.fillPath()
    if fold > 0 {
        cg.setFillColor(rgb(0xD9D4C7))
        cg.move(to: CGPoint(x: page.maxX - fold, y: page.minY))
        cg.addLine(to: CGPoint(x: page.maxX - fold, y: page.minY + fold))
        cg.addLine(to: CGPoint(x: page.maxX, y: page.minY + fold))
        cg.closePath()
        cg.fillPath()
        cg.setFillColor(rgb(indigoBottom, 0.26))
        for (y, width) in [(0.17, 0.50), (0.29, 1.0), (0.41, 0.92), (0.53, 1.0), (0.65, 0.96), (0.77, 0.70)] as [(CGFloat, CGFloat)] {
            let line = CGRect(x: page.minX + 60, y: page.minY + page.height * y - 15, width: (page.width - 120) * width, height: 30)
            cg.addPath(CGPath(roundedRect: line, cornerWidth: 15, cornerHeight: 15, transform: nil))
            cg.fillPath()
        }
    }
    let centre = CGPoint(x: small ? 512 : 560, y: page.minY + page.height * (small ? 0.50 : 0.53))
    cg.setStrokeColor(rgb(0x2A2F8F))
    cg.setLineWidth(small ? 70 : 30)
    cg.setLineCap(.round)
    cg.setLineJoin(.round)
    cg.addPath(handLoop(center: centre, rx: small ? 190 : 150, ry: small ? 112 : 74, tilt: -5))
    cg.strokePath()
}

// ---- concept C: the nib, a pen closing the loop ----

func conceptC(_ cg: CGContext, pixels: Int) {
    drawTile(cg)
    let small = pixels <= 32
    let stroke: CGFloat = small ? 128 : 104, radius: CGFloat = small ? 236 : 250
    let gap = rad(-45), halfGap = rad(small ? 44 : 38)
    strokeLoop(cg, radius: radius, stroke: stroke, gap: -45, halfGap: halfGap)
    // The nib lies across the gap: its tip just past the end of the stroke, its shoulders towards the stroke's start.
    let end = CGPoint(x: 512 + radius * cos(gap - halfGap), y: 512 + radius * sin(gap - halfGap))
    let start = CGPoint(x: 512 + radius * cos(gap + halfGap), y: 512 + radius * sin(gap + halfGap))
    let chord = hypot(start.x - end.x, start.y - end.y)
    let along = CGPoint(x: (start.x - end.x) / chord, y: (start.y - end.y) / chord)
    let length = chord - stroke * (small ? 1.35 : 1.15), width = stroke * (small ? 1.5 : 1.55)
    cg.saveGState()
    cg.translateBy(x: end.x + along.x * stroke * 0.40, y: end.y + along.y * stroke * 0.40)
    cg.rotate(by: atan2(along.y, along.x) - .pi / 2)
    let nib = CGMutablePath()
    nib.move(to: .zero)
    nib.addCurve(to: CGPoint(x: width / 2, y: length * 0.64), control1: CGPoint(x: width * 0.12, y: length * 0.16), control2: CGPoint(x: width / 2, y: length * 0.38))
    nib.addLine(to: CGPoint(x: width / 2, y: length))
    nib.addLine(to: CGPoint(x: -width / 2, y: length))
    nib.addLine(to: CGPoint(x: -width / 2, y: length * 0.64))
    nib.addCurve(to: .zero, control1: CGPoint(x: -width / 2, y: length * 0.38), control2: CGPoint(x: -width * 0.12, y: length * 0.16))
    nib.closeSubpath()
    cg.setFillColor(rgb(warmWhite))
    cg.addPath(nib)
    cg.fillPath()
    if !small {
        cg.setStrokeColor(rgb(indigoBottom))
        cg.setLineWidth(12)
        cg.setLineCap(.round)
        cg.move(to: CGPoint(x: 0, y: length * 0.12))
        cg.addLine(to: CGPoint(x: 0, y: length * 0.50))
        cg.strokePath()
        cg.setFillColor(rgb(indigoBottom))
        let hole = width * 0.12
        cg.fillEllipse(in: CGRect(x: -hole, y: length * 0.55 - hole, width: 2 * hole, height: 2 * hole))
    }
    cg.restoreGState()
}

// ---- rendering ----

/// The icon at `pixels` × `pixels`, drawn on a 1024-unit canvas with y down.
func icon(_ pixels: Int, _ draw: (CGContext, Int) -> Void) -> CGImage {
    let cg = bitmap(pixels, pixels)
    cg.translateBy(x: 0, y: CGFloat(pixels))
    cg.scaleBy(x: CGFloat(pixels) / 1024, y: -CGFloat(pixels) / 1024)
    draw(cg, pixels)
    return cg.makeImage()!
}

func label(_ cg: CGContext, _ text: String, at point: CGPoint, size: CGFloat, color: CGColor, weight: NSFont.Weight = .regular) {
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                     .foregroundColor: NSColor(cgColor: color) ?? .black]
    cg.textPosition = point
    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), cg)
}

/// On a light and a dark band: the icon at 256, 128, 64, 32 and 16 pixels; the 32 and 16 pixel images magnified
/// with nearest-neighbour sampling; a Finder list row at 16 points on a Retina display (a 32-pixel image).
func sheet(title: String, note: String, draw: @escaping (CGContext, Int) -> Void, path: String) {
    let width = 1500, band = 470, header = 110
    let cg = bitmap(width, 2 * band + header)
    cg.setFillColor(rgb(0xFFFFFF))
    cg.fill(CGRect(x: 0, y: 0, width: width, height: 2 * band + header))
    label(cg, title, at: CGPoint(x: 40, y: CGFloat(2 * band + 62)), size: 30, color: rgb(0x1D1D1F), weight: .semibold)
    label(cg, note, at: CGPoint(x: 40, y: CGFloat(2 * band + 24)), size: 19, color: rgb(0x1D1D1F, 0.6))
    for (index, (background, text, name)) in [(0xF5F5F7, 0x1D1D1F, "light"), (0x1E1E20, 0xF2F2F7, "dark")].enumerated() {
        let y0 = CGFloat((1 - index) * band)
        cg.setFillColor(rgb(UInt32(background)))
        cg.fill(CGRect(x: 0, y: y0, width: CGFloat(width), height: CGFloat(band)))
        var x: CGFloat = 40
        let base = y0 + 64
        for size in [256, 128, 64, 32, 16] {
            cg.draw(icon(size, draw), in: CGRect(x: x, y: base, width: CGFloat(size), height: CGFloat(size)))
            label(cg, "\(size) px", at: CGPoint(x: x, y: base - 32), size: 17, color: rgb(UInt32(text), 0.6))
            x += CGFloat(size) + (size == 16 ? 64 : 40)
        }
        for (size, scale) in [(32, 8), (16, 14)] {
            cg.interpolationQuality = .none
            cg.draw(icon(size, draw), in: CGRect(x: x, y: base, width: CGFloat(size * scale), height: CGFloat(size * scale)))
            cg.interpolationQuality = .default
            label(cg, "\(size) px, ×\(scale)", at: CGPoint(x: x, y: base - 32), size: 17, color: rgb(UInt32(text), 0.6))
            x += CGFloat(size * scale) + 56
        }
        let row = y0 + CGFloat(band) - 84
        cg.draw(icon(32, draw), in: CGRect(x: 40, y: row, width: 32, height: 32))
        label(cg, "Human in the Loop", at: CGPoint(x: 84, y: row + 8), size: 26, color: rgb(UInt32(text)))
        label(cg, "Finder list row, 16 pt on a Retina display (\(name))", at: CGPoint(x: 330, y: row + 8), size: 17, color: rgb(UInt32(text), 0.5))
    }
    save(cg.makeImage()!, path)
}

/// The three concepts side by side at 256, 32 and 16 pixels (the small ones magnified), on light and on dark.
func comparison(_ concepts: [(String, (CGContext, Int) -> Void)], path: String) {
    let column = 470, width = column * concepts.count + 40, height = 760
    let cg = bitmap(width, height)
    cg.setFillColor(rgb(0xF5F5F7)); cg.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
    cg.setFillColor(rgb(0x1E1E20)); cg.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
    for (i, (name, draw)) in concepts.enumerated() {
        for (band, text) in [(1, 0x1D1D1F), (0, 0xF2F2F7)] as [(Int, UInt32)] {
            let x = CGFloat(40 + i * column), y0 = CGFloat(band * height / 2)
            cg.draw(icon(256, draw), in: CGRect(x: x, y: y0 + 70, width: 256, height: 256))
            cg.interpolationQuality = .none
            cg.draw(icon(32, draw), in: CGRect(x: x + 270, y: y0 + 198, width: 128, height: 128))
            cg.draw(icon(16, draw), in: CGRect(x: x + 270, y: y0 + 70, width: 112, height: 112))
            cg.interpolationQuality = .default
            label(cg, name, at: CGPoint(x: x, y: y0 + 32), size: 19, color: rgb(text, 0.75), weight: .medium)
        }
    }
    save(cg.makeImage()!, path)
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let concepts: [(file: String, title: String, note: String, draw: (CGContext, Int) -> Void)] = [
    ("concept-a-bead", "A · The bead: a loop with a human mark (chosen)",
     "The loop is open until the dot, the human, closes it. Two large shapes; still a loop and a dot at 16 px.",
     { conceptA($0, pixels: $1) }),
    ("concept-a-variant-top-gap", "A, variant · The gap at the top (rejected)",
     "With the dot at twelve o'clock the mark reads as a power button.",
     { conceptA($0, pixels: $1, gap: -90) }),
    ("concept-b-page", "B · The margin loop: a page with a passage circled",
     "Literal and clear at 256 px; below 64 px a generic document icon with a blob.",
     { conceptB($0, pixels: $1) }),
    ("concept-c-nib", "C · The nib: a pen closing the loop",
     "Charming at 256 px; below 64 px the nib becomes an arrowhead and the mark reads as Reload.",
     { conceptC($0, pixels: $1) }),
]
for concept in concepts {
    if !concept.file.contains("variant") { save(icon(1024, concept.draw), "\(out)/\(concept.file)-1024.png") }
    sheet(title: concept.title, note: concept.note, draw: concept.draw, path: "\(out)/\(concept.file)-sizes.png")
}
comparison([("A · the bead", { conceptA($0, pixels: $1) }), ("B · the margin loop", { conceptB($0, pixels: $1) }),
            ("C · the nib", { conceptC($0, pixels: $1) })], path: "\(out)/concepts-compared.png")
print("Rendered the concepts into \(out)")
