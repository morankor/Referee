import Foundation
import RefereeCore

// The mock provider of plan.md section 5.9: a scripted, deterministic LLMProvider. It runs in-process; it opens no
// connection and starts no process.

public struct MockResponse: Sendable {
    public var text: String
    public var chunkSize: Int                 // characters per delta
    public var delayPerChunk: Duration
    public var failAfterChunks: Int?          // then throw `failure`
    public var failure: LLMError?
    public var stallAfterChunks: Int?         // then emit nothing more and never finish, until the consumer cancels
    public var stop: StopReason
    public init(text: String, chunkSize: Int = 7, delayPerChunk: Duration = .zero, failAfterChunks: Int? = nil, failure: LLMError? = nil,
                stallAfterChunks: Int? = nil, stop: StopReason = .endOfTurn) {
        self.text = text; self.chunkSize = chunkSize; self.delayPerChunk = delayPerChunk; self.failAfterChunks = failAfterChunks
        self.failure = failure; self.stallAfterChunks = stallAfterChunks; self.stop = stop
    }

    /// `text` cut into the deltas the mock emits: `chunkSize` characters each (at least one), the last one shorter.
    /// A character is a Swift `Character`, so no delta ever splits a letter with its accent.
    var deltas: [String] {
        let size = max(1, chunkSize)
        var result: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[start..<end]))
            start = end
        }
        return result
    }
}

public struct MockScript: Sendable {
    public var responses: [RequestPurpose: [MockResponse]]       // consumed in order per purpose; the last one repeats
    public init(responses: [RequestPurpose: [MockResponse]]) { self.responses = responses }

    /// Fixtures/llm: review_clean, discussion_revise, question_answer, report_sample.
    ///
    /// One response per purpose, read from the files each time this is called. Two purposes have no file of their own:
    /// a voice revision (.revise) answers with report_sample again, and a test prompt (.ping) answers "OK". A file that
    /// cannot be read leaves its purpose without a response, and a request for it then fails with `.notConfigured`.
    public static var sample: MockScript {
        var responses: [RequestPurpose: [MockResponse]] = [.ping: [MockResponse(text: "OK")]]
        let files: [(RequestPurpose, String)] = [
            (.review, "llm/review_clean.txt"), (.discussion, "llm/discussion_revise.txt"), (.question, "llm/question_answer.txt"),
            (.report, "llm/report_sample.txt"), (.revise, "llm/report_sample.txt"),
        ]
        for (purpose, file) in files {
            if let text = try? Fixtures.text(file) {
                responses[purpose] = [MockResponse(text: text)]
            } else {
                Log.event("mock.fixture.missing", ["purpose": .id(purpose.rawValue)])
            }
        }
        return MockScript(responses: responses)
    }

    /// review: two complete blocks of review_clean, half of the third, then .overloaded. Other purposes as in `sample`.
    ///
    /// "Half of the third" is the first half of that block's lines: its kind, category, page and quote, and neither
    /// title nor body. The parser of plan section 6.5 drops such a block when the stream ends, so a review through
    /// this script keeps exactly two comments, as the scenes of section 10.1 expect.
    public static var failsAfterTwoComments: MockScript {
        interruptedReview { response in
            response.failAfterChunks = response.deltas.count
            response.failure = .overloaded(retryAfter: nil)
        }
    }

    /// review: the same text, then silence. Other purposes as in `sample`.
    public static var stallsAfterTwoComments: MockScript {
        interruptedReview { response in
            response.stallAfterChunks = response.deltas.count
        }
    }

    /// `sample` with the review answer cut in the middle of its third block; `interrupt` says what happens after the cut.
    private static func interruptedReview(_ interrupt: (inout MockResponse) -> Void) -> MockScript {
        var script = sample
        guard let whole = script.responses[.review]?.first else { return script }
        var response = MockResponse(text: twoBlocksAndHalfOfTheThird(of: whole.text), chunkSize: whole.chunkSize)
        interrupt(&response)
        script.responses[.review] = [response]
        return script
    }

    /// The first two "@@COMMENT" blocks of `text` and the first half of the third block's lines (five of nine, say),
    /// each line with its line break. A block runs from one "@@COMMENT" line to the next, the last one to the "@@DONE"
    /// line. A text with fewer than three blocks comes back whole.
    static func twoBlocksAndHalfOfTheThird(of text: String) -> String {
        var lines: [Substring] = []                     // every line of the text, with its line break
        var blockStarts: [Int] = []                     // positions in `lines` of the "@@COMMENT" lines
        var end: Int?                                   // position of the "@@DONE" line
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(of: "\n").map { text.index(after: $0) } ?? text.endIndex
            let marker = text[lineStart..<lineEnd].trimmingCharacters(in: .whitespacesAndNewlines)
            if marker == "@@DONE", end == nil { end = lines.count }
            if marker == "@@COMMENT", end == nil { blockStarts.append(lines.count) }
            lines.append(text[lineStart..<lineEnd])
            lineStart = lineEnd
        }
        guard blockStarts.count >= 3 else { return text }
        let third = blockStarts[2]
        let thirdEnd = blockStarts.count > 3 ? blockStarts[3] : (end ?? lines.count)
        let kept = third + (thirdEnd - third + 1) / 2
        return lines[..<kept].joined()
    }
}

