# WP5 — CLIProviders

Notes of work package WP5 (`plan.md` §11.4): the four subscription providers that drive the vendors' own CLIs. Read by Gate 1.

## What exists after this step

| Part | Files (`Sources/CLIProviders/`) |
| --- | --- |
| Binary resolution (§5.6.1): explicit path, `REFEREE_CLI_PATH_*`, candidates (globs newest first), PATH; version within 20 s with exit 0; result cached by modification time, inode and size; help commands kept for the flag check | `BinaryResolver.swift` |
| Child environment and login-shell PATH (§5.6.2) | `ChildEnvironment.swift`, `CLIHost.swift` |
| Process runner (§5.6.3): stdin on a thread, stdout lines, 64 KB stderr ring, three timeouts, SIGINT/2 s/SIGTERM/3 s/SIGKILL, whole-tree kill | `CLIRunner.swift`, `CLIProcess.swift`, `PipeReader.swift`, `StdinWriter.swift`, `ProcessTree.swift`, `CLICommand.swift`, `CLIWorkspace.swift` |
| Argument tables with protected elements, `!` removal, whole-word flag check | `CLIArguments.swift` and one table per adapter |
| The four adapters with their tripwires, sign-in checks and model lists | `ClaudeCodeAdapter.swift`, `CodexAdapter.swift`, `AntigravityAdapter.swift`, `GrokBuildAdapter.swift` (with the ACP client), `CLIAdapter.swift`, `CLIProvider.swift`, `CLIPrompt.swift` |
| Page images with CoreGraphics for `.pageImages` (110 dpi, `p001.png` …) | `PageImageRenderer.swift` |
| `CLIProviderFactory` (§11.3 surface unchanged) | `CLIProviderFactory.swift`; the Wave 0 placeholder is gone |

Tests (`Tests/CLIProvidersTests/`, 88 in the default run, of which 2 skip visibly: the smoke prompt and the experiment): every acceptance row of WP5, the fake CLIs of §10.3 (`FakeCLIScripts.swift`, `FakeCLIFixtures.swift`, `FakeCLIHarness.swift`), and the real-binary rows.

## Delivery experiment (§5.6.6): outcome and constants

Run through the adapters themselves (`REFEREE_CLI_EXPERIMENT=C1` or `X1`, test `CLIDeliveryExperimentTests`), with `Fixtures/pdf/ay_round_nolinks.pdf` only, system prompt "You read academic manuscripts and answer questions about them precisely." and the question of §5.6.6 as printed.

| # | CLI | Result | Answer (complete) | Tokens in / out | Time |
| --- | --- | --- | --- | --- | --- |
| C1 | Claude Code 2.1.330, document block on stdin | **PASS** | `\frac{\pi f(s_i \mid H)}{\pi f(s_i \mid H) + (1 - \pi) f(s_i \mid L)}` / `0.87` | 8,418 / 58 | 3.5 s |
| X1 | codex-cli 0.167.0-alpha.3.2, four PNGs at 110 dpi with `-i` | **PASS** | `\frac{\pi f(s_i \mid H)}{\pi f(s_i \mid H) + (1-\pi)f(s_i \mid L)}` / `0.87` | 17,434 / 40 | 13.1 s |

C2 was not run (only if C1 fails), and no retry was needed. Both runs ended `.finished(.endOfTurn)`, no tripwire fired, no status was emitted.

