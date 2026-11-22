import Foundation
import Testing
import RefereeCore
@testable import ScholarKit
import TestSupport

/// Acceptance row "transient failures" (plan.md section 11.4, WP7): a 429 or 5xx is retried once, after
/// `Retry-After` or 2 s; a second failure makes the lookup `.failed`, which is never cached.
@Suite struct ScholarKitRetryTests {
    @Test func a429WithRetryAfterOneIsRetriedOnceAfterThatSecond() async throws {
        let clock = TestClock()
        let arrivals = ArrivalLog(clock: clock)
        let answers = ResponseQueue(["api.crossref.org": [Stub.status(429, headers: ["Retry-After": "1"]), Stub.json(Bodies.crossrefHochreiter)],
                                     "api.openalex.org": [Stub.json(Bodies.openAlexHochreiter)]])
        StubURLProtocol.setHandler { request in
            arrivals.record(request)
            return answers.next(for: request)
        }
        let harness = ResolverHarness(clock: clock)
        defer { harness.cleanUp() }

        let reference = await harness.resolver.resolve(try Entries.hochreiter(), documentSHA256: Documents.first)

        #expect(reference.status == .resolved)
        #expect(reference.doi == "10.1162/neco.1997.9.8.1735")
        let crossref = arrivals.at("api.crossref.org")
        #expect(crossref.count == 2)
        guard crossref.count == 2 else { return }
        #expect(crossref[1].uptime - crossref[0].uptime >= 1)
        #expect(FileManager.default.fileExists(atPath: harness.referencesFile(Documents.first).path))
    }

    @Test func aSecond429MakesTheLookupFailedAndNothingIsCached() async throws {
        StubURLProtocol.setHandler { _ in Stub.status(429, headers: ["Retry-After": "1"]) }
        let harness = ResolverHarness()
        defer { harness.cleanUp() }
        let entry = try Entries.hochreiter()

        let reference = await harness.resolver.resolve(entry, documentSHA256: Documents.first)

        #expect(reference == ResolvedReference(entryID: entry.id, status: .failed, confidence: 0, resolvedAt: harness.clock.now()))
        #expect(StubURLProtocol.recordedRequests.count == 2)
        #expect(!FileManager.default.fileExists(atPath: harness.referencesFile(Documents.first).path))

        // Not cached in memory either: the next click asks again.
        _ = await harness.resolver.resolve(entry, documentSHA256: Documents.first)
        #expect(StubURLProtocol.recordedRequests.count == 4)
    }

    @Test func aRetryAfterFromOpenAlexIsWaitedBeyondItsOwnSpacing() async throws {
        let clock = TestClock()
        let arrivals = ArrivalLog(clock: clock)
        let answers = ResponseQueue(["api.openalex.org": [Stub.status(429, headers: ["Retry-After": "1"]), Stub.json(Bodies.openAlexHochreiter)]])
        StubURLProtocol.setHandler { request in
            arrivals.record(request)
            return answers.next(for: request)
        }
        let harness = ResolverHarness(clock: clock)
        defer { harness.cleanUp() }
        var entry = try Entries.hochreiter()
        entry.parsed.doi = "10.1162/neco.1997.9.8.1735"

        let reference = await harness.resolver.resolve(entry, documentSHA256: Documents.first)

        #expect(reference.status == .resolved)
        #expect(arrivals.at("api.openalex.org").map(\.uptime) == [0, 1])
    }

    @Test func aServerErrorWithoutRetryAfterIsRetriedAfterTwoSeconds() async throws {
        let clock = TestClock()
        let arrivals = ArrivalLog(clock: clock)
        let answers = ResponseQueue(["api.openalex.org": [Stub.status(503), Stub.json(Bodies.openAlexHochreiter)]])
        StubURLProtocol.setHandler { request in
            arrivals.record(request)
            return answers.next(for: request)
        }
        let harness = ResolverHarness(clock: clock)
        defer { harness.cleanUp() }
        var entry = try Entries.hochreiter()
        entry.parsed.doi = "10.1162/neco.1997.9.8.1735"

        let reference = await harness.resolver.resolve(entry, documentSHA256: Documents.first)

        #expect(reference.status == .resolved)
        #expect(arrivals.at("api.openalex.org").map(\.uptime) == [0, 2])
    }