/// Answers each request with the next response scripted for the request's purpose (the last one repeats), cut into
/// deltas of `chunkSize` characters, `delayPerChunk` apart, and ends with `.finished`. Same script, same deltas, same order.
///
/// - The request is recorded, and its response chosen, when `stream(_:)` is called. The stream itself is cold:
///   nothing is emitted until it is iterated.
/// - `failAfterChunks: n`: once n deltas are out, the stream throws `failure`. `stallAfterChunks: n`: once n deltas
///   are out, it emits nothing and does not finish until the consuming task is cancelled; it then throws `.cancelled`.
///   A response whose text has fewer than n deltas never reaches that point and finishes normally.
/// - A purpose the script has no response for: the stream throws `.notConfigured`.
/// - One model, "mock", with a context window of 1,000,000 tokens (plan section 5.2). A `.pdf` part is accepted and ignored.
public final class MockLLMProvider: LLMProvider, @unchecked Sendable {
    public let descriptor: ProviderDescriptor
    private let script: MockScript
    private let lock = NSLock()
    private var requests: [LLMRequest] = []
    private var answered: [RequestPurpose: Int] = [:]

    public init(id: ProviderID = "mock", script: MockScript = .sample, isLocal: Bool = true, supportsNativePDF: Bool = false) {
        self.script = script
        // "Mock" for the plain one; "Mock (remote)", "Mock (fail)", … for the others, so that a menu can tell them apart.
        let variant = id.hasPrefix("mock-") ? String(id.dropFirst("mock-".count)) : id
        descriptor = ProviderDescriptor(id: id, displayName: id == "mock" ? "Mock" : "Mock (\(variant))", vendor: "Mock", authMode: .none,
                                        isLocal: isLocal, destination: isLocal ? "this Mac" : "mock.example.org",
                                        supportsNativePDF: supportsNativePDF, streaming: .token,
                                        retentionNote: "A stand-in for tests and snapshots; nothing leaves this Mac.", isExperimental: false)
    }

    public var recordedRequests: [LLMRequest] {               // lock-protected
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    public func availability() async -> ProviderAvailability { .ready(detail: "Built in") }

    public func listModels() async throws -> [ModelInfo] {
        [ModelInfo(id: "mock", displayName: "mock", contextWindow: 1_000_000, supportsPDFInput: descriptor.supportsNativePDF)]
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        let playback = MockPlayback(response: record(request), request: request)
        return AsyncThrowingStream(unfolding: { try await playback.next() })
    }

    /// Keeps the request and returns the response that answers it: the next one for its purpose, the last one again
    /// when the list is used up, nil when the script has none.
    private func record(_ request: LLMRequest) -> MockResponse? {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        guard let scripted = script.responses[request.purpose], !scripted.isEmpty else { return nil }
        let position = answered[request.purpose, default: 0]
        answered[request.purpose] = position + 1
        return scripted[min(position, scripted.count - 1)]
    }
}

/// One answer being played. `next()` is what the stream calls for each element, in the consumer's own task, so
/// cancelling that task interrupts a delay or a stall at once.
private actor MockPlayback {
    private let response: MockResponse?
    private let purpose: RequestPurpose
    private let deltas: [String]
    private let usage: Usage
    private var emitted = 0
    private var ended = false

    init(response: MockResponse?, request: LLMRequest) {
        self.response = response
        purpose = request.purpose
        deltas = response?.deltas ?? []
        // Rough, and the same on every run: one token for every four characters.
        var promptCharacters = request.system.count
        for case .text(let text) in request.parts { promptCharacters += text.count }
        usage = Usage(inputTokens: max(1, promptCharacters / 4), outputTokens: max(1, (response?.text.count ?? 0) / 4))
    }

    func next() async throws -> LLMEvent? {
        guard let response else {
            throw LLMError.notConfigured("the mock script has no response for \"\(purpose.rawValue)\" requests")
        }
        if ended { return nil }
        if let limit = response.failAfterChunks, emitted >= limit {
            ended = true
            throw response.failure ?? LLMError.server(status: 500, message: "the mock was scripted to fail")
        }
        if let limit = response.stallAfterChunks, emitted >= limit {
            while true { try await pause(.seconds(3600)) }
        }
        if emitted < deltas.count {
            if response.delayPerChunk > .zero { try await pause(response.delayPerChunk) }
            emitted += 1
            return .textDelta(deltas[emitted - 1])
        }
        ended = true
        return .finished(response.stop, usage)
    }

    /// Sleeps, and turns the cancellation of the consuming task into the error providers are allowed to throw.
    private func pause(_ duration: Duration) async throws {
        do { try await Task.sleep(for: duration) } catch { throw LLMError.cancelled }
    }
}
