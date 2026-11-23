import Foundation
import RefereeCore

/// The retry rule of plan section 5.7, which every HTTP provider's `stream` goes through.
///
/// - Only while no text delta has been yielded: after the first delta a failure goes to the engine, which keeps the
///   partial result.
/// - `.rateLimited` and `.overloaded` with a `Retry-After`: wait `min(t, 60)` s plus 0–1 s of jitter. Otherwise, and
///   for `.server` and `.network`: 2 s, 6 s, 18 s, each ±25%.
/// - At most three attempts in all; a `.status("Retrying in N s (reason)")` before each wait.
/// - Never retried: a timeout (the request has already waited ten minutes) and every error whose `isRetryable` is false.
///
/// `sleep` and `random` are injected so that tests run instantly and deterministically.
struct RetryPolicy: Sendable {
    var maxAttempts = 3
    var backoffSeconds: [Double] = [2, 6, 18]
    var jitter = 0.25
    var maxRetryAfterSeconds: Double = 60
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    var random: @Sendable () -> Double = { Double.random(in: 0..<1) }

    static let standard = RetryPolicy()
    /// One attempt, no retry.
    static let none = RetryPolicy(maxAttempts: 1)

    /// How long to wait before retry number `retry` (1 for the first) after `error`; nil = do not retry.
    func delay(after error: LLMError, retry: Int) -> Duration? {
        let seconds: Double
        switch error {
        case .rateLimited(let retryAfter?, _), .overloaded(let retryAfter?):
            seconds = min(max(retryAfter, 0), maxRetryAfterSeconds) + random()
        case .rateLimited, .overloaded, .server, .network:
            guard !backoffSeconds.isEmpty else { return nil }
            let base = backoffSeconds[min(max(retry - 1, 0), backoffSeconds.count - 1)]
            seconds = base * (1 - jitter + 2 * jitter * random())
        default:
            return nil
        }
        return .seconds(seconds)
    }

    /// "Retrying in 6 s (overloaded)".
    static func status(waiting delay: Duration, after error: LLMError) -> String {
        let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
        return "Retrying in \(max(1, Int(seconds.rounded()))) s (\(reason(error)))"
    }

    static func reason(_ error: LLMError) -> String {
        switch error {
        case .rateLimited: return "rate limited"
        case .overloaded: return "overloaded"
        case .server(let status, _): return "server error \(status)"
        case .network: return "network error"
        default: return "error"
        }
    }

    static func logReason(_ error: LLMError) -> String {
        switch error {
        case .rateLimited: return "rate-limited"
        case .overloaded: return "overloaded"
        case .server: return "server"
        case .network: return "network"
        default: return "other"
        }
    }
}

/// The error an attempt ended with, as the consumer will see it, and whether the rule allows another attempt.
struct AttemptFailure: Sendable {
    let error: LLMError
    let retryable: Bool

    init(_ error: Error) {
        switch error {
        case let timedOut as TimedOut:
            self.error = timedOut.error; self.retryable = false
        case let llm as LLMError:
            self.error = llm; self.retryable = llm.isRetryable
        case is CancellationError:
            self.error = .cancelled; self.retryable = false
        default:
            self.error = .network(error.localizedDescription); self.retryable = true
        }
    }
}

/// Plays one attempt after another, by the rule of `RetryPolicy`. Every `next()` runs in the consumer's task, one at a
/// time, so the state needs no lock; the wait happens in the consumer's task too, so cancelling it ends the wait.
final class RetryingReader: @unchecked Sendable {
    private let policy: RetryPolicy
    private let providerID: ProviderID
    private let makeAttempt: @Sendable () throws -> AsyncThrowingStream<LLMEvent, Error>
    private var current: AsyncThrowingStream<LLMEvent, Error>.AsyncIterator?
    private var attempts = 0
    private var sawText = false
    private var pendingWait: Duration?
    private var done = false

    init(policy: RetryPolicy, providerID: ProviderID, makeAttempt: @escaping @Sendable () throws -> AsyncThrowingStream<LLMEvent, Error>) {
        self.policy = policy
        self.providerID = providerID
        self.makeAttempt = makeAttempt
    }

    func next() async throws -> LLMEvent? {
        guard !done else { return nil }
        if let wait = pendingWait {
            pendingWait = nil
            do {
                try await policy.sleep(wait)
            } catch {
                done = true
                throw LLMError.cancelled
            }
        }
        let event: LLMEvent?
        do {
            event = try await pull()
        } catch {
            current = nil
            let failure = AttemptFailure(error)
            guard failure.retryable, !sawText, attempts < policy.maxAttempts,
                  let wait = policy.delay(after: failure.error, retry: attempts) else {
                done = true
                throw failure.error
            }
            pendingWait = wait
            Log.event("llm.retry", ["provider": .id(providerID), "attempt": .int(attempts + 1),
                                    "reason": .id(RetryPolicy.logReason(failure.error))])
            return .status(RetryPolicy.status(waiting: wait, after: failure.error))
        }
        guard let event else {
            done = true
            return nil
        }
        switch event {
        case .textDelta: sawText = true
        case .finished: done = true
        case .status, .model: break
        }
        return event
    }

    private func pull() async throws -> LLMEvent? {
        var iterator: AsyncThrowingStream<LLMEvent, Error>.AsyncIterator
        if let existing = current {
            iterator = existing
        } else {
            attempts += 1
            iterator = try makeAttempt().makeAsyncIterator()
        }
        defer { current = iterator }
        return try await iterator.next()
    }
}
