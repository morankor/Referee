import Foundation
import RefereeCore

/// Streams an open-access PDF into a file (plan.md sections 8.7 and 12.5): https only, redirects followed only to
/// https, stopped at the size limit, accepted only when the body starts with `%PDF-`. Throws `ResolverError` only.
/// Runs outside the resolver's actor.
struct PDFDownloader: Sendable {
    static let defaultMaxBytes = 100_000_000                 // 100 MB
    static let signature = Data("%PDF-".utf8)
    /// Longest tolerated silence while a PDF arrives.
    static let timeout: TimeInterval = 60
    private static let writeChunk = 1 << 16

    let session: URLSession
    let maxBytes: Int

    /// Writes the body to `file` (which exists and is empty) and returns its size.
    func download(_ url: URL, to file: URL) async throws -> Int {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue(ServiceRequests.userAgent(contact: nil), forHTTPHeaderField: "User-Agent")
        let redirects = HTTPSRedirectsOnly()
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: redirects)
            guard !redirects.refusedRedirect else {
                bytes.task.cancel()
                throw ResolverError.noOpenAccessPDF                  // it leads to plain http: offered in the browser instead
            }
            guard let http = response as? HTTPURLResponse else {
                bytes.task.cancel()
                throw ResolverError.downloadFailed("the server did not answer over HTTP")
            }
            guard (200..<300).contains(http.statusCode) else {
                bytes.task.cancel()
                throw ResolverError.downloadFailed("HTTP \(http.statusCode)")
            }
            guard http.expectedContentLength <= Int64(maxBytes) else {
                bytes.task.cancel()
                throw ResolverError.downloadFailed(tooLarge)
            }
            return try await write(bytes, to: file)
        } catch {
            throw Self.resolverError(for: error)
        }
    }

    private func write(_ bytes: URLSession.AsyncBytes, to file: URL) async throws -> Int {
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: file)
        } catch {
            bytes.task.cancel()
            throw ResolverError.downloadFailed("it could not be saved")
        }
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(Self.writeChunk)
        var total = 0
        var signatureChecked = false
        for try await byte in bytes {
            total += 1
            guard total <= maxBytes else {
                bytes.task.cancel()
                throw ResolverError.downloadFailed(tooLarge)
            }
            buffer.append(byte)
            if !signatureChecked, total == Self.signature.count {
                guard buffer.starts(with: Self.signature) else {
                    bytes.task.cancel()
                    throw ResolverError.notAPDF
                }
                signatureChecked = true
            }
            if buffer.count >= Self.writeChunk {
                try flush(&buffer, to: handle)
            }
        }
        guard signatureChecked else { throw ResolverError.notAPDF }   // shorter than the signature
        try flush(&buffer, to: handle)
        return total
    }

    private func flush(_ buffer: inout Data, to handle: FileHandle) throws {
        do {
            try handle.write(contentsOf: buffer)
        } catch {
            throw ResolverError.downloadFailed("it could not be saved")
        }
        buffer.removeAll(keepingCapacity: true)
    }

    private var tooLarge: String {
        maxBytes >= 1_000_000 ? "it is larger than \(maxBytes / 1_000_000) MB" : "it is larger than \(maxBytes) bytes"
    }

    static func resolverError(for error: Error) -> ResolverError {
        if let error = error as? ResolverError { return error }
        if error is CancellationError { return .downloadFailed("it was cancelled") }
        guard let urlError = error as? URLError else { return .downloadFailed("the connection failed") }
        switch urlError.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: return .offline
        case .cancelled: return .downloadFailed("it was cancelled")
        case .timedOut: return .downloadFailed("the server did not answer in time")
        case .appTransportSecurityRequiresSecureConnection: return .noOpenAccessPDF
        default: return .downloadFailed("the connection failed")
        }
    }
}

/// Lets a download follow redirects to https addresses only, and remembers when it refused one.
final class HTTPSRedirectsOnly: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var refused = false

    var refusedRedirect: Bool { lock.withLock { refused } }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        if request.url?.scheme?.lowercased() == "https" { return request }
        lock.withLock { refused = true }
        return nil
    }
}
