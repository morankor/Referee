# Gate 1 — Merge, contract fixes, command line, end to end

Notes of the Gate 1 integrator (`plan.md` §11.4, Gate 1), on `main`. Read by the coordinator before Wave 2 starts, and by the three UI packages and Wave 3. Every plan change named here has a row in Appendix G.6.

## Merge

The nine Wave 1 branches were merged with `git merge --no-ff` in the order 1, 2, 3, 4, 5, 6, 7, 8a, 8b. No conflict; `scripts/build.sh` after each merge: exit 0, no warning. `scripts/test.sh` after the last: 776 tests, one failure, `LLMKitCancellationTests.cancellingTheConsumerCancelsTheRequestAndEndsTheStream`: a real race, not a flaky test. A consumer cancelled while it waits for bytes can see the line stream end without an error (`AsyncThrowingStream(unfolding:)` stops calling its closure once its consumer is cancelled), and the attempt reader took the end for a body that ended early (`.malformedResponse("stream ended early")`). Fixed in `HTTPStreamClient.LineReader` and in `AttemptReader`: a cancelled consumer gets `.cancelled`. The test then passed eight runs in a row with eight busy loops on the machine.

## The coordinator's decisions, as applied

| # | Decision | What was done |
| --- | --- | --- |
| 1 | `TextRange` clash | One `typealias TextRange = RefereeCore.TextRange` per module, in `TextRangeAlias.swift`: PaperText, PDFBridge, CitationKit, ReviewEngine, AppCore, TestSupport and the test targets AppCoreTests, CitationKitTests, PDFBridgeTests, PaperTextTests, PersistenceTests, RefereeCoreTests, ReviewEngineTests, IntegrationTests; `RefereeUI` and `RefereeUITests` have `Common/CommonTextRangeAlias.swift`, ready for Wave 2. Verified both ways: without the alias a type annotation fails with "ambiguous for type lookup", with it the module builds; no module that `@testable import`s another breaks. §3.7 states the convention (one alias per module, none added in Wave 2, `RefereeCore.TextRange` in public declarations). Qualified uses stay |
| 2 | Data files in test targets | One rule (§3.7): Swift literals, or data files in `Tests/<Target>Tests/Fixtures/` with `exclude: ["Fixtures"]` for exactly those targets, and no Swift file in that folder. `ReviewEngineTests` is excluded in `Package.swift` and §3.2 (identical) and its four files moved out of the hidden `.llm` folder; `EngineFixtureFiles.swift` moved out of `Fixtures/`. LLMKit's two literal files left its `Fixtures/` folder (`LLMKitAppendixD*.swift`). CLIProviders and ScholarKit keep literals. §3.3, §10.3, §11.2 and Appendix D say the same |
| 3 | Additions the UI needs | `answerConsent(granted:askAgain:)`; `ReplyFailure` with `replyFailure` and `retryFailedReply()` (a failed reply is no banner any more, and the banner's `retryLastFailedJob()` serves the review lane only); `revealConversationInPDF(_:)` (the workaround through `selectedCommentID` removed); `SettingsModel.secretErrors` (Keychain errors left `modelErrors`); `SessionStoring.recoveryNotice(sha256:)` with a default, written by the file store after a load from the backup and shown by the model as a warning banner; `LLMProvider.listModels(includeHidden:)` with a default, implemented by the HTTP providers, reached by `SettingsModel.refreshModels(of:includeHidden:)`; `ResolvedReference.failureReason`, one sentence per failure that names the service and never the reference. All additive with defaults, in code, A.3, A.5, A.7, A.9, §11.3 and §9.3–§9.9 |
| 4 | Engine seams | `ReviewEngine.init(…, debugDumpDirectory:)`; `LiveDependencies` passes `REFEREE_DEBUG_DUMP` of the environment it is given and the engine reads no environment. `reviseVoice(draft:findings:context:)`: the result keeps the draft's comment ids and versions, and its recommendation when the new text names none. `ReplyEvent.notice`, `ReportEvent.notice` for the silent text fallback; the model shows them as info banners. Checked in the model: drafts no comment replaced are discarded at the end of every run (a test for a completed run added); a stream that ends without `.finished` was recorded as **failed** ("The run ended before it finished."), now as **cancelled** without a banner; `unload` was **not** always called once per `load`: a window closed while its paper was loading never unloaded it (fixed, tested with a slow counting service); citation rectangles are filled only where `rects` is empty (correct); a session whose file has a newer schema is never autosaved (correct) |
| 5 | CLI providers | `CLAUDE_CODE_OAUTH_TOKEN` is copied for `claude` only (`passedThroughNames` of its adapter, in every process run for it); `USER` is always set (app's `USER`, else `LOGNAME`, else the account name); tests for both. `REFEREE_CLI_EXPERIMENT` in §10.6; §5.6.6 names `wp5-cliproviders.md` and the outcome. `SnapshotSupport`'s rows now carry the experiment's outcome (claude-cli PDF as a document block, codex-cli "sent as page images", `maxPromptBytes` 9,000,000 and 4,000,000), and `SnapshotRowsTests` compares all nine static rows with the real descriptors: equal. **Incident check:** read every test of `CLIProvidersTests`. Fake-based tests build their host through `FakeCLIHarness.host`, which sets `searchesDefaultLocations = false`; the resolver tests that search candidates and the PATH use the name `fakecli` and temporary candidates; `CLIRealBinaryTests` run real binaries on purpose, with `--version`, `--help`, `auth status`, `login status` and `debug prompt-input` only; smoke and experiment are gated. Added `CLIRealBinaryGuardTests`: every adapter's real spec, candidate list included, with a fake that fails its version check, must fail to resolve and must refuse to stream |
| 6 | Reading in parts | `Fixtures/tex/ay_long.tex`: 16 pages of invented prose, round-bracket author–year citations of the nine public references, a table and an equation; about 33,000 characters of rendered text. phi4 (16,384-token window, input budget about 28,900 characters) reads it in 2 parts and a whole-paper pass; gemma4:e4b (capped at 32,768) in one. Its abstract carries the sentence the e2e question quotes. Built by `make-fixtures.sh` (Appendix C, identical; the source is not printed), with its raw dump; the seven old PDFs rebuilt in a scratch copy dump byte-identically, so only the new PDF was committed. `e2e-ollama.sh` takes `[pdf]` and `--expect-parts`; the acceptance line is `scripts/e2e-ollama.sh phi4 Fixtures/pdf/ay_long.pdf --expect-parts` |
| 7 | Plan corrections | §6.7 and §7.2 describe how WP2 measures a range (between the outermost characters with plausible boxes), and the §4.3 sample rectangles are the measured ones (also in the three tests that hold copies of the sample). WP2's protected-PDF row names `num_links` and says why the others differ. `.empty`: stated in A.2 and §7.2. Journal PDFs go in `Fixtures/private/journal/` (§3.3, §3.6, Q7, WP1's row). A.3: the mention-text example follows §8.4 ("Smith and Jones (2019"), `rawText` follows §8.1. §2.1: ScholarKit imports CryptoKit. Dates: decided to keep whole seconds, stated in §3.7, §4.3 and on `SessionStoring`. Export errors: `ExportError` (A.9, §2.5) |
| 8 | Everything else | Below |

## Decisions beyond the coordinator's list

- **`SettingsModel.setSecret` is `async`** and reaches the Keychain off the main actor, as do the reads of `refreshAvailability` (WP4: the Keychain dialog blocks the calling thread; on the main actor the window would freeze).
- **Settings ▸ Privacy and References had no API that `RefereeUI` can reach**: `AppDependencies.dataDirectory` and `SettingsModel.dataDirectory`; `SessionStoring.deleteAllSessions()` (default: delete what the list shows; the file store also removes damaged and newer folders) and `SettingsModel.deleteAllReviewData()`; `ReferenceResolving.cachedPDFBytes()` and `clearPDFCache()` with defaults, and `SettingsModel.pdfCacheBytes`, `refreshPDFCacheSize()`, `clearPDFCache()` (WP7's note).
- **The References list's status icons and the card's "Search Google Scholar" had no source**: `ReviewSessionModel.references` (entry id → latest result) and `searchURL(for:)`. "Look up all references when a document opens" was not implemented; `open` now resolves every entry when it is on (off by default).
- `StoreError.corrupt` is thrown only when nothing could be read, so its message now says "…is damaged and has no usable backup."
- §9.6: the detected path of a CLI is not shown in v1 (no API reports it); the version is in the status detail.
- WP6's problem 7: §6.2 states the warning in automatic mode. WP5's problem 6: §5.6.3 describes the reader threads as built. WP3's problem 3: a merged mention's source is `.linkAnnotation`, stated in A.3 and §8.5. WP7's problem 3: `ResolutionSource`'s meaning stated, `.linkAnnotation` and `.openAlex` kept as reserved cases. WP2's "two things documented by this package only": on `PaperService` in A.2. WP8a's note that §6.10's defect did not reproduce: one sentence in §6.10.
- WP8a problem 3 (`report_sample.txt` has no emphasis): no change; WP8a's variant test covers emphasis.
- `referee-cli` finds `phi4:latest` for `phi4`, and without `--model` takes a provider's first listed model (a CLI keeps its default), as the Settings pane preselects.
- **arXiv's side stamp** ("arXiv:1409.0473v7 [cs.CL] 19 May 2016", printed rotated up the left margin of page 1) is boilerplate of §7.2 step 2. On all three fetched papers it was the title guess, because its rotated bounds are the tallest on the page; it is now `.watermark`, and a mention of arXiv inside the text is not (tests in `PaperTextArxivStampTests`).
- Gate 0's safety nets cover the new contract: `ContractConsumers` calls every new requirement, `CommonSurfaceCheck` and `SurfaceCheck` name every new member.
- Subprocesses in `IntegrationTests` run on threads of their own: reading a pipe inside a task blocked cooperative threads, and with every target's tests running at once the first version of the CLI tests hung the whole run.

## Contract problems

None open. Every problem of the nine Wave 1 notes is decided above and in Appendix G.6; what needs the coordinator is listed under "Left for the coordinator".

## Built at this gate

- `referee-cli` with the eight subcommands of §10.2, on `LiveDependencies.make` with a temporary `REFEREE_HOME` (removed at the end) and no Keychain unless `--use-keychain`. §10.2 describes the output as built.
- `scripts/e2e-ollama.sh [model] [pdf] [--expect-parts]` and `scripts/fetch-optional-fixtures.sh` (arXiv 1706.03762, 1409.0473, 1803.09015 into `Fixtures/private/`, one request every three seconds).
- `Tests/IntegrationTests`: every row of the Gate 1 table, plus the snapshot rows, the debug-dump folder and the data folder through `LiveDependencies`, and a check that no tracked file holds a home-directory path.

## Left for the coordinator

1. **Grok Build was not installed** (WP5: the npm package has neither a `repository` nor a `homepage` field). Gate 1 may reach only the local Ollama server and arxiv.org, so the question whether a maintainer address on `x.ai` is enough stays open; the adapter is as specified and keeps its experimental label.
2. Gate 0's item 4: the commits before WP0a's cleanup still contain the checkout's absolute path. The tree does not (an integration test now checks every tracked file).
3. WP1's weak spots on real files, not seen in any fixture or in the three arXiv papers: running heads that alternate between even and odd pages, a short last page whose chain has fewer than five numbers, a heading at the top of a page joined to a run from the page before, a ruler on both margins. Worth a look when the user supplies journal-system PDFs (Q7, now `Fixtures/private/journal/`).
4. `/opt/homebrew/bin/codex` is still broken (the resolver passes over it); the final README should tell the user to reinstall Codex (Wave 3).
5. Nothing was sent to a subscription CLI or a paid API at this gate. `referee-cli providers` and `CLIRealBinaryTests` run the installed `claude` and `codex` with `--version`, `--help`, `auth status` and `login status` only. The network was used for three arXiv downloads (9 s, one request every three seconds) and for the local Ollama server.

## Warnings for the Wave 2 briefs

- **`TextRange`**: `RefereeUI` and `RefereeUITests` already have their alias (`Common/CommonTextRangeAlias.swift`). Write `TextRange` bare inside them; add no alias (a second one is a redeclaration error); in a `public` declaration write `RefereeCore.TextRange`.
- **Test data in `RefereeUITests`**: Swift literals only. The manifest excludes `Fixtures` for `ReviewEngineTests` alone and is frozen for Wave 2; a data file in a test folder makes SwiftPM warn.
- **New members of Appendix A.9** (all additive): `replyFailure` / `retryFailedReply()` for the red line under a thread or a chat answer (a failed reply raises no banner; the banner's Retry is `retryLastFailedJob()`, review lane only); `revealConversationInPDF(_:)` for the Chat tab's passage (not `selectedCommentID`); `answerConsent(granted:askAgain:)`; `references[entry.id]` for the References list's icons; `searchURL(for:)` for Search Google Scholar; `ExportError` from `exportReport`. `SettingsModel`: `secretErrors`, `refreshModels(of:includeHidden:)` (the "Show all" toggle, OpenAI and Gemini), `dataDirectory`, `deleteAllReviewData()` (close every review window first), `pdfCacheBytes` with `refreshPDFCacheSize()` and `clearPDFCache()`. **`setSecret` is now `async`**: call it from a `Task`.
- **Notices** of replies and reports (the PDF was refused, the text went instead) arrive as info banners, like a review's. A run whose stream ends without `.finished` is recorded as cancelled, with no banner.
- **The citation card's failed state** reads `ResolvedReference.failureReason` ("Lookup failed: Crossref is busy; try again in a minute.").
- **Settings ▸ Providers**: no API reports a CLI's detected path; show the version from the status detail and the `executablePath` override field (§9.6 now says so).
- **The debug-dump tag** of the destination indicator (§10.5): `LiveDependencies` reads `REFEREE_DEBUG_DUMP` from the environment it is given; in the app that is the process environment, so the Shell can read `ProcessInfo.processInfo.environment["REFEREE_DEBUG_DUMP"]`.
- **Snapshot rows**: `claude-cli` and `codex-cli` now take the PDF (Codex "sent as page images", which the plan sentence shows in brackets), so a plan through them can send the file; `antigravity-cli`, `grok-cli` and `xai-api` stay text only.
- **Tests**: the integration tests run the built `referee-cli`, so `scripts/build.sh` must run before `scripts/test.sh`; every `scripts/test.sh` also sends one 16-token prompt to the smallest local Ollama model while Ollama runs (WP4's live test). A test that reads a pipe or waits for a process must not do it on a cooperative thread (see `Subprocess` in `Tests/IntegrationTests/IntegrationSupport.swift`): with every target's tests running at once it hangs the run.

## Other runs of step 4

- `scripts/fetch-optional-fixtures.sh`, once: arXiv 1706.03762, 1409.0473 and 1803.09015 (15, 15 and 45 pages) into `Fixtures/private/`, 9 s. `IntegrationRealPaperTests` then ran instead of skipping: each paper through load, matcher and citations in under 0.6 s; the entries found from the text equal those the links name, in order (62, 76 and 176 mentions; the numeric paper is the prototype's: 40 entries, 76 mentions). This run is what showed the arXiv stamp as the title guess.
- `REFEREE_TEST_KEYCHAIN=1 scripts/test.sh --filter LLMKitTests`, once: `theRealKeychainSetsGetsReplacesAndDeletes()` passed after 0.105 s; `test.sh: OK (108 tests)`; afterwards `security dump-keychain` lists no `local.referee.tests` item.

## End to end

Both through `scripts/e2e-ollama.sh` (review, then the question about the abstract), on this machine (M3, 24 GiB), Ollama 0.40.17. Final run, at commit `01d00ef`, after deleting `.build` and `build`:

| | `gemma4:e4b` | `phi4` (`phi4:latest`) |
| --- | --- | --- |
| Paper | `ay_round_nolinks.pdf`, 4 pages | `ay_long.pdf`, 16 pages |
| Plan | text, 1 request, about 900 input tokens | text, 2 parts and a whole-paper pass, 3 requests, about 10,800 input tokens; window 16,384 |
| Requests sent | 2 (one continuation: the first answer was cut at the 4,096-token reserve or inside a block) | 3 |
| Comments | 15: 4 major, 6 minor, 4 questions, 1 strength; 3 marked similar | 21: 6 major, 15 minor; 1 marked similar |
| Anchored | 15 of 15, all exact | 21 of 21, all exact |
| Review | 146.6 s | 591.4 s |
| Whole script (build, plan, review, question) | 161 s | 625 s |
| Answer to the question | non-empty; quotes the abstract and says the text neither confirms nor refutes it (a weak answer: the model's, not the pipeline's) | non-empty; quotes the abstract and the 2.4-point estimate against an 11.8 percent mean |

An earlier run of each, at commit `b04465b`: gemma4:e4b 8 comments, 8 anchored (exact), 1 request, 54.9 s; phi4 19 comments, 19 anchored (one `fuzzy 1.00`), 2 similar, 3 requests, 554.3 s. The difference between runs is the models' own variation; the pipeline completed every time. No model behaviour stopped either script.

## Acceptance

Final run, at commit `01d00ef` (this notes file was committed after it; no code changed), after `rm -rf .build build`:

| Command | Result | Final line |
| --- | --- | --- |
| `scripts/build.sh` | exit 0; no line with "warning" or "error" (one file is named `ExportError.swift`) | `Build complete! (43.65s)` |
| `scripts/test.sh` | exit 0; no warning; four tests skipped visibly (real Keychain, delivery experiment, live reference services, CLI smoke prompt); the real-papers test ran; the known CoreGraphics notice of WP2's damaged-PDF tests appears once | `test.sh: OK (827 tests)` |
| `"$(swift build --show-bin-path)"/referee-cli review Fixtures/pdf/ay_round_nolinks.pdf --provider mock` | exit 0 | `SUMMARY comments=6 anchored=6 pageOnly=0 unanchored=0 similar=0 requests=1 status=completed seconds=0.0` |
| `"$(swift build --show-bin-path)"/referee-cli extract Fixtures/pdf/s1_ruler.pdf --stats` | exit 0 | `ruler 1–60 on 4 pages` |
| `scripts/e2e-ollama.sh` | exit 0 | `e2e-ollama.sh: OK (gemma4:e4b on ay_round_nolinks.pdf: 15 comments, 15 anchored, 2 requests, 152 s)` |
| `scripts/e2e-ollama.sh phi4 Fixtures/pdf/ay_long.pdf --expect-parts` | exit 0 | `e2e-ollama.sh: OK (phi4 on ay_long.pdf: 21 comments, 21 anchored, 3 requests, 625 s)` |
| `scripts/snapshots.sh --scene placeholder` | exit 0; `{"scene":"placeholder",…,"width":2560,"height":1600,"nonBlank":true,"failures":[]}`; the PNG shows the three columns, page 1 of the fixture from its top edge and the title `ay_round_nolinks.pdf` | `build/snapshots/placeholder.png` |
| The 23 files the plan prints in full against their blocks (`cmp`, as Gate 0 did) | identical | `23 of 23 identical` |
| `git status --porcelain \| wc -l` | after the last commit | `0` |
