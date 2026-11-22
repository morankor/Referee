# WP0a — Scaffold and contracts

Notes of the first Wave 0 session (`plan.md` §11.4). Read by WP0b, by the Gate 0 reviewer and by the coordinator.

## What exists after this step

| Part | State |
| --- | --- |
| `Package.swift`; `scripts/build.sh`, `test.sh`, `run.sh`, `bundle.sh`, `snapshots.sh`; `Sources/Referee/main.swift`; `Sources/Composition/LiveDependencies.swift`; `Sources/RefereeCore/` A.1–A.8 | Byte-identical to the blocks printed in the plan |
| `Sources/RefereeCore/DefaultSettings.swift`, `FormatSpec.swift` | Written here; the prompt texts are generated from the Appendix B blocks, not retyped |
| `Makefile`, `scripts/make-icon.sh`, `.gitignore`, `README.md`, `docs/contract-notes/README.md` | Written here from the descriptions in §3.3 and §3.4 (the plan describes these files; it does not print them) |
| Every other target | The declarations of §11.3 and Appendix A.9 with placeholder bodies; no `fatalError` anywhere |
| Twelve test targets | One smoke-test file each, 26 tests in all |

Not created, because they belong to later steps: `Fixtures/`, `scripts/make-fixtures.sh`, `CommonTheme.swift`, `CommonUIActions.swift` (WP0b); `scripts/e2e-ollama.sh`, `scripts/fetch-optional-fixtures.sh` (Gate 1). The `Makefile` already has the `fixtures` and `e2e` targets that call them.

## How the copy was checked against the plan

1. A script extracted every fenced block of `plan.md` into a file. The sixteen files of the first table row were compared with their blocks byte for byte (`cmp`): identical.
2. A second script took every declaration line of the §11.3 block (169 fragments) and of Appendix A.9 (134) and looked for it, spelled the same, in `Sources/`: none missing. The reverse check found no `public` declaration outside those blocks other than members a conformance requires (`descriptor`, `body`, the four `URLProtocol` overrides).
3. A temporary file, not committed, named every declaration of §11.3 with its printed argument labels from `RefereeUITests` and `IntegrationTests`; it compiled without errors or warnings.
4. A temporary test, not committed, wrote the thirteen compiled prompt constants to files. Eleven are byte-identical to their Appendix B blocks. The other two are the review tasks, which differ from the print in the two ways described under decision 2.

## Decisions

Things the plan left open, decided inside this step's files.

1. **Default settings that no single place states.** `defaults` is empty (no provider is preselected; `applyFirstRunDefaultsIfNeeded` chooses one). `references.pdfCacheLimitMB` is 500 (§4.2), `ui.sidebarWidth` 380 (§9.2), `ui.autoAdvanceAfterTriage` true (§9.4), `ui.showRejectedHighlights` false (§7.3), every rubric category enabled, every provider's `inputMode` `.auto`. The prompt texts and the template carry no final line break.
2. **`FormatSpec` texts.** See contract problem 4, which also gives the rule.
3. **Placeholder bodies beyond the ones WP0a item 3 names.** The rule was: the simplest body that is safe and cannot be mistaken for the real thing.
   - `PaperTextBuilder.build` also sets `hasTextLayer` by the 200-letter rule of §7.2, so that a normal document is not announced as scanned. `PaperRenderer.chunkPageRanges` fills ranges greedily. `QuoteMatcher.locationLabel` gives "p. N" or "pp. A–B".
   - `PDFPaperService.load` throws `PaperError.unreadable`; `RawExtractor.extract` returns an empty document; `SelectionInfoBuilder.make` returns `nil`.
   - `LLMKitFactory` and `CLIProviderFactory` return placeholder providers whose descriptors carry the roster values of §5.2 and the retention notes of §9.7. `listModels()` returns an empty list. `KeychainSecretStore` keeps secrets in memory and never calls the Keychain.
   - `ReviewEngine.plan` returns a one-request text plan with the warning "The review engine is not implemented yet." Every stream yields `.started`, then `.finished` with a failed run, and ends normally. The failed run shows whether the engine found the provider: its `destination` is the provider's, and for an unknown id its message is "Provider is not set up: no provider with the id … is registered".
   - `ReferenceResolver.searchURL` builds a real Google Scholar query; `fetchPDF` throws `.noOpenAccessPDF`.
   - `AppPaths` has its documented behaviour already (two pure functions). Reason: every later step relies on `REFEREE_HOME` to keep tests, the command-line tool and snapshot runs out of the user's Library, and a placeholder that ignored it would be unsafe in any worktree where a real store or resolver meets it. `FileSessionStore` and `FileSettingsStore` work in memory; `listSessions` is newest first.
   - `PaperSize.current` follows the one-line rule of §11.3. `ReportExporter` returns UTF-8 text for `.markdown` and `.plainText` and throws `StoreError.io` for `.docx` and `.pdf`. `SelectionNormalizer.normalize` returns its input.
   - `ReviewSessionModel`: `open(url:)` loads the paper through the paper service and sets `phase`; `close()` unloads it; `reloadSettings` keeps the settings; `exportReport`, `reportText` and `fetchReferencePDF` pass the call on. Everything else is empty or returns a neutral value. No session is created, nothing is saved, no job starts. `SettingsModel.update` changes the settings in memory only.
   - `AppMain`: with `--ui-snapshot` it calls `SnapshotRunner.run` and exits with its code (the placeholder runner returns 1). Otherwise it shows the still empty welcome window and a menu with Quit.
   - `referee-cli` prints one line to standard error and exits with 2.
