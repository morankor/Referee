import Foundation
import Testing
import RefereeCore
import TestSupport
@testable import LLMKit

// Helpers of the LLMKit tests. No test reaches a vendor: every session comes from StubURLProtocol.session() (or, for
// the timeout case, from TimeoutURLProtocol below), made in the test function itself, and no key is real.

/// Provider settings a test can change while a provider is in use (settings are read at call time, section 5.3).
final class SettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ProviderID: ProviderSettings]

    init(_ values: [ProviderID: ProviderSettings] = [:]) { self.values = values }

    func get(_ id: ProviderID) -> ProviderSettings {
        lock.withLock { values[id] ?? Harness.defaultSettings(for: id) }
    }

    func set(_ id: ProviderID, _ settings: ProviderSettings) {
        lock.withLock { values[id] = settings }
    }
}

/// A provider environment around a session that the calling test made. Construct it in the test function itself, after
/// `StubURLProtocol.setHandler`: the session belongs to the task that makes it.
struct Harness {
    static let keys: [String: String] = ["anthropic-api": "test-key-anthropic-0001", "openai-api": "test-key-openai-0001",
                                         "gemini-api": "test-key-gemini-0001", "xai-api": "test-key-xai-0001"]

    let session: URLSession
    let secrets: InMemorySecretStore
    let settings: SettingsBox

    init(keys: [String: String] = Harness.keys, settings: [ProviderID: ProviderSettings] = [:],
         session: URLSession = StubURLProtocol.session()) {
        self.session = session
        self.secrets = InMemorySecretStore(keys)
        self.settings = SettingsBox(settings)
    }

    var environment: ProviderEnvironment {
        let settings = self.settings
        return ProviderEnvironment(settings: { settings.get($0) }, secrets: secrets, urlSession: session, processEnvironment: [:])
    }

    func provider(_ id: ProviderID, retry: RetryPolicy = .none) -> HTTPProvider {
        guard let provider = LLMKitFactory.makeProviders(environment: environment, retry: retry).first(where: { $0.id == id }) else {
            preconditionFailure("no provider \(id)")
        }
        return provider
    }

    /// Enabled, model "m"; Ollama keeps its default extraBodyJSON (`{"think": false}`).
    static func defaultSettings(for id: ProviderID) -> ProviderSettings {
        var settings = DefaultSettings.make().providers[id] ?? ProviderSettings(enabled: true, inputMode: .auto)
        settings.enabled = true
        settings.model = "m"
        return settings
    }
}

// ---- requests the tests send ----

enum Requests {
    static let system = "SYSTEM PROMPT"
    static let task = "TASK TEXT"
    static let paper = "PAPER TEXT"
    static let pdfBytes = Data("%PDF-1.7 a very small manuscript".utf8)
    static let pdfFileName = "Real Name 2024 Submission.pdf"

    static func text(model: String? = "m1", maxOutputTokens: Int? = nil, contextWindow: Int? = nil) -> LLMRequest {
        LLMRequest(model: model, system: system, parts: [.text(task)], maxOutputTokens: maxOutputTokens, contextWindow: contextWindow,
                   purpose: .review)
    }

    /// The paper as text, the cache boundary, the task (a text-mode review, section 6.3).
    static func paperThenTask(model: String? = "m1", maxOutputTokens: Int? = nil, contextWindow: Int? = nil) -> LLMRequest {
        LLMRequest(model: model, system: system, parts: [.text(paper), .cacheBoundary, .text(task)], maxOutputTokens: maxOutputTokens,
                   contextWindow: contextWindow, purpose: .review)
    }

    /// The PDF, the cache boundary, the task (a PDF-mode review).
    static func pdfThenTask(model: String? = "m1") -> LLMRequest {
        LLMRequest(model: model, system: system, parts: [.pdf(data: pdfBytes, fileName: pdfFileName), .cacheBoundary, .text(task)],
                   purpose: .review)
    }
}

// ---- stub responses ----

enum Chunking: String, CaseIterable, Sendable {
    case whole, bytes

    func chunks(_ body: String) -> [Data] {
        let data = Data(body.utf8)
        switch self {
        case .whole: return [data]
        case .bytes: return data.map { Data([$0]) }
        }
    }
}

enum Stub {
    static func stream(_ body: String, for provider: ProviderID, chunking: Chunking = .whole, delay: Duration = .zero) -> StubURLProtocol.Response {
        let type = provider == "ollama" ? "application/x-ndjson" : "text/event-stream"
        return StubURLProtocol.Response(headers: ["Content-Type": type], chunks: chunking.chunks(body), delayPerChunk: delay)
    }

    static func json(_ body: String, status: Int = 200, headers: [String: String] = [:]) -> StubURLProtocol.Response {
        var all = headers
        all["Content-Type"] = all["Content-Type"] ?? "application/json"
        return StubURLProtocol.Response(status: status, headers: all, chunks: [Data(body.utf8)])
    }

