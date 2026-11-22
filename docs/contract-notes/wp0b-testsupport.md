# WP0b — Test support, fixtures, composition, snapshot runner

Notes of the second Wave 0 session (`plan.md` §11.4). Read by the Gate 0 reviewer, by the coordinator, and by any Wave 1 or Wave 2 agent who wants to know how a fake behaves in a case its comment does not cover.

## What exists after this step

| Part | State |
| --- | --- |
| `Package.swift`, `scripts/bundle.sh`, `scripts/make-fixtures.sh`, the three LaTeX sources, `Fixtures/llm/review_clean.txt`, `discussion_revise.txt`, `report_sample.txt` | Byte-identical to the blocks printed in the plan (copied by a script, compared with `cmp`) |
| `Sources/TestSupport` | Real. Every declaration of §11.3, with the behaviour of its comment, §5.9 and §10.3. `Placeholder.swift` is gone |
| `Fixtures/pdf`, `Fixtures/raw` | Seven PDFs built by `scripts/make-fixtures.sh` as printed, and their dumps |
| `Fixtures/llm/question_answer.txt`, `Fixtures/sessions/sample.json` | Written here from the descriptions in Appendix D.9 and WP0b item 3 |
| `PDFBridge.RawExtractor.extract`, `PDFPaperService.load`, `referee-cli dump-raw` | Simplest working form. `rects`, `unload` and `SelectionInfoBuilder` are still placeholders (WP2); the other seven subcommands are Gate 1's |
| `RefereeUI/Common` | Real: `CommonSnapshotRunner`, `CommonSnapshotScene`, `CommonTheme`, `CommonUIActions`, `CommonIntegrationScenes` (empty) |
| `ReviewWindowView`, the three panes, `WelcomeView`, `SettingsRootView`, `ReferenceViewerView`, `AppMain`, `ReaderController` | Placeholders that work: the window is composed as §9.2 prescribes, `attach()` loads the display document, `AppMain` runs the snapshot mode or opens a review window for a PDF path. One scene, `placeholder` |
| Tests | 119: `RefereeCoreTests` 76, `RefereeUITests` 18, `PDFBridgeTests` 6, `IntegrationTests` 4, and the Wave 0a smoke tests of the other eight targets |

## How it was checked

1. The script of WP0a's notes, extended: 23 files that the plan prints in full are identical to their blocks, and every declaration of §11.3 (174 fragments), of Appendix A.9 (140) and of the `UIActions` block of §9.1 is in the sources with the same spelling.
2. The public declarations of `TestSupport` are those of §11.3 and the members their protocols require, plus one property (contract problem 3). `RefereeUI/Common` adds `Theme`, whose surface the plan does not print (decision 9).
3. The rebuilt PDFs have the byte sizes of the ones the plan's author built (183,964 bytes for `ay_nolinks.pdf`, the number in the sample of §4.3), and a dump of each of the author's PDFs is byte-identical to the dump of the rebuilt one. Pages, lines and links of the committed dumps equal the author's own dumps; the committed ones also have the outline (three entries in each hyperref fixture).
4. The whole suite was run five times in parallel (1.1 s each) and three times with `--no-parallel` (3.3 s each): no failure.
5. The placeholder snapshot was opened and looked at, in light and dark, at 1280 × 800, 1000 × 640, 1500 × 1000 and 2400 × 1300. The bundled release binary was run on the same scene from the repository root (exit 0), from another directory (exit 1: the fixture is not found) and from there with `REFEREE_REPO_ROOT` (exit 0). Scenes of the other three kinds, a scene with the sample session, a failing `verify`, a missing PDF and a missing session were run through temporary scenes that are not committed.
6. The app was started three times for three seconds each (with a fixture, with a missing file, with no argument) and its log read with `/usr/bin/log show --info`: `shell.review.ready document=bool(true) pages=int(4)`, `shell.review.failed`, `shell.welcome.shown`.

## Decisions

Things the plan left open, decided inside this step's files.

