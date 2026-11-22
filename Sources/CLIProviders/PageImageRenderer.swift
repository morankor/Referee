import Foundation
import CoreGraphics
import ImageIO
import RefereeCore

/// Renders the pages of a PDF to PNG files with CoreGraphics (`CGPDFDocument`, no PDFKit), for the `.pageImages`
/// delivery of plan.md section 5.6.6.
enum PageImageRenderer {
    static let defaultDPI: CGFloat = 110

    /// Writes `p001.png`, `p002.png`, … into the working directory and returns their URLs in page order.
    static func render(pdf: Data, into workspace: CLIWorkspace, dpi: CGFloat = defaultDPI, maxPages: Int) throws -> [URL] {
        guard let provider = CGDataProvider(data: pdf as CFData), let document = CGPDFDocument(provider) else {
            throw LLMError.invalidRequest("the pdf file could not be read for page images")
        }
        guard document.isUnlocked else { throw LLMError.invalidRequest("the pdf file is encrypted, so no page images can be made") }
        let count = document.numberOfPages
        guard count > 0 else { throw LLMError.invalidRequest("the pdf file has no pages") }
        guard count <= maxPages else {
            throw LLMError.invalidRequest("the pdf file has \(count) pages; page images are sent for at most \(maxPages)")
        }
        var urls: [URL] = []
        for number in 1...count {
            guard let page = document.page(at: number), let image = image(of: page, dpi: dpi) else {
                throw LLMError.invalidRequest("page \(number) of the pdf file could not be rendered")
            }
            let url = workspace.url.appendingPathComponent(String(format: "p%03d.png", number))
            try writePNG(image, to: url)
            urls.append(url)
        }
        return urls
    }

    /// One page on a white background, the crop box scaled to `dpi`, the page's rotation applied.
    static func image(of page: CGPDFPage, dpi: CGFloat) -> CGImage? {
        let box = page.getBoxRect(.cropBox)
        let scale = dpi / 72
        let rotation = ((page.rotationAngle % 360) + 360) % 360
        let quarterTurn = rotation == 90 || rotation == 270
        let width = Int((quarterTurn ? box.height : box.width) * scale + 0.5)
        let height = Int((quarterTurn ? box.width : box.height) * scale + 0.5)
        guard width > 0, height > 0, width <= 20_000, height <= 20_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        // Turn the page as the viewer would (rotationAngle is clockwise), then move the crop box to the origin.
        switch rotation {
        case 90:
            context.translateBy(x: 0, y: box.width)
            context.rotate(by: -.pi / 2)
        case 180:
            context.translateBy(x: box.width, y: box.height)
            context.rotate(by: .pi)
        case 270:
            context.translateBy(x: box.height, y: 0)
            context.rotate(by: .pi / 2)
        default:
            break
        }
        context.translateBy(x: -box.minX, y: -box.minY)
        context.clip(to: box)
        context.drawPDFPage(page)
        return context.makeImage()
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw LLMError.cliLaunchFailed("could not write a page image")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw LLMError.cliLaunchFailed("could not write a page image") }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
