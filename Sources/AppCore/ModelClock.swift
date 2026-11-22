import Foundation

/// The time source of the two models: the dates they stamp on what they create, and the waits behind every debounce
/// (autosave 1 s, settings save 0.5 s, report lint 0.5 s) and the fading of notices (6 s). Tests inject a clock they
/// advance by hand (plan.md section 11.4, WP8b: "use an injected clock for debounces").
///
/// A wait is given as a deadline, computed when the wait is scheduled, not when it starts: a test that advances its
/// clock before the waiting task has even run still releases it.
protocol ModelClock: Sendable {
    func now() -> Date
    /// Returns once `now() >= deadline`. Throws `CancellationError` when the waiting task is cancelled.
    func sleep(until deadline: Date) async throws
}

/// The wall clock, for the app.
struct SystemModelClock: ModelClock {
    func now() -> Date { Date() }

    func sleep(until deadline: Date) async throws {
        let interval = deadline.timeIntervalSinceNow
        if interval > 0 { try await Task.sleep(for: .seconds(interval)) }
        try Task.checkCancellation()
    }
}
