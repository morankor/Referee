import Foundation
import Testing
import RefereeCore
import TestSupport
@testable import LLMKit

/// One recorded stream of Appendix D and what it must yield.
struct RecordedStream: Sendable, CustomTestStringConvertible {
    let provider: ProviderID
    let body: String
    let deltas: [String]
    let finished: LLMEvent
    /// The line before which the body is cut for the "early end" row: the vendor's terminal event.
    let terminalLine: String
    /// The model the stream names (step 5c): `message.model`, the response's `model`, every chunk's `model`, the
    /// interaction's `model`, every line's `model`. Appendix D.2's OpenAI sample names none.
    let model: String?

    var testDescription: String { provider }

    static let all: [RecordedStream] = [
        RecordedStream(provider: "anthropic-api", body: AppendixD.anthropic,
                       deltas: ["@@COMMENT\nkind: major\n", "title: Example\n@@END\n@@DONE"],
                       finished: .finished(.endOfTurn, Usage(inputTokens: 25, outputTokens: 15)), terminalLine: "event: message_stop", model: "m"),
        RecordedStream(provider: "openai-api", body: AppendixD.openai, deltas: ["Hello", " world"],
                       finished: .finished(.endOfTurn, Usage(inputTokens: 12, outputTokens: 2)), terminalLine: "event: response.completed", model: nil),
        RecordedStream(provider: "xai-api", body: AppendixD.xai, deltas: ["Ah", ","],
                       finished: .finished(.endOfTurn, Usage(inputTokens: 41, outputTokens: 2)), terminalLine: "data: [DONE]", model: "m"),
        RecordedStream(provider: "gemini-api", body: AppendixD.gemini, deltas: ["1, 2, 3, ", "4, 5"],
                       finished: .finished(.endOfTurn, Usage(inputTokens: 11, outputTokens: 90)), terminalLine: "event: interaction.completed",
                       model: "m"),
        RecordedStream(provider: "ollama", body: AppendixD.ollama, deltas: ["OK"],
                       finished: .finished(.endOfTurn, Usage(inputTokens: 33, outputTokens: 2)),
                       terminalLine: #"{"model":"gemma:2b","created_at":"2026-11-22T07:32:06.346764Z""#, model: "gemma:2b"),
    ]

    /// The body up to (not including) the terminal event.
    var cutBeforeTerminal: String {
        guard let range = body.range(of: terminalLine) else { return body }
        return String(body[..<range.lowerBound])
    }
}

/// WP4 "stream parsing", "unknown events", "in-stream errors", "truncation" and "early end".
@Suite struct LLMKitStreamParsingTests {
    private func play(_ body: String, provider id: ProviderID, chunking: Chunking = .whole,
                      request: LLMRequest = Requests.text(contextWindow: 8_192)) async -> StreamOutcome {
        StubURLProtocol.setHandler { _ in Stub.stream(body, for: id, chunking: chunking) }
        return await collect(Harness().provider(id).stream(request))
    }

    // ---- stream parsing, per provider ----

    @Test(arguments: RecordedStream.all)
    func theRecordedStreamGivesTheSameDeltasInOneChunkAndInOneByteChunks(_ recorded: RecordedStream) async throws {
        for chunking in Chunking.allCases {
            let outcome = await play(recorded.body, provider: recorded.provider, chunking: chunking)
            #expect(outcome.error == nil, "\(chunking): \(String(describing: outcome.error))")
            #expect(outcome.deltas == recorded.deltas, "\(chunking)")
            #expect(outcome.text == recorded.deltas.joined())
            #expect(outcome.finishes == [recorded.finished], "\(chunking)")
            #expect(outcome.events.last == recorded.finished, "exactly one .finished, and last")
            #expect(outcome.statuses.isEmpty)
        }
    }

    // ---- the model the stream names (step 5c) ----

    /// Each recorded stream names its model once, before `.finished`, in one chunk and in one-byte chunks; xAI and
    /// Ollama name it in every chunk and line, and it is still sent once. Appendix D.2's OpenAI sample names none.
    @Test(arguments: RecordedStream.all)
    func theRecordedStreamNamesItsModelOnceBeforeItFinishes(_ recorded: RecordedStream) async throws {
        for chunking in Chunking.allCases {
            let outcome = await play(recorded.body, provider: recorded.provider, chunking: chunking)
            #expect(outcome.models == (recorded.model.map { [$0] } ?? []), "\(chunking)")
            if let position = outcome.events.firstIndex(where: { if case .model = $0 { return true } else { return false } }) {
                #expect(position < outcome.events.count - 1, "before .finished")
            }
        }
    }