Constants set from it (Gate 1: copy these into `SnapshotSupport`'s static rows, which still carry the Wave 0 values; also `maxPromptBytes`, which those rows leave nil):

| Provider | `CLIPDFDelivery` | `supportsNativePDF` | `pdfDeliveryNote` | `maxPromptBytes` | Tripwire in PDF mode |
| --- | --- | --- | --- | --- | --- |
| `claude-cli` | `.documentBlock` (`ClaudeCodeAdapter.delivery`) | true | nil | 9,000,000 | as §5.6.4: no tools at all |
| `codex-cli` | `.pageImages` (`CodexAdapter.delivery`) | true | "sent as page images" | 4,000,000 | as §5.6.4 |
| `antigravity-cli`, `grok-cli` | `.none` | false | nil | 4,000,000 | — |

What the streams looked like (account fields removed):

- Claude Code, init line of the smoke run (C1's has the same shape; it also listed a fifth built-in plugin, `cc-plugin-easel`): `{"type":"system","subtype":"init","tools":[],"mcp_servers":[],"agents":["claude","Explore","general-purpose","Plan","web-fetch"],"plugins":["cc-plugin-agents-md","cc-plugin-telemetry","cc-plugin-privacy","cc-plugin-plugin-authoring"],"skills":[],"slash_commands":[],"permissionMode":"default","apiKeySource":"none","output_style":"default","model":"claude-opus-5-5","claude_code_version":"2.1.330", …}`. Then a `system`/`status` line, `stream_event`s (`message_start`, one `text` block, `text_delta`s, `message_delta`, `message_stop`), one `assistant` line, a `rate_limit_event` line, and the `result` line (`"subtype":"success","is_error":false,"stop_reason":"end_turn"`). `--system-prompt-file`, absent from `--help`, is accepted. The tool list is empty as §5.6.4 hoped; built-in agent definitions and plugins are still listed under `--safe-mode`, and none can act without a tool.
- Codex: `thread.started`, `turn.started`, one `item.completed` of type `agent_message` with the whole answer, `turn.completed` with `usage`. No `item.updated` with partial text, which confirms the "message" granularity of the roster.
- For planning (WP6, §6.4): a 4-page PDF cost 8,418 input tokens through Claude Code (about 2,100 a page) and 17,434 through Codex (its own instructions are about 12,600 tokens, see the smoke row; about 1,200 a page image).

## Real prompts sent (complete list)

| # | When | Through | What | Result |
| --- | --- | --- | --- | --- |
| 1 | §5.6.6 | Claude Code | C1 with `ay_round_nolinks.pdf` | PASS, as above |
| 2 | §5.6.6 | Codex | X1 with `ay_round_nolinks.pdf` | PASS, as above |
| 3 | acceptance, `REFEREE_CLI_SMOKE=1` | Claude Code | "Reply with exactly: OK" | "OK", `.finished(.endOfTurn)`, 754 / 4 tokens, no tripwire |
| 4 | acceptance, `REFEREE_CLI_SMOKE=1` | Codex | "Reply with exactly: OK" | "OK", `.finished(.endOfTurn)`, 12,603 / 5 tokens, no tripwire |

Antigravity and Grok Build are not installed; the smoke test skipped them ("agy is not installed", "grok is not installed"). Totals: two prompts per CLI of the three plus one allowed.

**Incident during development (fixed, not a prompt through a subscription).** In three early test runs, seven test cases sent a `codex exec` request to `api.openai.com` that was rejected with "401 Unauthorized: Missing bearer or basic authentication in header". Cause: under load the fake CLI's `--version` probe missed its deadline (see decision 2), and the resolver went on to its next candidates, which include the real Codex inside the ChatGPT app. The test environment's HOME was an empty temporary directory, so Codex had no credentials and no access to the user's `~/.codex`; the prompt was the tests' synthetic text ("SYSTEM-MARKER-3K9 You are a referee." / "USER-MARKER-7Q2 Please review."); no manuscript and no fixture went out, and no subscription was used. Fix: `CLIHost.searchesDefaultLocations`. Every test that runs a fake sets it to false, so the resolver looks only at the explicit path and the override variable and can never reach a real binary. The resolver tests that exercise candidates and PATH use the name `fakecli` and temporary candidates only.

## grok

`npm view @xai-official/grok name version repository homepage maintainers` gives: name `@xai-official/grok`, version 1.0.92, maintainer `xai-security` with an address on `x.ai`. The package has **neither a `repository` nor a `homepage` field** (checked in the full `npm view --json`; it also runs a `postinstall` script). The brief allowed the install only if its repository or homepage is on an xAI domain or xAI's GitHub organisation, so **grok was not installed**, and `docs/contract-notes/wp5-grok-help.txt` was not written (there is no help text to save). The Grok Build adapter is as specified in §5.6.4, unchecked against a binary: its flag check and `agent stdio --help` requirement will decide on a real install, and the experimental label stays. Gate 1 can decide whether a maintainer address on `x.ai` is enough to install it and read the help text then.

## Corrections to the argument tables

- Claude Code and Codex: none needed. Every protected flag is in the installed help texts (`claude --help` 2.1.330, `codex exec --help` 0.167.0-alpha.3.2), the flag check passes for both (real-binary tests), and both ran the tables of §5.6.4 unchanged (rows 1–4 above).
- Codex `-c` values: the plan writes them in shell notation (`-c web_search="disabled"`). They are passed as the TOML strings the shell form `-c 'web_search="disabled"'` would give, i.e. the argument is `web_search="disabled"` with its quotes, so that Codex parses a TOML string and never relies on its fallback for text that is not TOML. `history.persistence="none"` likewise; `agents.enabled=false` as is.
- Grok Build: not checked (not installed). Separator of `--disallowed-tools` (comma) and placement of the options before `agent stdio` stay as printed.

## Decisions

Things the plan left open, decided inside `Sources/CLIProviders`.

1. **No `FileHandle` for the pipes** (§5.6.3 says stdout is read with `FileHandle.bytes`). Measured here: `FileHandle.bytes` serialises reads across handles (with twelve silent children, a thirteenth child's two lines arrived after 3.0 s instead of 0.2 s). `readabilityHandler` did not have that problem in isolation, but under the parallel tests some pipes stopped delivering data while other processes came and went (descriptor numbers are reused at once, and a dispatch source must not outlive its descriptor). So the runner creates its pipes itself with close-on-exec, gives the child its ends as `FileHandle`s that do not close on deallocation, closes those in the parent after spawning (`Process` leaves them open when given file handles, verified), and reads each pipe on a thread of its own (`PipeReader`: `poll` with 250 ms, then `read`) that owns and closes its descriptor. stdin is written by `StdinWriter`, a thread that owns its descriptor, with `F_SETNOSIGPIPE` (a CLI that exits without reading gives EPIPE, not a SIGPIPE that ends the app). `LineSplitter` is used as specified.
2. **First runs of new executables are slow.** macOS assesses a new executable on its first run: measured here, 40 new two-line scripts started at once took up to 8.3 s each (mean 4.1 s), against 0.01 s for a script that has run before or for a new script run as `/bin/sh <script>`. For the app this is covered by the 20 s version timeout and the resolver's cache; for the tests, the fakes and their few entry scripts are installed once per test process and run once right away (`FakeCLIInstall`), and a test chooses a fake's behaviour through `$HOME/fake.env` in a home directory of its own.
3. **The whole tree.** Descendants are listed with `proc_listchildpids` before the first signal and twice a second while the CLI runs; every signal is sent only to a process whose start time still matches (`proc_pidinfo`), so a reused pid is never hit. `Process` makes the CLI the leader of a process group of its own (verified), so the group is also killed while the CLI is alive (`killpg`), and after any kill the watchdog sweeps the group's members (`proc_listpgrppids`, start time not before the CLI's) on every tick until the run is finished: this catches a child whose fork was under way while the group was being killed (seen in the tests as `sleep 600` orphans before the sweep existed). If the CLI exits by itself and something still holds its pipes after 2 s, the tracked descendants and the group are killed; after 4 s the pipes are abandoned.
4. **Timeouts.** "start" counts from spawn to the first stdout byte, "idle" from the last complete line (or the first byte), "total" from spawn. A timeout ends the run gracefully (SIGINT, 2 s, SIGTERM, 3 s, SIGKILL); the error is thrown once the process is gone and before the working directory is removed. Probes (`--version`, help, sign-in status, model lists, `grok sessions delete`) are run to completion with one 20 s cap and are killed at once when they overrun. A death by signal n is reported as exit code 128 + n.
5. **After the result line.** A CLI that has printed its success line gets 10 s to exit before it is ended; the run still succeeds. After a failure line it gets 2 s. `.finished` is yielded only after the process is gone and the working directory removed, so a consumer that sees `.finished` sees no leftovers.
6. **Resolver.** Step (4) searches the child's PATH (the login shell's PATH plus the fallbacks) instead of running `command -v` in a second shell: same result for an executable, one shell run fewer, and testable. A glob candidate contributes all its matches, newest version first (natural order of the digits), so a broken newest copy falls back to an older one. A failed validation is cached for 5 minutes (a busy machine can make a healthy binary miss the deadline), a success until the file changes. An explicit path or override that does not exist is passed over. Nothing found gives `.notConfigured("<name> is not installed")`; only broken copies give `.notConfigured("<name> was found but does not run (…); reinstall it")`; `availability()` turns both into `.needsSetup` with the install command.
7. **Flag check.** The first help command's stdout and stderr are searched; a flag is present if neither a letter, a digit, "_" nor "-" is next to it. Every further help command (Grok's `agent stdio --help`) must exit 0; if one does not, the reason names the command. `stream` throws `.notConfigured(<the same reason>)` without starting the CLI, and `listModels` does too.
8. **`!` in `extraArguments`.** It matches an element by its flag name (the first token up to "=") or by all its tokens joined with spaces; a removal that names nothing gives the status "ignored: X is not a default argument". Extra arguments are otherwise passed verbatim; a user who adds `--tools default` gets a tripwire, not tools.
9. **Requests.** Text parts are joined with a blank line; `.cacheBoundary` is dropped. With an empty system text the inline form is the user text alone. A `.pdf` part on a route with delivery `.none` is `.invalidRequest`; more than one PDF too. A model id is refused (`.invalidRequest`) if it starts with "-", is not one printable token, or is longer than 200 characters. A prompt above `maxPromptBytes` is `.contextTooLong` before anything starts; for the document block the message names the pdf, so the engine's fallback to text mode applies.
10. **Tripwires beyond §5.6.4, all fail-closed.** Claude Code: an allowlist of block types (`text`, `thinking`, `redacted_thinking`) for both `content_block_start` and `assistant` lines, so any new tool-like block trips; `input_json_delta`; a `user` line with a `tool_result`; any line with a non-null `parent_tool_use_id`; text before the init line; a success result without an init line. Antigravity: text before the init line; a success result without one. Codex: an item without a type. Grok Build: requests from the agent are answered (permission: "cancelled") before the kill.
11. **Classification beyond §5.6.4.** Claude: `api_error_status` 401 → `.auth`; `stop_reason` from `message_delta` or the result (`max_tokens`, `refusal`) is used when present; input tokens include cache creation and cache reads. Codex: "log in" counts as an auth word; an `error` event is not final (Codex also reports reconnects that way) and decides the run only if no turn completes. Antigravity: "not recognized as a known model" is checked before "limit". Grok Build: "quota", "usage limit" → `.quotaExhausted`, "rate limit" → `.rateLimited`, so its `quota` fake gives `.quotaExhausted` as the failures row asks.
12. **Codex text.** A new `agent_message` item starts on a new line if the text so far does not end with one. With page images, a model's `supportsPDFInput` comes from its `input_modalities` (all twelve models here take images).
13. **Grok Build session.** Requests are sent one at a time, each after the previous answer. After the prompt's answer and 500 ms without a line: `session/delete` if advertised, waiting at most 5 s for its answer; then stdin is closed and the agent gets 2 s to exit before it is terminated; then, if the session was not deleted through the protocol, `grok sessions delete <sid>` (20 s cap); a failure there is the one `.status` before `.finished`. After a tripwire, an error or a cancellation the command runs too (best effort, no status). A failed write to the agent's stdin is not an error by itself: the exit or a timeout decides. An agent that exits right after answering keeps its answer (a fake variant tests this). A `protocolVersion` other than 1 in the answer is `.malformedResponse`. `clientInfo.version` is the bundle's short version, or "0.1.0".
14. **Working directories** are made under the app's TMPDIR (else the system's), resolved with `realpath` (so `/private/var/...`, as the CLIs report it), mode 0700; files in them 0600. Directories older than two hours that a crash left behind are removed at the first run after launch, once per process.
15. **Availability texts.** Claude: ready with the detail "Logged in · claude <version>"; logged out: needs setup, reason "Claude Code is not signed in", hint "Run \`claude\` in Terminal and use /login"; unreadable status: needs setup, reason "Could not read Claude Code's sign-in status", hint "Run \`claude auth status\` in Terminal". Codex: ready with "Logged in using ChatGPT · codex <version>". Claude's models: `default`, `opus`, `sonnet`, `haiku`, `fable` with the display names Default, Opus, Sonnet, Haiku, Fable; no CLI call. Grok's model list skips lines ending in ":" and repeats.
16. **Log events** (no text, no paths): `cli.run.start` (provider, bytes, pdf, delivery), `cli.run.end` (provider, outcome, ms), `cli.tripwire` (provider, tool).
17. **Test knobs** in the internal `CLIHost` (the app uses the defaults): a fixed PATH instead of the login shell, run and probe timeouts, `searchesDefaultLocations`, a delivery override (the experiment), and a line observer (the smoke and experiment tests print every stdout line so that a failure can be studied without a second prompt).
18. **Two facts about the installed CLIs.** `codex login status` writes "Logged in using ChatGPT" to **stderr**; the adapter reads the first non-empty line of stdout, else of stderr. `claude auth status` finds the subscription login only when `USER` is set (with `LOGNAME` alone it reports `loggedIn: false`); `USER` is in §5.6.2's list, so the app is fine, but a test that injects an environment must include it.

