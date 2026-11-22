import Foundation

/// The recorded and documented stream lines of Appendix D (D.5–D.8), and what the fake CLIs print around them.
///
/// They are Swift literals rather than files under `Fixtures/`: the test target's manifest entry (frozen) declares no
/// resources, and SwiftPM warns about every file in a target directory that it does not handle (contract problem 1 in
/// docs/contract-notes/wp5-cliproviders.md). `FakeCLIHarness` writes them next to the fake scripts at test time.
enum AppendixD {
    // MARK: D.5 Claude Code

    static let claudeOK = [
        #"{"type":"system","subtype":"init","session_id":"s1","model":"m","tools":[],"mcp_servers":[]}"#,
        #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":40,"output_tokens":1}}},"session_id":"s1","parent_tool_use_id":null,"uuid":"u1"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}},"session_id":"s1","parent_tool_use_id":null,"uuid":"u2"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}},"session_id":"s1","parent_tool_use_id":null,"uuid":"u3"}"#,
        #"{"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"Hello world"}]},"session_id":"s1","parent_tool_use_id":null}"#,
        #"{"type":"result","subtype":"success","is_error":false,"result":"Hello world","session_id":"s1","num_turns":1,"duration_ms":1200,"total_cost_usd":0.001,"usage":{"input_tokens":40,"output_tokens":2}}"#,
    ]
    static let claudeInit = claudeOK[0]
    static let claudeDeltaBefore = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Before the tool. "}},"session_id":"s1","parent_tool_use_id":null}"#
    static let claudeDeltaAfter = #"{"type":"stream_event","event":{"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"AFTER-THE-TOOL"}},"session_id":"s1","parent_tool_use_id":null}"#
    static let claudeToolBlockStart = #"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tu_1","name":"Bash","input":{}}},"session_id":"s1"}"#
    static let claudeToolAssistant = #"{"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"tool_use","id":"tu_1","name":"Bash","input":{"command":"ls"}}]},"session_id":"s1"}"#
    /// A tool in a stream event, then the assistant line (D.5's tripwire variant).
    static let claudeToolBlocks = [claudeInit, claudeDeltaBefore, claudeToolBlockStart, claudeToolAssistant, claudeDeltaAfter]
    /// A tool only in an assistant line (no partial messages).
    static let claudeToolAssistantOnly = [claudeInit, claudeDeltaBefore, claudeToolAssistant, claudeDeltaAfter]
    static let claudeToolsOnBash = [#"{"type":"system","subtype":"init","session_id":"s1","model":"m","tools":["Bash"],"mcp_servers":[]}"#, claudeDeltaAfter]
    static let claudeToolsOnMissing = [#"{"type":"system","subtype":"init","session_id":"s1","model":"m","mcp_servers":[]}"#, claudeDeltaAfter]
    static let claudeAuth = [claudeInit, #"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login","session_id":"s1"}"#]
    static let claudeExpired = [claudeInit, #"{"type":"result","subtype":"success","is_error":true,"result":"Failed to authenticate: OAuth session expired and could not be refreshed","session_id":"s1"}"#]
    static let claudeQuota = [claudeInit, #"{"type":"result","subtype":"success","is_error":true,"result":"You've hit your session limit · resets 3:45pm","session_id":"s1"}"#]
    static let claudeDuringExecution = [claudeInit, #"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["something broke"],"session_id":"s1"}"#]
    static let claudeRetry = #"{"type":"system","subtype":"api_retry","attempt":1,"max_retries":10,"retry_delay_ms":2000,"error_status":529,"error":"overloaded","session_id":"s1","uuid":"u9"}"#
    /// Read-tool mode lines of D.5 (used only if the experiment had ended at C2).
    static let claudeInitRead = #"{"type":"system","subtype":"init","session_id":"s1","model":"m","tools":["Read"],"mcp_servers":[]}"#

    /// `claude auth status` [V, shape only; values replaced]. The account fields are placeholders the parser must ignore.
    static let claudeAuthSubscription = #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"<plan>","loginExpiresAt":"2026-12-31T00:00:00.000Z","email":"<account>","orgId":"<account>"}"#
    static let claudeAuthAPIKey = #"{"loggedIn":true,"authMethod":"api_key","apiProvider":"firstParty"}"#
    static let claudeAuthLoggedOut = #"{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}"#

    // MARK: D.6 Codex

    static let codexOK = [
        #"{"type":"thread.started","thread_id":"0199a213-81c0-7800-8aa1-bbab2a035a53"}"#,
        #"{"type":"turn.started"}"#,
        #"{"type":"item.started","item":{"id":"item_1","type":"reasoning","text":""}}"#,
        #"{"type":"item.updated","item":{"id":"item_2","type":"agent_message","text":"Hello"}}"#,
        #"{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"Hello world"}}"#,
        #"{"type":"turn.completed","usage":{"input_tokens":24763,"cached_input_tokens":24448,"output_tokens":122,"reasoning_output_tokens":0}}"#,
    ]
    static let codexStart = Array(codexOK.prefix(2))
    static let codexBefore = #"{"type":"item.updated","item":{"id":"item_2","type":"agent_message","text":"Before the tool. "}}"#
    static let codexAfter = #"{"type":"item.updated","item":{"id":"item_2","type":"agent_message","text":"Before the tool. AFTER-THE-TOOL"}}"#
    static let codexCommand = #"{"type":"item.started","item":{"id":"item_3","type":"command_execution","command":"ls","status":"in_progress"}}"#
    static let codexFileChange = #"{"type":"item.completed","item":{"id":"item_4","type":"file_change","changes":[],"status":"completed"}}"#
    static let codexMCP = #"{"type":"item.started","item":{"id":"item_5","type":"mcp_tool_call","server":"s","tool":"t","status":"in_progress"}}"#
    static let codexUnknown = #"{"type":"item.started","item":{"id":"item_6","type":"some_future_type"}}"#
    static let codexTodo = #"{"type":"item.completed","item":{"id":"item_7","type":"todo_list","items":[]}}"#
    static let codexErrorItem = #"{"type":"item.completed","item":{"id":"item_8","type":"error","message":"a notice"}}"#
    static let codexToolCommand = codexStart + [codexBefore, codexCommand, codexAfter]
    static let codexToolUnknown = codexStart + [codexBefore, codexUnknown, codexAfter]
    static let codexAuth = codexStart + [#"{"type":"turn.failed","error":{"message":"unexpected status 401 Unauthorized: please log in again"}}"#]
    static let codexQuota = codexStart + [#"{"type":"turn.failed","error":{"message":"You've hit your usage limit. Try again later."}}"#]

    /// `codex debug models`, recorded on this machine with codex-cli 0.167.0-alpha.3.2 and trimmed to the fields that
    /// matter (no account data is in this output).
    static let codexDebugModels = #"""
    {"models":[
    {"slug":"gpt-6.2-sol","display_name":"GPT-6.2-Sol","context_window":500000,"max_context_window":872000,"visibility":"list","priority":1,"input_modalities":["text","image"]},
    {"slug":"gpt-6.2-astra","display_name":"GPT-6.2-Astra","context_window":272000,"max_context_window":872000,"visibility":"list","priority":2,"input_modalities":["text","image"]},
    {"slug":"gpt-6.1-terra","display_name":"GPT-6.1 Terra","context_window":500000,"max_context_window":872000,"visibility":"list","priority":4,"input_modalities":["text","image"]},
    {"slug":"gpt-reserve","display_name":"GPT-Reserve","context_window":272000,"max_context_window":872000,"visibility":"hide","priority":7,"input_modalities":["text","image"]},
    {"slug":"gpt-6.1-sol","display_name":"GPT-6.1-Sol","context_window":500000,"max_context_window":872000,"visibility":"list","priority":3,"input_modalities":["text","image"]},
    {"slug":"gpt-6-astra","display_name":"GPT-6-Astra","context_window":272000,"max_context_window":872000,"visibility":"list","priority":5,"input_modalities":["text","image"]},
    {"slug":"gpt-6-sol","display_name":"GPT-6-Sol","context_window":272000,"max_context_window":872000,"visibility":"list","priority":6,"input_modalities":["text","image"]},
    {"slug":"gpt-6-luna","display_name":"GPT-6-Luna","context_window":272000,"max_context_window":872000,"visibility":"list","priority":8,"input_modalities":["text","image"]},
    {"slug":"gpt-5.6-sol","display_name":"GPT-5.6-Sol","context_window":272000,"max_context_window":872000,"visibility":"list","priority":9,"input_modalities":["text","image"]},
    {"slug":"gpt-5.6-terra","display_name":"GPT-5.6-Terra","context_window":272000,"max_context_window":872000,"visibility":"list","priority":10,"input_modalities":["text","image"]},
    {"slug":"gpt-5.6-luna","display_name":"GPT-5.6-Luna","context_window":272000,"max_context_window":872000,"visibility":"list","priority":11,"input_modalities":["text","image"]},
    {"slug":"codex-auto-review","display_name":"Codex Auto Review","context_window":272000,"max_context_window":872000,"visibility":"hide","priority":12,"input_modalities":["text","image"]}
    ]}
    """#

    // MARK: D.7 Antigravity

    static let agyOK = [
        #"{"event":"init","conversation_id":"9ec58bfd","init":{"cwd":"/tmp/x","tools":["ask_permission","run_command","write_to_file"],"permission_mode":"request-review"}}"#,
        #"{"event":"step_update","step_update":{"conversation_id":"9ec58bfd","step_index":0,"state":"DONE","step_type":"user_input"}}"#,
        #"{"event":"step_update","step_update":{"conversation_id":"9ec58bfd","step_index":2,"state":"ACTIVE","step_type":"agent_response","text_delta":"apple"}}"#,
        #"{"event":"step_update","step_update":{"conversation_id":"9ec58bfd","step_index":2,"state":"DONE","step_type":"agent_response","text_delta":"\n","duration_seconds":1.17,"usage":{"input_tokens":30384,"output_tokens":4,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":30388}}}"#,
        #"{"event":"step_update","step_update":{"conversation_id":"9ec58bfd","step_index":3,"state":"DONE","step_type":"checkpoint","duration_seconds":0.5}}"#,
        #"{"event":"result","result":{"conversation_id":"9ec58bfd","status":"SUCCESS","response":"apple\n","duration_seconds":1.43,"num_turns":1,"usage":{"input_tokens":30384,"output_tokens":4,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":30388}}}"#,
    ]
    static let agyInit = agyOK[0]
    static let agyBefore = #"{"event":"step_update","step_update":{"conversation_id":"edb1c8c1","step_index":2,"state":"ACTIVE","step_type":"agent_response","text_delta":"Before the tool. "}}"#
    static let agyAfter = #"{"event":"step_update","step_update":{"conversation_id":"edb1c8c1","step_index":5,"state":"ACTIVE","step_type":"agent_response","text_delta":"AFTER-THE-TOOL"}}"#
    static let agyToolStep = #"{"event":"step_update","step_update":{"conversation_id":"edb1c8c1","step_index":4,"state":"DONE","step_type":"tool","tool_name":"run_command","duration_seconds":0.07,"tool_info":{"name":"run_command","parameters":{"CommandLine":"echo hello_headless_demo"},"output":"hello_headless_demo\r\n"}}}"#
    static let agyTool = [agyInit, agyBefore, agyToolStep, agyAfter]
    static let agyToolsOnAlways = [#"{"event":"init","conversation_id":"9ec58bfd","init":{"cwd":"/tmp/x","tools":["run_command"],"permission_mode":"always-proceed"}}"#, agyAfter]
    static let agyToolsOnMissing = [#"{"event":"init","conversation_id":"9ec58bfd","init":{"cwd":"/tmp/x","tools":["run_command"]}}"#, agyAfter]
    static let agyAuth = [agyInit, #"{"event":"result","result":{"conversation_id":"","status":"ERROR","response":"","error":"authentication required: sign in to Antigravity first"}}"#]
    static let agyQuota = [agyInit, #"{"event":"result","result":{"conversation_id":"","status":"ERROR","response":"","error":"quota exceeded for this account"}}"#]
    static let agyModelNotFound = [agyInit, #"{"event":"result","result":{"conversation_id":"","status":"ERROR","response":"","error":"invalid model selection (--model \"x\" --effort \"\"): model x is not recognized as a known model or custom model in settings"}}"#]
    static let agyModels = """
    gemini-4-neon-high             Gemini 4 Neon (High)
    gemini-4-neon-low              Gemini 4 Neon (Low)
    gemini-4-flash   Gemini 4 Flash

    """

    // MARK: D.8 Grok Build (agent side of the exchange; the client side is checked against `grokClientLines`)

    static let grokInitializeResult = #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"sessionCapabilities":{"delete":{}}},"authMethods":[{"id":"cached_token","name":"Cached login"},{"id":"xai.api_key","name":"API key"}]}}"#
    static let grokAgentLines = [
        grokInitializeResult,
        #"{"jsonrpc":"2.0","id":2,"result":{}}"#,
        #"{"jsonrpc":"2.0","id":3,"result":{"sessionId":"sess_1"}}"#,
        #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_1","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"thinking"}}}}"#,
        #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hello"}}}}"#,
        #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":" world"}}}}"#,
        #"{"jsonrpc":"2.0","id":4,"result":{"stopReason":"end_turn"}}"#,
        #"{"jsonrpc":"2.0","id":5,"result":{}}"#,
    ]
    /// What the client must write, in order (D.8, `→` lines), with "<workdir>" and "<prompt>" standing for the run's values.
    static let grokClientLines = [
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":false,"writeTextFile":false},"terminal":false},"clientInfo":{"name":"referee","version":"0.1.0"}}}"#,
        #"{"jsonrpc":"2.0","id":2,"method":"authenticate","params":{"methodId":"cached_token","_meta":{"headless":true}}}"#,
        #"{"jsonrpc":"2.0","id":3,"method":"session/new","params":{"cwd":"<workdir>","mcpServers":[]}}"#,
        #"{"jsonrpc":"2.0","id":4,"method":"session/prompt","params":{"sessionId":"sess_1","prompt":[{"type":"text","text":"<prompt>"}]}}"#,
        #"{"jsonrpc":"2.0","id":5,"method":"session/delete","params":{"sessionId":"sess_1"}}"#,
    ]
    static let grokToolCall = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_1","update":{"sessionUpdate":"tool_call","toolCallId":"call_001","title":"Reading file","kind":"read","status":"pending"}}}"#
    static let grokPermission = #"{"jsonrpc":"2.0","id":7,"method":"session/request_permission","params":{"sessionId":"sess_1","toolCall":{"toolCallId":"call_001"},"options":[{"optionId":"allow-once","name":"Allow once","kind":"allow_once"},{"optionId":"reject-once","name":"Reject","kind":"reject_once"}]}}"#
    static let grokPermissionAnswer = #"{"jsonrpc":"2.0","id":7,"result":{"outcome":{"outcome":"cancelled"}}}"#
    static let grokModels = """
    grok-code-fast-1   fast model for coding
    grok-4.2           the general model

    """

    // MARK: Garbage

    /// Not JSON, half JSON, control bytes, a long line, invalid UTF-8.
    static var garbage: Data {
        var data = Data("this is not json\n{\"unterminated\": \n]]]\n{\"type\":\n".utf8)
        data.append(contentsOf: [0x01, 0x02, 0xFF, 0xFE, 0x0A])
        data.append(Data(String(repeating: "x", count: 5_000).utf8))
        data.append(0x0A)
        return data
    }
}
