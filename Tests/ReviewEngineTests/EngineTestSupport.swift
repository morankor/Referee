import Foundation
import Testing
@testable import ReviewEngine
import RefereeCore
import TestSupport

/// Shared helpers of the ReviewEngine tests. Every model is `MockLLMProvider`; papers come from `makeSamplePaper()` or
/// are built here from page texts; the matcher, renderer and paper service are the fakes of `TestSupport`.
enum EngineTest {
    /// One of the four model outputs of `Tests/ReviewEngineTests/Fixtures` (see `EngineFixtures` for where they are).
    static func fixture(_ name: String) throws -> String {
        try EngineFixtures.text(name)
    }

    /// A file name that must never reach a prompt or a log (section 12.2).
    static let secretFileName = "Rossi-Weber JPE-2026-0417 confidential.pdf"

    /// A paper whose page i has the body lines `pages[i]`, each on a line of its own.
    static func paper(pages: [[String]], fileBytes: Int = 4_096, encrypted: Bool = false, hasTextLayer: Bool = true) -> LoadedPaper {
        let texts = pages.enumerated().map { index, lines -> PageText in
            var string = ""
            var textLines: [TextLine] = []
            for (position, line) in lines.enumerated() {
                let range = TextRange(location: (string as NSString).length, length: (line as NSString).length)
                textLines.append(TextLine(pageIndex: index, range: range, contentRange: range, text: line, kind: .body,
                                          bounds: PageRect(pageIndex: index, x: 72, y: 700 - Double(position) * 14, width: 450, height: 12)))
                string += line + "\n"
            }
            return PageText(index: index, size: PageSize(width: 612, height: 792), string: string, lines: textLines)
        }
        let data = Data(repeating: 0x25, count: fileBytes)
        let ref = DocumentRef(sha256: String(repeating: "a", count: 64), fileName: secretFileName, byteCount: fileBytes, pageCount: pages.count)
        return LoadedPaper(ref: ref, data: data, isEncrypted: encrypted, text: PaperText(pages: texts, hasTextLayer: hasTextLayer, hasMarginLineNumbers: false))
    }

    /// `count` pages, each with one body line of `characters` characters that starts with "Page N." (so the page can be
    /// recognised in a prompt).
    static func paper(pageCount count: Int, charactersPerPage characters: Int, fileBytes: Int = 4_096, encrypted: Bool = false,
                      hasTextLayer: Bool = true) -> LoadedPaper {
        let pages = (1...max(1, count)).map { number -> [String] in
            let head = "Page \(number) marker \(pageWord(number))."
            let filler = String(repeating: " lorem ipsum", count: max(0, (characters - head.count) / 12))
            return [head + filler]
        }
        return paper(pages: pages, fileBytes: fileBytes, encrypted: encrypted, hasTextLayer: hasTextLayer)
    }

    /// A word that appears on page `number` only: "alpha", "bravo", …
    static func pageWord(_ number: Int) -> String {
        let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet", "kilo", "lima"]
        return number >= 1 && number <= words.count ? "PAGEWORD-" + words[number - 1] : "PAGEWORD-\(number)"
    }

    static func context(provider: ProviderID = "mock", model: ModelInfo? = ModelInfo(id: "mock", displayName: "mock", contextWindow: 1_000_000),
                        settings: ProviderSettings = ProviderSettings(enabled: true, inputMode: .auto), meta: ManuscriptMeta = ManuscriptMeta(reviewerNotes: ""),
                        digest: String? = nil) -> EngineContext {
        let defaults = DefaultSettings.make()
        return EngineContext(provider: ProviderRef(providerID: provider, model: model?.id), providerSettings: settings, model: model,
                             prompts: defaults.prompts, rubric: defaults.rubric, meta: meta, paperDigest: digest)
    }

    static func engine(_ providers: [any LLMProvider], paper: LoadedPaper, memory: UInt64 = 16 << 30, dump: URL? = nil) -> ReviewEngine {
        ReviewEngine(providers: ProviderRegistry(providers), paperService: FakePaperService(paper: paper), matcherFactory: { FakeQuoteMatcher(paper: $0) },
                     renderer: FakePaperRenderer(), physicalMemoryBytes: memory, debugDumpDirectory: dump)
    }

    static func script(_ purpose: RequestPurpose, _ responses: [MockResponse]) -> MockScript {
        var script = MockScript.sample
        script.responses[purpose] = responses
        return script
    }

    static func collect<Event>(_ stream: AsyncThrowingStream<Event, Error>) async throws -> [Event] {
        var events: [Event] = []
        for try await event in stream { events.append(event) }
        return events
    }

    /// The system prompt and every text part of a request, one after the other.
    static func text(of request: LLMRequest) -> String {
        ([request.system] + request.parts.compactMap { if case .text(let text) = $0 { return text } else { return nil } }).joined(separator: "\n")
    }

    /// The text parts of the user turn only.
    static func userText(of request: LLMRequest) -> String {
        request.parts.compactMap { if case .text(let text) = $0 { return text } else { return nil } }.joined(separator: "\n")
    }

    static func temporaryDirectory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("referee-engine-\(name)-\(UUID().uuidString)", isDirectory: true)
    }
}

extension Array where Element == ReviewEvent {
    var comments: [ReviewComment] { compactMap { if case .comment(let comment, _) = $0 { return comment } else { return nil } } }
    var notices: [String] { compactMap { if case .notice(let text) = $0 { return text } else { return nil } } }
    var digests: [String] { compactMap { if case .digest(let text) = $0 { return text } else { return nil } } }
    var phases: [ReviewPhase] { compactMap { if case .phase(let phase) = $0 { return phase } else { return nil } } }
    var startedRun: RunRecord? { if case .started(let run)? = first { return run } else { return nil } }
    var finishedRun: RunRecord? { if case .finished(let run)? = last { return run } else { return nil } }
}

extension Array where Element == ReplyEvent {
    var text: String { compactMap { if case .textDelta(let text) = $0 { return text } else { return nil } }.joined() }
    var finished: (reply: ThreadMessage, proposal: CommentRevision?, run: RunRecord)? {
        if case .finished(let reply, let proposal, let run)? = last { return (reply, proposal, run) }
        return nil
    }
}

extension Array where Element == ReportEvent {
    var text: String { compactMap { if case .textDelta(let text) = $0 { return text } else { return nil } }.joined() }
    var finished: (draft: ReportDraft, run: RunRecord)? {
        if case .finished(let draft, let run)? = last { return (draft, run) }
        return nil
    }
}

/// Events seen by a consumer running in another task.
final class EventBox<Event: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [Event] = []
    private var ended = false
    func add(_ event: Event) { lock.withLock { events.append(event) } }
    func end() { lock.withLock { ended = true } }
    var snapshot: (events: [Event], ended: Bool) { lock.withLock { (events, ended) } }
}
