# Referee plan: independent review

Reviewed: `/Users/morankoren/Referee/plan.md` (4,040 lines), all sections and appendices.
Date: 2026-11-22. Machine: macOS 26.6.1, Apple Silicon, Command Line Tools 26.6 (Swift 6.3.3).

Method: read the whole plan; compiled Appendix A as printed; ran the plan's scripts and fixture build as printed; wrote Swift probes for PDFKit, the SwiftUI/AppKit window, click interception, export, and the Keychain; ran the plan's default review prompt through local Ollama models; checked vendor documentation live and against the copies the plan's author downloaded; rendered Codex's model-visible tool list locally (no prompt was sent to any subscription CLI or paid API). Plan references are section numbers and line numbers (`l. N`) of `plan.md`. Probe sources and outputs are listed at the end.

---

## 1. Verdict

The plan can be executed, but not as written. The build side is sound: the §3.2 manifest, `build.sh`, `test.sh`, `bundle.sh`, `make-fixtures.sh`, Appendix A and the snapshot capture mechanism all work on this toolchain as printed, and the two risky UI assumptions I tested (intercepting citation clicks in a `PDFView` subclass, SwiftUI overlays above the PDF appearing in captures) hold. What is wrong is concentrated in three places, and each is cheap to fix now and expensive after Wave 0 freezes.

The three things most likely to sink it:

