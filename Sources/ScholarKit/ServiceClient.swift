import Foundation
import RefereeCore

/// One GET to Crossref or OpenAlex under the host's limits, with the retry of plan.md section 8.7: a 429 or a 5xx
/// is retried once, after `Retry-After` or 2 s; a second one, a network error or any other status is a failure.
/// Runs outside the resolver's actor.
struct ServiceClient: Sendable {
    enum Response: Sendable, Equatable {
        case ok(Data)                    // 2xx and its body
        case notFound                    // 404
        case failed(reason: String)      // an id for the log: "network", "cancelled", "rate-limited", "server", "http-403", …
    }

    let session: URLSession
    let limiter: HostLimiter
    let clock: any ResolverClock

    /// A lookup answer is a few kilobytes; more than this is not a lookup answer.
    static let maxBodyBytes = 4_000_000
    /// Wait used when a 429 or 5xx gives no usable `Retry-After`.
    static let defaultRetryWait: Double = 2
    /// A server that asks for a longer wait than this is not retried: the lookup fails at once, uncached, and the
    /// card offers Retry.
    static let maxRetryWait: Double = 60

    func get(_ request: URLRequest, host: ServiceHost, policy: HostPolicy) async -> Response {
        var attempt = 1
        while true {
            do {
                try await limiter.acquire(host, policy: policy)
            } catch {
                return .failed(reason: "cancelled")
            }
            let exchange = await send(request)
            await limiter.release(host)
            switch exchange {
            case .failure(let reason):
                Log.event("scholar.request", ["host": .id(host.rawValue), "attempt": .int(attempt), "error": .id(reason)])
                return .failed(reason: reason)
            case .reply(let status, let retryAfter, let body):
                Log.event("scholar.request", ["host": .id(host.rawValue), "attempt": .int(attempt), "status": .int(status)])
                if (200..<300).contains(status) { return .ok(body) }
                if status == 404 { return .notFound }
                guard status == 429 || (500..<600).contains(status) else { return .failed(reason: "http-\(status)") }
                let wait = retryAfter ?? Self.defaultRetryWait
                guard attempt == 1, wait <= Self.maxRetryWait else { return .failed(reason: status == 429 ? "rate-limited" : "server") }
                await limiter.holdOff(host, seconds: wait)
                attempt += 1
            }
        }
    }

    // ---- one exchange ----

    private enum Exchange {
        case reply(status: Int, retryAfter: Double?, body: Data)
        case failure(String)
    }

    private func send(_ request: URLRequest) async -> Exchange {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                bytes.task.cancel()
                return .failure("not-http")
            }
            guard (200..<300).contains(http.statusCode) else {
                bytes.task.cancel()                                  // the body of an error is not needed
                return .reply(status: http.statusCode, retryAfter: retryAfter(in: http), body: Data())
            }
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count > Self.maxBodyBytes {
                    bytes.task.cancel()
                    return .failure("too-large")
                }
            }
            return .reply(status: http.statusCode, retryAfter: nil, body: body)
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
            return .failure(cancelled ? "cancelled" : "network")
        }
    }

    /// `Retry-After` as seconds or as an HTTP date; nil when absent or unreadable.
    private func retryAfter(in response: HTTPURLResponse) -> Double? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
            return nil
        }
        if let seconds = Double(value) { return seconds.isFinite ? max(0, seconds) : nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(clock.now()))
    }
}
