import Foundation

/// The fake CLIs of plan.md section 10.3: `claude`, `codex`, `agy`, `grok`. `FakeCLIHarness` writes them, with the lines
/// of `AppendixD`, into a temporary directory (they are literals here for the reason given on `AppendixD`).
///
/// Variables, set by the harness's per-test wrapper scripts:
/// - `FAKE_MODE`: ok, auth, quota, garbage, crash (stderr and exit 3), stderr-auth (an auth message on stderr, exit 1),
///   hang (sleep 600), slow (one line per second), tool, tools-on, echo-bytes (print the stdin byte count after
///   300 KB of noise), print-env (write cwd, its listing, the arguments and the environment to `FAKE_OUT`),
///   spawn-child (start `sleep 600` in the background and record its pid).
/// - `FAKE_VARIANT`: which tool or tools-on stream.
/// - `FAKE_HELP=missing-flag`: the help text leaves out one protected flag; grok also knows `no-stdio`.
/// - `FAKE_VERSION`: hang or fail; `FAKE_VERSION_TEXT`: what `--version` prints.
/// - `FAKE_AUTH` (claude: subscription, apikey, loggedout), `FAKE_LOGIN` (codex: chatgpt, apikey, out), `FAKE_MODELS=fail`.
/// - `FAKE_PIDS`: a file that gets "probe <pid>", "run <pid>" and "child <pid>" lines; `FAKE_LOG`: grok's received lines.
/// - `FAKE_STDIN_COPY`: echo-bytes also copies stdin there.
enum FakeCLIScripts {
    static let all: [String: String] = ["claude": claude, "codex": codex, "agy": agy, "grok": grok]

