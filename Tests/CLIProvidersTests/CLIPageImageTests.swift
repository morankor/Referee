import Foundation
import CoreGraphics
import ImageIO
import Testing
@testable import CLIProviders
import RefereeCore
import TestSupport

/// Acceptance row "page images": the four pages of `ay_round_nolinks.pdf` rendered with CoreGraphics at 110 dpi give
/// `p001.png` … `p004.png` in the working directory, each more than 900 px wide and not blank.
@Suite struct CLIPageImageTests {
    @Test func fourPagesAt110DPI() throws {
        let pdf = try Data(contentsOf: Fixtures.url("pdf/ay_round_nolinks.pdf"))
        let workspace = try CLIWorkspace.create(in: FileManager.default.temporaryDirectory)
        defer { workspace.remove() }
        let urls = try PageImageRenderer.render(pdf: pdf, into: workspace, maxPages: CodexAdapter.maxPageImages)
        #expect(urls.map(\.lastPathComponent) == ["p001.png", "p002.png", "p003.png", "p004.png"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.url.path).sorted() == ["p001.png", "p002.png", "p003.png", "p004.png"])
        for url in urls {
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            #expect(CGImageSourceGetType(source) as String? == "public.png")
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width > 900, "\(url.lastPathComponent) is \(image.width) px wide")
            #expect(image.height > image.width)
            #expect(Self.darkPixelShare(image) > 0.005, "\(url.lastPathComponent) looks blank")
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            #expect(mode == 0o600)
        }
    }

    @Test func tooManyPagesOrNotAPDF() throws {
        let workspace = try CLIWorkspace.create(in: FileManager.default.temporaryDirectory)
        defer { workspace.remove() }
        let pdf = try Data(contentsOf: Fixtures.url("pdf/ay_round_nolinks.pdf"))
        #expect(throws: LLMError.invalidRequest("the pdf file has 4 pages; page images are sent for at most 3")) {
            try PageImageRenderer.render(pdf: pdf, into: workspace, maxPages: 3)
        }
        #expect(throws: LLMError.self) { try PageImageRenderer.render(pdf: Data("not a pdf".utf8), into: workspace, maxPages: 40) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.url.path).isEmpty)
    }

    /// The share of pixels darker than mid-grey, at full size.
    static func darkPixelShare(_ image: CGImage) -> Double {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }
        return Double(pixels.filter { $0 < 128 }.count) / Double(pixels.count)
    }
}
