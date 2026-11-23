#!/bin/bash
# Draws the app icon into build/AppIcon.icns: the mark of Human in the Loop, a loop closed by a dot, on an indigo
# rounded square (docs/brand/brand.md, "Icon"). Usage: scripts/make-icon.sh
# Uses only what macOS and the Command Line Tools ship: swift and iconutil. Each of the ten images of the iconset is
# drawn from the vectors at its own pixel size, the 16- and 32-pixel ones with a heavier loop and a wider gap, so that
# no size is a blurred reduction of a larger one. scripts/bundle.sh calls it when the icon is missing and carries on
# without an icon if it fails.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
SET="build/AppIcon.iconset"
rm -rf "$SET"
mkdir -p "$SET"

REFEREE_ICONSET="$SET" REFEREE_ICON_PNG="build/AppIcon-1024.png" swift - <<'SWIFT'
import Foundation
import CoreGraphics
import ImageIO

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon.sh: \(message)\n".utf8))
    exit(1)
}

// ---- docs/brand/brand.md, "Icon": units of the 1024-unit canvas, y down ----

/// The rounded square: 824 units with 100 units of margin, the macOS template, with continuous corners.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let cornerRadius: CGFloat = 185.4
let cornerSmoothing: CGFloat = 0.6
/// The loop's centre and its gap, centred on the upper right.
let centre = CGPoint(x: 512, y: 512)
let gapAngle: CGFloat = -45 * .pi / 180
struct Mark { let radius, stroke, dot, clearance: CGFloat }
let regular = Mark(radius: 250, stroke: 92, dot: 136, clearance: 28)      // 64 pixels and up
let small = Mark(radius: 236, stroke: 124, dot: 161, clearance: 68)       // 16 and 32 pixels: 1 pixel of gap at 16

// ---- colours, sRGB ----