1. **Seams that no contract covers.** The engine contract cannot carry what §6 says the engine needs (the paper digest for discussions and questions, the model's context window). The Reader and Shell packages are built in parallel against two different descriptions of `ReaderController`, and nobody is told to call `attach()`, open the find bar, or draw the banner. The snapshot mode swaps the provider registry after the engine has already captured the old one, so three required scenes cannot be produced. Eight agents will each pass their own acceptance and the parts will not connect.
2. **Everything about real journal PDFs rests on two synthetic LaTeX files.** A `[V]` claim that an acceptance test depends on is false on the plan's own fixtures. The author–year citation rules, read literally, drop "In Smith (2019)" and "The Banerjee (1992) model" and can cut the reference list at "A Course in Game Theory. MIT Press." Selections on a line-numbered manuscript carry the margin numbers into the prompt and draw page-wide highlights. None of the acceptance tests would notice.
3. **The subscription layer is specified from documentation and tested only against its own fakes, and it leaves agent tools on.** The Grok invocation never removes tools although the CLI has a flag for it; the Antigravity invocation runs in a mode that auto-executes commands; the Codex invocation is mostly safe, but the plan's own escape hatch re-enables a UI-automation plugin on this machine. §12.5 tells the user the model has no tools in any configuration. That is not true.

Counts: 1 blocker, 11 major, 17 minor.

---

## 2. Findings

### 2.0 Coverage of the request

| Asked for | Where in the plan | Status |
| --- | --- | --- |
| PDF reader with AI comments in a sidebar | §7, §9.2–9.3 | Covered. Layout verified by probe. |
| Approve / reject / discuss each comment; add my own | §6.8, §9.3–9.4 | Covered. |
| Highlight text and ask the AI about it | §6.9, §9.5 | Covered, but broken on line-numbered manuscripts (M6). |
| Generate the review for me to edit | §6.10, §9.8, App. B.4 | Covered; template and voice rules follow the skill file. |
| API key for Anthropic, Gemini, OpenAI, Grok; Ollama local | §5.4 | Covered. Documentation claims check out (section 3). |
| Subscription for Anthropic | §5.6.4 Claude Code | Covered. Flags verified against `claude --help` 2.1.330. Text only (M10). |
| Subscription for OpenAI | §5.6.4 Codex | Covered. Flags verified; residual tools (B1). Text only. |
| Subscription for Gemini | §5.6.4 Antigravity | Weakened: built blind for a CLI that is not installed; leaves command execution on (B1). Dropping `gemini` itself is correct (see below). |
| Subscription for Grok | §5.6.4 Grok Build | Weakened: built blind; tools not removed (B1); the vendor does not say whether headless use draws on a plan. |
| Open cited papers by clicking in-text references | §8 | Covered for hyperref PDFs. For link-less author–year PDFs it will miss common forms (M7). |

**The `gemini` decision is right.** The Gemini CLI README now says free individual access and Google AI Pro / Ultra "moved to Antigravity CLI on June 18, 2026", and Google's blog post of 2026-05-19 says Gemini CLI "will stop serving requests for Google AI Pro and Ultra" and stays available only with paid API keys and Code Assist licences. The `gemini` 0.30.0 installed here predates that. Supporting `gemini -p` as well would be cheap to write (it has `-p`, `-o stream-json` and `--approval-mode plan`), but it would serve only paid API keys, which the direct Gemini API provider already serves with native PDF input, and it has no flag that removes tools. Do not add it.

**The Grok CLI exists** (`grok`, documented at docs.x.ai/build), so adding it is defensible, but see B1 and the deferral in section 4.

**In the plan and not asked for** (each adds build or integration surface): `referee-cli` with twelve subcommands; `.docx` and `.pdf` export; a two-column reading-order repair; a four-service reference-lookup chain; a report linter plus an LLM "voice revision" pass; a reference-viewer window with tab grouping; a consent card, Local-only mode and run audit trail; a welcome window with recent reviews; prompt and rubric editors; schema migration; an LRU PDF cache. Section 4 says which to cut.

**Prompts against the skill file.** The default prompts in Appendix B follow `peer-review/SKILL.md` closely: the five questions in order, the mathematics checks, the table-citation rule, the overclaiming list, the six report headings including publication probability, first person, the banned words. Two gaps showed up in real output. `gemma4:e4b` addressed the authors directly ("You state that the coefficient…"), which the skill's examples never do; add "refer to 'the authors'; never write 'you'" to `reviewSystem`. And `strength` comments came out as generic praise (M9). The weakness of the reviews will not be the prompts. It will be what the model is given to read (M9, M10).

**What holds up** (verified, no change needed): the §3.2 manifest builds with stub sources and `bundle.sh` produces an app that passes `codesign --verify`; Appendix A.1–A.8 compiles as printed with no warnings; A.9's declarations compile with stub bodies; `scripts/test.sh` returns 0 / 1 / 3 as claimed and `--filter <Target>` works; `make-fixtures.sh --pdf-only` builds all six PDFs as printed; a literal implementation of the §6.7 fold located 42 of 43 quotes written by `gemma4:e4b` and `phi4` across five runs (40 exactly, 2 through the fuzzy stage; the one miss was a "quote" `phi4` invented); the block output format, including `@@NOTES` when reading in parts, was followed without error by both models; the worktree procedure of §11.1 is sound (a private `.build` per worktree is what matters, and the plan has it); a `PDFView` subclass that swallows `mouseDown` on a link does stop PDFKit's jump to the bibliography; in-memory highlight annotations draw, hit-test and leave `documentURL` nil; SwiftUI overlays above the PDF are present in `CGWindowListCreateImage` captures.

---

### Blocker

#### B1. Untrusted manuscript text is handed to CLI agents that still have tools; §12.5's assurance is false

**Where.** §5.6.4 (l. 807–847), §5.6.3 (l. 769), §12.5 (l. 2211: "the model has no tools in any provider configuration (API calls declare none; CLIs run with tools removed or in an empty sandboxed directory)").

**What is wrong, per CLI.**

- **Grok Build** (l. 838–840). The invocation passes `--max-turns 1 --disable-web-search --no-subagents --no-memory --no-plan` and nothing that removes tools. The CLI reference lists `--tools <LIST>`, `--disallowed-tools <LIST>` ("Allow or remove built-in tools"), `--sandbox <PROFILE>` and `--allow/--deny` rules; the plan uses none of them. The headless page does not say what happens to a tool call when nobody is there to approve it. The manuscript also travels as a process argument, visible in `ps`.
- **Antigravity** (l. 824, 831). The plan omits `--mode`, so since v1.5.7 print mode runs in `auto`, and it adds `--sandbox`. The docs say that in `auto` "workspace file edits and sandboxed or safe, reversible commands run automatically", and the modes page adds that safe commands run automatically *outside* the sandbox. The sample `init` event in the plan's own Appendix D.7 lists `run_command` and `write_to_file`. The sandbox page says unmounted paths are invisible and the network is off by default, so the exposure is probably contained, but nobody can confirm that here and there is no flag that removes the tools.
- **Codex** (l. 808–811). Better than I expected, and I could check it without sending a prompt: `codex debug prompt-input` renders the model-visible tool list. With an empty config directory (the nearest stand-in for `--ignore-user-config`) and the plan's overrides, `exec_command` and `write_stdin` are gone, so `features.shell_tool=false` works. What remains: a JavaScript `exec` orchestrator with nested `apply_patch`, `view_image` and MCP-resource tools, a `spawn_agent` family, and read access to the whole disk (`<entry access="read"><special>:root</special>`). With the user's real config, which is what the plan's suggested `!--ignore-user-config` (l. 816) restores, the list also contains `mcp__cua_repl.js`: "Control native apps or browsers on the user's computer by reading or operating UI", from the `unified-computer-use` plugin enabled in `~/.codex/config.toml` on this machine.
- **Claude Code** (l. 790–795). Sound. `--tools ""` is documented as "none", `--safe-mode` keeps subscription auth, `--strict-mcp-config` with no `--mcp-config` loads no servers. I could not confirm the runtime tool list without a prompt.

No adapter checks what the CLI actually exposed, and no adapter stops when a tool is used.

I rate this a blocker because the input is other people's confidential text that can carry instructions, the plan promises the opposite in writing, and two of the four invocations would ship as specified. With the tripwire below and the deferral in section 4 it stops being one.

**Evidence.** `review/out/cx_plan.json`, `cx_default.json`, `codex_prompt_input.json` (tool lists); `claude --help` 2.1.330; <https://docs.x.ai/build/cli/reference> ; <https://docs.x.ai/build/cli/headless-scripting> ; <https://antigravity.google/docs/cli/headless> ; <https://antigravity.google/docs/cli/modes> ; <https://antigravity.google/docs/sandbox?tab=cli> .

**Change.**

1. Add a fail-closed tripwire to every CLI adapter, since all three structured streams already expose what is needed. Claude: abort unless the `system/init` line has `tools: []` and `mcp_servers: []`. Codex: abort on any `item.*` of type `command_execution`, `file_change`, `mcp_tool_call`, `collab_tool_call` or `web_search` (the types are in `codex-rs/exec/src/exec_events.rs`). Antigravity: abort on any `step_update` with `step_type == "tool"`. On a trip, kill the process, discard the output, and show "the CLI tried to use a tool; the run was stopped".
2. Codex: add `--strict-config` so a renamed feature key fails loudly instead of silently restoring the shell; add `--disable view_image`; delete the `!--ignore-user-config` advice from l. 816; add a WP5 test that runs `codex debug prompt-input` with the adapter's flags (skipped when the binary is absent) and asserts the output contains no `exec_command`, `write_stdin` or `mcp__`.
3. Grok: add the documented tool-removal flag and a restrictive `--sandbox` profile, or do not ship the adapter (section 4).
4. Antigravity: pin a mode instead of inheriting `auto`, rely on the tripwire, or do not ship the adapter (section 4).
5. Rewrite §12.5 to say what is true per provider.

---

### Major

#### M1. The engine contract cannot carry what §6 requires

**Where.** Appendix A.6 (l. 2871–2877, 2886–2893, 2926–2932) against §6.3 (l. 948) and §6.4 (l. 967).

**What is wrong.**

- §6.3 says the paper context for `discuss` and `ask` on a small context window is "`session.paperDigest` … followed by the rendered text of the anchor's page and its two neighbours". Neither `discuss(paper:comment:message:context:)` nor `ask(paper:conversation:question:context:)` receives a session or a digest, and `EngineContext` holds only provider, provider settings, prompts, rubric and meta. Only `generateReport` gets the session. WP6 cannot implement l. 948 for exactly the local-model case it was written for.
- §6.4 computes `context = settings.contextWindowOverride ?? model.contextWindow ?? …` and `sendsPDF` consults `ModelInfo.supportsPDFInput`. Nothing says where `model` comes from. `ProviderSettings.cachedModels` appears only in its own declaration (l. 2970). `plan()` is "no network", so it cannot call `listModels()`. With no model info the Anthropic path falls to 128,000 tokens, which at 4,500 tokens per page refuses PDF mode above 23 pages; the plan's own running example, a 34-page PDF sent in one request (l. 1559, l. 2005), then silently drops to text mode.
- `SendPlan` reports "cannot run" only as free text in `warnings` (l. 913, 971). `canStartReview` and the Review button have nothing to test.
- "Paper context" for `ask` with no selection and for the report on a small window has no anchor page; unspecified.

**Change (before Wave 0 freezes).** Add `model: ModelInfo?` and `paperDigest: String?` to `EngineContext`; state that AppCore fills `model` from `cachedModels`, refreshing once per session; add `blockingReason: String?` to `SendPlan`; say that without an anchor the context is the digest plus page 1.

#### M2. Snapshot mode as wired cannot produce three required scenes

**Where.** §10.1 step 1 (l. 1607), `SnapshotScene` (l. 1624–1632), §5.9 (l. 872–879), Composition wiring (l. 1839), scenes `consent`, `banner-error`, `sidebar-streaming` (l. 1642–1643, 1652).

**What is wrong.** `LiveDependencies.make` builds `ReviewEngine(providers: registry, …)`. The runner then replaces `deps.providers` with `ProviderRegistry(TestSupport.snapshotProviders)`. The engine still holds the first registry, so the "non-local mock for the consent scene" exists for the model and not for the engine: `engine.plan` has no descriptor to plan with and a review would fail with "provider not found". `RefereeUI` cannot rebuild the engine because it does not depend on `ReviewEngine` or `Composition`. Separately, `banner-error` needs a mock that fails mid-stream and `sidebar-streaming` needs one that stalls after N chunks. `MockResponse` has a uniform `delayPerChunk` and no stall, `SnapshotScene` has no provider or script field, and `snapshotProviders` is described as one local mock, one non-local mock and static providers. A scene's `prepare` closure only sees the model, the reader and the settings model.

The acceptance commands check "exit 0, non-blank", so WP10 and WP11 can pass with scenes that do not show the required state.

**Change.** Have `LiveDependencies.make` build the snapshot registry and `FakeResolver` itself when `REFEREE_SNAPSHOT=1` (Composition already depends on TestSupport). Define four mock ids in `snapshotProviders` and name them in the plan: `mock` (local), `mock-remote` (non-local), `mock-fail` (throws after N chunks), `mock-stall` (stops after N chunks until cancelled); enable all four in the temporary `settings.json`. Scenes select one with `model.setActiveProvider`. Add `stallAfterChunks: Int?` to `MockResponse`.

#### M3. The Reader–Shell seam is not specified, and the two descriptions of `ReaderController` disagree

**Where.** §7.4 (l. 1234–1238, 1247) against §11.3 (l. 1828); menu (l. 1428, 1430); WP9 (l. 2089) against WP11 (l. 2121); `ReaderCommand` (l. 3151–3156); `reloadSettings` (l. 3207), `applyFirstRunDefaultsIfNeeded` (l. 3290).

**What is wrong.** WP9 and WP11 run in parallel in Wave 2 and each sees the other only as the Wave 0 placeholder.

- §7.4 gives `ReaderController` a public `pdfView` and `attach()`. §11.3, "the fixed public surface" that Wave 0 creates "exactly", gives it only `init(model:)`. If Wave 0 follows §11.3, WP11 cannot call `attach()` or reach `pdfView`; if WP9 relies on the shell calling `attach()`, the merged app opens a window with no PDF. The word `attach()` occurs once in the plan.
- The reader "observes" `.find(query)`, but `readerCommand` is `private(set)` and no model method issues it. The Edit menu's Find, Find Next and Find Previous and the View menu's zoom items belong to WP11; the find bar and the `PDFView` belong to WP9. There is no route between them.
- WP9 builds a "banner slot" in `ReaderPane`; WP11 builds the "banner" in `ReviewWindowView`; §9.2 puts it in an overlay on the window and §9.9 at the top of the PDF column. Two banners or none.
- `SettingsModel.update` posts a notification; `ReviewSessionModel.reloadSettings` is public. Nobody is told to connect them. The same holds for `applyFirstRunDefaultsIfNeeded` at launch.

**Change.** Make §11.3 the single source and add to it: `ReaderController.pdfView`, `attach()` (and who calls it: the snapshot runner and `ReviewWindowController`, right after creating the controller), `showFind()`, `findNext()`, `findPrevious()`, `zoom(_:)`. Or route these through the model with new `ReaderCommand` cases and model methods. Assign the banner and the consent card to the Shell overlay and delete "banner slot" from WP9. State that `WindowManager` observes `.refereeSettingsDidChange` and calls `reloadSettings` on every open model, and that `AppDelegate` calls `applyFirstRunDefaultsIfNeeded` once at launch. Add one integration scene, owned by WP13, that opens a real PDF in the real window and asserts the display document is loaded.

#### M4. The HTTP session's timeouts are specified where the session is not built

**Where.** §5.3 (l. 594) against `ProviderEnvironment.urlSession` (l. 3071), Composition (l. 1839) and WP0's reading list (l. 1847).

**What is wrong.** `timeoutIntervalForRequest = 600`, no cookies and no cache are stated in §5.3, which WP4 reads. The `URLSession` is created in `Composition`, which WP0 writes and which is frozen, and WP0 is not told to read §5. WP4 must use the injected session because its tests inject `StubURLProtocol.session()` through the same field. A default session has a 60-second idle timeout, and Ollama sends nothing while it evaluates the prompt.

**Evidence.** With the plan's request shape (`stream: true`, `num_ctx 16384`) and a seven-page part of the real sample, `phi4` sent its first byte after 95.5 s (6.5 s load, 89.0 s prompt evaluation; `ollama/ttfb.py`). The same request through `URLSession(configuration: .default)` failed after 61.0 s with `NSURLErrorDomain -1001 The request timed out` (`probes/Sources/timeoutprobe`). Under §5.7 that error is `.network`, so it is retried twice more with the same result: three minutes, then "Network error". Reasoning models on the hosted APIs can be silent for as long.

**Change.** Put the session configuration in WP0's task list (item for `Composition`), and also tell WP4 to set `URLRequest.timeoutInterval = 600` on every streaming request so the adapter does not depend on it.

#### M5. A `[V]` claim that an acceptance test enforces is false on the plan's own fixtures

**Where.** §7.2 (l. 1194: "The line list matches the newline-separated lines of the string one to one [V]"); WP2 acceptance, "raw consistency" (l. 1914: "line count equals the number of newline-separated lines").

**Evidence.** `pdfprobe lines` on the fixtures built from Appendix C: page 2 of `ay_nolinks`, `ay_round_nolinks` and `ay_links` gives one more `selectionsByLine()` entry than newline-separated lines (23 against 22, 20 against 19, 20 against 19), because the displayed equation becomes four line selections. On the real sample `dl1/numeric.pdf`, 10 of 15 pages disagree, by as much as 77 against 48.

The design itself survives: on every page tested each line selection had exactly one text range, ranges were monotone, and every `RawLine.text` equalled the substring at its range. Only the stated relation to newlines is wrong. It still matters beyond one test row: Wave 0 writes `RawExtractor` "in its simplest form" and freezes it, and an implementer who trusts the claim will pair newline-split text with line bounds by index, or assert the counts are equal. Either gives wrong geometry or a crash on every page with a displayed equation.

**Change.** Delete the newline clause from l. 1194 and l. 1914. Keep "one range per line, ranges increasing and non-overlapping, text equals substring". Add `numeric.pdf`-style content (a displayed fraction, a table) to the things WP2 must not choke on.

#### M6. On line-numbered manuscripts, a selection carries the margin numbers into the prompt and the anchor

**Where.** §7.4 (l. 1246), §6.9 (l. 1140: "quote = selected text, spans and rects from the selection"), §9.3 (own comments anchored to the selection), `SelectionInfoBuilder` (l. 1776).

**Evidence.** `pdfprobe drag` on `ay_nolinks.pdf` page 1, a simulated drag from the middle of one line to the middle of the next: the selection's string is `" As shown by Acemoglu et al. [2011],11\nnetwork structure determines wheth"`, and the first line's bounds are `x=-2.2 w=498.4`, the full page width. On page 3 a three-line drag returns `"…Working35\n36\npaper.\n37\nLee, J. (2021)…"`.

**What is wrong.** `SelectionInfoBuilder` sees only the `PDFSelection` and the `PDFDocument`; it has no `PaperText` and cannot know which characters are margin numbers. As specified, "Ask AI" sends the model a passage with line numbers fused into words, an own comment stores that as its quote, and its highlight is a page-wide bar. This is the journal-system case the plan names as its main target (U12).

**Change.** In `ReviewSessionModel.readerSelectionChanged`, normalise every selection through `paper.text`: clip each span to the `contentRange` of the `.body` lines it touches, drop `.marginNumberOnly`, `.watermark` and header lines, rebuild `text` from the clipped spans, and take `rects` from `PaperService.rects(for:in:)`. State this in WP8 and add a test on `ay_nolinks` with the two selections above.

#### M7. Author–year citation detection, read literally, misses common forms and can cut the reference list

**Where.** §8.4 steps 3–4 (l. 1307–1308), §8.2 steps 1–2 (l. 1279–1280), §8.7 validation (l. 1355); WP3 acceptance (l. 1934–1936).

**What is wrong.**

- *Sentence-initial words.* Step 3 accepts "surname words (upper-case initial…)" walking left from the year and step 4 requires that "the left-most accepted surname must be in the dictionary". In "In Smith (2019)", "Following Smith (2019)", "See Smith (2019)" (the lead-in list has only lower-case `see`) and "The Banerjee (1992) model", the left-most accepted word is "In", "Following", "See" or "The". None is in the dictionary, so the mention is skipped. These are among the most common ways an economics paper cites. The fixture has none of them: every citation in Appendix C follows a lower-case word.
- *End of the reference list.* Rule 2(a) ends the list at a line of at most 40 characters that matches `^[A-Z](\.\d+)?\s+[A-Z]`. I ran the rule: `"A Course in Game Theory. MIT Press."`, `"J Econ Theory 144(2):445–471"` and `"D Fudenberg, J Tirole (1991) Game Theory"` all end the list, as do entry lines that begin "Tables.", "Figures of", "Supplementary material" or "Appendix to:". Every entry after that point disappears, and step 4 then skips every citation of it. Springer's reference style (International Journal of Game Theory, Economic Theory, Social Choice and Welfare) produces such lines routinely.
- *Heading.* The heading regex requires the line to be exactly "References" and so on. If margin-number stripping leaves a digit on that line, the index is empty and no citation is clickable.
- *Year window.* A Crossref or Semantic Scholar candidate is rejected unless its year is within one of the entry's. In economics the gap between the working paper an author cites and the published version is often three to five years, so correct matches will be thrown away as "No match found".

**Change.** Step 4: scan the accepted tokens for the left-most one *that is in the dictionary* and whose following tokens up to the year are all surname or connector tokens; discard what lies to its left. Rule 2(a): require the candidate heading to be followed by at least three lines that are not entry-like, or to be set in a taller font than the list (bounds are available), and drop the bare-capital-letter pattern unless it is in sequence (A, then B). Heading: allow trailing digits. Validation: when the first author matches and at least 85% of title words match, accept any year and show "year differs". Add to `ay_*` fixtures: "In Banerjee (1992)", "The Avery and Zemsky (1998) model", "See Lee (2021)", a book entry that wraps to "A Course in Game Theory. MIT Press.", and an entry in Springer style.

#### M8. The single Keychain item can silently lose every stored key after a rebuild

**Where.** §5.8 (l. 865), R9 (l. 2232), `SecretStoring` (l. 2859–2862).

**Evidence.** `kcprobe`, with user interaction disabled so nothing could prompt. Binary A (ad-hoc signed; its designated requirement is its cdhash) adds the item and reads it: status 0. After a one-line source change and rebuild, binary B: attributes-only lookup 0; read **−25293**; `SecItemUpdate` **0**. After B's update, A's read also returns −25293.

**What is wrong.** The plan's assumption that a rebuilt binary needs the user's approval to read is confirmed. What the plan does not anticipate is that a rebuilt binary can *write* without approval. The store keeps six secrets in one JSON blob, so every `setSecret` is read–modify–write. If the read fails (the user clicks Deny, or dismisses the dialog) and the implementation treats failure as "empty", the write succeeds and the blob now holds one key. The other five are gone.

**Change.** State in §5.8 and in the `SecretStoring` doc comment: `setSecret` must throw unless the existing item was read successfully or `SecItemCopyMatching` returned `errSecItemNotFound`. Add a WP4 test with a fake keychain backend that fails reads. Tell the user in the README that `REFEREE_SIGN_IDENTITY` with a self-signed certificate removes the prompt, since the requirement is then the certificate and not the cdhash.

#### M9. Local-model defaults make reviews slower and worse than this machine allows

**Where.** §5.4.5 (l. 676–679), §6.4 (l. 955–977), §6.2 (l. 930), §6.6 (l. 1057).

**Evidence** (plan's default prompt from Appendix B, `temperature 0.2`):

| Run | Prompt tokens | Output tokens | Thinking | Wall | Format | Anchors |
| --- | --- | --- | --- | --- | --- | --- |
| `gemma4:e4b`, fixture, one pass, 16k | 2,205 | 2,432 | 4,076 chars | 120 s | 9 blocks, `@@DONE` | 8 exact, 1 fuzzy |
| `phi4`, fixture, one pass, 16k | 2,118 | 625 | none | 101 s | 5 blocks, `@@DONE` | 4 exact, 1 not found |
| `gemma:2b`, fixture, 8k | 2,201 | 259 | none | 18 s | ignored format | fallback comment |
| `gemma4:e4b`, real paper pp. 1–7, `TASK_PART`, 16k | 6,543 | 3,107 | 5,547 chars | 155 s | 6 blocks, `@@NOTES`, `@@DONE` | 6 exact |
| `phi4`, real paper pp. 1–7, `TASK_PART`, 16k | 6,347 | 1,211 | none | 245 s | 7 blocks, `@@NOTES`, `@@DONE` | 6 exact, 1 fuzzy |
| `gemma4:e4b`, real paper, all 15 pages, one pass, 32k | 12,290 | 4,096 (cut: `length`) | 6,061 chars | 231 s | 16 blocks, no `@@DONE` | 16 exact |

**What is wrong.**

- `ollamaDefaultContextCap = 16_384` (l. 960). The plan itself records that Ollama's own default on 24–48 GiB is 32k (l. 683). With the plan's own arithmetic the input budget is 8,264 tokens at 16k and 24,648 at 32k, so the cap triples the number of parts for no reason on this machine, and reading in parts is exactly what the skill file forbids ("Read the paper fully before writing anything").
- `charsPerToken = 3.0` (l. 955). Measured: 4.3 to 4.5 characters per token on these prompts. Parts are a third smaller than they need to be.
- `gemma4` thinks by default, and thinking tokens count against `num_predict`, which the plan sets to `min(4096, context/4)` (l. 969, 977). In the part-1 run roughly 1,400 of 3,107 output tokens were thinking. In the 32k single pass the answer was cut at exactly 4,096 tokens with no `@@DONE`. The request body has no `think` field. Every such cut costs a continuation that re-sends and re-evaluates the paper.
- One pass over the whole 15-page paper at 32k took 231 s. Two parts at 16k took 155 s each before the whole-paper pass. The larger window is both faster and what the skill file asks for.
- Six of the sixteen comments in the single pass were of kind `strength` ("Clear architectural overview"), each a generic compliment, despite "use it sparingly". The skill file forbids exactly this.
- The `[[page N]]` marker falls in mid-sentence. `gemma4:e4b` produced the comment "Incomplete sentence structure … ends abruptly with 'verify the differentiability of'" for a sentence that simply continues on the next page. The stated reason for not reflowing (l. 930: "untouched lines keep quotes verbatim") does not hold, because the matcher folds away whitespace and hyphens anyway.
- The duplicate rule (l. 1057) needs 60% title-word overlap. `gemma4:e4b` wrote two comments on the same quoted equation under different titles ("Undefined variables in the core equation", "Missing definition of the likelihood ratio"); both survive.
- Both models wrote `suggestion: N/A` or `No suggestion.`; rule 5 (l. 1029) keeps that as a suggestion.

**Change.** Default cap 32,768 when physical memory is at least 24 GiB, else 16,384. `charsPerToken = 3.5`. Send `"think": false` to Ollama by default (through `DefaultSettings`' `extraBodyJSON`, which needs no contract change) and document how to turn it back on. Render reflowed paragraphs for the model, de-hyphenated, with the page marker moved to the next sentence boundary; keep the line-based text for matching. Treat two comments whose anchors overlap by 80% and whose kinds match as duplicates regardless of title, and show the second collapsed with "similar to …" instead of dropping it. Drop suggestions that fold to `na`, `none`, `nosuggestion`. Cap `strength` comments at two per run in `FORMAT_REVIEW` ("at most two, and only if you can say what is unusual about it"), or leave the kind out of the default format and let the user add it.

#### M10. The subscription routes are text-only, so mathematics and tables reach the model garbled

**Where.** §5.2 roster (l. 560–563, "Native PDF: no" for every CLI), §6.2 (l. 911).

**What is wrong.** The plan says PDF mode "is preferred … because referee work depends on tables and mathematics" and then gives it only to API-key providers. A user on a Claude or ChatGPT subscription, which is the route this user is most likely to use, gets PDFKit's text. On the fixture, the posterior-belief fraction arrives as four lines: `µi =`, `πf(si |H)`, `πf(si |H) + (1−π)f(si |L).`, `(1)`. A proof-heavy theory paper is the user's daily material, and the skill file's "check every step" cannot be done on that input.

**Change.** Investigate before Wave 1, with one consented prompt on a public PDF: (a) `claude -p --input-format stream-json` with a user message that contains a base64 `document` block (the CLI reference documents the flag; the docs do not say whether document blocks are accepted, so this needs a test); or (b) copy the PDF into the empty working directory as `manuscript.pdf` and allow exactly one tool, `--tools "Read" --restricted`, which confines file tools to the working directory and whose Read tool returns a PDF as a document block. If either works, set `supportsNativePDF = true` for `claude-cli`. If neither does, say plainly in the destination indicator that a subscription review is text-only.

#### M11. Wave 0 is too large to freeze unreviewed, and there is no gate at which a wrong contract gets fixed

**Where.** WP0 (l. 1845–1873), §11.1 (l. 1725–1727, 1737), §11.5 (l. 2159–2166), WP8 (l. 2042–2083).

**What is wrong.**

- WP0 writes all of `RefereeCore` plus memberwise initialisers for about forty-five structs, default settings and prompts, every fake in `TestSupport`, real raw extraction, `Composition`, stubs for nine targets with every A.9 member, the complete snapshot runner, placeholder views, `AppMain`, seven scripts and a Makefile, six fixture PDFs with raw dumps, seven model-output fixtures (four of which it must author), a sample session in specific states, and twelve test targets. My estimate is 4,500 to 5,500 lines. All of it is frozen afterwards, including the fakes eight other agents test against and the snapshot runner three agents depend on. Nothing reviews it before the freeze. This review found M1 to M4 in exactly that material.
- An agent that finds a contract wrong mid-wave may only work around it and write a note (l. 1737). §11.5 applies "agreed contract changes" in Wave 3. §11.1 has the integrator merge and test between waves but does not have it read the notes. Wave 2 would then be built on Wave 1's workarounds and changed again in Wave 3.
- WP8 is the hub every UI package depends on and it is the largest Wave 1 package: about fifty model members, consent, lanes, autosave, citations, the report, two stores, paths, migration, and the exporter, with twenty test groups.
- Several acceptance gates can pass while the work is useless: the four CLI adapters are tested only against fake CLIs the same agent writes from the same text (no real CLI ever receives a prompt before the user tries one); `.pdf` export passes on `%PDF` (see m1); snapshot scenes pass on "non-blank"; WP3 passes on a fixture with no sentence-initial citation.
- Agents can verify how the UI looks and nothing about how it behaves. Snapshots are faithful, overlays included. But no acceptance step sends a click, a key or a drag: the citation click, the J/K/A/R keys and the selection bar after a real selection are checked only as pictures that a `prepare` closure staged through the model.

**Change.** Split WP0 as l. 1861 already allows, and add a short review step by a second agent before the freeze: compile one trivial consumer of each protocol, run the placeholder snapshot, read `TestSupport`. Add an explicit gate after Wave 1: merge, read every `contract-notes` file, patch `RefereeCore` and the frozen paths, run everything, and only then cut Wave 2 worktrees. Split WP8 into Persistence plus `ReportExporter` (small) and the two models. With the user's consent, let the integrator send one trivial prompt ("Reply with OK") through each installed CLI; it costs nothing measurable and is the only real test those adapters will get. Add two interaction checks to the snapshot mode: hit-test a citation rectangle and call `mouseDown(with:)` on the view found there with a synthetic event, then assert `citationLookup` changed and the page did not (my probe shows this drives `PDFView` without activating the app); and feed a key sequence through `TriageKeymap` into the model and assert the resulting statuses.

A simpler decomposition is available at the cost of one more wave: build a thin vertical slice first (PaperText, PDFBridge, ReviewEngine, the Ollama adapter alone, a minimal model and window) and run `e2e-ollama.sh` on it before fanning out to the other providers, citations, the report and settings. That finds contract errors while two or three packages exist instead of twelve.

---

### Minor

**m1. PDF export.** §6.10 (l. 1173), §11.3 (l. 1818–1821), WP8 test (l. 2081). `dataWithPDF(inside:)` returned one page of 468 × 2,607 pt for a four-section report; `NSPrintOperation` with `jobDisposition = .save` produced five Letter pages in 0.33 s with no UI and no `NSApplication`. Off the main thread the same code aborts with `NSWindow should only be instantiated on the main thread!`, and Swift Testing does not run tests on the main thread unless told to. Change: always use the print operation; mark `ReportExporter.data` `@MainActor`; assert page count and page size in the test. `.docx` export worked on both threads and round-tripped with bold headings.

**m2. `referee-cli` needs things `AppDependencies` does not have.** `dump-raw` needs `RawExtractor` and PDFKit; `extract` needs a `PaperRendering`. The target depends only on `RefereeCore` and `Composition` (l. 215). An undeclared transitive `import PDFBridge` does compile on this toolchain (probe `review/transitive`), so this works by accident. Change: add `PDFBridge` and `PaperText` to the target's dependencies, or add `renderer` to `AppDependencies`.

**m3. `streamingReplyText` is one slot for two lanes.** A.9 (l. 3174) and WP8 (l. 2058) stream discussion, chat and report text into the same property; §2.3 (l. 156) lets a report and a discussion run at once. Change: add `streamingReportText`.

**m4. Three orderings for `visibleComments`.** A.9 (l. 3193) says "first span location; unanchored first"; §9.3 (l. 1466) says unanchored last; §6.7 (l. 1100–1102) says reading order of the first span's line, unanchored last. Change: one sentence, in A.9.

**m5. `CitationLookup` has no case for an entry opened from the References tab.** `lookUpEntry(entryID:)` (l. 3251) has no mention id to put in `.resolved(mentionID:…)` and the card has nothing to anchor to. Change: `enum Target { case mention(Int), entry(Int) }`.

**m6. Tests that cannot be written as specified.** (a) WP6 "privacy … with a spy on `Log`" (l. 2018): `Log` is a frozen enum with a private logger and no hook. Add `Log.testSink`. (b) The Keychain test: §5.8 (l. 866) says all tests set `REFEREE_NO_KEYCHAIN`, WP4 (l. 1965) says the test is skipped when it is set; so it never runs. (c) §4.6 (l. 535) greps `Sources/` for `write(to:`; every store, cache and exporter calls `Data.write(to:)`. WP12 (l. 2147) adds "applied to a PDF document", which grep cannot tell. Search for `PDFDocument` in the same statement, or drop the test in favour of the byte-identity check. (d) The key-leak regex `sk-[A-Za-z0-9_-]{20,}` (l. 2176) matches ordinary hyphenated text such as `task-specific-identification-threshold`; anchor it with `\b` and scan tracked files only, not `.build/`.

**m7. Sample session and fixture hash.** `Fixtures/sessions/sample.json` must sit under `sessions/<sha256>/` (l. 1629), but a rebuilt fixture PDF has a new hash: my rebuild of `ay_nolinks.pdf` is 176,112 bytes against 176,097 in §4.3. Change: the runner computes the hash of the fixture PDF at run time and rewrites `document.sha256` when it copies the session.

**m8. Parser tolerance.** The `FIELD` pattern (l. 1020) does not allow a list marker, so `- kind: major` or `* **Quote:** …` becomes a continuation of the previous field. Small models that drift into Markdown do this. Allow an optional leading `[-*•]\s+` or `\d+[.)]\s+`.

**m9. Folding.** §6.7 (l. 1079) uses canonical decomposition plus a hand list of ligatures. Compatibility decomposition (NFKD) covers the ligatures and also superscript digits, full-width forms and mathematical alphanumerics (U+1D400 block), which PDFs built from Word equations commonly carry for italic variables (not tested here; the LaTeX fixtures do not produce them).

**m10. Cursor over citations.** §7.4 (l. 1244) sets the cursor in `mouseMoved`. Mouse events land on an internal `PDFPageView` (hit-test chain: `PDFPageView < PDFDocumentView < PDFClipView < PDFScrollView < PDFView`), and PDFKit chooses its own cursor from `areaOfInterest(for:)`, which returned the link bit over the citation in my probe. A cursor set in `mouseMoved` is likely to be overridden (I did not probe the cursor itself). Override `areaOfInterest(for:)` and return `.linkArea` over a mention rectangle.

**m11. Overlay coordinates.** `PDFView.isFlipped` is false; `pdfView.convert(_:from:)` gives bottom-left coordinates and SwiftUI overlays need the y axis flipped. One sentence in §7.4 saves WP9 a snapshot cycle.

**m12. Snapshot windows can stay out of sight.** A window moved to (−6000, −6000) is clamped by AppKit so that only a 40 × 94 pt corner stays on screen, and it still captures identically (same overlay pixel counts). Wave 2 will otherwise flash 1280 × 800 windows over the user's work for several minutes. Add `setFrameOrigin` after `orderFrontRegardless` in §10.1 step 2.

**m13. Toolbar label.** `Button("Review", systemImage:)` in a toolbar shows the icon only on macOS 26; §9.2 wants the word. Use `.labelStyle(.titleAndIcon)`.

**m14. xAI adapter.** §5.4.3 uses the Responses endpoint, whose stream schema xAI does not document, and must send `store: false`. xAI's Chat Completions endpoint has a documented stream and stores nothing. Use it for xAI and delete assumption R12.

**m15. Lookup chain value.** Semantic Scholar without a key answered HTTP 429 on the first request from this machine. Step 4 (l. 1349) will mostly add a retry delay. See section 4.

**m16. Resolver cache outlives the review.** `resolver-cache.json` keeps the reference strings of a confidential manuscript for 180 days, and "Delete Review Data…" removes only `sessions/<sha256>/` (l. 460). Record which session used each cache entry and delete with it, or clear the cache with the review.

**m17. Small contract tidying.** `SelectionInfoBuilder.make(from:in:)` (l. 1776) is `make(from:document:)` in §7.4 (l. 1246). `ReviewPhase.anchoring` (l. 2883) is never emitted. `LogValue.id(String)` accepts any string, so "cannot carry free text" (l. 2181) is a convention, not a guarantee. `scripts/snapshots.sh --scene x` without an output directory takes `--scene` as the directory. The Gemini adapter maps every `interaction.completed` to `.endOfTurn` (l. 668), so a truncated answer is caught only by the missing `@@DONE`. The §5.5 table has no default row for an unknown Gemini error code, and the sample error in Appendix D.3 (`gateway_timeout`) is such a code; say "anything else → `.server`".

---

## 3. External claims checked

"Local copy" means the page the plan's author saved under `scratchpad/docs_dl/`; "live" means fetched again by me today.

| # | Claim in the plan | Outcome | Source |
| --- | --- | --- | --- |
| 1 | Gemini CLI stopped serving free and Google AI Pro/Ultra accounts on 2026-06-18; they moved to Antigravity CLI (l. 23) | Confirmed, live | <https://github.com/google-gemini/gemini-cli> ; <https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli/> |
| 2 | `agy` flags `--input-format/--output-format stream-json`, `--disable-slash-commands`, `--sandbox`, `--print-timeout`, `--model`; stdin line `{"event":"user","message":{"content":…}}`; events `init`, `step_update`, `result` (l. 824–830) | Confirmed, live | <https://antigravity.google/docs/cli/headless> ; <https://antigravity.google/docs/cli/reference> |
| 3 | `agy` print mode defaults to `auto` since v1.5.7; unapprovable actions are soft-denied (l. 831) | Confirmed, live. The plan's conclusion that this is safe is not established (B1) | <https://antigravity.google/docs/cli/headless> ; <https://antigravity.google/docs/cli/modes> |
| 4 | `agy --sandbox` contains commands | Partly. Docs: unmounted paths invisible, network off by default, `~/.ssh` and `.env` blocked. Untestable here | <https://antigravity.google/docs/sandbox?tab=cli> |
| 5 | Grok Build is an official CLI with headless `-p`, `--output-format plain`, `--cwd`, `--no-auto-update` (l. 838) | Confirmed, live | <https://docs.x.ai/build/overview> ; <https://docs.x.ai/build/cli/headless-scripting> |
| 6 | Grok flags `--system-prompt-override`, `--max-turns`, `--disable-web-search`, `--no-subagents`, `--no-memory`, `--no-plan`, `grok models` | Confirmed, live | <https://docs.x.ai/build/cli/reference> |
| 7 | Grok invocation leaves the agent without tools (§12.5) | Wrong. `--tools` / `--disallowed-tools` exist and are not used; default headless approval behaviour is undocumented | same |
| 8 | Whether headless Grok draws on a subscription | Unverifiable (the plan says so) | <https://docs.x.ai/build/overview> |
| 9 | Claude Code flags `--safe-mode`, `--tools ""`, `--disallowedTools`, `--strict-mcp-config`, `--disable-slash-commands`, `--no-session-persistence`, `--permission-prompts none`, `--include-partial-messages` (l. 790–795) | Confirmed by `claude --help` 2.1.330 on this machine | local binary |
| 10 | `--system-prompt-file` | Confirmed in the CLI reference (not in `--help`) | local copy `cc_cli_ref.md` |
| 11 | `--bare` never reads the subscription login; will become the default for `-p` | Confirmed | `claude --help`; local copy `cc_headless.md` |
| 12 | Claude stdin capped at 10 MB; SIGTERM exits 143; `claude auth status` JSON, exit 0/1 | Confirmed. `auth status` field names confirmed by running it | local copy `cc_headless.md`, `cc_cli_ref.md`; local binary |
| 13 | Anthropic terms on OAuth and third-party apps, as quoted (l. 851) | Confirmed, wording matches | local copy `cc_legal.md` |
| 14 | `anthropic-version: 2026-10-21`; `temperature`, `top_p`, `top_k` rejected with 400 on every model (l. 605, 617) | Confirmed, live | <https://platform.claude.com/docs/en/api/versioning> ; <https://platform.claude.com/docs/en/api/migration-2026-10-21> |
| 15 | `x-api-key` header still accepted on 2026-10-21 | Confirmed, live ("The Claude API accepts a key in either header") | migration page above |
| 16 | Anthropic PDF limits 128 MB, 600 pages, 100 under a 1M window; model list fields `max_input_tokens`, `max_tokens`, `capabilities.pdf_input` (l. 619–620) | Confirmed | local copies `an_pdf.md`, `an_models_list.md` |
| 17 | `pdfTokensPerPage` Anthropic 4,500 (l. 961) | Conservative. Docs say 1,500–3,000 per page for text, plus image tokens | `an_pdf.md` |
| 18 | OpenAI Responses `input_file` with `file_data` data URL and `filename`; 50 MB per file and per request; text and page images both sent (l. 631–642) | Confirmed, live | <https://developers.openai.com/api/docs/guides/file-inputs> |
| 19 | OpenAI `store` defaults to true, kept at least 30 days; stream events `response.output_text.delta`, `.completed`, `.incomplete`, `.failed`; model list has no context window | Confirmed | local copies `oa_ref_create.md`, `oa_ref_stream_events.md`, `oa_ref_models_list.md` |
| 20 | Gemini Interactions API is GA and recommended; `generateContent` is legacy (l. 25) | Confirmed, live ("As of June 2026, it is Generally Available") | <https://aistudio.google.com/docs/interactions-overview> |
| 21 | `POST …/v1/interactions`, `x-goog-api-key`, `input` item `{type: document, data, mime_type}`, `system_instruction`, `store`, `generation_config.max_output_tokens` (l. 658–667) | Confirmed, live. Note the overview's REST example still shows `v1beta` | <https://aistudio.google.com/api-reference/interactions-api/create-interaction?api-version=v1> |
| 22 | Gemini stream: `step.delta` with `delta.type == "text"`, `interaction.completed` with `interaction.usage.total_*_tokens`, final `data: [DONE]`; skip unknown events (l. 668) | Confirmed, live | <https://aistudio.google.com/docs/streaming> |
| 23 | Gemini stores interactions 55 days (paid) / 1 day (free) unless `store=false` | Confirmed, live | interactions-overview page |
| 24 | xAI Responses stores 30 days by default; files only by URL or upload; `/v1/models` has `context_length`; stream is data-only SSE ending `[DONE]` (l. 650–653) | Confirmed | local copies `xai_comparison.md`, `xai_files_chat.md`, `xai_models_ref.md`, `xai_responses_ref.md` |
| 25 | xAI Responses stream event names match OpenAI's | Unverifiable; the only documented stream is Chat Completions (m14) | local copy `xai_streaming.md` |
| 26 | Codex flags `--json`, `--skip-git-repo-check`, `--ephemeral`, `--ignore-user-config`, `--ignore-rules`, `--sandbox read-only`, `-C`, `-c` (l. 808–810) | Confirmed by `codex exec --help` 0.167.0-alpha.3.2 | local binary in ChatGPT.app |
| 27 | `features.shell_tool=false` removes the shell | Confirmed by `codex debug prompt-input` (B1) | `review/out/cx_default.json` against `cx_plan.json` |
| 28 | Codex JSONL events; `codex login status` prints "Logged in using ChatGPT"; `codex debug models` JSON | Confirmed (events from docs and source; the two commands by running them) | local copies `cx_noninteractive.md`, `cx_gh_exec_events.rs`; local binary |
| 29 | `/opt/homebrew/bin/codex --version` hangs (l. 28) | No longer true: it now fails at once with `ENOENT` for the vendor binary. Validation with a timeout is still right | run today |
| 30 | Ollama `/api/tags` has `details.context_length` and `capabilities`; default context by memory (l. 683, 686) | Confirmed on 0.40.17 and in docs | local server; local copy `ol_ctx.md` |
| 31 | Ollama thinking | The plan ignores `message.thinking` but sends no `think` field; docs: default applies when unset (M9) | local copy `ol_thinking.md` |
| 32 | OpenAlex DOI lookup is free without key or email (l. 1347) | Confirmed, live: `x-ratelimit-cost-usd: 0` | request today |
| 33 | OpenAlex search costs credits, about 100 a day without a key (l. 1350) | Confirmed, live: `cost-usd 0.001` of a `0.1` daily budget shared per IP | request today |
| 34 | Crossref public pool 1 request/s, concurrency 1 (l. 1361) | Confirmed, live | response headers today |
| 35 | Semantic Scholar keyless calls are often throttled (l. 1363) | Confirmed, live: HTTP 429 on the first request | request today |
| 36 | Unpaywall now runs on OpenAlex | Not re-checked; nothing depends on it once OpenAlex is used | — |
| 37 | Error-mapping table §5.5: Anthropic status and `error.type` pairs; Gemini Interactions error codes; OpenAI quota and overload codes | Confirmed for every Anthropic row and every Gemini code listed. Two gaps: the table has no default row for an unknown Gemini code, and Appendix D.3's sample error uses `gateway_timeout`, which the table does not list | local copies `an_errors.md`, `an_ratelimits.md`, `gem_api_errors.md`, `oa_error_codes.md` |

---

## 4. Recommended cuts and deferrals

| Cut or defer | Why | What it saves |
| --- | --- | --- |
| **Defer the Antigravity and Grok Build adapters** until the user has installed the CLI and agreed to one test prompt. Keep the two provider ids and Settings rows, showing "not installed" with the install command. | Neither can be run here; both leave tools on as specified (B1); Grok's plan coverage is unknown. The API-key routes for both vendors are in v1. | About 40% of WP5, two fake CLIs, the 240 KB argument-length branch in planning, and the only two code paths nobody can verify. |
| **Defer the two-column reading-order repair** (§7.2 step 2) and replace the two-column fixtures with a single-column numeric one. | The user's field is single-column. It is the most intricate heuristic in WP1 and was verified only by a Python prototype on two pages. | A third of WP1's algorithmic work and three acceptance rows. |
| **Cut `.pdf` export; keep `.md`, `.txt`, copy, and `.docx`.** | Not asked for; needs the main thread and a print operation (m1). `.docx` is a few lines and works. | The off-screen text view, pagination, a crash-prone test. |
| **Reduce reference lookup to: printed arXiv id, printed DOI → OpenAlex, Crossref bibliographic → OpenAlex, then "Search Scholar".** Drop Semantic Scholar, OpenAlex search and arXiv title search. | Semantic Scholar is throttled without a key; OpenAlex search is budgeted; arXiv search needs an XML parser for a rare case. | About 40% of WP7, two optional keys in Settings, three token buckets. |
| **Trim `referee-cli`** to `dump-raw`, `extract`, `anchor`, `citations`, `plan`, `review`, `ask`, `providers`. | These are what agents use to verify. `resolve`, `report`, `lint`, `models` duplicate tests. | A quarter of WP12. |
| **Drop the "Quote in chat" stretch goal and viewer tab grouping** (§7.7). | Unrequested window management. | Small, but it is pure risk in WP9 and WP11. |
| **Keep the schema version check; drop the migration chain** (§4.4) until there is a version 2. | Nothing to migrate. | Small. |
| **Remove the `!--ignore-user-config` advice** (l. 816). | It re-enables the user's Codex plugins, including UI automation (B1). | A hole. |

Keep: the consent card and Local-only mode (the manuscripts are confidential), the linter (cheap and it enforces the user's own rubric), the JSON and prose fallbacks (`gemma:2b` needed them), `e2e-ollama.sh`.

---

## 5. What I could not check

- Any real request to Anthropic, OpenAI, Gemini or xAI, and any prompt through Claude Code or Codex. So: the actual runtime tool list of `claude -p --tools ""`; whether Codex's `exec` or `spawn_agent` tools are usable in `codex exec` under a read-only sandbox; whether `--ignore-user-config` also stops plugins recorded elsewhere under `~/.codex`; whether Claude's stream-json input accepts a `document` block (M10).
- Anything about `agy` and `grok` beyond their documentation: neither is installed.
- What the vendor CLIs write locally on their own account. `~/.codex` holds a `logs_2.sqlite` here; whether `--ephemeral` keeps prompt text out of it I do not know.
- A real Editorial Manager or ScholarOne PDF. Margin-number stripping, reference-list splitting and citation detection were examined on the plan's synthetic fixtures and one public arXiv paper only. I did not open any of the user's own files. Permission-restricted PDFs (owner password, copying disabled) are a common journal-system case I could not test.
- The plan's reading-order repair and margin-number detection as Swift code; they exist only as the author's Python prototypes, which I ran but did not re-derive.
- A real mouse click through the window server. The probe called `mouseDown(with:)` on the hit-tested view directly, which showed the internal `PDFPageView` forwards to the subclass; events sent with `window.sendEvent` to a non-key, non-active window were not delivered, and I did not activate the app to avoid taking focus.
- Keychain behaviour inside a signed `.app` bundle with a stable self-signed identity; I tested ad-hoc signed bare executables.
- "Open With" registration of the hand-made bundle, and behaviour under full Xcode.

---

## Appendix: probes

All under `/private/tmp/claude-502/-Users-morankoren/ff24cb6e-2520-4f35-a533-0955209fd44f/scratchpad/review/`.

| Path | What it is | Result |
| --- | --- | --- |
| `fixrepo/` | The plan's scripts and LaTeX sources extracted verbatim by line number; `scripts/make-fixtures.sh --pdf-only` | Six PDFs built in 3.5 s |
| `contracts/` | Appendix A.1–A.8 verbatim as `RefereeCore`; A.9 with stub bodies as `AppCore` | Both compile, Swift 5 mode, no warnings |
| `skelcopy/` | A copy of the author's stub package, whose manifest and scripts are byte-identical to §3.2 and §3.4; `build.sh`, `test.sh`, `bundle.sh` | Builds in 35 s; 12 tests pass; `build/Referee.app` is valid on disk |
| `transitive/` | Undeclared transitive import; the plan's `test.sh` on a two-test package | Import compiles; exits 0 / 1 / 3 for pass / failing or uncompilable test / zero tests |
| `probes/Sources/pdfprobe` | Line lists, bounds, simulated drag selection, link targets, `characterBounds` | M5, M6; link and bounds claims confirmed; `characterBounds(at:)` disagrees with `page.string` on 24 of 25 samples, as the plan says |
| `probes/Sources/uiprobe` | `NavigationSplitView` + `.inspector` + toolbar in an `NSHostingController` window; `PDFView` subclass; overlays; capture | Click on a link follows it by default (page 0 → 1) and does not when `mouseDown` returns without `super`; overlays and highlights are in the capture (`out/uiprobe.png`); off-screen capture works |
| `probes/Sources/exportprobe` | `.docx`, `dataWithPDF`, `NSPrintOperation`, on and off the main thread | m1 |
| `probes/Sources/kcprobe` | Keychain add / read / update across a rebuild, interaction disabled | M8. The probe item was deleted afterwards |
| `out/cx_default.json`, `cx_plan.json`, `cx_hard.json`, `codex_prompt_input.json` | `codex debug prompt-input` under three flag sets and with the user's config | B1 |
| `ollama/` | The plan's default prompt, rendered papers, raw outputs, `parse.py` (a literal implementation of §6.5 and the §6.7 fold), `ttfb.py` | M9, M4 |
| `probes/Sources/timeoutprobe` | A default `URLSession` against Ollama's first byte | M4 |
