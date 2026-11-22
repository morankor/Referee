import Foundation
import Testing
import RefereeCore
import TestSupport

/// MockLLMProvider and the mock scripts (plan.md section 5.9).
@Suite struct MockProviderTests {
    private func request(_ purpose: RequestPurpose, text: String = "Paper text.") -> LLMRequest {
        LLMRequest(system: "You are a referee.", parts: [.text(text)], purpose: purpose)
    }

    /// Everything a stream yields, and the error it ends with, if any.
    private func collect(_ stream: AsyncThrowingStream<LLMEvent, Error>) async -> (events: [LLMEvent], error: Error?) {
        var events: [LLMEvent] = []
        do {
            for try await event in stream { events.append(event) }
            return (events, nil)
        } catch {
            return (events, error)
        }
    }

    private func deltas(_ events: [LLMEvent]) -> [String] {
        events.compactMap { if case .textDelta(let text) = $0 { return text } else { return nil } }
    }

    /// The blocks of a review answer that are closed: from a "@@COMMENT" line to its "@@END" line.
    private func closedBlocks(in text: String) -> Int {
        var open = false
        var closed = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line == "@@COMMENT" { open = true }
            if line == "@@END", open { closed += 1; open = false }
        }
        return closed
    }

    // ---- the provider ----

    @Test func theDefaultMockIsLocalAndHasOneModel() async throws {
        let mock = MockLLMProvider()
        #expect(mock.descriptor.id == "mock")
        #expect(mock.descriptor.displayName == "Mock")
        #expect(mock.descriptor.vendor == "Mock")
        #expect(mock.descriptor.authMode == .none)
        #expect(mock.descriptor.isLocal)
        #expect(!mock.descriptor.supportsNativePDF)
        #expect(mock.descriptor.streaming == .token)
        #expect(!mock.descriptor.isExperimental)
        if case .ready = await mock.availability() {} else { Issue.record("the mock should be ready") }
        let models = try await mock.listModels()
        #expect(models.map(\.id) == ["mock"])
        #expect(models.first?.contextWindow == 1_000_000)
        #expect(models.first?.supportsPDFInput == false)

        let remote = MockLLMProvider(id: "mock-remote", isLocal: false, supportsNativePDF: true)
        #expect(!remote.descriptor.isLocal)
        #expect(remote.descriptor.destination == "mock.example.org")
        #expect(remote.descriptor.supportsNativePDF)
        #expect(try await remote.listModels().first?.supportsPDFInput == true)
        #expect(remote.descriptor.displayName == "Mock (remote)")
        #expect(MockLLMProvider(id: "second").descriptor.displayName == "Mock (second)")
    }

    @Test func aResponseIsCutIntoDeltasOfChunkSizeAndEndsWithFinished() async {
        let script = MockScript(responses: [.question: [MockResponse(text: "abcdefghij", chunkSize: 4, stop: .maxTokens)]])
        let (events, error) = await collect(MockLLMProvider(script: script).stream(request(.question)))
        #expect(error == nil)
        #expect(deltas(events) == ["abcd", "efgh", "ij"])
        #expect(events.count == 4)
        guard case .finished(let stop, let usage)? = events.last else {
            Issue.record("the last event should be .finished")
            return
        }
        #expect(stop == .maxTokens)
        #expect(usage?.inputTokens != nil)
        #expect(usage?.outputTokens != nil)
    }

    @Test func charactersAreNeverSplit() async {
        let text = "Sørensen e\u{301}te\u{301} 👩‍🔬 µi"
        let script = MockScript(responses: [.question: [MockResponse(text: text, chunkSize: 1)]])
        let (events, _) = await collect(MockLLMProvider(script: script).stream(request(.question)))
        #expect(deltas(events).joined() == text)
        #expect(deltas(events).count == text.count)
        #expect(deltas(events).allSatisfy { $0.count == 1 })

        // A chunk size that makes no sense still gives one character per delta, not a hang.
        let odd = MockScript(responses: [.question: [MockResponse(text: "abc", chunkSize: 0)]])
        #expect(deltas(await collect(MockLLMProvider(script: odd).stream(request(.question))).events) == ["a", "b", "c"])
    }

    @Test func theSameScriptGivesTheSameDeltasInTheSameOrder() async throws {
        let first = await collect(MockLLMProvider().stream(request(.review)))
        let second = await collect(MockLLMProvider().stream(request(.review)))
        #expect(first.error == nil)
        #expect(first.events == second.events)
        #expect(deltas(first.events).joined() == (try Fixtures.text("llm/review_clean.txt")))
        #expect(deltas(first.events).dropLast().allSatisfy { $0.count == 7 })
        #expect(first.events.last == .finished(.endOfTurn, Usage(inputTokens: 7, outputTokens: 651)))
    }

    @Test func responsesAreConsumedInOrderPerPurposeAndTheLastOneRepeats() async {
        let script = MockScript(responses: [
            .review: [MockResponse(text: "first"), MockResponse(text: "second")],
            .question: [MockResponse(text: "answer")],
        ])
        let mock = MockLLMProvider(script: script)
        var texts: [String] = []
        for purpose in [RequestPurpose.review, .question, .review, .review, .question] {
            texts.append(deltas(await collect(mock.stream(request(purpose))).events).joined())
        }
        #expect(texts == ["first", "answer", "second", "second", "answer"])
    }

    @Test func everyRequestIsRecordedWhenStreamIsCalled() async {
        let mock = MockLLMProvider()
        #expect(mock.recordedRequests.isEmpty)
        let first = request(.review, text: "one")
        let second = LLMRequest(model: "mock", system: "s", parts: [.pdf(data: Data("%PDF-".utf8), fileName: "manuscript.pdf"), .cacheBoundary, .text("two")],
                                maxOutputTokens: 100, contextWindow: 2_000, purpose: .question)
        _ = mock.stream(first)                      // recorded although it is never iterated
        #expect(mock.recordedRequests == [first])
        let (events, error) = await collect(mock.stream(second))
        #expect(error == nil)                       // a PDF part is accepted
        #expect(!deltas(events).isEmpty)
        #expect(mock.recordedRequests == [first, second])
    }

    @Test func aPurposeWithoutAResponseIsNotConfigured() async {
        let mock = MockLLMProvider(script: MockScript(responses: [:]))
        let (events, error) = await collect(mock.stream(request(.report)))
        #expect(events.isEmpty)
        guard case .notConfigured? = error as? LLMError else {
            Issue.record("expected LLMError.notConfigured, got \(String(describing: error))")
            return
        }
        #expect(mock.recordedRequests.count == 1)
    }

    @Test func afterFailAfterChunksTheStreamThrowsTheFailure() async {
        let response = MockResponse(text: "abcdefghij", chunkSize: 2, failAfterChunks: 3, failure: .rateLimited(retryAfter: 2, message: "slow down"))
        let (events, error) = await collect(MockLLMProvider(script: MockScript(responses: [.review: [response]])).stream(request(.review)))
        #expect(events == [.textDelta("ab"), .textDelta("cd"), .textDelta("ef")])
        #expect(error as? LLMError == .rateLimited(retryAfter: 2, message: "slow down"))

        // A text that ends before the failure point finishes normally.
        let short = MockResponse(text: "abcd", chunkSize: 2, failAfterChunks: 3, failure: .overloaded(retryAfter: nil))
        let result = await collect(MockLLMProvider(script: MockScript(responses: [.review: [short]])).stream(request(.review)))
        #expect(result.error == nil)
        #expect(result.events.last == .finished(.endOfTurn, Usage(inputTokens: 7, outputTokens: 1)))
    }

    /// Without a `failure`, the mock fails as a server would: status 500.
    @Test func failAfterChunksWithoutAFailureIsAServerError() async {
        let response = MockResponse(text: "abcdef", chunkSize: 2, failAfterChunks: 1)
        let (events, error) = await collect(MockLLMProvider(script: MockScript(responses: [.review: [response]])).stream(request(.review)))
        #expect(events == [.textDelta("ab")])
        guard case .server(let status, _)? = error as? LLMError else {
            Issue.record("expected LLMError.server, got \(String(describing: error))")
            return
        }
        #expect(status == 500)
    }

    /// `stallAfterChunks: n` on a response of one's own: n deltas, then silence until the consumer is cancelled, which
    /// ends the stream with `.cancelled`. A stall point past the end of the text is never reached.
    @Test func afterStallAfterChunksNothingComesUntilTheConsumerIsCancelled() async throws {
        final class Seen: @unchecked Sendable {
            private let lock = NSLock()
            private var events: [LLMEvent] = []
            private var failure: Error?
            private var ended = false
            func add(_ event: LLMEvent) { lock.withLock { events.append(event) } }
            func end(_ error: Error?) { lock.withLock { ended = true; failure = error } }
            var snapshot: (events: [LLMEvent], ended: Bool, failure: Error?) { lock.withLock { (events, ended, failure) } }
        }
        let response = MockResponse(text: "abcdefghij", chunkSize: 2, stallAfterChunks: 2)
        let stream = MockLLMProvider(script: MockScript(responses: [.review: [response]])).stream(request(.review))
        let seen = Seen()
        let consumer = Task {
            do {
                for try await event in stream { seen.add(event) }
                seen.end(nil)
            } catch {
                seen.end(error)
            }
        }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while seen.snapshot.events.count < 2, clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(seen.snapshot.events == [.textDelta("ab"), .textDelta("cd")])
        #expect(!seen.snapshot.ended)
        consumer.cancel()
        await consumer.value
        #expect(seen.snapshot.failure as? LLMError == .cancelled)

        let beyond = MockResponse(text: "abcd", chunkSize: 2, stallAfterChunks: 3)
        let (events, error) = await collect(MockLLMProvider(script: MockScript(responses: [.review: [beyond]])).stream(request(.review)))
        #expect(error == nil)
        #expect(deltas(events) == ["ab", "cd"])
        #expect(events.count == 3)                              // the two deltas and .finished
    }

    /// A consumer cancelled while the mock waits out a delay ends at once, with `.cancelled`.
    @Test func aDelayedStreamThatIsCancelledEndsWithCancelled() async {
        let response = MockResponse(text: "abcdef", chunkSize: 2, delayPerChunk: .seconds(30))
        let stream = MockLLMProvider(script: MockScript(responses: [.review: [response]])).stream(request(.review))
        let consumer = Task { () -> (count: Int, error: Error?) in
            var count = 0
            do {
                for try await _ in stream { count += 1 }
                return (count, nil)
            } catch {
                return (count, error)
            }
        }
        try? await Task.sleep(for: .milliseconds(100))
        let clock = ContinuousClock()
        let cancelledAt = clock.now
        consumer.cancel()
        let result = await consumer.value
        #expect(clock.now - cancelledAt < .seconds(2))
        #expect(result.count == 0)
        #expect(result.error as? LLMError == .cancelled)
    }

    @Test func delaysSeparateTheDeltas() async {
        let response = MockResponse(text: "abcdef", chunkSize: 2, delayPerChunk: .milliseconds(30))
        let clock = ContinuousClock()
        let started = clock.now
        let (events, error) = await collect(MockLLMProvider(script: MockScript(responses: [.review: [response]])).stream(request(.review)))
        #expect(error == nil)
        #expect(deltas(events) == ["ab", "cd", "ef"])
        #expect(clock.now - started >= .milliseconds(85))
    }

    // ---- the three scripts ----

    @Test func theSampleScriptAnswersWithTheFixtures() async throws {
        let sample = MockScript.sample
        #expect(Set(sample.responses.keys) == [.review, .discussion, .question, .report, .revise, .ping])
        #expect(sample.responses.values.allSatisfy { $0.count == 1 })
        #expect(sample.responses[.review]?.first?.text == (try Fixtures.text("llm/review_clean.txt")))
        #expect(sample.responses[.discussion]?.first?.text == (try Fixtures.text("llm/discussion_revise.txt")))
        #expect(sample.responses[.question]?.first?.text == (try Fixtures.text("llm/question_answer.txt")))
        #expect(sample.responses[.report]?.first?.text == (try Fixtures.text("llm/report_sample.txt")))
        #expect(sample.responses[.revise]?.first?.text == (try Fixtures.text("llm/report_sample.txt")))
        #expect(sample.responses[.ping]?.first?.text == "OK")

        let mock = MockLLMProvider()
        let reply = await collect(mock.stream(request(.discussion)))
        #expect(deltas(reply.events).joined().contains("\n@@REVISED\n"))
        let ping = await collect(mock.stream(request(.ping, text: "Reply with exactly: OK")))
        #expect(deltas(ping.events).joined() == "OK")
    }

    @Test func mockFailYieldsTwoClosedBlocksThenThrows() async throws {
        let mock = MockLLMProvider(id: "mock-fail", script: .failsAfterTwoComments)
        let (events, error) = await collect(mock.stream(request(.review)))
        #expect(error as? LLMError == .overloaded(retryAfter: nil))
        #expect(!events.contains { if case .finished = $0 { return true } else { return false } })

        let text = deltas(events).joined()
        let whole = try Fixtures.text("llm/review_clean.txt")
        #expect(whole.hasPrefix(text))
        #expect(closedBlocks(in: text) == 2)
        #expect(text.components(separatedBy: "@@COMMENT\n").count - 1 == 3)       // the third block was begun…
        #expect(text.hasSuffix("page: 1\nquote: The effect is statistically significant but economically small.\n"))
        // …and has neither title nor body, so the parser of section 6.5 drops it and exactly two comments remain.
        let third = text.components(separatedBy: "@@COMMENT\n").last ?? ""
        #expect(!third.contains("title:"))
        #expect(!third.contains("body:"))

        // The last response repeats: a retry fails in the same way.
        let again = await collect(mock.stream(request(.review)))
        #expect(again.events == events)
        #expect(again.error as? LLMError == .overloaded(retryAfter: nil))

        // The other purposes answer as the sample does.
        let report = await collect(mock.stream(request(.report)))
        #expect(report.error == nil)
        #expect(deltas(report.events).joined() == (try Fixtures.text("llm/report_sample.txt")))
    }

    @Test func mockStallNeverFinishesUntilCancelled() async throws {
        let mock = MockLLMProvider(id: "mock-stall", script: .stallsAfterTwoComments)
        let failing = await collect(MockLLMProvider(script: .failsAfterTwoComments).stream(request(.review)))
        let expected = deltas(failing.events)

        /// What the consumer saw, readable while it is still waiting.
        final class Seen: @unchecked Sendable {
            private let lock = NSLock()
            private var deltas: [String] = []
            private var ended = false
            private var failure: Error?
            func add(_ delta: String) { lock.withLock { deltas.append(delta) } }
            func end(_ error: Error?) { lock.withLock { ended = true; failure = error } }
            var snapshot: (deltas: [String], ended: Bool, failure: Error?) { lock.withLock { (deltas, ended, failure) } }
        }
        let seen = Seen()
        let stream = mock.stream(request(.review))
        let consumer = Task {
            do {
                for try await event in stream {
                    if case .textDelta(let delta) = event { seen.add(delta) }
                    if case .finished = event { Issue.record("a stalled stream must not finish") }
                }
                seen.end(nil)
            } catch {
                seen.end(error)
            }
        }

        // All the text arrives at once; then nothing, and the stream stays open.
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while seen.snapshot.deltas.count < expected.count, clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(seen.snapshot.deltas == expected)
        try await Task.sleep(for: .milliseconds(300))
        #expect(seen.snapshot.deltas == expected)
        #expect(!seen.snapshot.ended)

        // Cancelling the consumer ends it promptly, with the error providers throw for a cancellation.
        let cancelledAt = clock.now
        consumer.cancel()
        await consumer.value
        #expect(clock.now - cancelledAt < .seconds(2))
        #expect(seen.snapshot.ended)
        #expect(seen.snapshot.failure as? LLMError == .cancelled)
    }

    @Test func aStreamThatIsNeverIteratedDoesNothing() async {
        // Cold: creating the stream starts no work. With a stall scripted at the very start, a hot stream would be
        // left running here for ever.
        let response = MockResponse(text: "abc", stallAfterChunks: 0)
        let mock = MockLLMProvider(script: MockScript(responses: [.review: [response]]))
        _ = mock.stream(request(.review))
        #expect(mock.recordedRequests.count == 1)
    }

    @Test func staticProviderReportsWhatItWasGivenAndNeverStreams() async throws {
        let descriptor = ProviderDescriptor(id: "example", displayName: "Example", vendor: "Example", authMode: .apiKey, isLocal: false,
                                            destination: "example.org", supportsNativePDF: true, streaming: .token, retentionNote: "none",
                                            isExperimental: true)
        let models = [ModelInfo(id: "m", displayName: "M", contextWindow: 10)]
        let provider = StaticProvider(descriptor: descriptor, availability: .unavailable(reason: "switched off"), models: models)
        #expect(provider.descriptor == descriptor)
        #expect(await provider.availability() == .unavailable(reason: "switched off"))
        #expect(try await provider.listModels() == models)
        let (events, error) = await collect(provider.stream(request(.ping)))
        #expect(events.isEmpty)
        guard case .notConfigured? = error as? LLMError else {
            Issue.record("expected LLMError.notConfigured, got \(String(describing: error))")
            return
        }
    }
}