let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
func colour(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
let indigoTop = colour(0x454CC2), indigoBottom = colour(0x1E2266)
let loopColour = colour(0xE8EBFF, 0.92)                                  // a cool white, a little of the indigo through it
let dotColour = colour(0xFFF5E8)                                         // a warm white: the most solid thing on the icon

/// A rounded rectangle with continuous corners: each corner is a circular arc between two cubic transitions, which
/// spread the turn over `(1 + smoothing) * radius` of each edge.
func continuousRect(_ rect: CGRect, radius r: CGFloat, smoothing xi: CGFloat) -> CGPath {
    func rad(_ degrees: CGFloat) -> CGFloat { degrees * .pi / 180 }
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
    path.addCurve(to: CGPoint(x: x0 + w - p + a + b + c, y: y0 + d), control1: CGPoint(x: x0 + w - p + a, y: y0),
                  control2: CGPoint(x: x0 + w - p + a + b, y: y0))
    path.addArc(center: CGPoint(x: x0 + w - r, y: y0 + r), radius: r, startAngle: rad(alpha - 90), endAngle: rad(-alpha), clockwise: false)
    path.addCurve(to: CGPoint(x: x0 + w, y: y0 + p), control1: CGPoint(x: x0 + w, y: y0 + p - a - b),
                  control2: CGPoint(x: x0 + w, y: y0 + p - a))
    path.addLine(to: CGPoint(x: x0 + w, y: y0 + h - p))
    path.addCurve(to: CGPoint(x: x0 + w - d, y: y0 + h - p + a + b + c), control1: CGPoint(x: x0 + w, y: y0 + h - p + a),
                  control2: CGPoint(x: x0 + w, y: y0 + h - p + a + b))
    path.addArc(center: CGPoint(x: x0 + w - r, y: y0 + h - r), radius: r, startAngle: rad(alpha), endAngle: rad(90 - alpha), clockwise: false)
    path.addCurve(to: CGPoint(x: x0 + w - p, y: y0 + h), control1: CGPoint(x: x0 + w - p + a + b, y: y0 + h),
                  control2: CGPoint(x: x0 + w - p + a, y: y0 + h))
    path.addLine(to: CGPoint(x: x0 + p, y: y0 + h))
    path.addCurve(to: CGPoint(x: x0 + p - a - b - c, y: y0 + h - d), control1: CGPoint(x: x0 + p - a, y: y0 + h),
                  control2: CGPoint(x: x0 + p - a - b, y: y0 + h))
    path.addArc(center: CGPoint(x: x0 + r, y: y0 + h - r), radius: r, startAngle: rad(90 + alpha), endAngle: rad(180 - alpha), clockwise: false)
    path.addCurve(to: CGPoint(x: x0, y: y0 + h - p), control1: CGPoint(x: x0, y: y0 + h - p + a + b),
                  control2: CGPoint(x: x0, y: y0 + h - p + a))
    path.addLine(to: CGPoint(x: x0, y: y0 + p))
    path.addCurve(to: CGPoint(x: x0 + d, y: y0 + p - a - b - c), control1: CGPoint(x: x0, y: y0 + p - a),
                  control2: CGPoint(x: x0, y: y0 + p - a - b))
    path.addArc(center: CGPoint(x: x0 + r, y: y0 + r), radius: r, startAngle: rad(180 + alpha), endAngle: rad(270 - alpha), clockwise: false)
    path.addCurve(to: CGPoint(x: x0 + p, y: y0), control1: CGPoint(x: x0 + p - a - b, y: y0),
                  control2: CGPoint(x: x0 + p - a, y: y0))
    path.closeSubpath()
    return path
}

/// The icon at `pixels` × `pixels`: the rounded square, its gradient, the loop and the dot. No shadow or highlight is
/// drawn in: macOS 26 masks the square to its own shape and adds its own depth (brand.md, "Icon").
func icon(pixels: Int) -> CGImage {
    guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("no drawing context") }
    let scale = CGFloat(pixels) / 1024
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: scale, y: -scale)                                 // the canvas, y down

    context.saveGState()
    context.addPath(continuousRect(body, radius: cornerRadius, smoothing: cornerSmoothing))
    context.clip()
    guard let gradient = CGGradient(colorsSpace: sRGB, colors: [indigoTop, indigoBottom] as CFArray, locations: [0, 1]) else { fail("no gradient") }
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY), options: [])
    context.restoreGState()

    let mark = pixels <= 32 ? small : regular
    let halfGap = (mark.dot / 2 + mark.clearance + mark.stroke / 2) / mark.radius     // the dot, its clearance, a round end
    let loop = CGMutablePath()
    loop.addArc(center: centre, radius: mark.radius, startAngle: gapAngle + halfGap, endAngle: gapAngle - halfGap + 2 * .pi, clockwise: false)
    context.setStrokeColor(loopColour)
    context.setLineWidth(mark.stroke)
    context.setLineCap(.round)
    context.addPath(loop)
    context.strokePath()

    let dot = CGPoint(x: centre.x + mark.radius * cos(gapAngle), y: centre.y + mark.radius * sin(gapAngle))
    context.setFillColor(dotColour)
    context.fillEllipse(in: CGRect(x: dot.x - mark.dot / 2, y: dot.y - mark.dot / 2, width: mark.dot, height: mark.dot))
    guard let image = context.makeImage() else { fail("could not draw the icon at \(pixels) pixels") }
    return image
}

func write(_ image: CGImage, to path: String) {
    guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
    else { fail("could not create \(path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("could not write \(path)") }
}

let environment = ProcessInfo.processInfo.environment
guard let set = environment["REFEREE_ICONSET"], let preview = environment["REFEREE_ICON_PNG"] else { fail("REFEREE_ICONSET or REFEREE_ICON_PNG is not set") }
// The ten images an .iconset holds: 16, 32, 128, 256 and 512 points, each at 1x and 2x.
var drawn: [Int: CGImage] = [:]
for points in [16, 32, 128, 256, 512] {
    for (factor, suffix) in [(1, ""), (2, "@2x")] {
        let pixels = points * factor
        let image = drawn[pixels] ?? icon(pixels: pixels)
        drawn[pixels] = image
        write(image, to: "\(set)/icon_\(points)x\(points)\(suffix).png")
    }
}
if let largest = drawn[1024] { write(largest, to: preview) }
SWIFT

iconutil -c icns "$SET" -o build/AppIcon.icns
echo "Built build/AppIcon.icns"