1. **Mock provider** (§5.9).
   - A request is recorded, and its response chosen, when `stream(_:)` is called. The stream is cold: nothing is emitted until it is iterated, and each element is produced in the consumer's task, so cancelling that task interrupts a delay or a stall at once. A stalled or delayed stream that is cancelled throws `LLMError.cancelled`; a stream cancelled between two elements just ends.
   - One model, `mock` (context 1,000,000), so that the indicator of the scene `review-empty` reads "Local · mock" as §10.1 has it. `availability()` is `.ready("Built in")`. Usage is one token per four characters, the same on every run. Display names: "Mock", "Mock (remote)", "Mock (fail)", "Mock (stall)".
   - `MockScript.sample` also answers `.revise` (with `report_sample.txt` again) and `.ping` (with "OK"); §11.3 names files for the other four purposes only. A purpose without a response throws `.notConfigured`. `failAfterChunks` without a `failure` throws `.server(status: 500, …)`. A fail or stall point beyond the end of the text is never reached.
   - `mock-fail` and `mock-stall` are local, so a scene can review through them without the consent card. Their scripts answer every purpose except a review as `sample` does.
   - `SnapshotSupport.settings()` chooses the model `mock` for each mock and in the review default; `cachedModels` stays empty, so the model fetches the list itself.
   - The nine static rows: Anthropic, xAI, Ollama and Claude Code are ready with models; OpenAI, Gemini, Codex and Antigravity need setup; Grok Build is unavailable for a missing safety flag. Model ids are invented (`example-large`), except Ollama's two.
2. **`StubURLProtocol`.**
   - The handler and the record of requests belong to the task that calls `setHandler`, and serve the sessions that task makes. Swift Testing runs every test in its own task, in parallel, and all test targets share one process; a single handler for the process would be overwritten by whichever test set it last. A test proves that twelve concurrent users do not mix. The cost is one rule for test authors: set the handler and make the session in the test function itself, and start every test with `setHandler` (pass `nil` when requests should fail). Details and limits are in the type's comment.
   - `setHandler` empties `recordedRequests`. The handler receives the request as it is recorded, with the body in `httpBody`. A handler that returns `nil` gives `URLError.cannotConnectToHost`.
   - Every response gets the header `X-Content-Type-Options: nosniff` unless it sets that header. Without it URLSession holds back the first 512 bytes of a body that has no Content-Type, or is `text/plain`, and three small chunks 150 ms apart arrived together at the end (measured).
   - `delayPerChunk` is waited before every chunk, the first included. With a zero delay the body is delivered inside `startLoading`.
3. **The other fakes.**
   - `FakePaperService.rects`: `y` and `height` are those of the line in which the span starts when the paper has that line's bounds, else 100 and 12.
   - `FakeQuoteMatcher`: case-sensitive; the hinted page first, then the pages in order; the label names the page of the first span. With `makeSamplePaper()` it finds two of the six quotes of `review_clean.txt` (the third and the sixth); the other four cross a line break or stand on a line without spaces. A test pins this.
   - `FakePaperRenderer`: `pages` is a range of positions in `paper.pages`, cut to the paper; N is the page's `index` + 1; no pages give the empty string; sizes are counted in Swift characters.
   - `FakeResolver`: authors, year, DOI and arXiv id are the entry's parsed values; source `.entryText`; a fixed date. `fetchPDF` returns `Fixtures/pdf/num_twocol_links.pdf`.
   - `ScriptedReviewEngine`: `discuss` and `ask` play the same reply events, `generateReport` and `reviseVoice` the same report events; `lint` is not listed in `calls`; a cancelled stream ends without throwing.
   - `InMemorySessionStore.listSessions` is newest first. `InMemorySecretStore` throws `.unreadable(status: -25293)`.
   - `identityPaperText`: `hasTextLayer` by the 200-letter rule, no title guess. `makeSamplePaper`: the real SHA-256 of the PDF, `lastKnownPath` nil.
   - `TestSupport` imports CryptoKit for that hash, which the table of §2.1 does not list.
