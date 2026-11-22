import Foundation
import RefereeCore

// Wave 0a placeholder (see Placeholder.swift).

/// load returns `paper`; rects(for:in:) returns one rectangle per span (x 100, width 200, on the span's page).
/// Placeholder: load throws and there are no rectangles.
public final class FakePaperService: PaperService, @unchecked Sendable {
    public init(paper: LoadedPaper) {}

    public func load(url: URL) async throws -> LoadedPaper { throw NotImplementedYet(what: "FakePaperService.load") }

    public func load(data: Data, fileName: String) async throws -> LoadedPaper { throw NotImplementedYet(what: "FakePaperService.load") }

    public func rects(for spans: [TextSpan], in document: DocumentRef) async -> [PageRect] { [] }

    public func unload(_ document: DocumentRef) async {}
}