4. **`TestSupport` is deliberately inert.** Every declaration of §11.3 exists, and none of the documented behaviour does: the fixture readers and `makeSamplePaper` throw, the mock scripts are empty, the mock provider refuses to stream, the in-memory stores keep nothing, `failReads` cannot be set, `FakePaperService.load` throws, `ScriptedReviewEngine` plays nothing. Three things do work because there is no neutral value to return: `Fixtures.root` and `Fixtures.url`, `StaticProvider`, and `StubURLProtocol.session()`, which returns a session wired to the stub so that every request fails as "connection refused" and none can reach the network.
5. **File names.** One type per file. In `RefereeUI` every file starts with its area, and the three `Common` files already have the names WP0b's list uses. The Wave 0 files of `ReportExporter` and `PaperSize` are in `Sources/AppCore/Export/`, where WP8a will edit them.
6. **Smoke tests.** Each one states something that holds for the placeholder and must still hold for the real implementation (provider ids in order, `REFEREE_HOME` paths, a store round trip, the state of a new model), so no owner has to delete it. Two targets are shared by several owners (`AppCoreTests`, `RefereeUITests`); their smoke tests name nothing that differs between placeholder and implementation.
7. **`.gitignore` has one line more than §3.3 lists: `__pycache__/`.** Running the prototypes in `docs/prototypes` creates that folder, which would make `git status` dirty for WP1 and WP3. A compiled file from it had already been committed, with the absolute path of the checkout inside it; it is removed. Two absolute paths in `docs/plan-review.md` were made relative; nothing else in the review changed. The commits before this step still contain all three.

## Contract problems