    /// The recorded body of Appendix D for a provider.
    static func appendixD(_ provider: ProviderID) -> String {
        switch provider {
        case "anthropic-api": return AppendixD.anthropic
        case "openai-api": return AppendixD.openai
        case "xai-api": return AppendixD.xai
        case "gemini-api": return AppendixD.gemini
        default: return AppendixD.ollama
        }
    }
}

// ---- reading what came back ----

struct StreamOutcome: Sendable {
    var events: [LLMEvent] = []
    var error: Error?

    var deltas: [String] {
        events.compactMap { event in
            if case .textDelta(let text) = event { return text }
            return nil
        }
    }
    var text: String { deltas.joined() }
    var statuses: [String] {
        events.compactMap { event in
            if case .status(let text) = event { return text }
            return nil
        }
    }
    var finishes: [LLMEvent] {
        events.filter { event in
            if case .finished = event { return true }
            return false
        }
    }
    /// The models the stream named (`.model`, step 5c), in order.
    var models: [String] {
        events.compactMap { event in
            if case .model(let name) = event { return name }
            return nil
        }
    }
    var llmError: LLMError? { error as? LLMError }
}

func collect(_ stream: AsyncThrowingStream<LLMEvent, Error>) async -> StreamOutcome {
    var outcome = StreamOutcome()
    do {
        for try await event in stream { outcome.events.append(event) }
    } catch {
        outcome.error = error
    }
    return outcome
}

extension URLRequest {
    var jsonBody: JSONValue? { httpBody.flatMap { JSONValue.parse($0) } }
}

/// A JSON literal of a test, parsed the same way as the request bodies.
func json(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) -> JSONValue {
    guard let value = JSONValue.parse(text) else {
        Issue.record("not JSON: \(text)", sourceLocation: sourceLocation)
        return .null
    }
    return value
}

/// The case of an error, without its message, for tables of expected mappings.
enum ErrorKind: String, Sendable {
    case notConfigured, auth, rateLimited, quotaExhausted, overloaded, contextTooLong, invalidRequest, modelNotFound, refused, network
    case server, malformedResponse, cancelled, cli, other

    init(_ error: Error?) {
        guard let error = error as? LLMError else { self = .other; return }
        switch error {
        case .notConfigured: self = .notConfigured
        case .auth: self = .auth
        case .rateLimited: self = .rateLimited
        case .quotaExhausted: self = .quotaExhausted
        case .overloaded: self = .overloaded
        case .contextTooLong: self = .contextTooLong
        case .invalidRequest: self = .invalidRequest
        case .modelNotFound: self = .modelNotFound
        case .refused: self = .refused
        case .network: self = .network
        case .server: self = .server
        case .malformedResponse: self = .malformedResponse
        case .cancelled: self = .cancelled
        case .cliLaunchFailed, .cliTimeout, .cliExited, .toolUseBlocked: self = .cli
        }
    }
}

extension LLMError {
    var retryAfter: Double? {
        switch self {
        case .rateLimited(let seconds, _), .overloaded(let seconds): return seconds
        default: return nil
        }
    }
    var status: Int? {
        if case .server(let status, _) = self { return status }
        return nil
    }
}

// ---- small concurrency helpers ----

/// A lock-protected counter, for handlers that answer by the order of requests.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// 1 for the first call, 2 for the second, …
    func next() -> Int { lock.withLock { count += 1; return count } }
    var value: Int { lock.withLock { count } }
}

/// Records the waits of a retry rule instead of sleeping, so that retry tests are instant.
final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Duration] = []

    var durations: [Duration] { lock.withLock { recorded } }

    /// Three attempts, no sleeping, jitter that leaves the base delays as they are (random() == 0.5).
    func policy(maxAttempts: Int = 3, random: Double = 0.5) -> RetryPolicy {
        RetryPolicy(maxAttempts: maxAttempts, sleep: { [self] duration in lock.withLock { recorded.append(duration) } }, random: { random })
    }
}

/// Polls `condition` until it holds or `timeout` passes; returns whether it held.
func eventually(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// A URL protocol whose every request fails with `URLError.timedOut`, as a request does after ten minutes of silence.
/// Its sessions are made per test and count their own requests.
final class TimeoutURLProtocol: URLProtocol {
    private static let tokenHeader = "X-LLMKit-Test-Token"
    private static let counts = CountRegistry()

    static func session(token: String) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TimeoutURLProtocol.self]
        configuration.httpAdditionalHeaders = [tokenHeader: token]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }

    static func requestCount(token: String) -> Int { counts.count(token) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.counts.add(request.value(forHTTPHeaderField: Self.tokenHeader) ?? "")
        client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
    }

    override func stopLoading() {}
}

final class CountRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func add(_ token: String) { lock.withLock { counts[token, default: 0] += 1 } }
    func count(_ token: String) -> Int { lock.withLock { counts[token] ?? 0 } }
}