4. **`failsAfterTwoComments`: where the third block is cut.** See contract problem 2.
5. **Fixtures.**
   - `question_answer.txt` is three sentences that quote "The coefficient in Table 2 is 0.91".
   - `sample.json` has seven comments, a placeholder hash (64 zeros) and size, and two completed runs by `mock`. No anchor has spans or rectangles; five comments wait as page-only for the model to locate their quote.

     | Title | State | Kind | Page | Anchors as |
     | --- | --- | --- | --- | --- |
     | The interval includes one, yet the effect is called robust | pending; a thread of two messages and a proposed revision | major | 1 | exact (the Table 2 sentence) |
     | The estimate cannot be told apart from no effect | pending, `similarTo` the first | major | 1 | exact (same quote) |
     | Nothing shows that rollout timing is unrelated to outcomes | approved | major | 1 | fuzzy, 0.91 (one word of the quote changed) |
     | The threshold is named but never defined | the reviewer's own, approved | minor | 1 | exact |
     | The main result is stated clearly | rejected | strength | 2 | exact |
     | How are the standard errors computed? | pending | question | 3 | page only (the quote is not in the paper) |
     | There is no discussion of related work | pending, category `literature` | minor | none | unanchored (the quote is not in the paper) |

     The plan asks for quotes that occur in the fixtures; two deliberately do not, because the scene `sidebar-states` needs a page-only and an unanchored card and a quote that occurs would be anchored on load. The fuzzy quote and the two absent ones were checked on all four same-text dumps with a literal reading of §6.7 step 4 (it reproduces the plan's own fuzzy example at 0.90). The similar pair lies on page 1, so page 1 of `reader-highlights` will have two yellow highlights on one passage, a green one with the dashed border of a fuzzy anchor, and a blue one.
   - `Fixtures/raw` holds exactly what `referee-cli dump-raw` prints: sorted keys, pretty-printed, slashes not escaped, one final line break.
6. **Raw extraction.** A line selection without a range on its page is skipped; CR, LF, U+2028 and U+2029 are trimmed from the end of a range; top-level outline items have depth 0. `load` reports a missing or unreadable file without naming it.
7. **`referee-cli`.** `dump-raw <pdf>` only; exit 2 for anything else, 1 for a file that is not a PDF or is locked.
8. **Snapshot runner** (§10.1). Also listed at the top of `CommonSnapshotRunner.swift`.
   - Every scene gets a data folder and a dependency graph of its own. With one folder for the run, a scene would see the sessions and settings an earlier scene saved, and its picture would depend on which scenes ran before it.
   - Window sizes: review 1280 × 800, reference viewer 900 × 700, settings 780 × 560, welcome the size the view asks for, or 640 × 440. `--size` applies to review and reference-viewer scenes. Review and viewer windows have the style mask of §9.1; the other two are titled, closable and miniaturizable, so their pictures include a title bar above the content.
   - The window is a private subclass of `NSWindow` that overrides one method, `constrainFrameRect(_:to:)`, so that AppKit cannot shrink it to the screen. A plain window is cut down to the visible part of the screen when it is shown: on this display (1600 × 900 points, 828 of them free between menu bar and Dock) a scene of 1500 × 1000 came out 1500 × 828, and the default 1280 × 800 has 28 points to spare, which a larger Dock would take. The window is placed where AppKit puts a plain window that is sent to (−6000, −6000): its top right corner, 40 × 74 points, inside the bottom left of the main screen. For a scene that fits the screen the result is the same picture as with a plain window; scenes of 1500 × 1000 and 2400 × 1300 were captured in full.
   - A welcome scene gets two sample summaries of recent reviews: §11.3 gives a scene no way to provide them. A reference-viewer scene shows its `fixturePDF`, titled with the file name.
   - A scene that names a `fixtureSession` must name a `fixturePDF`.
   - `prepare` is called once the reader has loaded the display document (three seconds at most), so a scene can set a selection at once.
   - Besides what `verify` returns, these count as failed expectations: the fixture PDF did not open; the window did not keep the size it was given; the data folder could not be prepared; the window could not be captured or written.
   - The settings are written to `settings.json` and also saved through the settings store, which reaches the Wave 0 store that keeps everything in memory.
   - `manifest.jsonl` is appended to and never emptied. Exit 1 for an unknown scene name or no scene at all, 2 for wrong arguments. The arguments may start with the program name.
   - PNG sizes are in pixels of the display the run happens on: 2560 × 1600 here for 1280 × 800 points.
9. **`Theme`** (§9.10 describes it, nothing prints it): `kindColor(_:)`, `statusColor(_:)`, `ownColor`; `Highlight` (`pending`, `approved`, `rejected`, `own`, `question`) with `highlightHue`, `highlightAlpha(_:selected:)` and `highlightColor(_:selected:)`; `fuzzyBorderWidth`, `fuzzyBorderDash`; `pdfBackground`; `cardCornerRadius`, `cardPadding`, `listSpacing`, `sidebarPadding`; `cardTitleFont`, `bodyFont`, `quoteFont`, `metadataFont`. All colours are system colours.
10. **Placeholders.** The three panes show a label; `ReaderPane` shows the controller's PDF view and sets no minimum width (contract problem 1). `AppMain` logs `shell.review.ready`, `shell.review.failed` or `shell.welcome.shown`, with no file name. After loading a document `ReaderController` goes to the top left corner of its first page: left to itself PDFKit opened the fixture 43 points below the top of the page in a view of 692 × 768 points and 158 points below it in one of 912 × 968 (measured in document units), which WP9 may want to know.
11. **Tests outside `RefereeCoreTests`.** `PDFBridgeTests` compares the extraction of each fixture with its committed dump. `RefereeUITests/Reader/ReaderAttachTests.swift` states the contract of `attach()` against the surface only, so it holds for the real controller too. `IntegrationTests` has one test of the snapshot registry; the test Gate 0 step 4 asks for is not written.

## Contract problems

1. **The composition of §9.2 cannot be 1280 points wide if the PDF pane declares its minimum width.** With `.inspector` attached to the `NavigationSplitView`, SwiftUI on macOS 26.6 adds the inspector's width to whatever minimum the detail column declares. Measured in a hosted window, with the column widths of §9.2:

   | Detail content | Smallest window the layout allows |
   | --- | --- |
   | `.frame(minWidth: 480)` | 1448 (208 + 480 + 380 + 380) |
   | `.frame(minWidth: 100)` | 1068 |
   | no declared minimum | 968 |
   | `.frame(minWidth: 480)`, inspector hidden | 688 |
   | `.frame(minWidth: 480)`, inspector attached to the detail content instead | 1276 (the sidebar is counted twice) |

   A hosted window grows to that width after its first layout, whatever size it was given. Telling the hosting controller not to size the window (`sizingOptions = []`) keeps 1280 but squeezes the navigator to 124 and the sidebar to 294 points. So "PDF: flexible, min 480 pt" (§9.2) and "1280 × 800 default, 1000 × 640 minimum" (§9.1) cannot both be written as the plan words them.
   *Done here:* the placeholder `ReaderPane` declares no minimum; the window is then 1280 × 800, and at 1000 × 640 the columns are 208, 412 and 380 points. The runner makes windows with a default `NSHostingController`, as §10.1 says the app does, and reports a scene whose window did not keep its size, so a pane that brings the problem back fails its scene instead of producing a wider picture.
   *Suggested:* say in §9.2 and in WP9 that `ReaderPane` sets no minimum width and that the 1000-point minimum of the window is what keeps the PDF readable.
2. **"Half of the third block" against "two comments kept"** (§5.9 and §11.3 against §6.5 rule 5, §6.6, §10.1 `banner-error`, Gate 1 "snapshot graph"). On a failure the engine closes the parser, and the parser emits an open block unless it has neither title nor body. Half of the third block of `review_clean.txt` by characters ends 25 characters into its body, so a review through `mock-fail` would keep three comments, the third cut off in the middle of a word.
   *Done here:* the half is counted in lines. The text ends after the third block's quote line (five of its nine lines): kind, category, page and quote, and neither title nor body. The parser drops such a block, two comments remain, and the draft of `sidebar-streaming` shows a badge and a quote. Tests pin the cut.
3. **`FakeResolver` could not show that `forget` was called** (§11.3; WP8b's row "delete" expects "`FakeResolver` saw `forget`").
   *Done here:* one public property beyond §11.3, `forgottenDocuments: [String]`.
   *To decide:* keep it and print it in §11.3, or remove it and have WP8b wrap the resolver. The same question exists for WP8b's row "autosave … one save": `InMemorySessionStore` has no counter, and nothing was added there, because a test can wrap the store or look at what `loadSession` returns before and after the debounce.
4. **`Log.setTestSink` is one per process, and tests run in parallel** (Appendix A.8, §3.5). Two tests that install a sink at the same moment take each other's events. After Wave 1 that is `LogTests` here and the privacy test of WP6, in different targets, which no `.serialized` trait can order.
   *Done here:* `LogTests` holds the sink for an instant, uses event names of its own, and logs again when its event went elsewhere. It cannot protect the other test: when `LogTests` removes its sink, a sink installed by another test in that instant is removed with it.
   *Suggested:* either pass `--no-parallel` in `scripts/test.sh` (the suite passes that way too, and takes 3 s instead of 1 s today), or tell WP6 that its test must not assert that any particular event arrived.
5. **`log show` needs `--info`** (§11.5 step 4). `Log.event` writes at info level, and `log show --last 1m --predicate 'subsystem == "local.referee.app"'` prints no event without `--info`. In zsh `log` is also a shell builtin; `/usr/bin/log` is the tool.
6. **The prototype's check of `ay_nolinks`.** `python3 -I docs/prototypes/check_citations.py docs/prototypes Fixtures/raw/*.raw.json` prints 9 entries and 15 text mentions for `ay_links`, `ay_round_nolinks` and `s1_ruler`, 5 and 10 for the two numeric fixtures, and **8 and 9 for `ay_nolinks`**. The prototype reads an optional field on each line, `protoBoundsNoTrailingDigits` (the bounds without the margin digits, standing in for what `PDFPaperService` recomputes, §7.2), which the author's dump tool wrote and `RawDocument` does not have. With the author's dump the same command prints 9 and 15. Everything else the prototype prints (`kinds`, `lines`, `render`, and `cite` on the other five fixtures) is identical for the two sets of dumps. `docs/prototypes/README.md` now says so. Nothing in Wave 1 depends on it: WP3 does not test `ay_nolinks`, and Gate 1 tests it through the real service.

## For Gate 0

- Step 2: the surface checks should compile as they are; `FakeResolver.forgottenDocuments` and `Theme` are the two things §11.3 does not have.
- Step 4: with `REFEREE_SNAPSHOT=1` the placeholder engine's failed run for `mock-remote` has the destination `mock.example.org` and the message "The review engine is not implemented yet."
- Step 5: `scripts/make-fixtures.sh` needs `/Library/TeX/texbin` on the `PATH`. A rebuilt PDF differs from the committed one in about 70 bytes (the creation date and the document id); its dump is identical.
- While a scene runs, the top right corner of its window (40 × 74 points) is visible at the bottom left of the main screen, as §10.1 describes. The runner's window differs from a plain `NSWindow` in the one method named in decision 8; say so if Gate 0 prefers the plain window and the screen-dependent sizes that come with it.

## For Wave 1 and Wave 2

- Tests that use `StubURLProtocol`: set the handler and make the session in the test function, every test, handler first. Give a streamed response the Content-Type the real server sends.
- `MockLLMProvider.recordedRequests` grows when `stream(_:)` is called, not when the stream is read.
- A scene's `prepare` and `verify` get the models and the window, nothing else. A view that needs more state from a scene (the tab of a settings scene, the provider line of the welcome window) has to get it from something inside its own area.
- `Fixtures/sessions/sample.json` works with any of the four same-text PDFs; the runner writes the hash and the size of the scene's `fixturePDF` into the copy.

## Acceptance

Run on Command Line Tools 26.6 (Swift 6.3.3) after deleting `.build` and `build`, once on the tree as it was about to be committed and again on the last commit; the build time in the first line is that of the first run.

| Command | Result | Final line |
| --- | --- | --- |
| `scripts/build.sh` | exit 0; no line with "warning" or "error" | `Build complete! (37.26s)` |
| `scripts/test.sh` | exit 0; no "warning" | `test.sh: OK (119 tests)` |
| `scripts/test.sh --filter RefereeCoreTests` | exit 0 | `test.sh: OK (76 tests)` |
| `"$(swift build --show-bin-path)"/referee-cli dump-raw Fixtures/pdf/ay_nolinks.pdf \| head -c 200` | the first 200 bytes of the dump | `            "height" : 18.24498749999998,` (the last whole line) |
| `scripts/snapshots.sh --scene placeholder` | exit 0 | `build/snapshots/placeholder.png` (before it: `{"scene":"placeholder","file":"build/snapshots/placeholder.png","width":2560,"height":1600,"nonBlank":true,"failures":[]}`) |
| `scripts/bundle.sh && codesign --verify build/Referee.app` | exit 0; no "warning" in the release build | `Built build/Referee.app` (`codesign --verify` prints nothing) |
| `git status --porcelain \| wc -l` | | `0` |

The placeholder picture (2560 × 1600 pixels) shows a window titled `ay_round_nolinks.pdf` with three columns: on the left a grey panel labelled "Navigator"; in the middle page 1 of the fixture from its top edge (title, author, abstract, the heading and first paragraph of the introduction); on the right a grey panel labelled "Sidebar".