    /// Shared by the four scripts (pasted after the shebang).
    private static let common = #"""
    here=$(cd "$(dirname "$0")" && pwd)
    mode="${FAKE_MODE:-ok}"
    note() { [ -n "$FAKE_PIDS" ] && echo "$1 $2" >> "$FAKE_PIDS"; return 0; }
    consume() { cat > /dev/null; }
    version() {
      note probe $$
      case "${FAKE_VERSION:-ok}" in
        hang) sleep 600; exit 0 ;;
        fail) echo "fake: the real binary is missing" >&2; exit 1 ;;
      esac
      echo "${FAKE_VERSION_TEXT:-$1}"
      exit 0
    }
    help_text() {
      note probe $$
      if [ "$FAKE_HELP" = missing-flag ]; then grep -v -e "$2" "$fx/help.txt"; else cat "$fx/help.txt"; fi
      exit 0
    }
    record() {
      [ -n "$FAKE_OUT" ] || return 0
      {
        echo "CWD=$(pwd -P)"
        echo "LS=$(ls -A | tr '\n' ' ')"
        for a in "$@"; do printf 'ARG=%s\n' "$a"; done
        env | sed 's/^/ENV=/'
      } > "$FAKE_OUT"
    }
    noise() { awk 'BEGIN { for (i = 0; i < 3000; i++) print "noise line " i " ................................................................................." }'; }
    count_stdin() {
      if [ -n "$FAKE_STDIN_COPY" ]; then tee "$FAKE_STDIN_COPY" | wc -c | tr -d ' '; else wc -c | tr -d ' '; fi
    }
    """#

    static let claude = "#!/bin/sh\n# Fake `claude` for CLIProvidersTests.\n" + common + #"""

    fx="$here/fixtures/claude"
    delta() { printf '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"%s"}},"session_id":"s1","parent_tool_use_id":null}\n' "$1"; }
    case "$1" in
      --version|-v) version "2.1.330 (Claude Code)" ;;
      --help|-h) help_text x --strict-mcp-config ;;
      auth)
        note probe $$
        case "${FAKE_AUTH:-subscription}" in
          subscription) cat "$fx/auth-subscription.json"; exit 0 ;;
          apikey) cat "$fx/auth-apikey.json"; exit 0 ;;
          *) cat "$fx/auth-loggedout.json"; exit 1 ;;
        esac ;;
    esac
    note run $$
    case "$mode" in
      ok) consume; cat "$fx/ok.jsonl" ;;
      auth) consume; cat "$fx/auth.jsonl"; exit 1 ;;
      quota) consume; cat "$fx/quota.jsonl"; exit 1 ;;
      garbage) consume; cat "$fx/garbage.txt"; exit 0 ;;
      crash) consume; echo "fake claude: something went wrong" >&2; exit 3 ;;
      stderr-auth) consume; echo "Not logged in · Please run /login" >&2; exit 1 ;;
      hang) sleep 600 ;;
      slow) consume; head -n 1 "$fx/ok.jsonl"; while :; do delta "tick "; sleep 1; done ;;
      tool) consume; cat "$fx/tool-${FAKE_VARIANT:-blocks}.jsonl"; sleep 600 ;;
      tools-on) consume; cat "$fx/tools-on-${FAKE_VARIANT:-bash}.jsonl"; sleep 600 ;;
      echo-bytes) noise; n=$(count_stdin); head -n 1 "$fx/ok.jsonl"; delta "$n"; tail -n 1 "$fx/ok.jsonl" ;;
      print-env) record "$@"; consume; cat "$fx/ok.jsonl" ;;
      spawn-child)
        consume
        sleep 600 &
        note child $!
        head -n 1 "$fx/ok.jsonl"; delta "first "
        if [ "$FAKE_VARIANT" = tool ]; then grep -e '"content_block_start"' "$fx/tool-blocks.jsonl"; fi
        while :; do sleep 1; delta "tick "; done ;;
    esac
    """#

    static let codex = "#!/bin/sh\n# Fake `codex` for CLIProvidersTests.\n" + common + #"""

    fx="$here/fixtures/codex"
    message() { printf '{"type":"item.completed","item":{"id":"item_9","type":"agent_message","text":"%s"}}\n' "$1"; }
    case "$1" in
      --version|-V) version "codex-cli 0.167.0-alpha.3.2" ;;
      login)
        note probe $$
        case "${FAKE_LOGIN:-chatgpt}" in
          chatgpt) echo "Logged in using ChatGPT" >&2; exit 0 ;;
          apikey) echo "Logged in using an API key" >&2; exit 0 ;;
          *) echo "Not logged in" >&2; exit 1 ;;
        esac ;;
      debug)
        note probe $$
        if [ "$FAKE_MODELS" = fail ] && [ "$3" != --bundled ]; then echo "fake codex: no network" >&2; exit 1; fi
        cat "$fx/debug-models.json"; exit 0 ;;
      exec)
        case "$2" in --help|-h) help_text x --ignore-rules ;; esac ;;
    esac
    note run $$
    case "$mode" in
      ok) consume; cat "$fx/ok.jsonl" ;;
      auth) consume; cat "$fx/auth.jsonl"; exit 1 ;;
      quota) consume; cat "$fx/quota.jsonl"; exit 1 ;;
      garbage) consume; cat "$fx/garbage.txt"; exit 0 ;;
      crash) consume; echo "fake codex: something went wrong" >&2; exit 3 ;;
      stderr-auth) consume; echo "Error: not logged in; run codex login" >&2; exit 1 ;;
      hang) sleep 600 ;;
      slow) consume; head -n 2 "$fx/ok.jsonl"; i=0; while :; do i=$((i+1)); printf '{"type":"item.updated","item":{"id":"m%s","type":"agent_message","text":"tick"}}\n' "$i"; sleep 1; done ;;
      tool) consume; cat "$fx/tool-${FAKE_VARIANT:-command}.jsonl"; sleep 600 ;;
      echo-bytes) noise; n=$(count_stdin); head -n 2 "$fx/ok.jsonl"; message "$n"; tail -n 1 "$fx/ok.jsonl" ;;
      print-env) record "$@"; consume; cat "$fx/ok.jsonl" ;;
      spawn-child)
        consume
        sleep 600 &
        note child $!
        head -n 2 "$fx/ok.jsonl"; message "first "
        if [ "$FAKE_VARIANT" = tool ]; then grep -e 'command_execution' "$fx/tool-command.jsonl"; fi
        i=0; while :; do sleep 1; i=$((i+1)); printf '{"type":"item.updated","item":{"id":"m%s","type":"agent_message","text":"tick"}}\n' "$i"; done ;;
    esac
    """#

    static let agy = "#!/bin/sh\n# Fake `agy` for CLIProvidersTests.\n" + common + #"""

    fx="$here/fixtures/agy"
    case "$1" in
      --version) version "agy 1.7.2" ;;
      --help|-h) help_text x --sandbox ;;
      models) note probe $$; cat "$fx/models.txt"; exit 0 ;;
    esac
    note run $$
    case "$mode" in
      ok) consume; cat "$fx/ok.jsonl" ;;
      auth) consume; cat "$fx/auth.jsonl"; exit 1 ;;
      quota) consume; cat "$fx/quota.jsonl"; exit 1 ;;
      model-not-found) consume; cat "$fx/model-not-found.jsonl"; exit 1 ;;
      garbage) consume; cat "$fx/garbage.txt"; exit 0 ;;
      crash) consume; echo "fake agy: something went wrong" >&2; exit 3 ;;
      stderr-auth) consume; echo "authentication required" >&2; exit 1 ;;
      hang) sleep 600 ;;
      slow) consume; head -n 1 "$fx/ok.jsonl"; while :; do sed -n 3p "$fx/ok.jsonl"; sleep 1; done ;;
      tool) consume; cat "$fx/tool.jsonl"; sleep 600 ;;
      tools-on) consume; cat "$fx/tools-on-${FAKE_VARIANT:-always}.jsonl"; sleep 600 ;;
      print-env) record "$@"; consume; cat "$fx/ok.jsonl" ;;
      spawn-child)
        consume
        sleep 600 &
        note child $!
        head -n 1 "$fx/ok.jsonl"; sed -n 3p "$fx/ok.jsonl"
        if [ "$FAKE_VARIANT" = tool ]; then sed -n 3p "$fx/tool.jsonl"; fi
        while :; do sleep 1; sed -n 3p "$fx/ok.jsonl"; done ;;
    esac
    """#

    static let grok = "#!/bin/sh\n# Fake `grok` for CLIProvidersTests: enough of the Agent Client Protocol for the requests of section 5.6.4.\n" + common + #"""

    fx="$here/fixtures/grok"
    reply() { printf '%s\n' "$1"; }
    read_request() {
      IFS= read -r line || exit 0
      [ -n "$FAKE_LOG" ] && printf '%s\n' "$line" >> "$FAKE_LOG"
      rid=$(printf '%s' "$line" | sed -n 's/^{"id":\([0-9][0-9]*\),.*$/\1/p')
    }
    chunk() { reply '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"'"$1"'"}}}}'; }
    case "$1" in
      --version) version "grok 0.1.0" ;;
      --help|-h) help_text x --disallowed-tools ;;
      models) note probe $$; cat "$fx/models.txt"; exit 0 ;;
      sessions) note probe $$; [ -n "$FAKE_LOG" ] && echo "sessions $2 $3" >> "$FAKE_LOG"; exit "${FAKE_DELETE_EXIT:-0}" ;;
    esac
    stdio=0; helpflag=0; prev=""
    for a in "$@"; do
      if [ "$prev" = agent ] && [ "$a" = stdio ]; then stdio=1; fi
      if [ "$stdio" = 1 ] && [ "$a" = --help ]; then helpflag=1; fi
      prev="$a"
    done
    if [ "$helpflag" = 1 ]; then
      note probe $$
      if [ "$FAKE_HELP" = no-stdio ]; then echo "error: unknown command 'stdio'" >&2; exit 2; fi
      echo "Usage: grok agent stdio [options]"; exit 0
    fi
    [ "$stdio" = 1 ] || { echo "fake grok: expected 'agent stdio'" >&2; exit 2; }
    note run $$
    case "$mode" in
      hang) sleep 600 ;;
      crash) echo "fake grok: something went wrong" >&2; exit 3 ;;
      garbage) cat "$fx/garbage.txt"; exit 0 ;;
    esac
    read_request
    if [ "$mode" = auth ]; then
      reply '{"jsonrpc":"2.0","id":'"$rid"',"result":{"protocolVersion":1,"agentCapabilities":{},"authMethods":[{"id":"xai.api_key","name":"API key"}]}}'
      consume; exit 0
    fi
    caps='{"sessionCapabilities":{"delete":{}}}'
    [ "$FAKE_VARIANT" = no-delete ] && caps='{}'
    reply '{"jsonrpc":"2.0","id":'"$rid"',"result":{"protocolVersion":1,"agentCapabilities":'"$caps"',"authMethods":[{"id":"cached_token","name":"Cached login"},{"id":"xai.api_key","name":"API key"}]}}'
    read_request
    reply '{"jsonrpc":"2.0","id":'"$rid"',"result":{}}'
    read_request
    [ "$mode" = print-env ] && record "$@"
    reply '{"jsonrpc":"2.0","id":'"$rid"',"result":{"sessionId":"sess_1"}}'
    read_request
    case "$mode" in
      quota) reply '{"jsonrpc":"2.0","id":'"$rid"',"error":{"code":-32603,"message":"You have reached your usage limit (quota exceeded)"}}'; consume; exit 0 ;;
      tool)
        chunk "Before the tool. "
        if [ "$FAKE_VARIANT" = permission ]; then cat "$fx/permission.jsonl"; else cat "$fx/tool-call.jsonl"; fi
        chunk "AFTER-THE-TOOL"
        sleep 600 ;;
      slow) while :; do chunk "tick "; sleep 1; done ;;
      spawn-child)
        sleep 600 &
        note child $!
        chunk "first "
        if [ "$FAKE_VARIANT" = tool ]; then cat "$fx/tool-call.jsonl"; fi
        while :; do sleep 1; chunk "tick "; done ;;
    esac
    cat "$fx/prompt-answer.jsonl" | sed "s/\"id\":4,/\"id\":$rid,/"
    [ "$FAKE_VARIANT" = exit-after-answer ] && exit 0
    if [ "$FAKE_VARIANT" != no-delete ]; then
      read_request
      reply '{"jsonrpc":"2.0","id":'"$rid"',"result":{}}'
    fi
    consume
    """#

    // MARK: Help texts

    static let claudeHelp = """
    Usage: claude [options] [command] [prompt]

    Options:
      --disable-slash-commands              Disable all skills and commands
      --disallowedTools, --disallowed-tools <tools...>  Comma or space-separated list of tool names to deny
      --include-partial-messages            Include partial message chunks as they arrive
      --input-format <format>               Input format (only works with --print)
      --model <model>                       Model for the current session
      --no-session-persistence              Don't save sessions to disk
      --output-format <format>              Output format (only works with --print)
      --permission-prompts <target>         Who answers permission prompts with --print
      -p, --print                           Print response and exit
      --restricted                          Restricted mode
      --safe-mode                           Start with all customizations disabled
      --strict-mcp-config                   Only use MCP servers from the given configuration
      --tools <tools...>                    Built-in tools to make available
      --verbose                             Override the verbose setting
      -v, --version                         Output the version number

    """
    static let codexHelp = """
    Run Codex non-interactively

    Usage: codex exec [OPTIONS] [PROMPT]

    Options:
      -c, --config <key=value>      Override a configuration value
          --enable <FEATURE>        Enable a feature (repeatable)
          --disable <FEATURE>       Disable a feature (repeatable)
          --strict-config           Error out when config.toml contains fields that are not recognized
      -i, --image <FILE>...         Optional image(s) to attach to the initial prompt
      -m, --model <MODEL>           Model the agent should use
      -s, --sandbox <SANDBOX_MODE>  Select the sandbox policy
      -C, --cd <DIR>                Tell the agent to use the specified directory as its working root
          --skip-git-repo-check     Allow running Codex outside a Git repository
          --ephemeral               Run without persisting session files to disk
          --ignore-user-config      Do not load the user's config.toml
          --ignore-rules            Do not load user or project execpolicy rules files
          --json                    Print events to stdout as JSONL

    """
    static let agyHelp = """
    Usage: agy [options] [prompt]

    Options:
      --input-format <format>        text or stream-json
      --output-format <format>       text, json or stream-json
      --mode <mode>                  accept-edits, auto or plan
      --sandbox                      confine commands
      --disable-slash-commands       turn slash commands off
      --print-timeout <duration>     give up after this long
      --model <slug>                 model to use

    """
    static let grokHelp = """
    Usage: grok [options] [command]

    Options:
      --no-auto-update               do not update
      --sandbox <mode>               sandbox mode
      --permission-mode <mode>       permission mode
      --disallowed-tools <tools>     tools to deny
      --disable-web-search           turn web search off
      --no-subagents                 no sub-agents
      --no-memory                    no memory
      --no-plan                      no planning
      -m, --model <model>            model

    Commands:
      agent stdio                    speak the Agent Client Protocol on stdin and stdout
      models                         list models
      sessions                       manage saved sessions

    """
}
