import Foundation
import Testing
import RefereeCore
import TestSupport
@testable import LLMKit

/// WP4 "retry" (plan section 5.7). The waits are recorded, not slept, so every test here is instant.
@Suite struct LLMKitRetryTests {
    private let overloadedBody = #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#

    @Test func twoOverloadedAnswersThenAGoodStreamGiveOneStreamAndTwoStatuses() async throws {
        let requests = Counter()
        StubURLProtocol.setHandler { [overloadedBody] _ in
            requests.next() <= 2 ? Stub.json(overloadedBody, status: 529) : Stub.stream(AppendixD.anthropic, for: "anthropic-api")
        }
        let sleeps = SleepRecorder()
        let outcome = await collect(Harness().provider("anthropic-api", retry: sleeps.policy()).stream(Requests.text()))
        #expect(outcome.error == nil)
        #expect(outcome.statuses == ["Retrying in 2 s (overloaded)", "Retrying in 6 s (overloaded)"])
        #expect(outcome.text == "@@COMMENT\nkind: major\ntitle: Example\n@@END\n@@DONE")
        #expect(outcome.finishes == [.finished(.endOfTurn, Usage(inputTokens: 25, outputTokens: 15))])
        #expect(sleeps.durations == [.seconds(2), .seconds(6)])
        #expect(StubURLProtocol.recordedRequests.count == 3)
        // The statuses come before anything of the successful attempt.
        #expect(outcome.events.prefix(2).allSatisfy { if case .status = $0 { return true } else { return false } })
    }

    @Test func two503AnswersThenAGoodStreamForOpenAI() async throws {
        let requests = Counter()
        let busy = #"{"error":{"message":"The server is overloaded.","type":"server_error","param":null,"code":"server_is_overloaded"}}"#
        StubURLProtocol.setHandler { _ in
            requests.next() <= 2 ? Stub.json(busy, status: 503) : Stub.stream(AppendixD.openai, for: "openai-api")
        }
        let sleeps = SleepRecorder()
        let outcome = await collect(Harness().provider("openai-api", retry: sleeps.policy()).stream(Requests.text()))
        #expect(outcome.error == nil)
        #expect(outcome.statuses == ["Retrying in 2 s (overloaded)", "Retrying in 6 s (overloaded)"])
        #expect(outcome.text == "Hello world")
        #expect(outcome.finishes.count == 1)
        #expect(StubURLProtocol.recordedRequests.count == 3)
    }

    @Test func aFailureAfterTheFirstDeltaIsNotRetried() async throws {
        // One delta, then an overloaded error event: retryable in itself, but text has already reached the consumer.
        let body = AppendixD.anthropic.replacingOccurrences(
            of: "event: content_block_stop",
            with: "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n\nevent: content_block_stop")
        StubURLProtocol.setHandler { _ in Stub.stream(body, for: "anthropic-api") }
        let sleeps = SleepRecorder()
        let outcome = await collect(Harness().provider("anthropic-api", retry: sleeps.policy()).stream(Requests.text()))
        #expect(outcome.deltas == ["@@COMMENT\nkind: major\n", "title: Example\n@@END\n@@DONE"])
        #expect(outcome.llmError == .overloaded(retryAfter: nil))
        #expect(outcome.statuses.isEmpty)
        #expect(sleeps.durations.isEmpty)
        #expect(StubURLProtocol.recordedRequests.count == 1)
    }

    @Test func anInStreamErrorBeforeAnyDeltaIsRetried() async throws {
        let requests = Counter()
        StubURLProtocol.setHandler { _ in
            Stub.stream(requests.next() == 1 ? AppendixDVariants.anthropicOverloadedEvent : AppendixD.anthropic, for: "anthropic-api")
        }
        let outcome = await collect(Harness().provider("anthropic-api", retry: SleepRecorder().policy()).stream(Requests.text()))
        #expect(outcome.statuses == ["Retrying in 2 s (overloaded)"])
        #expect(outcome.finishes.count == 1)
        #expect(StubURLProtocol.recordedRequests.count == 2)
    }

