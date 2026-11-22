import Foundation
import Testing
@testable import ReviewEngine
import RefereeCore
import TestSupport

/// The life of a job's stream (plan.md sections 2.3 and 6.1): cold, cancelled with its consumer, and never outliving it.
@Suite struct JobStreamTests {
    /// Opens a block, then streams nothing more until its consumer goes; remembers that it went.
    final class ProbeProvider: LLMProvider, @unchecked Sendable {
        let descriptor = ProviderDescriptor(id: "probe", displayName: "Probe", vendor: "Test", authMode: .none, isLocal: true, destination: "this Mac",
                                            supportsNativePDF: false, streaming: .token, retentionNote: "", isExperimental: false)
        private let lock = NSLock()
        private var requests = 0
        private var terminations = 0
        var counts: (requests: Int, terminations: Int) { lock.withLock { (requests, terminations) } }

        func availability() async -> ProviderAvailability { .ready(detail: "") }
        func listModels() async throws -> [ModelInfo] { [] }
        func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
            lock.withLock { requests += 1 }
            return AsyncThrowingStream { continuation in
                continuation.onTermination = { [weak self] _ in
                    guard let self else { return }
                    self.lock.withLock { self.terminations += 1 }
                }
                continuation.yield(.textDelta("@@COMMENT\nkind: major\n"))
            }
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test(.timeLimit(.minutes(1))) func droppingTheStreamCancelsTheJob() async throws {
        let paper = try makeSamplePaper()
        let probe = ProbeProvider()
        let engine = EngineTest.engine([probe], paper: paper)
        do {
            let stream = engine.review(paper: paper, existing: [], context: EngineTest.context(provider: "probe"))
            for try await event in stream {
                if case .draft = event { break }                        // the provider is streaming now
            }
        }
        try await waitUntil { probe.counts.terminations > 0 }
        #expect(probe.counts.requests == 1)
        #expect(probe.counts.terminations == 1)
    }

    @Test func aConsumerCancelledBeforeItStartsSendsNothing() async throws {
        let paper = try makeSamplePaper()
        let mock = MockLLMProvider()
        let stream = EngineTest.engine([mock], paper: paper).review(paper: paper, existing: [], context: EngineTest.context())
        let consumer = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var events: [ReviewEvent] = []
            for try await event in stream { events.append(event) }
            return events
        }
        #expect(try await consumer.value.isEmpty)
        try await Task.sleep(for: .milliseconds(50))
        #expect(mock.recordedRequests.isEmpty)
    }

    @Test func aSlowConsumerGetsEveryEventInOrder() async throws {
        let paper = try makeSamplePaper()
        let fast = MockLLMProvider()
        let reference = try await EngineTest.collect(EngineTest.engine([fast], paper: paper).review(paper: paper, existing: [], context: EngineTest.context()))
        let slow = MockLLMProvider()
        var events: [ReviewEvent] = []
        for try await event in EngineTest.engine([slow], paper: paper).review(paper: paper, existing: [], context: EngineTest.context()) {
            events.append(event)
            if events.count % 50 == 0 { try await Task.sleep(for: .milliseconds(2)) }
        }
        #expect(events.count == reference.count)
        #expect(events.comments.map(\.title) == reference.comments.map(\.title))
        #expect(events.finishedRun?.status == .completed)
        #expect(events.filter { if case .finished = $0 { return true } else { return false } }.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func aHugeBlockStreamedOneCharacterAtATimeStaysLinear() {
        var parser = CommentStreamParser(mode: .review)
        let body = String(repeating: "word ", count: 12_000) + "\n"
        let text = "@@COMMENT\nkind: minor\ntitle: Long\nbody:\n" + String(repeating: body, count: 3) + "@@END\n"
        let started = ContinuousClock.now
        var closed = 0
        for character in text {
            for output in parser.feed(String(character)) { if case .blockClosed = output { closed += 1 } }
        }
        #expect(closed == 1)
        #expect(ContinuousClock.now - started < .seconds(30))
    }
}