1. **Test targets do not declare `RefereeCore`, and cannot be written without it** (§3.2). Only `RefereeCoreTests` declares it. The other eleven test targets declare their own target and `TestSupport` (`IntegrationTests`: `Composition`, `AppCore`, `TestSupport`), and `RefereeUITests` does not declare `AppCore` either. The same section says that a target imports only modules it declares and that a transitive import "must not be relied on". No test of these targets can avoid naming `RawDocument`, `PaperText`, `ProviderEnvironment` or `AppDependencies`.
   *Done here:* nine smoke-test files say `import RefereeCore`. `Package.swift` is untouched. The import is safe in practice: the module is in each target's dependency closure, so it is always built first, and SwiftPM's own check accepts it. `scripts/test.sh --explicit-target-dependency-import-check warn` on a build from scratch reports nothing, while the same run with a probe `import CitationKit` in `PaperTextTests` (a module outside that target's closure) answers "Target PaperTextTests imports another target (CitationKit) in the package without declaring it a dependency."
   *Suggested:* at Gate 0 either add `"RefereeCore"` to the eleven test targets and `"AppCore"` to `RefereeUITests`, or reword the rule to "a target imports only modules in its dependency closure". Otherwise each of the nine Wave 1 agents meets the question alone.
2. **`TestSupport` has no stand-in for `CitationIndexing`** (§11.3, Appendix A.8). `AppDependencies` needs one, and `AppCoreTests` and `RefereeUITests` do not depend on `CitationKit`. WP8b is told that all its dependencies are fakes from `TestSupport`, and its `open` test expects citations.
   *Done here:* the AppCore smoke test has a private five-line struct.
   *Suggested:* add a `FakeCitationIndexer` (with an index to return) to `TestSupport` at Gate 0.
3. **`ReviewEngineTests` cannot reach "the Wave 0 `PaperRenderer`"** (WP6 in §11.4, §3.2). The renderer is in `PaperText`; the test target depends on `ReviewEngine` and `TestSupport`, and `TestSupport` has no `PaperRendering`. Unlike problem 1, an `import PaperText` there is outside the target's closure: SwiftPM's check flags it, as quoted above, and it builds only when `PaperText` happens to have been compiled first.
   *Done here:* the ReviewEngine smoke test has its own small renderer.
   *Suggested:* add `"PaperText"` to that test target, or a `FakePaperRenderer` to `TestSupport`.
4. **Appendix B.2 prints presentation marks inside the task texts.** The second `TASK_REVIEW` block carries "← only when …" annotations, the PDF block says `{same optional lines}`, and `TASK_PART` contains the line `{if i > 1:}`. §11.3 gives `FormatSpec` seven strings and nothing else, so these had to become text or disappear.
   *Done here:* each constant is the printed block, character for character, with no final line break, except that the three annotations (and the spaces before them) are removed and `{same optional lines}` is written out as the three lines it refers to. `taskReviewText` is both printed blocks in one string; the line `{paper text}` separates what goes before the cache boundary from what goes after. `{if i > 1:}` is kept as printed. The doc comment of `FormatSpec` tells `PromptBuilder` (WP6) how to treat each kind of placeholder, and a test in `RefereeCoreTests` pins the placeholders.
   *To decide:* whether WP6 should instead append the three optional lines itself, as §6.3 words it ("`TASK_REVIEW` + reviewer notes + titles"), in which case the three placeholder lines should leave the two constants. Also note that §6.3 lists the parts of a "part i of n" request as the text followed by the task, while `TASK_PART` puts the text in the middle of the task.
5. **`DefaultSettings`: two phrases can be read two ways** (§11.3, WP0a item 2).
   - "every provider id … present and disabled except `ollama`, whose `extraBodyJSON` is …" could mean that only the JSON differs. The first version of the plan (commit `0cd9639`, its WP0 block) has the sentence without its last clause, so the meaning is that **Ollama is enabled** and everything else is not. That is what the code does. It is consistent with `applyFirstRunDefaultsIfNeeded`, which still has to pick a model and set the default.
   - "every provider id of §5.2" is taken literally: all ten rows of the table, **`mock` included** (disabled). The same phrase in the comment on `SnapshotSupport.providers()` means the nine real ones (§5.9). If `mock` should not be written into the user's `settings.json`, remove it from `DefaultSettings.providerIDs`.
6. **Gate 0, step 2: `SurfaceCheck.swift` cannot live in `IntegrationTests` alone.** That target does not depend on `RefereeUI`, so it cannot name the declarations of the four UI areas. The temporary check of this step used `RefereeUITests` for `RefereeUI`, `AppCore`, `PDFBridge` and `TestSupport`, and `IntegrationTests` for the rest.
7. **Gate 0, step 4: a snapshot scene cannot start a review yet.** `SnapshotContext` gives a scene the models, not the engine, and `ReviewSessionModel.startReview()` is empty until WP8b. The check itself is possible without a scene: build `LiveDependencies.make` with `REFEREE_SNAPSHOT=1` and a temporary `REFEREE_HOME` in a test, call `engine.review` for `mock-remote`, and read the failed run (decision 3 says how it shows that the provider was found).
8. **Types without a public initialiser.** `Banner`, `ConsentRequest`, `ComposingComment` (A.9) and `SnapshotContext` (§11.3) are printed without one, so only their own module can build them. That is enough for the model and the runner; a test in another module cannot construct a `Banner` for a view. Left as printed.
9. **The built app contains the absolute path of the checkout.** `TestSupport.Fixtures` finds the repository from `#filePath`, as §3.6 prescribes, and `TestSupport` is linked into the app (§2.1). `strings build/Referee.app/Contents/MacOS/Referee` shows that one path, with the login name in it. Nothing in the repository is affected, and it does not matter while the app stays on this machine (Q8). It would matter before handing the app to anyone.

## For WP0b

- `TestSupport` is yours from the first line (decision 4). `Sources/TestSupport/Placeholder.swift` goes when the last placeholder does.
- The stores are in memory until WP8a. A `settings.json` or `session.json` that the snapshot runner writes into its temporary `REFEREE_HOME` is not read back by `FileSettingsStore` or `FileSessionStore`, and the placeholder model does not load sessions either. Give the models `SnapshotSupport.settings()` directly.
- `ReviewSessionModel.open(url:)` already sets `paper`, so `ReaderController.attach()` can load the display document once `PDFPaperService.load` works.
- `ShellAppMain.swift` holds a placeholder `start`; replace it. `CommonSnapshotScene.swift` and `CommonIntegrationScenes.swift` are complete as declarations; `CommonSnapshotRunner.swift` is the placeholder to fill.
- `scripts/bundle.sh` calls `scripts/make-icon.sh` only when `build/AppIcon.icns` is missing.

## Acceptance

Run on Command Line Tools 26.6 (Swift 6.3.3) after deleting `.build` and `build`, once on the tree as it was about to be committed and once more on the last commit; the build time in the first line is that of the first run.

| Command | Result | Final line |
| --- | --- | --- |
| `scripts/build.sh` | exit 0; the log contains no line with "warning" or "error" | `Build complete! (37.78s)` |
| `scripts/test.sh` | exit 0; no "warning" in the log | `test.sh: OK (26 tests)` |
| `scripts/bundle.sh && codesign --verify build/Referee.app` | exit 0; no "warning" in the log of the release build | `Built build/Referee.app` (`codesign --verify` prints nothing) |
| `git status --porcelain \| wc -l` | | `0` |

Also run: `"$(swift build --show-bin-path)"/Referee --ui-snapshot <dir>` exits with 1 (placeholder runner); the app started through its binary stays up with one window on screen (560 × 392 points, the welcome window with its title bar); `referee-cli` exits with 2; `scripts/make-icon.sh` writes `build/AppIcon.icns`, and the 1024-pixel PNG was looked at.