    @Test func authIsNotRetried() async throws {
        StubURLProtocol.setHandler { _ in Stub.json(AppendixDVariants.anthropicHTTPError, status: 401) }
        let sleeps = SleepRecorder()
        let outcome = await collect(Harness().provider("anthropic-api", retry: sleeps.policy()).stream(Requests.text()))
        #expect(outcome.llmError == .auth("invalid x-api-key"))
        #expect(outcome.events.isEmpty)
        #expect(sleeps.durations.isEmpty)
        #expect(StubURLProtocol.recordedRequests.count == 1)
    }

    @Test func aTimeoutIsNotRetried() async throws {
        let token = UUID().uuidString
        let harness = Harness(session: TimeoutURLProtocol.session(token: token))
        let sleeps = SleepRecorder()
        let outcome = await collect(harness.provider("anthropic-api", retry: sleeps.policy()).stream(Requests.text()))
        #expect(outcome.llmError == .network("the provider sent nothing for too long, so the request timed out"))
        #expect(outcome.statuses.isEmpty)
        #expect(sleeps.durations.isEmpty)
        #expect(TimeoutURLProtocol.requestCount(token: token) == 1)
        // The same for Ollama, whose transport mapping differs.
        let ollama = await collect(harness.provider("ollama", retry: sleeps.policy()).stream(Requests.text(contextWindow: 2_048)))
        #expect(ErrorKind(ollama.error) == .network)
        #expect(TimeoutURLProtocol.requestCount(token: token) == 2)
    }

