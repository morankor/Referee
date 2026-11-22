// The five recorded stream bodies of plan.md Appendix D.1-D.4, byte for byte, as Swift raw strings.
//
// Test data is either a Swift literal like these or a data file in the target's excluded `Fixtures/` folder (plan.md
// section 3.7); WP4 chose literals. Each literal ends with the body's final line break: the empty line before the
// closing delimiter.

enum AppendixD {
    /// D.1 Anthropic Messages stream.
    static let anthropic = #"""
event: message_start
data: {"type":"message_start","message":{"id":"msg_01","type":"message","role":"assistant","content":[],"model":"m","stop_reason":null,"usage":{"input_tokens":25,"output_tokens":1}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: ping
data: {"type":"ping"}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"@@COMMENT\nkind: major\n"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"title: Example\n@@END\n@@DONE"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":15}}

event: message_stop
data: {"type":"message_stop"}

"""#

    /// D.2 OpenAI Responses stream.
    static let openai = #"""
event: response.created
data: {"type":"response.created","response":{"id":"resp_1","status":"in_progress"},"sequence_number":0}

event: response.output_text.delta
data: {"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"content_index":0,"delta":"Hello","sequence_number":1,"logprobs":[]}

event: response.output_text.delta
data: {"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"content_index":0,"delta":" world","sequence_number":2,"logprobs":[]}

event: response.completed
data: {"type":"response.completed","response":{"id":"resp_1","status":"completed","usage":{"input_tokens":12,"output_tokens":2,"total_tokens":14}},"sequence_number":3}

"""#

    /// D.2 xAI Chat Completions stream.
    static let xai = #"""
data: {"id":"c1","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"reasoning_content":"The","role":"assistant"}}],"usage":{"prompt_tokens":41,"completion_tokens":1,"total_tokens":42},"system_fingerprint":"fp_x"}

data: {"id":"c1","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"content":"Ah","role":"assistant"}}],"usage":{"prompt_tokens":41,"completion_tokens":1,"total_tokens":42},"system_fingerprint":"fp_x"}

data: {"id":"c1","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"content":",","role":"assistant"}}],"usage":{"prompt_tokens":41,"completion_tokens":2,"total_tokens":43},"system_fingerprint":"fp_x"}

data: [DONE]

"""#

    /// D.3 Gemini Interactions stream.
    static let gemini = #"""
event: interaction.created
data: {"interaction":{"id":"v1_abc","status":"in_progress","object":"interaction","model":"m"},"event_type":"interaction.created"}

event: interaction.status_update
data: {"interaction_id":"v1_abc","status":"in_progress","event_type":"interaction.status_update"}

event: step.start
data: {"index":0,"step":{"type":"thought"},"event_type":"step.start"}

event: step.delta
data: {"index":0,"delta":{"signature":"abc","type":"thought_signature"},"event_type":"step.delta"}

event: step.stop
data: {"index":0,"event_type":"step.stop"}

event: step.start
data: {"index":1,"step":{"type":"model_output"},"event_type":"step.start"}

event: step.delta
data: {"index":1,"delta":{"text":"1, 2, 3, ","type":"text"},"event_type":"step.delta"}

event: step.delta
data: {"index":1,"delta":{"text":"4, 5","type":"text"},"event_type":"step.delta"}

event: step.stop
data: {"index":1,"event_type":"step.stop"}

event: interaction.completed
data: {"interaction":{"id":"v1_abc","status":"completed","usage":{"total_tokens":101,"total_input_tokens":11,"total_output_tokens":90}},"event_type":"interaction.completed"}

event: done
data: [DONE]

"""#

    /// D.4 Ollama chat stream (NDJSON).
    static let ollama = #"""
{"model":"gemma:2b","created_at":"2026-11-22T07:32:06.326224Z","message":{"role":"assistant","content":"OK"},"done":false}
{"model":"gemma:2b","created_at":"2026-11-22T07:32:06.346764Z","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop","total_duration":2405164125,"load_duration":2075894750,"prompt_eval_count":33,"prompt_eval_cached_count":0,"prompt_eval_duration":302959000,"eval_count":2,"eval_duration":20789000}

"""#
}
