import Foundation
import PDFKit
import CryptoKit
import RefereeCore

// The paper service of plan.md sections 4.6, 6.7 and 7.1-7.2: loading, the bounds of lines whose margin number was
// stripped, highlight rectangles, and releasing a document. `load` was written in Wave 0 in its simplest working form;
// WP2 completed the service.

/// Loads manuscripts and answers geometry questions about them, off the main thread.
///
/// The file is read once and never written (section 4.6). For every loaded document the actor keeps its own
/// `PDFDocument`, made with `PDFDocument(data:)` from the same bytes as the display document but sharing no object with it
/// (section 7.1), together with the finished `PaperText`; `rects(for:in:)` needs both. Documents are keyed by their
/// SHA-256 and counted: each `load` of a document must be matched by one `unload`, and the document is released when the
/// last load is, so one window closing never takes the document from another that shows the same file.
public actor PDFPaperService: PaperService {
    private let builder: any PaperTextBuilding
    private var documents: [String: OpenDocument] = [:]

    /// What the service keeps for a loaded document.
    private struct OpenDocument {
        let document: PDFDocument
        let text: PaperText
        let strings: [Int: NSString]        // page index -> PDFPage.string, as extracted
        let pagePositions: [Int: Int]       // page index -> position in text.pages
        var loads: Int
    }

    public init(builder: any PaperTextBuilding) {
        self.builder = builder
    }

    /// Reads the file once (`Data(contentsOf:options: .mappedIfSafe)`) and never writes to it. The error never names the
    /// file or its folder, because its message may be logged and shown.
    public func load(url: URL) async throws -> LoadedPaper {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            Log.event("pdf.load.failed", ["reason": .id("unreadable")])
            throw PaperError.unreadable(Self.reason(for: error))
        }
        var paper = try await load(data: data, fileName: url.lastPathComponent)
        paper.ref.lastKnownPath = url.path
        return paper
    }

    /// `.notAPDF` unless `%PDF-` starts within the first 1,024 bytes; `.unreadable` when PDFKit cannot open the data;
    /// `.encrypted` when a password is needed to open it; `.empty` for no pages. A PDF that opens without a password but
    /// is encrypted (an owner password, copying or printing disabled) loads with `isEncrypted == true`.
    public func load(data: Data, fileName: String) async throws -> LoadedPaper {
        let started = ContinuousClock.now
        do {
            let paper = try open(data, fileName: fileName)
            Log.event("pdf.load.done", ["pages": .int(paper.ref.pageCount), "links": .int(paper.links.count), "encrypted": .bool(paper.isEncrypted),
                                        "textLayer": .bool(paper.text.hasTextLayer), "marginNumbers": .bool(paper.text.hasMarginLineNumbers),
                                        "ms": .int(Int(started.duration(to: .now) / .milliseconds(1)))])
            return paper
        } catch let error as PaperError {
            Log.event("pdf.load.failed", ["reason": .id(Self.logID(error))])
            throw error
        }
    }

    /// One rectangle per text line touched (section 6.7, "From spans to highlight rectangles"): for each span, the part
    /// of it inside the `contentRange` of each line of its page, so margin numbers never count. Spans of a document that
    /// is not loaded, on a page it does not have, or outside every line give nothing; so does a part that holds only
    /// blank characters.
    public func rects(for spans: [TextSpan], in document: DocumentRef) async -> [PageRect] {
        guard let open = documents[document.sha256] else {
            Log.event("pdf.rects.notLoaded", ["spans": .int(spans.count)])
            return []
        }
        var rects: [PageRect] = []
        for span in spans {
            guard let page = Self.page(span.pageIndex, of: open.document), let string = open.strings[span.pageIndex],
                  let position = open.pagePositions[span.pageIndex],
                  let wanted = PageGeometry.clamped(span.range.nsRange, toLength: string.length) else { continue }
            for line in open.text.pages[position].lines {
                guard let content = PageGeometry.clamped(line.contentRange.nsRange, toLength: string.length) else { continue }
                let piece = NSIntersectionRange(wanted, content)
                guard piece.length > 0, let box = PageGeometry.bounds(of: piece, on: page, in: string),
                      let rect = PageGeometry.pageRect(box, pageIndex: span.pageIndex) else { continue }
                rects.append(rect)
            }
        }
        return rects
    }

    /// Releases one load of the document; the extraction document and its text go when every load has been released.
    public func unload(_ document: DocumentRef) async {
        guard var open = documents[document.sha256] else { return }
        open.loads -= 1
        documents[document.sha256] = open.loads > 0 ? open : nil
    }

    // MARK: - Loading

    private func open(_ data: Data, fileName: String) throws -> LoadedPaper {
        guard Self.startsAsAPDF(data) else { throw PaperError.notAPDF }
        guard let document = PDFDocument(data: data) else { throw PaperError.unreadable("it is damaged") }
        if document.isLocked { throw PaperError.encrypted }
        guard document.pageCount > 0 else { throw PaperError.empty }

        let raw = RawExtractor.extract(from: document)
        var strings: [Int: NSString] = [:]
        for page in raw.pages { strings[page.index] = page.string as NSString }
        let text = Self.finished(builder.build(from: raw), in: document, strings: strings)
        var positions: [Int: Int] = [:]
        for (position, page) in text.pages.enumerated() where positions[page.index] == nil { positions[page.index] = position }

        let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let loads = (documents[sha256]?.loads ?? 0) + 1
        documents[sha256] = OpenDocument(document: document, text: text, strings: strings, pagePositions: positions, loads: loads)

        let ref = DocumentRef(sha256: sha256, fileName: fileName, byteCount: data.count, pageCount: document.pageCount)
        return LoadedPaper(ref: ref, data: data, isEncrypted: document.isEncrypted, text: text, links: raw.links, outline: raw.outline)
    }

    /// The builder leaves every line's bounds as PDFKit gave them for the whole raw line (Appendix A.2, `PaperTextBuilding`).
    /// Where it removed a margin number, those bounds are wrong (they reach across the page), so they are replaced by
    /// the bounds of `contentRange` (section 7.2): nil when nothing visible is left, as on a line that was only a number.
    private static func finished(_ text: PaperText, in document: PDFDocument, strings: [Int: NSString]) -> PaperText {
        var text = text
        for position in text.pages.indices {
            let index = text.pages[position].index
            guard let page = page(index, of: document), let string = strings[index] else { continue }
            for line in text.pages[position].lines.indices {
                let current = text.pages[position].lines[line]
                guard current.contentRange != current.range else { continue }
                let box = PageGeometry.bounds(of: current.contentRange.nsRange, on: page, in: string)
                text.pages[position].lines[line].bounds = PageGeometry.pageRect(box, pageIndex: index)
            }
        }
        return text
    }

    /// Plan section 7.2: the data is a PDF only if `%PDF-` starts at one of its first 1,024 bytes.
    static func startsAsAPDF(_ data: Data) -> Bool {
        let marker = Data("%PDF-".utf8)
        guard let found = data.prefix(1_024 + marker.count - 1).range(of: marker) else { return false }
        return found.lowerBound - data.startIndex < 1_024
    }

    private static func page(_ index: Int, of document: PDFDocument) -> PDFPage? {
        index >= 0 && index < document.pageCount ? document.page(at: index) : nil
    }

    /// Why a file could not be read, in words that name neither the file nor its folder (the message may be logged).
    private static func reason(for error: Error) -> String {
        switch (error as? CocoaError)?.code {
        case .fileReadNoSuchFile?, .fileNoSuchFile?: return "it does not exist"
        case .fileReadNoPermission?: return "permission was denied"
        default: return "it could not be opened"
        }
    }

    private static func logID(_ error: PaperError) -> String {
        switch error {
        case .unreadable: return "unreadable"
        case .notAPDF: return "notAPDF"
        case .encrypted: return "encrypted"
        case .empty: return "empty"
        }
    }
}
