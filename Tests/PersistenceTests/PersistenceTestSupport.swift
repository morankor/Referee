import Foundation
import Testing
import RefereeCore

/// A folder of its own under the system's temporary directory for one test; nothing a store test writes goes anywhere
/// else (plan.md section 3.5). Removed when the test's body returns or throws.
func withTemporaryFolder<T>(_ body: (URL) async throws -> T) async throws -> T {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("referee-persistence-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    return try await body(folder)
}

/// The synchronous twin of `withTemporaryFolder`, for tests of the file helpers.
func withTemporaryFolderSync<T>(_ body: (URL) throws -> T) throws -> T {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("referee-persistence-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    return try body(folder)
}

/// The names in a folder, sorted; empty when it does not exist.
func names(in folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
}

/// Everything under a folder, by relative path, with the bytes of each file (a folder is "name/" with no bytes), to
/// show that nothing in it changed.
func contents(of folder: URL, prefix: String = "") throws -> [String: Data] {
    var result: [String: Data] = [:]
    for name in names(in: folder) {
        let url = folder.appendingPathComponent(name)
        var isFolder: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
        if isFolder.boolValue {
            result[prefix + name + "/"] = Data()
            result.merge(try contents(of: url, prefix: prefix + name + "/")) { first, _ in first }
        } else {
            result[prefix + name] = try Data(contentsOf: url)
        }
    }
    return result
}

/// The format plan.md section 3.7 prescribes for files on disk, written out independently of the stores.
func referenceEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}

/// Encodes a value, lets the test change the JSON object, and serialises it again.
func editedJSON<T: Encodable>(_ value: T, _ edit: (inout [String: Any]) -> Void) throws -> Data {
    var object = try #require(try JSONSerialization.jsonObject(with: referenceEncoder().encode(value)) as? [String: Any])
    edit(&object)
    return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
}

struct SimulatedFailure: Error {}

/// A value a `@Sendable` closure can write and the test read afterwards.
final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Sessions and settings with invented content. Dates are whole seconds, which survive an ISO 8601 round trip.
enum Samples {
    static let moment = Date(timeIntervalSince1970: 1_800_000_000)

    static func sha(_ pair: String) -> String { String(repeating: pair, count: 32) }

    static func session(sha256: String, fileName: String = "manuscript.pdf", title: String? = "A synthetic manuscript",
                        notes: String = "", updatedAt: Date = moment, comments: [ReviewComment] = [],
                        report: ReportDraft? = nil) -> ReviewSession {
        ReviewSession(schemaVersion: 1, id: UUID(),
                      document: DocumentRef(sha256: sha256, fileName: fileName, lastKnownPath: "/path/to/\(fileName)",
                                            byteCount: 183_964, pageCount: 4),
                      meta: ManuscriptMeta(title: title, reviewerNotes: notes), comments: comments, report: report,
                      createdAt: moment, updatedAt: updatedAt)
    }

    static func comment(_ status: CommentStatus, kind: CommentKind = .major, title: String = "A comment",
                        similarTo: UUID? = nil) -> ReviewComment {
        ReviewComment(id: UUID(), origin: .user, status: status, kind: kind, category: "claims", title: title,
                      body: "The body of the comment.", anchor: Anchor(quote: "", confidence: .none, locationLabel: ""),
                      includeInReport: status == .approved, similarTo: similarTo, createdAt: moment, updatedAt: moment)
    }

    /// A session that uses every type and every enum case a session file can hold.
    static func richSession(sha256: String) -> ReviewSession {
        let run = UUID()
        let first = UUID()
        let later = moment.addingTimeInterval(3_600)
        let exact = Anchor(quote: "The coefficient in Table 2 is 0.91 with a confidence interval that crosses one",
                           spans: [TextSpan(pageIndex: 0, range: TextRange(location: 676, length: 18)),
                                   TextSpan(pageIndex: 0, range: TextRange(location: 697, length: 59))],
                           rects: [PageRect(pageIndex: 0, x: 384.2, y: 189.2, width: 111, height: 10.6),
                                   PageRect(pageIndex: 0, x: 110.9, y: 165.2, width: 281, height: 10.6)],
                           pageIndex: 0, confidence: .exact, locationLabel: "p. 1, lines 13\u{2013}14")
        let comments = [
            ReviewComment(id: first, origin: .ai(runID: run), status: .approved, kind: .major, category: "claims",
                          title: "Confidence interval includes one", body: "The text calls the effect robust.",
                          suggestion: "Report the interval in the abstract.", anchor: exact,
                          thread: [ThreadMessage(id: UUID(), role: .user, text: "Is the interval in the text?", createdAt: moment),
                                   ThreadMessage(id: UUID(), role: .assistant, text: "Yes, in the introduction.", createdAt: later,
                                                 provider: ProviderRef(providerID: "ollama", model: "gemma4:e4b"))],
                          proposedRevision: CommentRevision(kind: .minor, title: "State the interval", body: "Shorter.",
                                                            suggestion: "Drop the word.", withdraw: false),
                          previousVersions: [CommentRevision(kind: .major, title: "Old title", body: "Old body.", withdraw: false)],
                          includeInReport: true, createdAt: moment, updatedAt: later),
            ReviewComment(id: UUID(), origin: .ai(runID: run), status: .pending, kind: .major, category: "claims",
                          title: "The same passage again", body: "Another view of it.", anchor: exact,
                          includeInReport: false, similarTo: first, createdAt: moment, updatedAt: moment),
            ReviewComment(id: UUID(), origin: .user, status: .rejected, kind: .strength, category: "writing", title: "Clear",
                          body: "The main result is stated clearly.",
                          anchor: Anchor(quote: "The main result", pageIndex: 1, confidence: .fuzzy(score: 0.82), locationLabel: "p. 2"),
                          includeInReport: false, createdAt: moment, updatedAt: moment),
            ReviewComment(id: UUID(), origin: .user, status: .pending, kind: .question, category: "data", title: "Standard errors?",
                          body: "How are they computed?",
                          anchor: Anchor(quote: "standard errors", pageIndex: 2, confidence: .pageOnly, locationLabel: "p. 3"),
                          proposedRevision: CommentRevision(kind: .question, title: "", body: "", withdraw: true),
                          includeInReport: false, createdAt: moment, updatedAt: moment),
        ]
        let conversations = [
            Conversation(id: UUID(), anchor: exact,
                         messages: [ThreadMessage(id: UUID(), role: .user, text: "Check this step.", createdAt: moment)], createdAt: moment),
            Conversation(id: UUID(), createdAt: later),
        ]
        let report = ReportDraft(markdown: "## Summary assessment\n\nShort.\n", recommendation: .majorRevision, generatedAt: later,
                                 provider: ProviderRef(providerID: "mock", model: nil), basedOnCommentIDs: [first], userEdited: true,
                                 versions: [ReportVersion(markdown: "## Summary assessment\n\nLonger.\n", savedAt: moment, note: "generated")])
        let provider = ProviderRef(providerID: "anthropic-api", model: "example-large")
        let runs = [
            RunRecord(id: run, kind: .review, provider: ProviderRef(providerID: "ollama", model: "gemma4:e4b"), destination: "127.0.0.1:11434",
                      sentPDF: false, requestCount: 1, startedAt: moment, finishedAt: later, status: .completed,
                      usage: Usage(inputTokens: 21_000, outputTokens: 1_800)),
            RunRecord(id: UUID(), kind: .discussion, provider: provider, destination: "api.anthropic.com", sentPDF: true,
                      requestCount: 2, startedAt: moment, status: .failed("The provider answered 529 (overloaded).")),
            RunRecord(id: UUID(), kind: .report, provider: provider, destination: "api.anthropic.com", sentPDF: false,
                      requestCount: 1, startedAt: later, finishedAt: later, status: .cancelled, usage: Usage(outputTokens: 12)),
            RunRecord(id: UUID(), kind: .question, provider: provider, destination: "api.anthropic.com", sentPDF: false,
                      requestCount: 1, startedAt: later, status: .running),
            RunRecord(id: UUID(), kind: .revise, provider: provider, destination: "api.anthropic.com", sentPDF: false,
                      requestCount: 1, startedAt: later, finishedAt: later, status: .completed),
        ]
        return ReviewSession(schemaVersion: 1, id: UUID(),
                             document: DocumentRef(sha256: sha256, fileName: "manuscript.pdf", lastKnownPath: "/path/to/manuscript.pdf",
                                                   byteCount: 183_964, pageCount: 4),
                             meta: ManuscriptMeta(title: "Information Aggregation in Sequential Markets", targetVenue: "A field journal",
                                                  manuscriptID: "MS-2026-0001", reviewerNotes: "Focus on identification."),
                             preferredProvider: provider, comments: comments, conversations: conversations, report: report,
                             paperDigest: "Notes from part 1 of 2.", runs: runs,
                             consents: [ConsentRecord(providerID: "anthropic-api", grantedAt: moment)],
                             createdAt: moment, updatedAt: later)
    }
}