    @Test func aRetryAfterGivenAsADateIsHonoured() async throws {
        let clock = TestClock()
        let arrivals = ArrivalLog(clock: clock)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let inThreeSeconds = formatter.string(from: clock.now().addingTimeInterval(3))
        let answers = ResponseQueue(["api.openalex.org": [Stub.status(503, headers: ["Retry-After": inThreeSeconds]), Stub.json(Bodies.openAlexHochreiter)]])
        StubURLProtocol.setHandler { request in
            arrivals.record(request)
            return answers.next(for: request)
        }
        let harness = ResolverHarness(clock: clock)
        defer { harness.cleanUp() }
        var entry = try Entries.hochreiter()
        entry.parsed.doi = "10.1162/neco.1997.9.8.1735"

        #expect(await harness.resolver.resolve(entry, documentSHA256: Documents.first).status == .resolved)
        #expect(arrivals.at("api.openalex.org").map(\.uptime) == [0, 3])
    }

    @Test func aWaitOfMoreThanAMinuteIsNotSatOut() async throws {
        StubURLProtocol.setHandler { _ in Stub.status(429, headers: ["Retry-After": "3600"]) }
        let harness = ResolverHarness()
        defer { harness.cleanUp() }

        let reference = await harness.resolver.resolve(try Entries.hochreiter(), documentSHA256: Documents.first)

        #expect(reference.status == .failed)
        #expect(StubURLProtocol.recordedRequests.count == 1)
    }

    @Test func aNetworkFailureIsFailedAtOnceAndNotCached() async throws {
        StubURLProtocol.setHandler(nil)                         // connection refused
        let harness = ResolverHarness()
        defer { harness.cleanUp() }
        let entry = try Entries.hochreiter()

        #expect(await harness.resolver.resolve(entry, documentSHA256: Documents.first).status == .failed)
        #expect(StubURLProtocol.recordedRequests.count == 1)
        #expect(await harness.resolver.resolve(entry, documentSHA256: Documents.first).status == .failed)
        #expect(StubURLProtocol.recordedRequests.count == 2)
        #expect(!FileManager.default.fileExists(atPath: harness.referencesFile(Documents.first).path))
    }

    @Test func aStatusThatIsNotTransientIsNotRetried() async throws {
        StubURLProtocol.setHandler { _ in Stub.status(403) }
        let harness = ResolverHarness()
        defer { harness.cleanUp() }

        #expect(await harness.resolver.resolve(try Entries.hochreiter(), documentSHA256: Documents.first).status == .failed)
        #expect(StubURLProtocol.recordedRequests.count == 1)
    }

    @Test func whenOpenAlexFailsAfterCrossrefTheLookupIsFailedButKeepsTheDOI() async throws {
        StubURLProtocol.setHandler { request in
            request.url?.host == "api.crossref.org" ? Stub.json(Bodies.crossrefHochreiter) : Stub.status(500)
        }
        let harness = ResolverHarness()
        defer { harness.cleanUp() }
        let entry = try Entries.hochreiter()

        let reference = await harness.resolver.resolve(entry, documentSHA256: Documents.first)

        #expect(reference == ResolvedReference(entryID: entry.id, status: .failed, doi: "10.1162/neco.1997.9.8.1735",
                                               landingURL: "https://doi.org/10.1162/neco.1997.9.8.1735", confidence: 0,
                                               resolvedAt: harness.clock.now()))
        #expect(StubURLProtocol.recordedRequests.map { $0.url?.host } == ["api.crossref.org", "api.openalex.org", "api.openalex.org"])
        #expect(!FileManager.default.fileExists(atPath: harness.referencesFile(Documents.first).path))
    }

    @Test func aCancelledLookupEndsItsRequestAndIsFailed() async throws {
        let slow = StubURLProtocol.Response(status: 200, headers: ["Content-Type": "application/json"],
                                            chunks: [Data(Bodies.crossrefHochreiter.utf8)], delayPerChunk: .seconds(30))
        StubURLProtocol.setHandler { _ in slow }
        let harness = ResolverHarness()
        defer { harness.cleanUp() }
        let entry = try Entries.hochreiter()
        let resolver = harness.resolver

        let lookup = Task { await resolver.resolve(entry, documentSHA256: Documents.first) }
        #expect(await waitUntil { StubURLProtocol.recordedRequests.count == 1 })
        lookup.cancel()
        let reference = await lookup.value

        #expect(reference.status == .failed)
        #expect(await waitUntil { await harness.session.allTasks.isEmpty })
        #expect(StubURLProtocol.recordedRequests.count == 1)
        #expect(!FileManager.default.fileExists(atPath: harness.referencesFile(Documents.first).path))
    }
}