## Contract problems

1. **Data files in a test target make SwiftPM warn** (§10.3 names `Tests/CLIProvidersTests/FakeCLI/claude` …; Appendix D says to save each block under the test target's `Fixtures/`; §11.2 allows `Tests/<Target>Tests/Fixtures/`). The frozen manifest declares neither `resources:` nor `exclude:`, and with two such files the build prints "warning: 'wp5-cliproviders': found 2 file(s) which are unhandled; explicitly declare them as resources or exclude from the target", which the acceptance forbids. *Workaround:* the fake scripts and the Appendix D lines are Swift literals (`FakeCLIScripts.swift`, `FakeCLIFixtures.swift`) that `FakeCLIHarness` writes into a temporary directory. *To decide:* either exclude `Fixtures` and `FakeCLI` folders of test targets in the manifest, or reword §10.3 and Appendix D. Other Wave 1 packages with fixture files will meet the same warning.
2. **`SnapshotSupport`'s static rows** (frozen) still say `pdf: false` for `claude-cli` and `codex-cli`, have no `pdfDeliveryNote`, and leave `maxPromptBytes` nil. Gate 1: use the table of the delivery section above (Gate 0 left this to Gate 1).
3. **§5.6.6 names the record `docs/contract-notes/wp5-cli.md`**; this package may write only `wp5-cliproviders.md`, so the outcome and the streams are recorded here.
4. **`REFEREE_CLI_EXPERIMENT`** (C1 or X1) is a variable of this package's tests that §10.6 does not list. It exists so that the experiment can be reproduced and can never run with `REFEREE_CLI_SMOKE=1` (Wave 3 step 5). Gate 1 may list it in §10.6 or delete `CLIDeliveryExperimentTests`.
5. **`CLAUDE_CODE_OAUTH_TOKEN` is not in §5.6.2's copy list.** A user who signs Claude Code in with `claude setup-token` and that variable would be reported as not signed in. Left as the plan says; flagged in case the list should grow.
6. **§5.6.3's "stdout is read with `FileHandle.bytes`"** is wrong for this use (decision 1); the plan text should say a reader thread per pipe.

## For Gate 1

- The delivery constants and `SnapshotSupport` (contract problem 2). With them, PDF mode becomes available for `claude-cli` (planning limit 100 pages) and `codex-cli` (40 pages); the engine's `pdfTokensPerPage` of §6.4 (4,500 and 1,500) are conservative against the measurements above.
- Wave 3 step 5 (`REFEREE_CLI_SMOKE=1 scripts/test.sh --filter CLIProvidersTests`) needs no change; it skips CLIs that are not installed or not signed in.
- A run takes a few seconds before the first model token: login-shell PATH (once), `--version` and help (once per binary, cached), sign-in status is not run by `stream`.
- The fakes are installed once per test process under `$TMPDIR/referee-wp5-fakes-<uuid>` and removed at exit (left-over ones are removed after an hour). The test suite runs in about 11 s here and leaves no process and no directory behind (checked after every run with `ps` and a listing of `$TMPDIR`).
- `/opt/homebrew/bin/codex` is still broken; the resolver passes over it to the ChatGPT app's copy (real-binary test). The README should still tell the user to reinstall Codex.

## Acceptance

Run on Command Line Tools 26.6 (Swift 6.3.3) with `-j 2`, after touching every file of `Sources/CLIProviders` and `Tests/CLIProvidersTests`.

| Command | Result | Final line |
| --- | --- | --- |
| `scripts/build.sh -j 2` | exit 0; no line with "warning" or "error" | `Build complete! (2.05s)` |
| `scripts/test.sh -j 2 --filter CLIProvidersTests` | exit 0; no "warning"; smoke and experiment skipped with their reasons; no process and no `referee-*` directory left afterwards | `test.sh: OK (88 tests)` |
| `scripts/test.sh -j 2` | exit 0; no "warning"; 38 suites | `test.sh: OK (216 tests)` |
| `REFEREE_CLI_SMOKE=1 scripts/test.sh -j 2 --filter CLIProvidersTests` (run once, for the smoke row, before the last two changes: the Grok driver's handling of an agent that exits right after answering, with its test, and one lock in `CLIProcess` written as `withLock` with the same effect; neither changes what the Claude or Codex path does) | exit 0; smoke ran for `claude-cli` and `codex-cli`, both "OK"; `antigravity-cli`, `grok-cli` skipped (not installed) | `test.sh: OK (87 tests)` |
| `git status --porcelain \| wc -l` | after the last commit | `0` |
