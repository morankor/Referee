import Foundation
import Testing
import RefereeCore
import TestSupport

/// StubURLProtocol (plan.md section 10.3). No test here can reach the network: every session comes from
/// `StubURLProtocol.session()`, and the hosts are under example.invalid.
@Suite struct StubURLProtocolTests {
    private func url(_ path: String) throws -> URL {
        try #require(URL(string: "https://stub.example.invalid/\(path)"))
    }

    /// The lines of a streamed body, read the way providers read them: byte by byte through LineSplitter.
    private func lines(of bytes: URLSession.AsyncBytes) async throws -> [String] {
        var splitter = LineSplitter()
        var lines: [String] = []
        for try await byte in bytes {
            if let line = splitter.push(byte) { lines.append(line) }
        }
        if let last = splitter.finish() { lines.append(last) }
        return lines
    }

    @Test func aResponseArrivesWithItsStatusHeadersAndBody() async throws {
        StubURLProtocol.setHandler { _ in
            StubURLProtocol.Response(status: 429, headers: ["Retry-After": "7", "Content-Type": "application/json"], chunks: [Data(#"{"error":"slow down"}"#.utf8)])
        }
        let (data, response) = try await StubURLProtocol.session().data(from: url("models"))
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 429)
        #expect(http.value(forHTTPHeaderField: "Retry-After") == "7")
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(String(decoding: data, as: UTF8.self) == #"{"error":"slow down"}"#)
    }

    @Test func aBodyInOneByteChunksGivesTheSameLinesAsInOneChunk() async throws {
        let body = "event: message_start\ndata: {\"type\":\"message_start\"}\n\nevent: ping\ndata: {\"type\":\"ping\"}\n\ndata: Sørensen\n"
        let expected = ["event: message_start", "data: {\"type\":\"message_start\"}", "", "event: ping", "data: {\"type\":\"ping\"}", "", "data: Sørensen"]
        let whole = Data(body.utf8)
        let chunkings: [[Data]] = [[whole], whole.map { Data([$0]) }, [whole.prefix(11), whole.dropFirst(11).prefix(40), whole.dropFirst(51)].map { Data($0) }]
        for chunks in chunkings {
            StubURLProtocol.setHandler { _ in StubURLProtocol.Response(chunks: chunks) }
            let (bytes, response) = try await StubURLProtocol.session().bytes(from: url("stream"))
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(try await lines(of: bytes) == expected)
        }
    }

    @Test func chunksWithADelayArriveOneByOne() async throws {
        let parts = ["data: one\n", "data: two\n", "data: three\n"]
        StubURLProtocol.setHandler { _ in
            StubURLProtocol.Response(chunks: parts.map { Data($0.utf8) }, delayPerChunk: .milliseconds(150))
        }
        let clock = ContinuousClock()
        let started = clock.now
        let (bytes, _) = try await StubURLProtocol.session().bytes(from: url("slow"))
        var splitter = LineSplitter()
        var arrivals: [(line: String, after: Duration)] = []
        for try await byte in bytes {
            if let line = splitter.push(byte) { arrivals.append((line, clock.now - started)) }
        }
        #expect(arrivals.map(\.line) == ["data: one", "data: two", "data: three"])
        // Each chunk waits its turn: the first line cannot come before one delay has passed, the last not before three.
        #expect((arrivals.first?.after ?? .zero) >= .milliseconds(140))
        #expect((arrivals.last?.after ?? .zero) >= .milliseconds(440))
        #expect((arrivals.first?.after ?? .zero) < (arrivals.last?.after ?? .zero) - .milliseconds(200))
    }

    @Test func noHandlerOrANilResponseIsAConnectionRefused() async throws {
        StubURLProtocol.setHandler(nil)
        let session = StubURLProtocol.session()
        do {
            _ = try await session.data(from: url("refused"))
            Issue.record("the request should have failed")
        } catch {
            #expect((error as? URLError)?.code == .cannotConnectToHost)
        }

        StubURLProtocol.setHandler { request in
            request.url?.lastPathComponent == "open" ? StubURLProtocol.Response(chunks: [Data("ok".utf8)]) : nil
        }
        #expect(String(decoding: try await session.data(from: url("open")).0, as: UTF8.self) == "ok")
        do {
            _ = try await session.data(from: url("closed"))
            Issue.record("the request should have failed")
        } catch {
            #expect((error as? URLError)?.code == .cannotConnectToHost)
        }
        #expect(StubURLProtocol.recordedRequests.compactMap(\.url?.lastPathComponent) == ["open", "closed"])
    }

    @Test func requestsAreRecordedWithTheirBodies() async throws {
        StubURLProtocol.setHandler { request in
            // The handler sees the body too, so it can answer according to it.
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            return StubURLProtocol.Response(chunks: [Data("echo:\(body)".utf8)])
        }
        let session = StubURLProtocol.session()
        var request = URLRequest(url: try url("v1/messages"))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("secret-key", forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"model":"m","stream":true}"#.utf8)
        let (data, _) = try await session.data(for: request)
        #expect(String(decoding: data, as: UTF8.self) == #"echo:{"model":"m","stream":true}"#)
        _ = try await session.data(from: url("v1/models"))

        let recorded = StubURLProtocol.recordedRequests
        #expect(recorded.count == 2)
        let first = try #require(recorded.first)
        #expect(first.url == request.url)
        #expect(first.httpMethod == "POST")
        #expect(first.timeoutInterval == 600)
        #expect(first.value(forHTTPHeaderField: "x-api-key") == "secret-key")
        #expect(first.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(first.httpBody == request.httpBody)
        #expect(recorded.last?.httpMethod == "GET")
        #expect(recorded.last?.httpBody == nil)
        // Nothing of the stub's own bookkeeping shows in what tests see.
        #expect(recorded.allSatisfy { request in request.allHTTPHeaderFields?.keys.contains { $0.lowercased().contains("stub") } != true })

        // Setting a handler again starts a new record.
        StubURLProtocol.setHandler { _ in StubURLProtocol.Response(chunks: []) }
        #expect(StubURLProtocol.recordedRequests.isEmpty)
        let (empty, response) = try await session.data(from: url("empty"))
        #expect(empty.isEmpty)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(StubURLProtocol.recordedRequests.count == 1)
    }

    @Test func aLargeBodySentAsAStreamIsRecordedWhole() async throws {
        StubURLProtocol.setHandler { _ in StubURLProtocol.Response(chunks: [Data("ok".utf8)]) }
        let body = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        var request = URLRequest(url: try url("upload"))
        request.httpMethod = "POST"
        _ = try await StubURLProtocol.session().upload(for: request, from: body)
        #expect(StubURLProtocol.recordedRequests.first?.httpBody == body)
    }

    @Test func cancellingTheConsumerStopsADelayedDelivery() async throws {
        StubURLProtocol.setHandler { _ in
            StubURLProtocol.Response(chunks: (0..<200).map { Data("data: \($0)\n".utf8) }, delayPerChunk: .milliseconds(50))
        }
        let session = StubURLProtocol.session()
        let target = try url("endless")
        let consumer = Task { () -> Int in
            var count = 0
            do {
                let (bytes, _) = try await session.bytes(from: target)
                for try await byte in bytes where byte == 0x0A { count += 1 }
            } catch {
                // cancelled: expected
            }
            return count
        }
        try await Task.sleep(for: .milliseconds(400))
        let clock = ContinuousClock()
        let cancelledAt = clock.now
        consumer.cancel()
        let received = await consumer.value
        #expect(clock.now - cancelledAt < .seconds(2))          // it did not wait for the ten seconds the body would take
        #expect(received >= 1)
        #expect(received < 200)
    }

    /// Each test has a handler of its own, so tests that use the stub can run in parallel (the default in Swift
    /// Testing). Twelve concurrent "tests", each with its own answer and many requests: nobody gets another's answer,
    /// and each sees only its own requests.
    @Test func handlersOfConcurrentTestsDoNotMix() async throws {
        let base = try url("who")
        let mismatches = await withTaskGroup(of: Int.self) { group -> Int in
            for worker in 0..<12 {
                group.addTask {
                    // A child task stands for one test: its own handler, its own session.
                    StubURLProtocol.setHandler { _ in StubURLProtocol.Response(chunks: [Data("worker \(worker)".utf8)], delayPerChunk: .milliseconds(2)) }
                    let session = StubURLProtocol.session()
                    var wrong = 0
                    for _ in 0..<15 {
                        let data = (try? await session.data(from: base).0) ?? Data()
                        if String(decoding: data, as: UTF8.self) != "worker \(worker)" { wrong += 1 }
                    }
                    if StubURLProtocol.recordedRequests.count != 15 { wrong += 1 }
                    return wrong
                }
            }
            var total = 0
            for await wrong in group { total += wrong }
            return total
        }
        #expect(mismatches == 0)
    }

    @Test func aSessionOnlyReachesTheHandlerOfTheTestThatMadeIt() async throws {
        StubURLProtocol.setHandler { _ in StubURLProtocol.Response(chunks: [Data("mine".utf8)]) }
        let target = try url("scoped")
        // A session made in another task has no handler there: its requests are refused, whatever this test has set.
        let foreign = await Task { StubURLProtocol.session() }.value
        do {
            _ = try await foreign.data(from: target)
            Issue.record("a session made in another task should not reach this test's handler")
        } catch {
            #expect((error as? URLError)?.code == .cannotConnectToHost)
        }
        // The session made here works from any task.
        let session = StubURLProtocol.session()
        let answer = await Task { String(decoding: (try? await session.data(from: target).0) ?? Data(), as: UTF8.self) }.value
        #expect(answer == "mine")
        #expect(StubURLProtocol.recordedRequests.count == 1)
    }
}

/// A suite that keeps its session in a property, as a test file with a shared helper would: the instance is made in
/// the test's own task, so the session belongs to that test.
@Suite struct StubURLProtocolPropertyTests {
    let session = StubURLProtocol.session()

    @Test func aSessionHeldByTheSuiteInstanceUsesTheTestsHandler() async throws {
        StubURLProtocol.setHandler { _ in StubURLProtocol.Response(chunks: [Data("from the property".utf8)]) }
        let target = try #require(URL(string: "https://stub.example.invalid/property"))
        #expect(String(decoding: try await session.data(from: target).0, as: UTF8.self) == "from the property")
    }
}
