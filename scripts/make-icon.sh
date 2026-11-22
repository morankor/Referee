#!/bin/bash
# Renders the app icon into build/AppIcon.icns: a rounded square with a serif "R". Usage: scripts/make-icon.sh
# Uses only what macOS and the Command Line Tools ship: swift, sips, iconutil. scripts/bundle.sh calls it when the
# icon is missing and carries on without an icon if it fails.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
PNG="build/AppIcon-1024.png"
SET="build/AppIcon.iconset"

REFEREE_ICON_PNG="$PNG" swift - <<'SWIFT'
import Foundation
import CoreGraphics
import CoreText
import ImageIO

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon.sh: \(message)\n".utf8))
    exit(1)
}

let side = 1024
let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
guard let path = ProcessInfo.processInfo.environment["REFEREE_ICON_PNG"] else { fail("REFEREE_ICON_PNG is not set") }
guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("no drawing context") }

// The rounded square, inset as macOS app icons are (824 of 1024 pixels), filled from top to bottom with a gradient.
let square = CGRect(x: 100, y: 100, width: 824, height: 824)
context.addPath(CGPath(roundedRect: square, cornerWidth: 185, cornerHeight: 185, transform: nil))
context.clip()
let colours = [CGColor(srgbRed: 0.20, green: 0.33, blue: 0.52, alpha: 1), CGColor(srgbRed: 0.10, green: 0.18, blue: 0.32, alpha: 1)] as CFArray
guard let gradient = CGGradient(colorsSpace: sRGB, colors: colours, locations: [0, 1]) else { fail("no gradient") }
context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: square.maxY), end: CGPoint(x: 0, y: square.minY), options: [])

// A serif "R", centred on its ink.
let font = CTFontCreateWithName("Georgia-Bold" as CFString, 640, nil)
let ivory = CGColor(srgbRed: 0.97, green: 0.96, blue: 0.93, alpha: 1)
let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: ivory] as CFDictionary
guard let letter = CFAttributedStringCreate(nil, "R" as CFString, attributes) else { fail("no attributed string") }
let line = CTLineCreateWithAttributedString(letter)
let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
context.textPosition = CGPoint(x: square.midX - ink.midX, y: square.midY - ink.midY)
CTLineDraw(line, context)

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
else { fail("could not create the image") }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fail("could not write \(path)") }
SWIFT

# The ten sizes an .iconset holds: 16, 32, 128, 256 and 512 points, each at 1x and 2x.
rm -rf "$SET"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$PNG" --out "$SET/icon_${size}x${size}.png" >/dev/null
  sips -z "$((size * 2))" "$((size * 2))" "$PNG" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o build/AppIcon.icns
echo "Built build/AppIcon.icns"
