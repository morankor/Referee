import Foundation
@testable import ScholarKit

/// A clock whose time moves only when a test or a sleeper moves it. `sleep(untilUptime:)` returns at once after
/// setting the time to its deadline, so the spacing of requests and `Retry-After` cost no real time, and a test can
/// read from `uptime()` when each request was sent.
final class TestClock: ResolverClock, @unchecked Sendable {
    private let lock = NSLock()
    private let start: Date
    private var elapsed: Double = 0

    /// 2027-01-15 08:00:00 UTC, a whole second, so that results stamped with it survive the ISO 8601 cache file unchanged.
    init(start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self.start = start
    }

    func now() -> Date {
        lock.withLock { start.addingTimeInterval(elapsed) }
    }

    func uptime() -> Double {
        lock.withLock { elapsed }
    }

    func sleep(untilUptime deadline: Double) async throws {
        try Task.checkCancellation()
        lock.withLock { elapsed = max(elapsed, deadline) }
        await Task.yield()
    }

    /// Moves the time forward, as days passing between two lookups.
    func advance(by seconds: Double) {
        lock.withLock { elapsed += seconds }
    }
}
