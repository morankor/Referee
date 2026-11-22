import Foundation

public struct DocumentRef: Codable, Sendable, Hashable {
    public var sha256: String            // lowercase hex of the PDF file bytes; primary key of a session
    public var fileName: String
    public var lastKnownPath: String?
    public var byteCount: Int
    public var pageCount: Int
    public init(sha256: String, fileName: String, lastKnownPath: String? = nil, byteCount: Int, pageCount: Int) {
        self.sha256 = sha256; self.fileName = fileName; self.lastKnownPath = lastKnownPath; self.byteCount = byteCount; self.pageCount = pageCount
    }
}

// ---- Raw extraction (produced by PDFBridge straight from PDFKit) ----

public struct RawLine: Codable, Sendable, Equatable {
    public var range: TextRange          // range in page string, excluding the trailing newline
    public var text: String              // == page string substring(range)
    public var bounds: PageRect?         // PDFSelection bounds of the whole line; x and width are wrong when margin digits are glued to it
    public init(range: TextRange, text: String, bounds: PageRect? = nil) { self.range = range; self.text = text; self.bounds = bounds }
}

public struct RawPage: Codable, Sendable, Equatable {
    public var index: Int
    public var label: String?
    public var size: PageSize            // mediaBox size
    public var string: String            // PDFPage.string ?? ""
    public var lines: [RawLine]          // from page.selection(for: whole).selectionsByLine(): ranges increase and never overlap.
                                         // Their number is NOT the number of newline-separated lines of `string`.
    public init(index: Int, label: String? = nil, size: PageSize, string: String, lines: [RawLine] = []) {
        self.index = index; self.label = label; self.size = size; self.string = string; self.lines = lines
    }
}

public enum RawLinkTarget: Codable, Sendable, Equatable {
    case internalDestination(pageIndex: Int, x: Double, y: Double)   // PDFActionGoTo / annotation.destination
    case url(String)                                                 // PDFActionURL / annotation.url
    case other
}

public struct RawLink: Codable, Sendable, Equatable {
    public var pageIndex: Int
    public var bounds: PageRect
    public var text: String              // text under the annotation (page.selection(for: bounds)), may be empty
    public var target: RawLinkTarget
    public init(pageIndex: Int, bounds: PageRect, text: String, target: RawLinkTarget) {
        self.pageIndex = pageIndex; self.bounds = bounds; self.text = text; self.target = target
    }
}

public struct OutlineItem: Codable, Sendable, Equatable, Identifiable {
    public var id: Int                   // preorder index
    public var title: String
    public var pageIndex: Int?
    public var depth: Int
    public init(id: Int, title: String, pageIndex: Int? = nil, depth: Int) { self.id = id; self.title = title; self.pageIndex = pageIndex; self.depth = depth }
}

public struct RawDocument: Codable, Sendable, Equatable {
    public var pages: [RawPage]
    public var links: [RawLink]
    public var outline: [OutlineItem]
    public init(pages: [RawPage] = [], links: [RawLink] = [], outline: [OutlineItem] = []) { self.pages = pages; self.links = links; self.outline = outline }
}

// ---- Clean text model (produced by PaperText.PaperTextBuilder; bounds finalised by PDFBridge) ----

public enum LineKind: String, Codable, Sendable {
    case body, marginNumberOnly, pageNumber, runningHeader, runningFooter, watermark, empty
}

public struct TextLine: Codable, Sendable, Equatable {
    public var pageIndex: Int
    public var range: TextRange          // the raw line
    public var contentRange: TextRange   // raw line minus the margin line number; == range when there is none
    public var text: String              // page string substring(contentRange)
    public var kind: LineKind
    public var marginNumber: Int?        // the printed line number of this line, or the margin (ruler) number level with it; nil when there is none
    public var bounds: PageRect?         // bounds of contentRange (clean geometry)
    public init(pageIndex: Int, range: TextRange, contentRange: TextRange, text: String, kind: LineKind, marginNumber: Int? = nil, bounds: PageRect? = nil) {
        self.pageIndex = pageIndex; self.range = range; self.contentRange = contentRange; self.text = text; self.kind = kind; self.marginNumber = marginNumber
        self.bounds = bounds
    }
}

public struct PageText: Codable, Sendable, Equatable {
    public var index: Int
    public var label: String?
    public var size: PageSize
    public var string: String            // raw PDFPage.string: the coordinate system for every TextRange on this page
    public var lines: [TextLine]         // in string order (PDFKit's order). Multi-column pages are not re-ordered in v1.
    public init(index: Int, label: String? = nil, size: PageSize, string: String, lines: [TextLine] = []) {
        self.index = index; self.label = label; self.size = size; self.string = string; self.lines = lines
    }
}