    /// OpenAI's response object names the model it ran (`response.created`, and again in `response.completed`): a
    /// variant of D.2 with the field. A name that changes during a stream is sent again; the last one counts.
    @Test func theOpenAIResponseObjectNamesItsModel() async throws {
        let named = AppendixD.openai
            .replacingOccurrences(of: #""response":{"id":"resp_1","status":"in_progress"}"#,
                                  with: #""response":{"id":"resp_1","status":"in_progress","model":"gpt-x-2026-10-01"}"#)
            .replacingOccurrences(of: #""response":{"id":"resp_1","status":"completed","#,
                                  with: #""response":{"id":"resp_1","status":"completed","model":"gpt-x-2026-10-01","#)
        #expect(named != AppendixD.openai)
        let outcome = await play(named, provider: "openai-api", chunking: .bytes)
        #expect(outcome.models == ["gpt-x-2026-10-01"])
        #expect(outcome.deltas == ["Hello", " world"])

        let changed = AppendixD.xai.replacingOccurrences(of: #""created":1,"model":"m","choices":[{"index":0,"delta":{"content":",""#,
                                                          with: #""created":1,"model":"m2","choices":[{"index":0,"delta":{"content":",""#)
        #expect(await play(changed, provider: "xai-api").models == ["m", "m2"])
    }

    /// Gemini: the interaction's `model` (D.3), or a `modelVersion` when an event carries one, the name generateContent
    /// responses use.
    @Test func geminiNamesTheModelOfTheInteraction() async throws {
        let versioned = AppendixD.gemini.replacingOccurrences(of: #""object":"interaction","model":"m"}"#,
                                                              with: #""object":"interaction","model":"m","modelVersion":"m-001"}"#)
        #expect(versioned != AppendixD.gemini)
        #expect(await play(versioned, provider: "gemini-api").models == ["m-001"])
        #expect(await play(AppendixD.gemini, provider: "gemini-api").models == ["m"])
    }

    @Test func theAnthropicTextIsTheCommentBlock() async throws {
        let outcome = await play(AppendixD.anthropic, provider: "anthropic-api", chunking: .bytes)
        #expect(outcome.text == "@@COMMENT\nkind: major\ntitle: Example\n@@END\n@@DONE")
    }

    @Test func crLfLineEndsParseTheSame() async throws {
        for recorded in RecordedStream.all {
            let outcome = await play(recorded.body.replacingOccurrences(of: "\n", with: "\r\n"), provider: recorded.provider, chunking: .bytes)
            #expect(outcome.deltas == recorded.deltas, "\(recorded.provider)")
            #expect(outcome.finishes == [recorded.finished], "\(recorded.provider)")
        }
    }

    @Test func aBodyWithoutItsFinalLineBreakParsesTheSame() async throws {
        for recorded in RecordedStream.all {
            var body = recorded.body
            while body.hasSuffix("\n") { body.removeLast() }
            let outcome = await play(body, provider: recorded.provider)
            #expect(outcome.finishes == [recorded.finished], "\(recorded.provider)")
        }
    }

    @Test func eventsAfterTheTerminalEventAreNotRead() async throws {
        // A second message after message_stop must not reach the consumer: exactly one .finished, last.
        let body = AppendixD.anthropic + AppendixD.anthropic
        let outcome = await play(body, provider: "anthropic-api")
        #expect(outcome.deltas.count == 2)
        #expect(outcome.finishes.count == 1)
    }

    // ---- unknown events ----

    /// Every SSE body with an unknown event after each event, comment, id and retry lines, and an unknown field in
    /// every JSON object at every depth; NDJSON with unknown lines and fields.
    private func withUnknowns(_ body: String, provider: ProviderID) -> String {
        var lines: [String] = []
        for line in body.components(separatedBy: "\n") {
            if provider == "ollama" {
                if let value = JSONValue.parse(line) {
                    lines.append(Self.text(of: Self.addingExtraFields(to: value)))
                    lines.append(#"{"status":"vendor.unknown","extra":{"a":[1,2]}}"#)
                    lines.append("")
                } else {
                    lines.append(line)
                }
                continue
            }
            if line.hasPrefix("data: {"), let value = JSONValue.parse(line.dropFirst(6)) {
                lines.append("data: " + Self.text(of: Self.addingExtraFields(to: value)))
            } else {
                lines.append(line)
            }
            if line.isEmpty {
                lines += [": keep-alive", "id: 42", "retry: 1000", "event: vendor.unknown",
                          #"data: {"type":"vendor.unknown","event_type":"vendor.unknown","object":"vendor.unknown","payload":{"a":[1,{"b":null}]}}"#,
                          "data: not json at all", ""]
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func addingExtraFields(to value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object):
            var result = object.mapValues(addingExtraFields)
            result["zz_unknown_field"] = ["nested": [1, "two", ["three": nil]], "flag": true]
            return .object(result)
        case .array(let array):
            return .array(array.map(addingExtraFields))
        default:
            return value
        }
    }

    private static func text(of value: JSONValue) -> String {
        String(decoding: (try? value.data()) ?? Data(), as: UTF8.self)
    }

    @Test(arguments: RecordedStream.all)
    func unknownEventsAndFieldsParseIdentically(_ recorded: RecordedStream) async throws {
        let noisy = withUnknowns(recorded.body, provider: recorded.provider)
        #expect(noisy != recorded.body)
        for chunking in Chunking.allCases {
            let outcome = await play(noisy, provider: recorded.provider, chunking: chunking)
            #expect(outcome.error == nil, "\(String(describing: outcome.error))")
            #expect(outcome.deltas == recorded.deltas)
            #expect(outcome.finishes == [recorded.finished])
        }
    }

    // ---- in-stream errors ----

    @Test func anAnthropicErrorEventIsOverloaded() async throws {
        let outcome = await play(AppendixDVariants.anthropicOverloadedEvent, provider: "anthropic-api", chunking: .bytes)
        #expect(outcome.llmError == .overloaded(retryAfter: nil))
        #expect(outcome.finishes.isEmpty)
    }

    @Test func anOpenAIResponseFailedIsMappedFromItsError() async throws {
        let outcome = await play(AppendixDVariants.openaiFailed, provider: "openai-api")
        #expect(outcome.llmError == .server(status: 500, message: "The server had an error while processing your request."))
        let event = await play(AppendixDVariants.openaiErrorEvent, provider: "openai-api")
        #expect(event.llmError == .rateLimited(retryAfter: nil, message: "Rate limit reached."))
    }

    @Test func geminiErrorEventsAreMappedByCode() async throws {
        let timeout = await play(AppendixDVariants.geminiErrorEvent, provider: "gemini-api")
        #expect(timeout.llmError == .server(status: 500, message: "Deadline expired before operation could complete."))
        let limited = await play(AppendixDVariants.geminiRateLimitedEvent, provider: "gemini-api")
        #expect(limited.llmError == .rateLimited(retryAfter: nil, message: "Deadline expired before operation could complete."))
        let failed = AppendixD.gemini.replacingOccurrences(of: #""status":"completed""#, with: #""status":"failed""#)
        #expect(ErrorKind(await play(failed, provider: "gemini-api").error) == .server)
    }

    @Test func anOllamaErrorLineIsAServerError() async throws {
        let outcome = await play(AppendixDVariants.ollamaErrorLine, provider: "ollama")
        #expect(outcome.deltas == ["OK"])
        #expect(outcome.llmError == .server(status: 500, message: "an error was encountered while running the model"))
    }

    @Test func anXAIErrorChunkIsAServerError() async throws {
        let body = "data: {\"error\":{\"message\":\"internal failure\",\"code\":\"internal\"}}\n\n"
        #expect(await play(body, provider: "xai-api").llmError == .server(status: 500, message: "internal failure"))
    }

    // ---- truncation and other stop reasons ----

    @Test func geminiIncompleteIsMaxTokens() async throws {
        let outcome = await play(AppendixDVariants.geminiIncomplete, provider: "gemini-api", chunking: .bytes)
        #expect(outcome.deltas == ["1, 2, 3, ", "4, 5"])
        #expect(outcome.finishes == [.finished(.maxTokens, Usage(inputTokens: 11, outputTokens: 90))])
    }

    @Test func xAIFinishReasonLengthIsMaxTokens() async throws {
        let outcome = await play(AppendixDVariants.xaiLength, provider: "xai-api", chunking: .bytes)
        #expect(outcome.text == "Ah,")
        #expect(outcome.finishes == [.finished(.maxTokens, Usage(inputTokens: 41, outputTokens: 2))])
        let filtered = AppendixDVariants.xaiLength.replacingOccurrences(of: #""finish_reason":"length""#, with: #""finish_reason":"content_filter""#)
        #expect(await play(filtered, provider: "xai-api").finishes == [.finished(.refusal, Usage(inputTokens: 41, outputTokens: 2))])
        let stopped = AppendixDVariants.xaiLength.replacingOccurrences(of: #""finish_reason":"length""#, with: #""finish_reason":"stop""#)
        #expect(await play(stopped, provider: "xai-api").finishes == [.finished(.endOfTurn, Usage(inputTokens: 41, outputTokens: 2))])
    }

    @Test func ollamaDoneReasonLengthIsMaxTokens() async throws {
        let outcome = await play(AppendixDVariants.ollamaLength, provider: "ollama")
        #expect(outcome.finishes == [.finished(.maxTokens, Usage(inputTokens: 33, outputTokens: 2))])
    }

    @Test func openAIIncompleteIsMaxTokensOrRefusal() async throws {
        let truncated = await play(AppendixDVariants.openaiIncomplete, provider: "openai-api")
        #expect(truncated.deltas == ["Hello", " world"])
        #expect(truncated.finishes == [.finished(.maxTokens, Usage(inputTokens: 12, outputTokens: 2))])
        let filtered = await play(AppendixDVariants.openaiContentFilter, provider: "openai-api")
        #expect(filtered.finishes == [.finished(.refusal, Usage(inputTokens: 12, outputTokens: 2))])
    }

    @Test func anOpenAIRefusalIsAStopReason() async throws {
        let body = AppendixD.openai.replacingOccurrences(
            of: "event: response.completed",
            with: "event: response.refusal.delta\ndata: {\"type\":\"response.refusal.delta\",\"delta\":\"I can't help with that.\"}\n\nevent: response.completed")
        let outcome = await play(body, provider: "openai-api")
        #expect(outcome.finishes == [.finished(.refusal, Usage(inputTokens: 12, outputTokens: 2))])
        #expect(!outcome.text.contains("help with that"))          // refusal text is not model text for the review
    }

    @Test func anthropicStopReasonsAreMapped() async throws {
        let cases: [(String, StopReason)] = [("max_tokens", .maxTokens), ("refusal", .refusal), ("stop_sequence", .endOfTurn),
                                             ("pause_turn", .other)]
        for (reason, expected) in cases {
            let body = AppendixD.anthropic.replacingOccurrences(of: #""stop_reason":"end_turn""#, with: #""stop_reason":"\#(reason)""#)
            let outcome = await play(body, provider: "anthropic-api")
            #expect(outcome.finishes == [.finished(expected, Usage(inputTokens: 25, outputTokens: 15))], "\(reason)")
        }
    }

    @Test func anthropicInputTokensIncludeTheCachedPrefix() async throws {
        let body = AppendixD.anthropic.replacingOccurrences(
            of: #""usage":{"input_tokens":25,"output_tokens":1}"#,
            with: #""usage":{"input_tokens":25,"cache_creation_input_tokens":1000,"cache_read_input_tokens":200,"output_tokens":1}"#)
        let outcome = await play(body, provider: "anthropic-api")
        #expect(outcome.finishes == [.finished(.endOfTurn, Usage(inputTokens: 1_225, outputTokens: 15))])
    }

    // ---- early end ----

    @Test(arguments: RecordedStream.all)
    func aBodyCutBeforeTheTerminalEventGivesTheDeltasThenMalformedResponse(_ recorded: RecordedStream) async throws {
        let cut = recorded.cutBeforeTerminal
        #expect(cut.count < recorded.body.count)
        for chunking in Chunking.allCases {
            let outcome = await play(cut, provider: recorded.provider, chunking: chunking)
            #expect(outcome.deltas == recorded.deltas)
            #expect(outcome.finishes.isEmpty)
            #expect(outcome.llmError == .malformedResponse("stream ended early"))
        }
    }

    @Test func doneBeforeTheTerminalEventIsAnEarlyEnd() async throws {
        for recorded in RecordedStream.all where ["anthropic-api", "openai-api", "gemini-api"].contains(recorded.provider) {
            let outcome = await play(recorded.cutBeforeTerminal + "data: [DONE]\n\n", provider: recorded.provider)
            #expect(outcome.deltas == recorded.deltas)
            #expect(outcome.llmError == .malformedResponse("stream ended early"), "\(recorded.provider)")
        }
    }

    @Test func anEmptyBodyIsAnEarlyEnd() async throws {
        for recorded in RecordedStream.all {
            let outcome = await play("", provider: recorded.provider)
            #expect(outcome.events.isEmpty)
            #expect(outcome.llmError == .malformedResponse("stream ended early"), "\(recorded.provider)")
        }
    }

    // ---- garbage ----

    @Test func garbageNeverCrashesOrHangs() async throws {
        var generator = SplitMix(seed: 7)
        let samples: [String] = [
            String(repeating: "data: {", count: 2_000),
            "data: " + String(repeating: "[", count: 2_000),
            "\u{0}\u{1}\u{2}data:\r\r\n\n\n",
            String(decoding: (0..<4_096).map { _ in UInt8.random(in: 0...255, using: &generator) }, as: UTF8.self),
            #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":12}}"# + "\n",
            #"{"message":{"content":["not","text"]},"done":"yes"}"# + "\n",
        ]
        for sample in samples {
            for recorded in RecordedStream.all {
                let outcome = await play(sample, provider: recorded.provider, chunking: .whole)
                #expect(outcome.finishes.isEmpty)
                #expect(outcome.error is LLMError, "\(recorded.provider)")
            }
        }
    }
}

/// A small deterministic generator for the garbage test.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
