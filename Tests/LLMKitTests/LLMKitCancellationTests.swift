import Foundation
import Testing
import RefereeCore
import TestSupport
@testable import LLMKit

/// WP4 "cancellation": cancelling the consuming task cancels the request (the stub's `stopLoading` runs, which a test
/// sees as the session having no task left) and the stream ends with `.cancelled` or silently, never hanging.
@Suite struct LLMKitCancellationTests {
    /// What a consumer saw, readable while it is still reading.
    final class Consumer: @unchecked Sendable {
        private let lock = NSLock()
        private var deltaCount = 0
        private var finished = false
        private var endedWith: Error??               // nil: still running; .some(nil): ended without an error

        func delta() { lock.withLock { deltaCount += 1 } }
        func finish() { lock.withLock { finished = true } }
        func end(_ error: Error?) { lock.withLock { endedWith = .some(error) } }
        var deltas: Int { lock.withLock { deltaCount } }
        var sawFinished: Bool { lock.withLock { finished } }
        var ended: Bool { lock.withLock { endedWith != nil } }
        var error: Error? { lock.withLock { endedWith ?? nil } }

        func start(_ stream: AsyncThrowingStream<LLMEvent, Error>) -> Task<Void, Never> {
            Task {
                do {
                    for try await event in stream {
                        switch event {
                        case .textDelta: delta()
                        case .finished: finish()
                        case .status: break
                        }
                    }
                    end(nil)
                } catch {
                    end(error)
                }
            }
        }
    }

    /// An Anthropic stream of 200 deltas, 50 ms apart: ten seconds if left alone.
    private var slowBody: [Data] {
        var chunks = [Data((AppendixD.anthropic.components(separatedBy: "event: content_block_start")[0]).utf8)]
        for index in 0..<200 {
            chunks.append(Data("event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"chunk \(index) \"}}\n\n".utf8))
        }
        chunks.append(Data("event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n".utf8))
        return chunks
    }

    @Test func cancellingTheConsumerCancelsTheRequestAndEndsTheStream() async throws {
        let chunks = slowBody
        StubURLProtocol.setHandler { _ in
            StubURLProtocol.Response(headers: ["Content-Type": "text/event-stream"], chunks: chunks, delayPerChunk: .milliseconds(50))
        }
        let harness = Harness()
        let consumer = Consumer()
        let task = consumer.start(harness.provider("anthropic-api", retry: .standard).stream(Requests.text()))

        #expect(await eventually(timeout: .seconds(8)) { consumer.deltas >= 2 })     // the body is arriving piece by piece
        #expect(await harness.session.allTasks.count == 1)                           // and the request is under way
        let clock = ContinuousClock()
        let cancelledAt = clock.now
        task.cancel()

        #expect(await eventually(timeout: .seconds(3)) { consumer.ended }, "the stream must end, not hang")
        #expect(clock.now - cancelledAt < .seconds(3))
        #expect(!consumer.sawFinished)
        #expect(consumer.deltas < 200)
        if let error = consumer.error { #expect(error as? LLMError == .cancelled) }     // or it ended silently
        // The HTTP request itself was cancelled: the stub's stopLoading ran and the session has no task left.
        #expect(await eventually(timeout: .seconds(3)) { await harness.session.allTasks.isEmpty })
    }

    @Test func cancellingBeforeTheFirstByteCancelsTheRequest() async throws {
        let chunks = slowBody
        StubURLProtocol.setHandler { _ in
            StubURLProtocol.Response(headers: ["Content-Type": "text/event-stream"], chunks: chunks, delayPerChunk: .seconds(2))
        }
        let harness = Harness()
        let consumer = Consumer()
        let task = consumer.start(harness.provider("openai-api").stream(Requests.text()))
        #expect(await eventually(timeout: .seconds(5)) { await harness.session.allTasks.count == 1 })
        task.cancel()
        #expect(await eventually(timeout: .seconds(3)) { consumer.ended }, "the stream must end, not hang")
        #expect(consumer.deltas == 0)
        if let error = consumer.error { #expect(error as? LLMError == .cancelled) }
        #expect(await eventually(timeout: .seconds(3)) { await harness.session.allTasks.isEmpty })
    }

    @Test func cancellingDuringARetryWaitEndsAtOnce() async throws {
        StubURLProtocol.setHandler { _ in Stub.json(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#, status: 529) }
        let harness = Harness()
        let consumer = Consumer()
        // A real sleep of about a minute between attempts.
        let policy = RetryPolicy(backoffSeconds: [60, 60, 60])
        let task = consumer.start(harness.provider("anthropic-api", retry: policy).stream(Requests.text()))
        #expect(await eventually(timeout: .seconds(5)) { StubURLProtocol.recordedRequests.count == 1 })
        try await Task.sleep(for: .milliseconds(100))                                // now waiting
        let clock = ContinuousClock()
        let cancelledAt = clock.now
        task.cancel()
        #expect(await eventually(timeout: .seconds(3)) { consumer.ended }, "the wait must end when the consumer is cancelled")
        #expect(clock.now - cancelledAt < .seconds(3))
        if let error = consumer.error { #expect(error as? LLMError == .cancelled) }
        #expect(StubURLProtocol.recordedRequests.count == 1)                         // no second attempt
    }

    @Test func abandoningTheStreamAfterTheFirstDeltaCancelsTheRequest() async throws {
        let chunks = slowBody
        StubURLProtocol.setHandler { _ in
            StubURLProtocol.Response(headers: ["Content-Type": "text/event-stream"], chunks: chunks, delayPerChunk: .milliseconds(50))
        }
        let harness = Harness()
        // The consumer stops reading by itself (a `break`), without being cancelled.
        for try await event in harness.provider("anthropic-api").stream(Requests.text()) {
            if case .textDelta = event { break }
        }
        #expect(await eventually(timeout: .seconds(3)) { await harness.session.allTasks.isEmpty })
    }
}
