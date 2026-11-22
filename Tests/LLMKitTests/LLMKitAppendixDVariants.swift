import Foundation

// The variants, error bodies and model lists that plan.md Appendix D.1-D.4 names next to each recorded stream. Where
// Appendix D says "the same with …", the variant is derived from the recorded body in `AppendixD`, so that it differs
// in that one place only. Swift literals, as in LLMKitAppendixDStreams.swift.

enum AppendixDVariants {
    // ---- D.1 Anthropic ----

    /// The in-stream error variant: `event: error` with `overloaded_error`, after `message_start`.
    static let anthropicOverloadedEvent = #"""
event: message_start
data: {"type":"message_start","message":{"id":"msg_01","type":"message","role":"assistant","content":[],"model":"m","stop_reason":null,"usage":{"input_tokens":25,"output_tokens":1}}}

event: error
data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}

"""#

    static let anthropicHTTPError = #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"},"request_id":"req_1"}"#

    /// The model list item of D.1 on a first page that says there is more.
    static let anthropicModelsPage1 = #"""
{"data":[{"type":"model","id":"m","display_name":"M","created_at":"2026-09-21T00:00:00Z","max_input_tokens":1000000,"max_tokens":128000,"capabilities":{"pdf_input":{"supported":true},"batch":{"supported":true}}}],"has_more":true,"first_id":"m","last_id":"m"}
"""#

    static let anthropicModelsPage2 = #"""
{"data":[{"type":"model","id":"small","display_name":"Small","created_at":"2026-01-01T00:00:00Z","max_input_tokens":200000,"max_tokens":64000,"capabilities":{"pdf_input":{"supported":false}}},{"type":"model","id":"legacy","display_name":"Legacy","created_at":"2025-01-01T00:00:00Z"}],"has_more":false,"first_id":"small","last_id":"legacy"}
"""#

    // ---- D.2 OpenAI ----

    /// The recorded stream, ending in `response.incomplete` for `max_output_tokens` instead of `response.completed`.
    static let openaiIncomplete = replacingLastEvent(of: AppendixD.openai, with: """
        event: response.incomplete
        data: {"type":"response.incomplete","response":{"id":"resp_1","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"usage":{"input_tokens":12,"output_tokens":2,"total_tokens":14}},"sequence_number":3}

        """)

    /// The same, for `content_filter`.
    static let openaiContentFilter = openaiIncomplete.replacingOccurrences(of: "max_output_tokens", with: "content_filter")

    static let openaiFailed = #"""
event: response.created
data: {"type":"response.created","response":{"id":"resp_1","status":"in_progress"},"sequence_number":0}

event: response.failed
data: {"type":"response.failed","response":{"id":"resp_1","status":"failed","error":{"code":"server_error","message":"The server had an error while processing your request."}},"sequence_number":1}

"""#

    static let openaiErrorEvent = #"""
event: error
data: {"type":"error","code":"rate_limit_exceeded","message":"Rate limit reached.","param":null,"sequence_number":1}

"""#

    static let openaiHTTPError = #"{"error":{"message":"This model's maximum context length is 128000 tokens.","type":"invalid_request_error","param":null,"code":"context_length_exceeded"}}"#

    /// D.2's list item among others that the filter of section 5.4.2 hides, in no particular order.
    static let openaiModels = #"""
{"object":"list","data":[
{"id":"x","object":"model","created":1686935002,"owned_by":"openai"},
{"id":"text-embedding-3-large","object":"model","created":1705953180,"owned_by":"system"},
{"id":"newest","object":"model","created":1746000000,"owned_by":"system"},
{"id":"whisper-1","object":"model","created":1677532384,"owned_by":"openai-internal"},
{"id":"middle","object":"model","created":1715000000,"owned_by":"system"},
{"id":"image-maker-1","object":"model","created":1745000000,"owned_by":"system"},
{"id":"chat-realtime-preview","object":"model","created":1727000000,"owned_by":"system"},
{"id":"omni-moderation-latest","object":"model","created":1731000000,"owned_by":"system"},
{"id":"chat-search-preview","object":"model","created":1741000000,"owned_by":"system"},
{"id":"computer-use-preview","object":"model","created":1741000001,"owned_by":"system"},
{"id":"sora-2","object":"model","created":1759000000,"owned_by":"system"},
{"id":"tts-1","object":"model","created":1681940951,"owned_by":"openai-internal"},
{"id":"dall-e-3","object":"model","created":1698785189,"owned_by":"system"},
{"id":"chat-audio","object":"model","created":1756000000,"owned_by":"system"},
{"id":"chat-transcribe","object":"model","created":1742000000,"owned_by":"system"}
]}
"""#

    // ---- D.2 xAI ----

    /// The recorded stream with the variant's last chunk, `finish_reason: "length"`, before `[DONE]`.
    static let xaiLength = AppendixD.xai.replacingOccurrences(of: "data: [DONE]\n", with: #"""
data: {"id":"c1","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{},"finish_reason":"length"}],"usage":{"prompt_tokens":41,"completion_tokens":2,"total_tokens":43},"system_fingerprint":"fp_x"}

data: [DONE]

"""#)

    static let xaiModels = #"""
{"data":[{"id":"x","created":1686935002,"context_length":256000,"aliases":[],"object":"model","owned_by":"xai"},{"id":"y","created":1700000000,"context_length":131072,"aliases":["y-latest"],"object":"model","owned_by":"xai"}]}
"""#

    // ---- D.3 Gemini ----

    /// "The same with `"status":"incomplete"` in `interaction.completed`."
    static let geminiIncomplete = AppendixD.gemini.replacingOccurrences(of: #""status":"completed""#, with: #""status":"incomplete""#)

    static let geminiErrorEvent = #"""
event: interaction.created
data: {"interaction":{"id":"v1_abc","status":"in_progress","object":"interaction","model":"m"},"event_type":"interaction.created"}

event: error
data: {"error":{"message":"Deadline expired before operation could complete.","code":"gateway_timeout"},"event_type":"error"}

"""#

    static let geminiRateLimitedEvent = geminiErrorEvent.replacingOccurrences(of: "gateway_timeout", with: "rate_limit_exceeded")

    static let geminiHTTPError = #"{"error":{"code":"invalid_request","message":"Request contains an invalid argument."}}"#

    /// D.3's list on a first page with a `nextPageToken`, plus a model the filter hides.
    static let geminiModelsPage1 = #"""
{"models":[{"name":"models/m","displayName":"M","inputTokenLimit":1048576,"outputTokenLimit":65536,"supportedGenerationMethods":["generateContent"]},{"name":"models/text-embedding-004","displayName":"Text Embedding","inputTokenLimit":2048,"outputTokenLimit":1,"supportedGenerationMethods":["embedContent"]}],"nextPageToken":"t"}
"""#

    static let geminiModelsPage2 = #"""
{"models":[{"name":"models/flash","displayName":"Flash","inputTokenLimit":1048576,"outputTokenLimit":8192},{"name":"models/flash-tts","displayName":"Flash TTS"},{"name":"models/flash-live","displayName":"Flash Live"},{"name":"models/veo-3","displayName":"Veo"},{"name":"models/flash-image","displayName":"Flash Image"}]}
"""#

    // ---- D.4 Ollama ----

    /// A delta, then the error line of D.4.
    static let ollamaErrorLine = #"""
{"model":"gemma:2b","created_at":"2026-11-22T07:32:06.326224Z","message":{"role":"assistant","content":"OK"},"done":false}
{"error":"an error was encountered while running the model"}

"""#

    static let ollamaLength = AppendixD.ollama.replacingOccurrences(of: #""done_reason":"stop""#, with: #""done_reason":"length""#)

    /// The `/api/tags` item of D.4, one model without `context_length` (so `/api/show` is asked), and one that cannot
    /// complete text.
    static let ollamaTags = #"""
{"models":[{"name":"gemma4:e4b","model":"gemma4:e4b","size":9608350718,"details":{"family":"gemma4","parameter_size":"8.0B","quantization_level":"Q4_K_M","context_length":131072},"capabilities":["completion","vision","audio","tools","thinking"]},{"name":"phi4:latest","model":"phi4:latest","size":9053116391,"details":{"family":"phi3","parameter_size":"14.7B","quantization_level":"Q4_K_M"},"capabilities":["completion"]},{"name":"embedder:latest","model":"embedder:latest","size":274302450,"details":{"family":"nomic-bert","context_length":2048},"capabilities":["embedding"]}]}
"""#

    static let ollamaShow = #"""
{"capabilities":["completion"],"model_info":{"general.architecture":"phi3","phi3.context_length":16384,"phi3.embedding_length":5120}}
"""#

    static let ollamaVersion = #"{"version":"0.40.17"}"#

    // ---- helpers ----

    /// `body` with its last SSE event (from its last `event:` line on) replaced by `event`.
    private static func replacingLastEvent(of body: String, with event: String) -> String {
        guard let start = body.range(of: "event:", options: .backwards)?.lowerBound else { return body + event }
        return String(body[..<start]) + event
    }
}
