import Foundation
import PDFKit
import RefereeCore

// Wave 0 placeholder (plan.md section 11.4, WP0a). WP0b gives `load` its simplest working form; WP2 completes the
// service (sections 4.6, 6.7 and 7.2).

public actor PDFPaperService: PaperService {
    private let builder: any PaperTextBuilding

    public init(builder: any PaperTextBuilding) {
        self.builder = builder
    }

    /// Placeholder: always fails, without touching the file.
    public func load(url: URL) async throws -> LoadedPaper {
        throw PaperError.unreadable("opening PDFs is not implemented yet")
    }

    /// Placeholder: always fails.
    public func load(data: Data, fileName: String) async throws -> LoadedPaper {
        throw PaperError.unreadable("opening PDFs is not implemented yet")
    }

    /// Placeholder: no rectangles.
    public func rects(for spans: [TextSpan], in document: DocumentRef) async -> [PageRect] { [] }

    public func unload(_ document: DocumentRef) async {}
}
