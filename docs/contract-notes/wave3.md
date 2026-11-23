# Wave 3 — Final integration

Notes of the Wave 3 integrator (`plan.md` §11.5, work package WP13), on `main`. Read by the coordinator and by the UI designer who comes next. Every plan change named here has a row in Appendix G.7.

## Merge

`wp/9-reader`, `wp/10-sidebar` and `wp/11-shell` were merged into `main` (`c593a0d`) with `git merge --no-ff`, in that order. No conflict: the three branches touched disjoint paths. `scripts/build.sh` after each merge: exit 0, no warning. `scripts/test.sh` after the last: `test.sh: OK (976 tests)`, the count of the coordinator's trial merge. `scripts/snapshots.sh` then failed one scene of 27, `reader-citation` ("the click did not open the card"), as in the trial.

## Why `reader-citation` failed, and the fix

Measured, not guessed: a probe in the scene printed the view `window.contentView.hitTest` found at the mention, and a map of every point of the PDF column. At the moment `prepare` ran, every point over the PDF hit the detail column's `NSHostingView`, never PDFKit's page view, and the view at the PDF's centre was an `NSProgressIndicator`. Taking the Shell's document-state overlay out of `ReviewWindowView` made every point hit `PDFPageView` again, and the scene passed.

The cause is timing, not geometry. `ReviewSessionModel.open(url:)` sets `paper` early (the reader shows the PDF at once) and `phase = .ready` last, in the same turn of the run loop in which it returns. The snapshot runner called `prepare` straight after `open` returned. SwiftUI applies an observed change on the window's next layout pass, so the window still showed the document as loading: the Shell's "Opening ay_links.pdf…" panel, a full-size view with a background, lay over the PDF and took the click. In WP9's worktree the placeholder window had no such overlay, so the same click reached the PDF. Neither the toolbar, the full-size content view, the banner nor the coordinates were involved: the point was right, and `mouseDown` would have worked.

The fix is in the runner (`CommonSnapshotRunner.swift`), whose contract is that `prepare` "can use the PDF view at once" (§10.1 step 2): after the display document is shown it calls `window.contentView?.layoutSubtreeIfNeeded()` once, which applies SwiftUI's pending changes. Measured three times: before the call the centre hits `NSProgressIndicator`, after it `PDFPageView`. With the call removed again, `reader-citation` and `check-citation-click` both fail; with it, both pass. The app itself is not affected: a person cannot click within the same turn of the run loop in which the document became ready, and while the panel is up it is meant to cover the PDF.

## The coordinator's decisions, as applied

