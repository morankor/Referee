import Foundation

/// Time as the resolver sees it. Injected (internal initialiser of `ReferenceResolver`) so that tests can space
/// requests, honour `Retry-After` and age cache entries without waiting: a test clock moves its own time forward
/// when asked to sleep.
protocol ResolverClock: Sendable {
    /// Wall-clock time: stamps results (`resolvedAt`), ages cache entries, orders the PDF cache.
    func now() -> Date
    /// Monotonic seconds since an arbitrary origin: spaces the requests to one host.
    func uptime() -> Double
    /// Returns once `uptime()` has reached `deadline` (at once when it already has). Throws `CancellationError`
    /// when the task is cancelled.
    func sleep(untilUptime deadline: Double) async throws
}

/// The clock of the app: `Date()` for dates, the continuous clock for spacing.
struct SystemResolverClock: ResolverClock {
    private let origin = ContinuousClock.now

    func now() -> Date { Date() }

    func uptime() -> Double {
        let elapsed = origin.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    func sleep(untilUptime deadline: Double) async throws {
        try Task.checkCancellation()
        guard deadline > uptime() else { return }
        try await Task.sleep(until: origin.advanced(by: .seconds(deadline)), clock: .continuous)
    }
}
