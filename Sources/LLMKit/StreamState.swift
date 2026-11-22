import Foundation
import RefereeCore

/// What an adapter remembers between the lines of one response (plan section 5.3).
struct StreamState: Sendable, Equatable {
    var stopReason: StopReason?
    var inputTokens: Int?
    var outputTokens: Int?
    /// OpenAI: the text of `response.refusal.delta` events, which decides between `.endOfTurn` and `.refusal`.
    var refusal = ""
    /// Ollama: the `num_ctx` sent with the request, for the "context window full" status (section 5.4.5).
    var contextWindow: Int?
    /// The vendor's terminal event has been seen.
    var terminated = false

    init(contextWindow: Int? = nil) {
        self.contextWindow = contextWindow
    }

    var usage: Usage? {
        inputTokens == nil && outputTokens == nil ? nil : Usage(inputTokens: inputTokens, outputTokens: outputTokens)
    }

    /// The `.finished` of the terminal event: the given stop reason, else the one remembered, else `.endOfTurn`.
    mutating func finished(_ stop: StopReason? = nil) -> LLMEvent {
        terminated = true
        return .finished(stop ?? stopReason ?? .endOfTurn, usage)
    }
}