| # | Decision | What was done |
| --- | --- | --- |
| a | `ReviewSessionModel.dismissCitationLookup()` | Closes the card and nothing else, and forgets a lookup under way so its card does not come back. `dismissTransientUI()` uses it as its first step. The Reader's `dismissCitationCard()` calls it; the workaround (calling `dismissTransientUI()` only while a card was open) is gone. Test: `dismissingTheCitationLookupClosesTheCardAndNothingElse` (AppCore) |
| b | `ReaderController.dismissFind() -> Bool` | Public, in §11.3. Esc's order, stated in §9.4: the consent card ("no"), the destination menu, then the model's transient UI (citation card, new comment, editor, open thread), then the find bar, then the selection. The find bar comes after the card, the editors and the thread because the referee keeps it open on purpose while stepping through matches, and before the selection because clearing the selection is what Esc does when nothing else is open. The Shell's key monitor does it in `ShellReviewWindowController.dismiss(model:reader:)`, since `TriageKeymap.apply` takes the model only. Tests: `ShellEscapeAndMenuTests` (two) |
| c | `addUserComment(…, suggestion: String? = nil)` | Between `body` and `anchoredTo`, so every existing call compiles; a blank suggestion is none, as in `editComment`. The Sidebar's composing card has the suggestion editor and passes it. A.9 and §9.3. Test: `anOwnCommentKeepsItsSuggestion` |
| d | `SettingsModel.flushPendingSave()` public | The window manager's `flushAll()` calls it on terminate; the 0.75 s wait and the time stamp of the last settings change are gone. A.9 and §9.1 |
| e | Provider availability in the window | Left out of v1: "No AI provider" means no provider configured, and an Ollama that is not running shows "Local · gemma4:e4b" until a job fails with its banner. Stated under the table of §9.7. For the design pass: if wanted, an `activeProviderAvailability` refreshed with the plan, at the cost of a request (HTTP) or a process run (CLI) each time |
| f | Scenes reaching view state through `NSHostingController.rootView` | The runner keeps `NSHostingController(rootView:)` on the bare view; §10.1 step 2 says so and names the scenes that depend on it |
| g | README in the bundle | `scripts/bundle.sh` copies `README.md` to `Contents/Resources/README.md` (the plan's printed copy in §3.4 is identical to the file, checked with `cmp`). Help ▸ Referee Help already looked there first; its comment and §9.1 say so |
| h | The Wave 2 rules | In §3.7. Checked on the merged tree: every top-level non-private declaration of `RefereeUI` and `RefereeUITests` starts with its area or is a name the plan prints (Common keeps Wave 0's `Snapshot…`, `Theme`, `UIActions`); the only extensions on others' types are `View.sidebarCardChrome` and file-private members; no conformance; suites prefixed; the one new session fixture is `sidebar-states.json`. `Sources/` had one `preconditionFailure` (LLMKit's `Endpoint.resolve`, for an adapter's own URL literal); it now throws `.invalidRequest`. The `#filePath` of `TestSupport`'s `Fixtures.root` stays (debug builds only, §3.6) and is the rule's one stated exception. A new test, `IntegrationTreeTests.noSourceFileUsesTheFilePathOrATrap`, checks every tracked Swift file under `Sources/` |
| i | The "for Wave 3" items of the three notes | Below |

### The "for Wave 3" items

- **The menu and the reference viewer.** Measured in a scratch process of its own (no input to any other app): a menu item that matches a key takes it even while it is disabled (`NSMenu.performKeyEquivalent` returned true and nothing ran), and with such an item in the main menu `NSApp.sendEvent(⌘F)` never reached a SwiftUI window's own ⌘F shortcut, while with the item removed it did. So WP9's fear was real: the Shell's Find and zoom items would have taken ⌘F, ⌘G, ⇧⌘G, ⌘+, ⌘−, ⌘0 from a reference viewer. Now these items (`ShellReaderMenuItem`) carry their keys only while a review window is key: the application delegate re-evaluates on every `didBecomeKey`/`didResignKey`, a moment after AppKit has settled the key window. Tests: the menu no longer takes those keys when they are out, and gets them back (`theReaderKeysAreInTheMenuOnlyWhileAReviewWindowIsKey`); the `reference-viewer` scene's `verify` presses ⌘+ and ⌘0 in the viewer's window and sees it zoom in and fit the width again.
- **One navigator toggle.** There is one: the Shell's toolbar button. `NavigatorPane` brings none (it has the Pages | Outline | References control), and `NavigationSplitView` adds none in a window made around `NSHostingController` (WP11's finding). Seen in every review picture at 1280 × 800 and 1000 × 640, light and dark. The View menu's Hide/Show Navigator (⌃⌘S) drives the same state.
- **The discussion scene under the real toolbar.** It fits at 1280 × 800: the card of comment A, its thread, the reply field and the proposed revision with Accept and Discard end about 18 points above the window's bottom edge, with the next card's top just showing. At 1000 × 640 the revision box is below the fold and the list scrolls, as a list should.
- **The highlight one glyph short before glued margin digits.** Fixed: small and contained. The character before glued digits has a box that PDFKit makes implausible, so the measurement stopped at the glyph before it. `PDFPaperService.rects(for:in:)` (highlights and selections only) now adds that glyph back, as wide as the mean of the last eight plausible glyphs of the range; the line bounds the text cleaning reads, the raw dumps and the rendering are untouched. Measured with `referee-cli anchor`: "The coefficient in" now ends at 498.8 (was 492.9), "…difficult to" at 500.2 (was 493.6; the line's true end is about 499.5); a range that ends at an ordinary character keeps its exact edge. §6.7 says so, §4.3's sample rectangle is remeasured (82.7 → 88.6 wide) and so are the three tests that hold copies of it. Test: `theGlyphBeforeGluedDigitsIsAddedBack`.
- WP11's items: the welcome window, the absolute path and `shell.review.ready` were checked at the launch (below); the menus' enabling as the key window changes could not be watched without driving the screen, and its building blocks are tested (see "For the design pass" for a manual pass). `check-triage-keys` builds its events with US key codes, as WP11 said any code would do.
- WP10's items: the window's minimum height was checked by running every scene at 1000 × 640 (no window grew). The others (a finished comment keeping its draft's id; the ".md" extension in the export panel; keys and focus that a picture cannot show) are in "For the design pass".

## Integration scenes (`Sources/RefereeUI/Common/CommonIntegrationScenes.swift`)

As §10.1 prints them; each runs its steps in `prepare`, so that its picture shows the result, and `verify` reports what did not hold.

- `check-document-loaded`: the window as the app makes it, on `ay_round_nolinks.pdf`; `verify`: `reader.isDocumentLoaded`, the display document has 4 pages, the model is `.ready` with a 4-page paper.
- `check-citation-click`: `ay_links.pdf`; the first rectangle of the mention "Acemoglu et al. [2011" from `model.citations`, its centre converted to window coordinates, `window.contentView.hitTest` there, a left-mouse-down `NSEvent` at that point, the matching mouse-up posted with `NSApp.postEvent(_:atStart: false)`, `mouseDown(with:)` on the hit view. `verify`: the hit view lies inside the PDF view (else the failure names the view that took the click), `citationLookup` left `.idle` with `target == .mention(id)`, and the PDF view's current page is unchanged.
- `check-triage-keys`: the sample session on `ay_nolinks.pdf`; the first two visible comments set to pending, "advance after decision" off through `reloadSettings`, the selection cleared; key-down events J, A, J, R, then U, K, each through `TriageKeymap.intent` and `TriageKeymap.apply`. Checked after the first four (first approved, second rejected and selected) and after the last two (second pending, first selected), and again in `verify`.

`CommonSnapshotRunnerTests.theIntegrationScenesOfSection101` checks their names, kinds, fixtures and that each has a `verify` (Wave 0's expectation that the list is empty is gone).

## Scenes, as seen

`scripts/snapshots.sh`: 30 scenes, exit 0, each `nonBlank` with no failure. Also all 30 with `--dark` and all 30 with `--size 1000x640` (which applies to the review and viewer scenes): exit 0 both, no failure, no window that grew. In every review picture: the toolbar (navigator toggle, title, indicator, Review or Cancel, Report, sidebar toggle), the navigator, the PDF and the sidebar together, nothing clipped, nothing overlapping except the overlays meant to (card, bar, menu, consent).

| Scene | What the default picture shows (1280 × 800 unless the kind has its own size) |
| --- | --- |
| `placeholder` | `ay_round_nolinks.pdf`: the full window, page 1 from its top, four thumbnails, the empty Comments tab |
| `welcome` | The "R" mark, Open PDF…, the drop hint, "AI: Local · mock" with a green dot; two recent reviews with their counts |
| `review-empty` | As `placeholder`; indicator "Local · mock" in green with the laptop |
| `consent` | The window dimmed; "Send this manuscript to Mock?" with the text-only sentence, the "again" line, the policy box, Ask again, Cancel, Send; indicator "Mock (remote) · mock · text only" in orange |
| `banner-error` | Red banner "Review stopped: The provider is overloaded." with Retry and × above the PDF; two comment cards and their yellow highlights |
| `settings-providers` | The four groups; Antigravity selected: orange experimental line, "Needs setup", the install command with Copy, Send Test Prompt; job defaults at the bottom |
| `settings-prompts` | The six prompt sections, Rubric, Quick questions, Output format; the review prompt in its editor |
| `settings-privacy` | Local only, Ask before the first send, the data folder with Reveal in Finder, Delete…, the two summaries |
| `settings-references` | Look up on click, the Crossref email field, downloaded papers "0 bytes", Keep at most 500 MB |
| `settings-advanced` | Margin numbers Automatic, advance after a decision on, rejected highlights off |
| `settings-api-key` | Anthropic API "Ready · Key set", "•••• stored" with Replace and Remove, the model picker, the retention note |
| `review-destination-menu` | The menu under the indicator: five providers with Mock (remote) checked, the plan sentence, the retention note, Local only, Privacy Settings… |
| `review-running` | Spinner, "Reading the paper…", Cancel in the toolbar; two cards and a draft under "Writing…" |
| `reader-highlights` | `ay_nolinks.pdf` page 1: green fuzzy highlight (dashed, selected, stronger) on lines 5–7, yellow on 13–14 now covering "in" whole, blue on 15–16; the selected card outlined |
| `reader-selection` | PDFKit's grey raw selection over lines 11–12; the selection bar just above "As shown by Acemoglu et al. [2011]," |
| `reader-citation` | `ay_links.pdf`: the card "Acemoglu et al. [2011]" above its mention, the reference as printed, the resolved record, five buttons |
| `reader-find` | The find bar under the toolbar: "effect", "1 of 3", the current match orange, the other yellow |
| `reader-references` | References in the navigator: nine entries, three checked, Banerjee marked; its card at the top of the PDF |
| `reader-ruler` | `s1_ruler.pdf` revealed so that the Table 2 sentence is a third of the way down: yellow at ruler 47–49; the card "p. 1, lines 47–49" outlined |
| `reference-viewer` | 900 × 700: two thumbnails, the bar (zoom, Fit Width, "2 pages", Find), the two-column page |
| `sidebar-pending` | Six pending cards from the mock review, the second selected; its passage stronger in the PDF |
| `sidebar-streaming` | Two finished cards, "Writing…" and the draft without buttons; Cancel in the toolbar |
| `sidebar-states` | Approved with ≈ location, similar (two lines), rejected (one grey line), page-only (dotted "p. 3"), unanchored (verify tag, "Passage not found", Attach disabled); all above the bottom edge |
| `sidebar-discussion` | Comment A selected, its thread, the reply field and the proposed revision with Accept and Discard, ending about 18 pt above the bottom |
| `sidebar-editing` | Comment B in the editor: Kind, Category, Title, Comment, Suggestion, Cancel, Save |
| `sidebar-chat` | The Chat tab with one conversation; in the PDF the purple passage and the selection bar over it (the scene leaves the selection set) |
| `sidebar-report` | Venue, Notes, "2 approved comments (1 major, 1 minor)", Regenerate, Revise Voice, Versions, Export ▾, the editor with headings, Style check (3), Recommendation "Major revision" |
| `check-document-loaded` | As `review-empty` |
| `check-citation-click` | As `reader-citation`, the card opened by the hit-test click |
| `check-triage-keys` | `ay_nolinks.pdf` after J, A, J, R, U, K: the first comment approved and selected (its green highlight revealed), the second pending with its proposed revision |

In `--dark` the cards, chips, overlays and editors read well; the PDF page stays white. At 1000 × 640 the three columns are about 208, 412 and 380 pt; the card is placed above its mention and pushed inside the PDF column; the consent card fits; long sidebar content scrolls.

### Seen, not changed (for the design pass)

- Snapshot windows are drawn inactive, so Review, Save, Accept and the like look grey in the pictures.
- With a long indicator ("Mock (remote) · mock · text only") the title in the toolbar is cut ("ay_round_nolinks…."), at both sizes.
- The consent card's "Later questions, discussions and the report…" line wraps well before the card's edge, unlike the paragraph above it.
- The first page's top edge: in most review pictures it sits a few points under the toolbar; in `check-citation-click`, which reads the PDF view's current page before the capture, the page-break margin above page 1 shows. The initial scroll position depends on when PDFKit finishes its layout.
- In `sidebar-chat` the selection bar stays over the passage after the question was asked (the model's selection is still set); whether asking should clear the selection is a design choice.
- `FakeResolver` titles are cut at 30 characters ("Resolved: Acemoglu, D., Dahleh, M. A., L"), by the fake.
- The References list shows a Springer-style entry without spaces ("DekelE,PiccioneM(2000)Sequen-…"): PDFKit's text of a tightly set line (§8.1, R5).

## Decisions beyond the coordinator's list

- The runner's extra layout pass (above), stated in §10.1 step 2.
- The reader items' keys and the glyph completion (above), both in G.7.
- §11.5 step 4 now gives the launch command as it has to be run: an absolute path (Launch Services starts the app in "/"), a throwaway `REFEREE_HOME`, and `REFEREE_NO_KEYCHAIN=1`, which `LiveDependencies` reads from whatever environment it is given, the app's included (§10.6).
- The help window's Esc row names what Esc closes.

## End to end, launch, smoke prompts

- **`scripts/e2e-ollama.sh`** (gemma4:e4b, `ay_round_nolinks.pdf`), after the contract changes: exit 0; plan: text, 1 request; review: 12 comments (including two strengths), 12 anchored exact, 1 request, 78.9 s; the question about the abstract answered; `e2e-ollama.sh: OK (gemma4:e4b on ay_round_nolinks.pdf: 12 comments, 12 anchored, 1 requests, 83 s)`.
- **`scripts/bundle.sh && codesign --verify build/Referee.app`**: exit 0, "valid on disk", "satisfies its Designated Requirement", `Built build/Referee.app`; `Contents/Resources` holds `AppIcon.icns` and `README.md`.
- **The launch**, once: `open -n --env REFEREE_HOME=<a new temporary folder> --env REFEREE_NO_KEYCHAIN=1 build/Referee.app --args <absolute path of Fixtures/pdf/ay_round_nolinks.pdf>`. `/usr/bin/log show --info --last 2m --predicate 'subsystem == "local.referee.app"'` printed `pdf.load.done … pages=int(4) textLayer=bool(true)`, `model.open encrypted=bool(false) pages=int(4)` and `shell.review.ready document=bool(true) pages=int(4)`, within 0.1 s of each other and a second after the launch. The temporary folder then held `settings.json` (first-run defaults: Ollama enabled with `gemma4:e4b` as the review default, nothing remote enabled) and one session. The process was ended with `kill` (found with `pgrep -f` on the bundle's binary) and the folder removed. Nothing of the user's data folder or Keychain was read or written.
- **The bundled binary's snapshot mode**: `build/Referee.app/Contents/MacOS/Referee --ui-snapshot build/snapshots-bundle --scene review-empty` → exit 0, `{"scene":"review-empty","file":"build/snapshots-bundle/review-empty.png","width":2560,"height":1600,"nonBlank":true,"failures":[]}`.
- **Smoke prompts** (§11.6), once: `REFEREE_CLI_SMOKE=1 scripts/test.sh --filter CLIProvidersTests` → `test.sh: OK (92 tests)`; the delivery experiment skipped (its variable not set). Claude Code 2.1.330: "OK", end of turn, 760 input and 44 output tokens. Codex 0.167.0-alpha.3.2 (the ChatGPT app's copy; the resolver passed over `/opt/homebrew/bin/codex`): "OK", end of turn, 12,605 input and 5 output tokens. Antigravity and Grok Build: skipped, not installed. Nothing else was sent to a subscription CLI or a paid API at this step; the network was used for the local Ollama server and these two prompts only.

## Contract problems

None open. Every problem of the three Wave 2 notes is decided above and in Appendix G.7.

## For the design pass

What a designer should look at first, in this order:

1. **The review window's toolbar at 1000 × 640 and with long texts**: the title gives way to the indicator ("ay_round_nolinks…."), and the Review button's running state ("Reading the paper…" with Cancel) sits over the inspector's column.
2. **The sidebar's density**: a pending card with quote, body and suggestion is about 220 pt tall at 380 pt wide, so two cards fill the column at 1280 × 800 and the discussion of one card takes the whole column.
3. **Provider availability in the window** (decision e): "Local · gemma4:e4b" in green while Ollama is not running.
4. **What the pictures cannot show**, for a manual pass in the app: Return and ⌘↩ in the reply and chat fields; ⌘↩ and Esc in the editor (two ⌘↩ owners when an editor and a thread are open); D focusing the reply field; Undo on hover over a rejected line; a lint finding selecting its range; Copy; the export panels keeping ".md"; the menus enabling and the find and zoom keys moving between a review window and a reference viewer as the key window changes.
5. The cosmetic items under "Seen, not changed" above.

## Left for the coordinator

1. The four checks that need the user's accounts are listed in the README ("Checks that need your accounts"): one real review per configured API provider and per installed CLI, the experimental CLIs if installed, and the self-signed identity.
2. Grok Build and Antigravity remain experimental and have never been run against the real programs (neither is installed).
3. WP1's weak spots on real journal-system PDFs (Gate 1, item 3) still wait for files in `Fixtures/private/journal/`; the README tells the user how to add them and what to run.

## Acceptance

Final run, after `rm -rf .build build`: see the table below (filled after the run).
