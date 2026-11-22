import Foundation
import PDFKit
import CryptoKit
import RefereeCore

// `load` was written in Wave 0 (plan.md section 11.4, WP0b) in its simplest working form, because the first window
// and the snapshot mode need a loaded paper. WP2 owns and completes the service (sections 4.6, 6.7 and 7.2): the
// bounds of lines whose margin number was stripped, `rects(for:in:)`, `unload`, and the tests.

public actor PDFPaperService: PaperService {
    private let builder: any PaperTextBuilding

    public init(builder: any PaperTextBuilding) {
        self.builder = builder
    }

    /// Reads the file once and never writes to it.
    public func load(url: URL) async throws -> LoadedPaper {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw PaperError.unreadable(Self.reason(for: error))
        }
        var paper = try await load(data: data, fileName: url.lastPathComponent)
        paper.ref.lastKnownPath = url.path
        return paper
    }

    public func load(data: Data, fileName: String) async throws -> LoadedPaper {
        guard data.prefix(1_024).range(of: Data("%PDF-".utf8)) != nil else { throw PaperError.notAPDF }
        guard let document = PDFDocument(data: data) else { throw PaperError.unreadable("it is damaged") }
        if document.isLocked { throw PaperError.encrypted }
        guard document.pageCount > 0 else { throw PaperError.empty }
        let raw = RawExtractor.extract(from: document)
        let ref = DocumentRef(sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), fileName: fileName,
                              byteCount: data.count, pageCount: document.pageCount)
        return LoadedPaper(ref: ref, data: data, isEncrypted: document.isEncrypted, text: builder.build(from: raw), links: raw.links,
                           outline: raw.outline)
    }

    /// Placeholder: no rectangles. WP2 implements it (section 6.7, "From spans to highlight rectangles").
    public func rects(for spans: [TextSpan], in document: DocumentRef) async -> [PageRect] { [] }

    /// Placeholder: nothing is kept after `load`, so there is nothing to release.
    public func unload(_ document: DocumentRef) async {}

    /// Why a file could not be read, in words that name neither the file nor its folder (the message may be logged).
    private static func reason(for error: Error) -> String {
        switch (error as? CocoaError)?.code {
        case .fileReadNoSuchFile?, .fileNoSuchFile?: return "it does not exist"
        case .fileReadNoPermission?: return "permission was denied"
        default: return "it could not be opened"
        }
    }
}