public struct PaperText: Codable, Sendable, Equatable {
    public var pages: [PageText]
    public var hasTextLayer: Bool            // false => scanned PDF (fewer than 200 letters in total)
    public var hasMarginLineNumbers: Bool    // lineno-style numbers on the text lines, or a ruler of numbers down the margin
    public var titleGuess: String?
    public init(pages: [PageText] = [], hasTextLayer: Bool, hasMarginLineNumbers: Bool, titleGuess: String? = nil) {
        self.pages = pages; self.hasTextLayer = hasTextLayer; self.hasMarginLineNumbers = hasMarginLineNumbers; self.titleGuess = titleGuess
    }
}

public struct LoadedPaper: Sendable, Equatable {
    public var ref: DocumentRef
    public var data: Data                    // the original, unmodified file bytes
    public var isEncrypted: Bool             // owner-password or permission-restricted PDF that opened without a password: its text is readable,
                                             // but the file itself is never sent to a provider (vendors reject encrypted PDFs)
    public var text: PaperText
    public var links: [RawLink]
    public var outline: [OutlineItem]
    public init(ref: DocumentRef, data: Data, isEncrypted: Bool, text: PaperText, links: [RawLink] = [], outline: [OutlineItem] = []) {
        self.ref = ref; self.data = data; self.isEncrypted = isEncrypted; self.text = text; self.links = links; self.outline = outline
    }
}

/// What the user has selected in the PDF view (computed on the main actor from PDFSelection).
/// As delivered by the view it can contain margin numbers and watermark text; ReviewSessionModel.readerSelectionChanged
/// normalises it against PaperText before anything else uses it (plan section 7.4).
public struct SelectionInfo: Sendable, Equatable {
    public var text: String
    public var spans: [TextSpan]             // one per text line touched
    public var rects: [PageRect]
    public init(text: String, spans: [TextSpan] = [], rects: [PageRect] = []) { self.text = text; self.spans = spans; self.rects = rects }
}

// ---- Anchoring ----

public enum AnchorConfidence: Codable, Sendable, Equatable {
    case exact
    case fuzzy(score: Double)   // 0.75 ... 1.0
    case pageOnly
    case none
}

public struct AnchorMatch: Sendable, Equatable {
    public var spans: [TextSpan]            // one per text line touched, in text order; never empty
    public var confidence: AnchorConfidence // .exact or .fuzzy
    public init(spans: [TextSpan] = [], confidence: AnchorConfidence) { self.spans = spans; self.confidence = confidence }
}

public protocol PaperTextBuilding: Sendable {
    /// Pure function of its input. Classifies lines, detects and strips margin line numbers, detects boilerplate.
    /// Leaves `TextLine.bounds` equal to the raw line bounds; PDFBridge recomputes bounds where contentRange != range.
    func build(from raw: RawDocument) -> PaperText
}

public protocol QuoteMatching: Sendable {
    /// `pageHint` is a 0-based page index. Returns nil when the quote cannot be located anywhere.
    func locate(quote: String, pageHint: Int?) -> AnchorMatch?
    /// "p. 4, lines 14–16", "p. 4, line 9", "p. 4", or across a page break "pp. 4–5 (p. 4 line 58 to p. 5 line 3)" / "pp. 4–5".
    /// Line numbers come from TextLine.marginNumber of the first and last lines touched.
    func locationLabel(for spans: [TextSpan]) -> String
}

public protocol PaperRendering: Sendable {
    /// LLM-facing text (plan section 6.2): body lines joined into paragraph-like lines, de-hyphenated, with one
    /// "[[page N]]" marker line (1-based) per page, placed at a sentence boundary.
    func render(_ paper: PaperText, pages: Range<Int>?) -> String
    /// Splits into consecutive page ranges whose rendered size is <= maxCharacters each (a single page may exceed it).
    func chunkPageRanges(_ paper: PaperText, maxCharacters: Int) -> [Range<Int>]
}

public protocol PaperService: Sendable {
    func load(url: URL) async throws -> LoadedPaper
    func load(data: Data, fileName: String) async throws -> LoadedPaper
    /// Highlight rectangles for spans: one rect per text line touched, margin numbers excluded.
    func rects(for spans: [TextSpan], in document: DocumentRef) async -> [PageRect]
    func unload(_ document: DocumentRef) async
}

public enum PaperError: RefereeError, Equatable {
    case unreadable(String)
    case notAPDF
    case encrypted
    case empty
    public var userMessage: String {
        switch self {
        case .unreadable(let why): return "The file could not be read (\(why))."
        case .notAPDF: return "This file is not a PDF."
        case .encrypted: return "This PDF is password-protected."
        case .empty: return "This PDF has no pages."
        }
    }
    public var recoverySuggestion: String? { nil }
    public var isRetryable: Bool { false }
}
