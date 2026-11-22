import Foundation
import Testing
import RefereeCore
@testable import ScholarKit
import TestSupport

/// Acceptance row "rate limits" (plan.md section 11.4, WP7; "Politeness and limits" in section 8.7). The test clock
/// does the waiting, so no test here sleeps for the spacing itself.
@Suite struct ScholarKitRateLimitTests {
    @Test func twoCrossrefCallsInARowAreAtLeastOneSecondApart() async throws {
        let clock = TestClock()
        let arrivals = ArrivalLog(clock: clock)
        StubURLProtocol.setHandler { request in
            arrivals.record(request)
            return request.url?.host == "api.crossref.org" ? Stub.json(Bodies.crossrefHochreiter) : Stub.json(Bodies.openAlexHochreiter)
        }
        let harness = ResolverHarness(clock: clock)
        defer { harness.cleanUp() }
        let entry = try Entries.hochreiter()

        _ = await harness.resolver.resolve(entry, documentSHA256: Documents.first)
        _ = await harness.resolver.resolve(entry, documentSHA256: Documents.second)

        let crossref = arrivals.at("api.crossref.org")
        #expect(crossref.count == 2)
        #expect(crossref.map(\.uptime) == [0, 1])
    }

    @Test func crossrefCallsMadeAtOnceAreSpacedAndNeverInFlightTogether() async throws {
        let clock = TestClock()
        let arrivals = ArrivalLog(clock: clock)
        let body = Data(Bodies.crossrefHochreiter.utf8)
        // The answer arrives in two halves 100 ms apart: it takes at least 200 ms from the request to its end.
        let slow = StubURLProtocol.Response(status: 200, headers: ["Content-Type": "application/json"],
                                            chunks: [Data(body.prefix(body.count / 2)), Data(body.dropFirst(body.count / 2))],
                                            delayPerChunk: .milliseconds(100))
        StubURLProtocol.setHandler { request in
            arrivals.record(request)
            return request.url?.host == "api.crossref.org" ? slow : Stub.json(Bodies.openAlexHochreiter)
        }
        let harness = ResolverHarness(clock: clock)
        defer { harness.cleanUp() }
        let entry = try Entries.hochreiter()

        async let first = harness.resolver.resolve(entry, documentSHA256: Documents.first)
        async let second = harness.resolver.resolve(entry, documentSHA256: Documents.second)
        let results = await [first, second]

        #expect(results.map(\.status) == [.resolved, .resolved])
        let crossref = arrivals.at("api.crossref.org")
        #expect(crossref.count == 2)
        guard crossref.count == 2 else { return }
        #expect(crossref[1].uptime - crossref[0].uptime >= 1)
        // Sent only after the first answer had been read to its end.
        #expect(crossref[0].instant.duration(to: crossref[1].instant) >= .milliseconds(200))
    }

    @Test func openAlexCallsAreAFifthOfASecondApart() async throws {
        let clock = TestClock()
        let arrivals = ArrivalLog(clock: clock)
        StubURLProtocol.setHandler { request in
            arrivals.record(request)
            return Stub.json(Bodies.openAlexHochreiter)
        }
        let harness = ResolverHarness(clock: clock)
        defer { harness.cleanUp() }
        var entry = try Entries.hochreiter()
        entry.parsed.doi = "10.1162/neco.1997.9.8.1735"

        _ = await harness.resolver.resolve(entry, documentSHA256: Documents.first)
        _ = await harness.resolver.resolve(entry, documentSHA256: Documents.second)

        let openAlex = arrivals.at("api.openalex.org")
        #expect(openAlex.count == 2)
        guard openAlex.count == 2 else { return }
        #expect(abs(openAlex[1].uptime - openAlex[0].uptime - 0.2) < 1e-9)
    }

    // ---- the limiter itself ----

    @Test func thePublicPoolAdmitsOneRequestAtATime() async throws {
        let clock = TestClock()
        let limiter = HostLimiter(clock: clock)
        let policy = HostPolicy.crossref(polite: false)
        try await limiter.acquire(.crossref, policy: policy)
        let second = Task { () async throws -> Double in
            try await limiter.acquire(.crossref, policy: policy)
            return clock.uptime()
        }
        #expect(await waitUntil { await limiter.occupancy(.crossref).waiting == 1 })
        #expect(await limiter.occupancy(.crossref).inFlight == 1)
        #expect(clock.uptime() == 0)                          // the second has not started: it waits for the slot

        await limiter.release(.crossref)
        #expect(try await second.value == 1)
        #expect(await limiter.occupancy(.crossref).inFlight == 1)
        await limiter.release(.crossref)
        #expect(await limiter.occupancy(.crossref).inFlight == 0)
    }

    @Test func thePolitePoolAdmitsThreeAtATimeAndThreeASecond() async throws {
        let clock = TestClock()
        let limiter = HostLimiter(clock: clock)
        let policy = HostPolicy.crossref(polite: true)
        var starts: [Double] = []
        for _ in 0..<3 {
            try await limiter.acquire(.crossref, policy: policy)
            starts.append(clock.uptime())
        }
        #expect(zip(starts, [0, 1.0 / 3, 2.0 / 3]).allSatisfy { abs($0 - $1) < 1e-9 })
        #expect(await limiter.occupancy(.crossref).inFlight == 3)

        let fourth = Task { () async throws -> Double in
            try await limiter.acquire(.crossref, policy: policy)
            return clock.uptime()
        }
        #expect(await waitUntil { await limiter.occupancy(.crossref).waiting == 1 })
        await limiter.release(.crossref)
        #expect(try await fourth.value >= 1 - 1e-9)           // no fourth start within the first second
        for _ in 0..<3 { await limiter.release(.crossref) }
        #expect(await limiter.occupancy(.crossref).inFlight == 0)
    }

    @Test func waitersAreServedInOrderAndACancelledOneLeavesWithoutASlot() async throws {
        let clock = TestClock()
        let limiter = HostLimiter(clock: clock)
        let policy = HostPolicy.crossref(polite: false)
        try await limiter.acquire(.crossref, policy: policy)
        let cancelled = Task { try await limiter.acquire(.crossref, policy: policy) }
        #expect(await waitUntil { await limiter.occupancy(.crossref).waiting == 1 })
        let next = Task { () async throws -> Double in
            try await limiter.acquire(.crossref, policy: policy)
            return clock.uptime()
        }
        #expect(await waitUntil { await limiter.occupancy(.crossref).waiting == 2 })

        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(await waitUntil { await limiter.occupancy(.crossref).waiting == 1 })
        #expect(await limiter.occupancy(.crossref).inFlight == 1)

        await limiter.release(.crossref)
        #expect(try await next.value == 1)
        await limiter.release(.crossref)
        #expect(await limiter.occupancy(.crossref).inFlight == 0)
        #expect(await limiter.occupancy(.crossref).waiting == 0)
    }

    @Test func aHoldOffDelaysThatHostOnly() async throws {
        let clock = TestClock()
        let limiter = HostLimiter(clock: clock)
        try await limiter.acquire(.openAlex, policy: .openAlex)
        await limiter.release(.openAlex)
        await limiter.holdOff(.openAlex, seconds: 5)

        try await limiter.acquire(.openAlex, policy: .openAlex)
        #expect(clock.uptime() == 5)
        await limiter.release(.openAlex)
        try await limiter.acquire(.crossref, policy: .crossref(polite: false))
        #expect(clock.uptime() == 5)                          // Crossref was never held off
        await limiter.release(.crossref)
    }
}

/// Polls `condition` until it holds (true) or ten seconds of real time have passed (false).
func waitUntil(_ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}
