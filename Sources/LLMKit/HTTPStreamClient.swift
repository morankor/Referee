import Foundation
import RefereeCore

/// `URLError.timedOut`, already translated. The consumer sees `error`; the retry wrapper sees that the request waited as
/// long as the session allows (ten minutes of silence) and does not try again (plan section 5.7).
struct TimedOut: Error, Sendable {
    let error: LLMError
}

/// The shared HTTP machinery of plan section 5.3.
struct HTTPStreamClient: Sendable {
    static let maxErrorBodyBytes = 64 * 1024

    let session: URLSession
    /// How a transport failure reads to the user. Ollama turns a refused connection into "not running" (section 5.5).
    let transport: @Sendable (URLError) -> LLMError

    init(session: URLSession, transport: @escaping @Sendable (URLError) -> LLMError = { HTTPStreamClient.defaultTransport($0) }) {
        self.session = session
        self.transport = transport
    }

    static func defaultTransport(_ error: URLError) -> LLMError {
        switch error.code {
        case .cancelled: return .cancelled
        case .timedOut: return .network("the provider sent nothing for too long, so the request timed out")
        default: return .network(error.localizedDescription)
        }
    }

    /// Sends the request. On 2xx yields each line of the body, empty lines included; otherwise throws `HTTPFailure`
    /// carrying at most 64 KB of the body. Cold: nothing is sent before the first element is asked for, and the lines
    /// are read in the consumer's task, so cancelling that task cancels the request.
    func lines(for request: URLRequest) -> AsyncThrowingStream<String, Error> {
        let reader = LineReader(client: self, request: request)
        return AsyncThrowingStream(unfolding: { try await reader.next() })
    }

    /// A non-streaming call (model lists, versions): the body of a 2xx response, else `HTTPFailure`.
    func json(for request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            let http = try Self.http(response)
            guard (200..<300).contains(http.statusCode) else {
                throw HTTPFailure(status: http.statusCode, headers: Self.headers(of: http), body: data)
            }
            return data
        } catch {
            throw translate(error)
        }
    }

    /// Any error met while sending a request or reading its response, in the forms the providers handle: `HTTPFailure`,
    /// `LLMError` or `TimedOut`.
    func translate(_ error: Error) -> Error {
        switch error {
        case is HTTPFailure, is LLMError, is TimedOut:
            return error
        case let urlError as URLError:
            if urlError.code == .cancelled { return LLMError.cancelled }
            let mapped = transport(urlError)
            return urlError.code == .timedOut ? TimedOut(error: mapped) : mapped
        case is CancellationError:
            return LLMError.cancelled
        default:
            return LLMError.network(error.localizedDescription)
        }
    }

    static func http(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw LLMError.malformedResponse("the answer was not an HTTP response") }
        return http
    }

    static func headers(of response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            headers[String(describing: name).lowercased()] = String(describing: value)
        }
        return headers
    }
}

/// Reads one response body line by line through `LineSplitter` (`AsyncBytes.lines` drops empty lines, section 5.3).
/// Every `next()` runs in the consumer's task and AsyncThrowingStream asks for one element at a time, so the mutable
/// state needs no lock. When the reader is released before the body ends (the consumer stopped or was cancelled), it
/// cancels the request.
final class LineReader: @unchecked Sendable {
    private let client: HTTPStreamClient
    private let request: URLRequest
    private var bytes: URLSession.AsyncBytes.AsyncIterator?
    private var task: URLSessionDataTask?
    private var splitter = LineSplitter()
    private var ended = false

    init(client: HTTPStreamClient, request: URLRequest) {
        self.client = client
        self.request = request
    }

    deinit {
        task?.cancel()
    }

    func next() async throws -> String? {
        guard !ended else { return nil }
        do {
            var iterator: URLSession.AsyncBytes.AsyncIterator
            if let current = bytes { iterator = current } else { iterator = try await open() }
            defer { bytes = iterator }
            while let byte = try await iterator.next() {
                if let line = splitter.push(byte) { return line }
            }
            ended = true
            // A cancelled consumer can see the body end without an error (the request was cancelled under it). That is
            // a cancellation, not a body that ended early (found at Gate 1, under load).
            if Task.isCancelled {
                task?.cancel()
                throw LLMError.cancelled
            }
            return splitter.finish()
        } catch {
            ended = true
            task?.cancel()
            throw client.translate(error)
        }
    }

    /// Sends the request and waits for the head of the response. A status other than 2xx is thrown as `HTTPFailure`
    /// with the first 64 KB of its body.
    private func open() async throws -> URLSession.AsyncBytes.AsyncIterator {
        let (stream, response) = try await client.session.bytes(for: request)
        task = stream.task
        let http = try HTTPStreamClient.http(response)
        var iterator = stream.makeAsyncIterator()
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            while body.count < HTTPStreamClient.maxErrorBodyBytes, let byte = try await iterator.next() { body.append(byte) }
            throw HTTPFailure(status: http.statusCode, headers: HTTPStreamClient.headers(of: http), body: body)
        }
        return iterator
    }
}
