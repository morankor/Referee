import Foundation
import RefereeCore

/// Serves HTTP requests from a handler instead of the network (plan.md section 10.3): the handler maps a request to a
/// status, headers and a body delivered in chunks, with an optional delay before each chunk.
///
/// **One handler per test, not per process.** Swift Testing runs every test in a task of its own, in parallel with
/// the others, so a single shared handler would be overwritten by whichever test set it last. The handler and the
/// record of requests therefore belong to the task that calls `setHandler`, and they serve the sessions that the same
/// task makes with `session()`. In practice:
///
/// - Call `setHandler`, `session()` and `recordedRequests` from the test function itself (or from functions it calls
///   directly), not from a child task, and make a new session in every test. A session never reaches the handler of
///   another running test.
/// - Start every test that uses the stub with `setHandler`, also when requests should fail (`setHandler(nil)`).
///   The call empties `recordedRequests` and replaces whatever an earlier test left behind. Tasks are told apart by
///   their identity, which a new task can inherit from one that has ended; a test that makes a session and never
///   sets a handler may therefore meet the handler of a test that is over, instead of "connection refused".
/// - Code that runs outside any task shares one slot.
///
/// **Chunks really arrive one by one.** URLSession holds back the first 512 bytes of a body that has no Content-Type
/// (or is text/plain) while it guesses the type, so the small chunks of a streamed answer would arrive together at
/// the end. The stub therefore adds the header `X-Content-Type-Options: nosniff` to every response that does not set
/// it. With `delayPerChunk` zero the whole body is delivered at once, in as many pieces as there are chunks.
public final class StubURLProtocol: URLProtocol {
    public struct Response: Sendable {
        public var status: Int
        public var headers: [String: String]
        public var chunks: [Data]             // delivered one by one, so parsers see real chunk boundaries
        public var delayPerChunk: Duration    // waited before every chunk, the first one included
        public init(status: Int = 200, headers: [String: String] = [:], chunks: [Data], delayPerChunk: Duration = .zero) {
            self.status = status; self.headers = headers; self.chunks = chunks; self.delayPerChunk = delayPerChunk
        }
    }

    /// Sets the calling test's handler and empties its `recordedRequests`. A handler that returns nil, or no handler
    /// (`setHandler(nil)`), makes the request fail with `URLError.cannotConnectToHost`.
    /// The handler gets the request as it is recorded: with its body in `httpBody`.
    public static func setHandler(_ handler: (@Sendable (URLRequest) -> Response?)?) {   // nil response = connection refused
        registry.setHandler(handler, scope: currentScope())
    }

    /// A new session whose every request goes to the calling test's handler and never to the network. It keeps no
    /// cache and no cookies.
    public static func session() -> URLSession {                                          // a URLSession that only talks to the handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = [scopeHeader: String(currentScope())]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    /// The requests the calling test's sessions have made since its last `setHandler`, in order of arrival.
    public static var recordedRequests: [URLRequest] {                                    // bodies included (httpBodyStream is read)
        registry.requests(scope: currentScope())
    }

    // ---- scopes ----

    /// Sessions carry their scope in this header. It is removed before a request is recorded or shown to a handler.
    private static let scopeHeader = "X-Referee-Stub-Scope"
    private static let noSniffHeader = "X-Content-Type-Options"
    private static let registry = StubRegistry()

    /// The identity of the running task, or 0 outside any task. It is unique among the tasks that are alive, which is
    /// what keeps tests that run at the same time apart; it is not unique over time.
    private static func currentScope() -> Int {
        withUnsafeCurrentTask { $0?.hashValue ?? 0 }
    }

    // ---- URLProtocol ----

    private let delivery = StubDelivery()

    public override class func canInit(with request: URLRequest) -> Bool { true }

    public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    public override func startLoading() {
        let scope = request.value(forHTTPHeaderField: Self.scopeHeader).flatMap { Int($0) }
        let recorded = Self.recordable(request)
        let handler = Self.registry.record(recorded, scope: scope)
        guard let response = handler?(recorded) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        var headers = response.headers
        if !headers.keys.contains(where: { $0.caseInsensitiveCompare(Self.noSniffHeader) == .orderedSame }) {
            headers[Self.noSniffHeader] = "nosniff"
        }
        guard let url = request.url,
              let head = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: head, cacheStoragePolicy: .notAllowed)
        if response.delayPerChunk <= .zero {
            for chunk in response.chunks { client?.urlProtocol(self, didLoad: chunk) }
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let delivery = self.delivery
        delivery.task = Task {
            for chunk in response.chunks {
                do { try await Task.sleep(for: response.delayPerChunk) } catch { return }
                delivery.unlessStopped { self.client?.urlProtocol(self, didLoad: chunk) }
            }
            delivery.unlessStopped { self.client?.urlProtocolDidFinishLoading(self) }
        }
    }

    public override func stopLoading() {
        delivery.stop()
    }

    /// The request as tests see it: without the scope header, and with the body read from `httpBodyStream` into
    /// `httpBody` (inside a URLProtocol the body of a request is only available as a stream).
    private static func recordable(_ request: URLRequest) -> URLRequest {
        var copy = request
        copy.setValue(nil, forHTTPHeaderField: scopeHeader)
        guard copy.httpBody == nil, let stream = request.httpBodyStream else { return copy }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        stream.open()
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        stream.close()
        copy.httpBody = body
        return copy
    }
}

/// A delayed delivery that `stopLoading` can end: after `stop()` no further call reaches the URL loading system.
private final class StubDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var task: Task<Void, Never>?            // set once in startLoading, before stopLoading can run

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        task?.cancel()
    }

    func unlessStopped(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        if !stopped { body() }
    }
}

/// Handlers and recorded requests, one slot per scope.
private final class StubRegistry: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> StubURLProtocol.Response?

    private struct Slot {
        var handler: Handler?
        var requests: [URLRequest] = []
    }

    private let lock = NSLock()
    private var slots: [Int: Slot] = [:]
    private var latest = 0                  // the scope whose handler was set last

    func setHandler(_ handler: Handler?, scope: Int) {
        lock.lock(); defer { lock.unlock() }
        slots[scope] = Slot(handler: handler)
        latest = scope
    }

    func requests(scope: Int) -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return slots[scope]?.requests ?? []
    }

    /// Keeps the request and returns the handler that answers it. A request without a scope comes from a session that
    /// `session()` did not make (or whose additional headers were replaced); it goes to the handler set last.
    func record(_ request: URLRequest, scope: Int?) -> Handler? {
        lock.lock(); defer { lock.unlock() }
        let key = scope ?? latest
        slots[key, default: Slot()].requests.append(request)
        return slots[key]?.handler
    }
}
