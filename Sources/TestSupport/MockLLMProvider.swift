import Foundation
import RefereeCore

// Wave 0a placeholder (see Placeholder.swift): the scripts are empty and the provider plays nothing.

public struct MockResponse: Sendable {
    public var text: String
    public var chunkSize: Int                 // characters per delta
    public var delayPerChunk: Duration
    public var failAfterChunks: Int?          // then throw `failure`
    public var failure: LLMError?
    public var stallAfterChunks: Int?         // then emit nothing more and never finish, until the consumer cancels
    public var stop: StopReason
    public init(text: String, chunkSize: Int = 7, delayPerChunk: Duration = .zero, failAfterChunks: Int? = nil, failure: LLMError? = nil,
                stallAfterChunks: Int? = nil, stop: StopReason = .endOfTurn) {
        self.text = text; self.chunkSize = chunkSize; self.delayPerChunk = delayPerChunk; self.failAfterChunks = failAfterChunks
        self.failure = failure; self.stallAfterChunks = stallAfterChunks; self.stop = stop
    }
}

public struct MockScript: Sendable {
    public var responses: [RequestPurpose: [MockResponse]]       // consumed in order per purpose; the last one repeats
    public init(responses: [RequestPurpose: [MockResponse]]) { self.responses = responses }
    public static var sample: MockScript { MockScript(responses: [:]) }                    // Fixtures/llm: review_clean, discussion_revise, question_answer, report_sample
    public static var failsAfterTwoComments: MockScript { MockScript(responses: [:]) }     // review: two complete blocks of review_clean, half of the third, then .overloaded
    public static var stallsAfterTwoComments: MockScript { MockScript(responses: [:]) }    // review: the same text, then silence
}

public final class MockLLMProvider: LLMProvider, @unchecked Sendable {
    public let descriptor: ProviderDescriptor

    public init(id: ProviderID = "mock", script: MockScript = .sample, isLocal: Bool = true, supportsNativePDF: Bool = false) {
        descriptor = ProviderDescriptor(id: id, displayName: "Mock", vendor: "Mock", authMode: .none, isLocal: isLocal,
                                        destination: isLocal ? "this Mac" : "mock.example.org", supportsNativePDF: supportsNativePDF,
                                        streaming: .token, retentionNote: "A stand-in for tests; nothing is sent.", isExperimental: false)
    }

    public var recordedRequests: [LLMRequest] { [] }               // lock-protected

    public func availability() async -> ProviderAvailability {
        .needsSetup(reason: "not implemented", hint: "The mock provider is written in Wave 0b.")
    }

    public func listModels() async throws -> [ModelInfo] { [] }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: LLMError.notConfigured("not implemented"))
        }
    }
}