    @Test func otherErrorsThatAreNeverRetried() async throws {
        let cells: [(Int, String, ErrorKind)] = [
            (402, #"{"type":"error","error":{"type":"billing_error","message":"Your credit balance is too low."}}"#, .quotaExhausted),
            (400, #"{"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long"}}"#, .contextTooLong),
            (400, #"{"type":"error","error":{"type":"invalid_request_error","message":"bad field"}}"#, .invalidRequest),
            (404, #"{"type":"error","error":{"type":"not_found_error","message":"model: nope"}}"#, .modelNotFound),
        ]
        for (status, body, kind) in cells {
            StubURLProtocol.setHandler { _ in Stub.json(body, status: status) }
            let sleeps = SleepRecorder()
            let outcome = await collect(Harness().provider("anthropic-api", retry: sleeps.policy()).stream(Requests.text()))
            #expect(ErrorKind(outcome.error) == kind)
            #expect(sleeps.durations.isEmpty, "\(kind)")
            #expect(StubURLProtocol.recordedRequests.count == 1, "\(kind)")
        }
        // A body that ends before its terminal event, before any delta: .malformedResponse, not retried.
        StubURLProtocol.setHandler { _ in Stub.stream("event: ping\ndata: {\"type\":\"ping\"}\n\n", for: "anthropic-api") }
        let early = await collect(Harness().provider("anthropic-api", retry: SleepRecorder().policy()).stream(Requests.text()))
        #expect(early.llmError == .malformedResponse("stream ended early"))
        #expect(StubURLProtocol.recordedRequests.count == 1)
    }

    @Test func threeFailuresGiveUpWithTheLastError() async throws {
        StubURLProtocol.setHandler { _ in Stub.json(#"{"error":{"code":"api_error","message":"boom"}}"#, status: 500) }
        let sleeps = SleepRecorder()
        let outcome = await collect(Harness().provider("gemini-api", retry: sleeps.policy()).stream(Requests.text()))
        #expect(outcome.llmError == .server(status: 500, message: "boom"))
        #expect(outcome.statuses == ["Retrying in 2 s (server error 500)", "Retrying in 6 s (server error 500)"])
        #expect(sleeps.durations == [.seconds(2), .seconds(6)])
        #expect(StubURLProtocol.recordedRequests.count == 3)
    }

    @Test func aRefusedConnectionIsRetriedAsANetworkError() async throws {
        let requests = Counter()
        StubURLProtocol.setHandler { _ in requests.next() == 1 ? nil : Stub.stream(AppendixD.xai, for: "xai-api") }
        let outcome = await collect(Harness().provider("xai-api", retry: SleepRecorder().policy()).stream(Requests.text()))
        #expect(outcome.statuses == ["Retrying in 2 s (network error)"])
        #expect(outcome.text == "Ah,")
        #expect(StubURLProtocol.recordedRequests.count == 2)
    }

    @Test func retryAfterIsHonouredUpTo60SecondsPlusJitter() async throws {
        let requests = Counter()
        StubURLProtocol.setHandler { _ in
            switch requests.next() {
            case 1: return Stub.json(#"{"error":{"message":"slow down","code":"rate_limit_exceeded"}}"#, status: 429, headers: ["Retry-After": "7"])
            case 2: return Stub.json(#"{"error":{"message":"slow down","code":"rate_limit_exceeded"}}"#, status: 429, headers: ["Retry-After": "120"])
            default: return Stub.stream(AppendixD.openai, for: "openai-api")
            }
        }
        let sleeps = SleepRecorder()
        let outcome = await collect(Harness().provider("openai-api", retry: sleeps.policy(random: 0.25)).stream(Requests.text()))
        #expect(outcome.finishes.count == 1)
        #expect(sleeps.durations == [.seconds(7.25), .seconds(60.25)])
        #expect(outcome.statuses == ["Retrying in 7 s (rate limited)", "Retrying in 60 s (rate limited)"])
    }

    @Test func settingsAndKeysAreReadAgainForEachAttempt() async throws {
        let requests = Counter()
        StubURLProtocol.setHandler { _ in requests.next() == 1 ? nil : Stub.stream(AppendixD.anthropic, for: "anthropic-api") }
        let harness = Harness()
        // The first attempt fails; before the second, the model changes.
        let policy = RetryPolicy(maxAttempts: 3, sleep: { _ in
            harness.settings.set("anthropic-api", {
                var settings = Harness.defaultSettings(for: "anthropic-api")
                settings.model = "second-model"
                return settings
            }())
        }, random: { 0.5 })
        _ = await collect(harness.provider("anthropic-api", retry: policy).stream(Requests.text(model: nil)))
        let models = StubURLProtocol.recordedRequests.map { $0.jsonBody?["model"] }
        #expect(models == ["m", "second-model"])
    }

    // ---- the rule itself ----

    @Test func theBackoffIs2And6And18SecondsWithin25Percent() {
        func policy(_ random: Double) -> RetryPolicy { RetryPolicy(random: { random }) }
        let server = LLMError.server(status: 500, message: "")
        #expect(policy(0.5).delay(after: server, retry: 1) == .seconds(2))
        #expect(policy(0.5).delay(after: server, retry: 2) == .seconds(6))
        #expect(policy(0.5).delay(after: server, retry: 3) == .seconds(18))
        #expect(policy(0).delay(after: server, retry: 1) == .seconds(1.5))
        #expect(policy(1).delay(after: .network("x"), retry: 2) == .seconds(7.5))
        #expect(policy(0.5).delay(after: .overloaded(retryAfter: nil), retry: 1) == .seconds(2))
        #expect(policy(0.5).delay(after: .rateLimited(retryAfter: nil, message: ""), retry: 2) == .seconds(6))
        #expect(policy(0.5).delay(after: .overloaded(retryAfter: 3), retry: 1) == .seconds(3.5))
        #expect(policy(0).delay(after: .rateLimited(retryAfter: 600, message: ""), retry: 1) == .seconds(60))
        for error in [LLMError.auth(""), .notConfigured(""), .quotaExhausted(""), .contextTooLong(""), .invalidRequest(""),
                      .modelNotFound(""), .refused(""), .cancelled, .malformedResponse(""), .toolUseBlocked("")] {
            #expect(policy(0.5).delay(after: error, retry: 1) == nil, "\(error)")
        }
        #expect(AttemptFailure(TimedOut(error: .network("timed out"))).retryable == false)
        #expect(AttemptFailure(LLMError.network("offline")).retryable == true)
    }
}
