# Gate 0 — Review of Wave 0

Notes of the Gate 0 review (`plan.md` §11.4), by an agent that wrote none of Wave 0. Read by the coordinator before Wave 1 starts, and by Gate 1. After this step the shared paths of §11.2 are frozen.

## What was checked

| Step | How | Result |
| --- | --- | --- |
| 1. Every protocol has a consumer | `Tests/RefereeCoreTests/ContractConsumers.swift`: for each of the 13 protocols of Appendix A a conformer written from the protocol alone (actors for `PaperService`, `ReferenceResolving`, `SessionStoring`, `SettingsStoring`; classes for `SecretStoring`, `LLMProvider`, `ReviewEngineProtocol`; structs for `RefereeError`, `PaperTextBuilding`, `QuoteMatching`, `PaperRendering`, `CitationIndexing`, `ProviderResolving`), plugged into an `AppDependencies`, and one function that calls every requirement through the existentials | Compiles without warnings and passes. Every protocol can be implemented as the plan intends; the one subtlety is that an actor must answer `ReferenceResolving.searchURL(for:)` as `nonisolated`, which the Wave 0 resolver already does |
| 2. §11.3 against the code | `Tests/RefereeUITests/Common/CommonSurfaceCheck.swift` (TestSupport, PDFBridge, AppCore with every member of Appendix A.9, RefereeUI with `Theme` and `UIActions`) and `Tests/IntegrationTests/SurfaceCheck.swift` (RefereeCore besides Appendix A, PaperText, CitationKit, LLMKit, CLIProviders, ReviewEngine, ScholarKit, Persistence, Composition): never called, they name every declaration with its printed labels and types, check actor and class kinds, and switch exhaustively over every public enum | Both compile. A mutation test (renaming `findNext()`, and the label `account:` of `KeychainSecretStore`) stopped the build in the right file each time; reverted. A text check found all 326 declaration fragments of §11.3 and A.9 in `Sources/` with the same spelling, default values included |
| | The files the plan prints in full: blocks extracted from `plan.md` by a script of my own and compared with `cmp` | All 23 identical (manifest, five scripts, `make-fixtures.sh`, `main.swift`, `LiveDependencies.swift`, A.1–A.8, three LaTeX sources, three `Fixtures/llm` files), before and after this step's changes |
| | The 13 prompt constants, by a temporary test (not committed) that wrote them to files, against the Appendix B blocks | Identical; the two review-task texts differ from the print only as G.4 decided (annotations removed, `{same optional lines}` written out). Rubric and quick questions equal B.6 |
| 3. The fakes | All of `TestSupport` read against §5.9, §10.3 and the comments of §11.3 | The behaviour matches. Tests added where a documented behaviour had none: `failAfterChunks` without a `failure` (a server error 500); a stall point of one's own, and one past the end of the text; a cancelled delay ends at once; the 200-letter rule of `identityPaperText`; `saveCount`; cancelling a stub consumer ends the `URLSession` task itself. Not unit-tested: `REFEREE_REPO_ROOT` and the release-build path of `Fixtures.root`, because setting an environment variable in the test process would reach every test running in parallel (WP0b ran the bundled binary from another directory instead) |
| 4. The snapshot path | `scripts/snapshots.sh --scene placeholder`, PNG opened | Exit 0, 2560 × 1600 pixels, `nonBlank`, no failures. The window is titled `ay_round_nolinks.pdf`; three columns: a grey "Navigator" panel, page 1 of the fixture from its top edge (title, "Anonymous", abstract, the introduction's first paragraph), a grey "Sidebar" panel |
| | `Tests/IntegrationTests/SnapshotGraphTests.swift`: `LiveDependencies.make` with `REFEREE_SNAPSHOT=1` and a temporary `REFEREE_HOME`, then `engine.plan` and `engine.review` for `mock-remote`, `mock` and `mock-fail` | Passes. The run's destination is `mock.example.org` (`this Mac` for the local two), the plan's `isLocal` is right, and no failure message says the provider is missing. It asserts nothing about how the run ends, so it holds for the real engine too; `mock-stall` is left out because the real engine would wait on it for ever |
| 5. The fixtures | `scripts/make-fixtures.sh --pdf-only` in a scratch copy (script and `Fixtures/tex` only), then `referee-cli dump-raw` on each rebuilt PDF | The seven PDFs have the committed byte sizes and differ in 68–76 bytes (dates and document ids); all seven dumps are byte-identical to the committed ones, so page counts and first lines are too |
| | Two rows marked ● | WP2 "links": 12, 12, 36 and three times 0; `num_links` has 10 internal links into page indices 2 and 3 and 2 URL links with `doi.org/10.3115/v1/D14-1179`; all 36 of `ay_links` internal. WP1 "ruler" (raw side): 60 number-only lines 1–60 at the start of every page of `s1_ruler`, and the line starting "ficient in Table 2 is 0.91". Also the raw side of WP1 "line numbers on text lines": `ay_nolinks` carries 1–16, 17–33, 34–48, 49–54, glued or alone (46 is glued after the digits of "34–55", the Springer entry WP1 must handle) |
| 6. Fixes | Below | |

Also checked: no tracked file contains a home-directory path, the login name or an email address (the fixture PDFs' info dictionaries hold only pdfTeX and macOS producer strings); the whole suite passed five times in a row while 24 busy loops kept all 8 cores of this machine loaded, as nine worktrees building at once will.

## What was changed, most serious first

1. **Log test sinks** (coordinator decision 4). `Log.setTestSink` is replaced by `Log.addTestSink(_:) -> UUID` and `Log.removeTestSink(_:)`, in `Sources/RefereeCore/Support.swift` and the A.8 block identically (`cmp`). Several sinks can be active; each test removes only its own. The doc comment says that a sink sees the events of every test running at that moment, so a test filters by its own event names or asserts only what holds for every event. `LogTests` is rewritten: no retries, no `.serialized`, and two new tests (two sinks at once, each removed alone; eight concurrent "tests" whose sinks all see all eight events). `scripts/test.sh` still runs in parallel.
2. **Frozen tests that could fail on a busy machine.** A provider stream built with `AsyncThrowingStream(unfolding:)`, the mock's included, ends *without an error* when its consumer is cancelled before the first element or between two elements; only a cancellation inside a delay or a stall throws `.cancelled` (shown with a throwaway probe). `SnapshotSupportTests.mockFailAndMockStallPlayTheirScripts` cancelled after a fixed 200 ms and took a silent end for "finished", and two mock tests demanded `.cancelled`; any of them could fail while nine builds load the machine, and no Wave 1 agent could fix a frozen test. They now assert what holds in every case (still open before the cancel, no `.finished`, ends promptly, any error is `.cancelled`). The delayed-chunk test of `StubURLProtocol` got three delays of slack instead of one.
3. **The `placeholder` scene.** A test in `Tests/RefereeUITests/Common` (which WP11 does not own) requires it, while the comment in `ShellScenes.swift` let WP11 drop it. It is now listed in §10.1's scene table as kept in every wave, and the comment says so.
4. **`InMemorySessionStore.saveCount`** (decision 3): the number of `save(_:)` calls (the decision says "`saveSession`"; the protocol's method is `save(_:)`), with a test. `FakeResolver.forgottenDocuments` stays; both are printed in §11.3.
5. **§10.1** (decision 7) now describes the runner as built: a data folder and dependency graph per scene; the `NSWindow` subclass whose `constrainFrameRect(_:to:)` returns the frame unchanged, and where the window is placed; content, size, style and title per scene kind; when the fixture PDF is opened; what `prepare` and `verify` receive; what counts as a failed scene; `manifest.jsonl` is never emptied; exit codes 0, 1, 2; PNG sizes in pixels. WP0b asked whether Gate 0 prefers a plain window: no, the subclass stays, since with a plain window a scene's size would depend on the display it runs on.
6. **The welcome scene's sample summaries** used `Fixtures.url(…).path`, the absolute path of the checkout, so a welcome window that shows a path would have put the home folder into a picture that agents describe in their notes. They now use paths relative to the repository root, where snapshots run.
7. §9.2 and WP9: `ReaderPane` declares no minimum width (decision 1). §5.9 and §11.3: the mock scripts cut after the third block's quote line, counted in lines (decision 2); the code's comments say the same. §11.3: `Theme` printed from the code (decision 6). §11.5: `/usr/bin/log show --info …` (decision 5). §2.1: `TestSupport` imports CryptoKit (decision 8).
8. §11.3 now states two behaviours of the fakes that only their doc comments had: a `StubURLProtocol` handler belongs to the calling test's task (set it, make the session and read the requests in the test function itself), and `MockLLMProvider` records a request when `stream(_:)` is called.

Every plan edit has a row in Appendix G.5. The mention of `setTestSink` that decision 4 places in §12.1 is in §12.2; it is changed there. G.1 still names `setTestSink`, as the record of the second version.

## Left for the coordinator

1. **`Tests/RefereeUITests/Common/` belongs to nobody after the freeze.** It is not in §11.2's frozen list and no Wave 2 package owns it, yet it holds four files that test frozen code (`CommonSmokeTests`, `CommonSnapshotRunnerTests`, `CommonThemeTests`, `CommonSurfaceCheck`). Suggest adding it to the frozen list of §11.2 (outside what I may edit).
2. §2.1 lists RefereeUI's imports without CryptoKit and ImageIO, which `CommonSnapshotRunner.swift` uses for the hash of a fixture session and for writing PNGs. Decision 8 covers `TestSupport` only, so the RefereeUI row is unchanged.
3. `SnapshotSupport`'s nine static rows copy the Wave 0 descriptors. If WP5's experiment (§5.6.6) gives `claude-cli` or `codex-cli` `supportsNativePDF` or a `pdfDeliveryNote`, Gate 1 should update those rows; Wave 1 cannot.
4. The commits before WP0a's cleanup still contain the absolute path of the checkout (WP0a decision 7); the tree does not.

## Warnings for the Wave 1 briefs

- **Parallel tests, one process.** The tests of all targets run in parallel in one process. Never call `setenv` or change the current directory in a test; pass environment dictionaries (as `LiveDependencies.make(environment:)` takes). A log sink sees every running test's events: filter by your own event names, remove only your sink. `NotificationCenter.default` is shared too (WP8b: post `.refereeSettingsDidChange` with the model as its object and filter on it).
- **A frozen test that fails is not yours to fix:** record it as a contract problem.
- **Cancellation** (WP4, WP5, WP6, WP8b): a provider's stream, the mock's included, may simply end when its consumer is cancelled between two elements, without throwing `.cancelled`. Code that turns a cancelled job into `.cancelled` (WP6's "cancellation" row, the model's lanes) must check `Task.isCancelled` after the loop, not wait for the error.
- **`StubURLProtocol`** (WP4, WP7): set the handler first in every test that uses it (`nil` included), and make the session in the test function itself, not in a child task. The stub has no hook for `stopLoading`; to see that cancelling a consumer cancelled its request, wait for `await session.allTasks` to become empty (as `StubURLProtocolTests` does).
- **WP2:** `RawExtractor`'s output must stay byte-identical to `Fixtures/raw` (frozen; WP1 and WP3 test against it, and `PDFBridgeSmokeTests` compares). A change it needs is a contract problem for Gate 1.
- **WP6:** `FakeQuoteMatcher` on `makeSamplePaper()` finds two of the six quotes of `review_clean.txt` (the third and the sixth). `MockLLMProvider.recordedRequests` grows when `stream(_:)` is called, not when the stream is read. The privacy row picks the engine's events by name.
- **WP8b:** `InMemorySessionStore.saveCount` and `FakeResolver.forgottenDocuments` serve the "autosave" and "delete" rows. No fake counts `listModels()` calls or throws from it: the "engine context" and "settings model" rows need a small `LLMProvider` of the test's own.
- **WP1:** `Fixtures/private` is git-ignored, so it is empty in a worktree and the "no false positives" row skips that part.

## Warnings for the Wave 2 briefs

- No pane declares a minimum width (§9.2); a review scene whose window grows fails.
- WP11 keeps the scene `placeholder` as it is, and should keep logging `shell.review.ready` (no file name) when a review window shows its document: §11.5 step 4 reads the log for it.
- A scene's `prepare` and `verify` get the window and the models only. A settings tab or a find query has to be set through something internal to the pane's own area. `WelcomeView(recent:open:)` receives no provider information, so in the snapshot its provider line shows whatever the view shows without one.
- Snapshot PNG sizes are pixels: 2560 × 1600 for the default 1280 × 800 points on this display.

## Acceptance

Run on Command Line Tools 26.6 (Swift 6.3.3) after deleting `.build` and `build`.

| Command | Result | Final line |
| --- | --- | --- |
| `scripts/build.sh` | exit 0; no line with "warning" or "error" | `Build complete! (38.06s)` |
| `scripts/test.sh` | exit 0; no "warning" | `test.sh: OK (129 tests)` (RefereeUITests 18, IntegrationTests 5) |
| `scripts/test.sh --filter RefereeCoreTests` | exit 0 | `test.sh: OK (85 tests)` |
| `scripts/snapshots.sh --scene placeholder` | exit 0; PNG opened (as described in step 4) | `build/snapshots/placeholder.png` (before it: `{"scene":"placeholder","file":"build/snapshots/placeholder.png","width":2560,"height":1600,"nonBlank":true,"failures":[]}`) |
| `scripts/bundle.sh && codesign --verify build/Referee.app` | exit 0; no "warning" in the release build | `Built build/Referee.app` (`codesign --verify` prints nothing) |
| `git status --porcelain \| wc -l` | | `0` |
