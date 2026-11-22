import Foundation
import RefereeCore

// Wave 0a placeholder (see Placeholder.swift): the handler is ignored and every request made through `session()`
// fails as "connection refused". Nothing can reach the network through it.

public final class StubURLProtocol: URLProtocol {
    public struct Response: Sendable {
        public var status: Int
        public var headers: [String: String]
        public var chunks: [Data]             // delivered one by one, so parsers see real chunk boundaries
        public var delayPerChunk: Duration
        public init(status: Int = 200, headers: [String: String] = [:], chunks: [Data], delayPerChunk: Duration = .zero) {
            self.status = status; self.headers = headers; self.chunks = chunks; self.delayPerChunk = delayPerChunk
        }
    }

    public static func setHandler(_ handler: (@Sendable (URLRequest) -> Response?)?) {}   // nil response = connection refused

    public static func session() -> URLSession {                                          // a URLSession that only talks to the handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    public static var recordedRequests: [URLRequest] { [] }                                   // bodies included (httpBodyStream is read)

    // ---- URLProtocol ----

    public override class func canInit(with request: URLRequest) -> Bool { true }

    public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    public override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }

    public override func stopLoading() {}
}
