# WP11 — Shell and settings

Notes of the work package "Shell and settings" (`plan.md` §11.4, WP11, Wave 2), on branch `wp/11-shell`, cut from `main` at `c593a0d`. Read by the Wave 3 integrator. In this worktree the Reader and the Sidebar are still Wave 0 placeholders, so every picture below judges the Shell's parts; the whole window is Wave 3's to check.

## What exists after this step

| File (`Sources/RefereeUI/Shell/`) | What it holds |
| --- | --- |
| `ShellAppMain.swift` | `AppMain.run`: the snapshot mode as before, otherwise `NSApplication` with `ShellAppDelegate` |
| `ShellAppDelegate.swift` | Main menu, dependencies and the one `SettingsModel` at launch, `applyFirstRunDefaultsIfNeeded()` once, files from Finder / the Dock / the command line, Open Recent, quit after saving |
| `ShellWindowManager.swift` | One review window per document hash, reference viewers, settings, welcome, help; `reloadSettings` on `.refereeSettingsDidChange`; the `UIActions` closures |
| `ShellReviewWindowController.swift` | Model and reader per window, `attach()` at once, the triage key monitor, the window's menu commands and their validation, Export Report…, Delete Review Data…, close → `model.close()` |
| `ShellMainMenu.swift` | The menus of §9.1, built in code |
| `ShellReviewWindowView.swift` | `ReviewWindowView` (§9.2), the toolbar, the Review button, the document states of §9.9 |
| `ShellDestination.swift`, `ShellDestinationViews.swift` | The indicator's state (§9.7 table) and its view; the destination menu |
| `ShellPlanText.swift`, `ShellFormat.swift` | The plan sentence and the consent card's text; numbers and sizes |
| `ShellConsentCard.swift`, `ShellBannerView.swift` | `ConsentCard` and `BannerView` |
| `ShellWelcomeView.swift` | `WelcomeView` |
| `ShellSettingsRootView.swift`, `ShellSettingsProviders.swift`, `ShellSettingsPrompts.swift`, `ShellSettingsPrivacy.swift`, `ShellProviderStatus.swift` | `SettingsRootView` and its five tabs (Privacy, References and Advanced share a file) |
| `ShellTriageKeymap.swift` | `TriageIntent`, `TriageKeymap` |
| `ShellWindowServices.swift` | The window state, the services the app gives the views (no-ops in the snapshot mode), the settings navigation |
| `ShellHelpView.swift` | Help ▸ Referee Help |
| `ShellScenes.swift` | `placeholder` unchanged, the seven scenes of §10.1 and five more |
| `Tests/RefereeUITests/Shell/` | 50 tests in 6 suites, and their helpers (the target has 68 with Common's and Reader's) |

No file was added to `Fixtures/sessions/`: no Shell scene needs a session.

## Decisions

Where the plan left a choice. Each file also says its own at the top.

**Review window**

1. The `NavigationSplitView`'s own navigator toggle does not appear in a window made around `NSHostingController`, so the Shell puts one in the toolbar (`.navigation` placement). Toolbar, left to right: navigator, title, indicator (principal), Review, Report, sidebar.
2. The Review button shows "Cancel", a spinner and the phase for every job of the review lane: "Reading part 2 of 5…", "Reading the paper…" (one part), "Reading the whole paper…", "Preparing the review…", "Writing the report…", "Revising the report…". Disabled, its tooltip is the plan's blocking reason, else one of "Open a PDF to review it.", "Set up an AI provider in Settings.", "Waiting for your answer about sending the manuscript.", "Working out what a review would send…", "A job is running."
3. Document states over the PDF: "Opening <file>…" with a spinner; "This file could not be opened: <reason>" with Open Another…; with no document, Open PDF…. A file that cannot be read still gets a window that says why.
4. Nothing in the window declares a minimum width: the banner and the overlays are wrapped so that they cannot widen the detail column. The review scenes keep 1280 × 800 and also 1000 × 640 (`--size 1000x640`, run by hand).
5. The banner draws `model.banner` (info blue, warning yellow with an orange icon, error red; Retry → `retryLastFailedJob()`, Open Settings → Settings ▸ Providers, × → `dismissBanner()`). When the model has none, a notice of the Shell's own takes the place: today only a failed export (`exportReport` throws `ExportError`; the model has no banner for it).

**Indicator, destination menu, consent (§9.7)**

6. Text: a local provider is "Local · <model>" (so `mock`, `mock-fail` and `mock-stall` all read "Local · mock"); a subscription CLI its name without the bracketed plan ("Claude Code · default"); any other provider its display name and model ("Mock (remote) · mock"); "default" when no model is chosen. " · text only" is added for a remote provider only once the plan is known; " · experimental" while `verifiedAt` is nil. `REFEREE_DEBUG_DUMP` set and non-empty adds a red "debug dump on" tag. "No AI provider" means `activeProvider == nil`, and a click on it opens Settings ▸ Providers.
7. Plan sentence: through a subscription CLI the destination reads "to <vendor> through <cli>" ("to OpenAI through codex"); the delivery note goes in brackets before the full stop. Token counts are rounded (to the thousand from 10,000, the hundred from 1,000, the ten below) and grouped with commas on every machine; sizes in decimal units ("184 KB", "2.1 MB").
8. The destination menu is drawn in the detail column, under the indicator, and narrows with a narrow column; a click outside it or Esc closes it. Its Local only switch changes the app's settings through the window manager's `SettingsModel` (in the snapshot mode, which has none, only the window's copy).
9. Consent card: the title names the vendor ("Send this manuscript to Anthropic?"); a second line names the provider and model; the plan's warnings follow the "again" line; the journal-policy sentence sits in a tinted box. Send is not the default button, so Return never sends a manuscript; Esc and ⌘. answer "no". While the card is up the window is dimmed and blocked, the destination menu closes, triage keys do nothing and the Review menu items are off.

**Settings (§9.6)**

10. A tab bar of the Shell's own (icon over title) instead of `TabView`; the window's content is a fixed 780 × 560 frame, so no pane can make it grow.
11. Providers is a list and a detail: the list shows every provider with its status light, an "Experimental" tag and its enable switch; the detail shows the full experimental sentence in orange under the name, the status with the hint (commands in back quotes, or a CLI's bare install command, get a Copy button), the key field ("•••• stored", Replace, Remove; `secretErrors` under it), the model picker with refresh, "Show all models" (OpenAI and Gemini only) and Custom…, the path override for CLIs, an Advanced disclosure, Send Test Prompt with its note, and the retention note. Choosing a model also updates the job defaults that name that provider, so the model chosen there is the one a review uses. The job defaults sit in a bar underneath ("None" / "Same as Review").
12. Text fields hand their text over on Return, on leaving the field, and when they disappear; the prompt editors 0.5 s after the last keystroke and on losing focus. "Restore Defaults…" and "Delete…" (all review data) ask first; these confirmations are the only modal UI.
13. Privacy shows the data folder with the home folder written "~"; the two summaries of §12.3 and §12.5 are short enough to fit the pane.
14. A settings scene chooses its tab, and the Providers scene its provider, through the root view's navigation object, reached as `(window.contentViewController as? NSHostingController<SettingsRootView>)?.rootView.navigation`. The window manager passes the same kind of object, so "Privacy Settings…" opens Settings on Privacy.

**Keys and menus (§9.1, §9.4)**

15. Letters count by the character they type (AZERTY's "a" key approves; the key at QWERTY's A, which types "q" there, does not). A key that types a letter of another script (Hebrew, Cyrillic, Greek) counts by its place on a US keyboard, so triage works with any input source. The digits count by their key (top row and keypad), so AZERTY's unshifted "&é"'" work. With Command, Control, Option or Shift held a key has no intent. D, E and N also show the sidebar when it is hidden.
16. The single keys are shown in the Review menu as real key equivalents (A, R, D, E, J, K, N). The key monitor handles them first; the items are enabled only while the review window itself is key, with no sheet over it and no text being edited, so that a letter typed in a field or a sheet stays there. While a sheet is up only the view commands of the window are enabled.
17. View ▸ shows "Hide/Show Navigator" and "Hide/Show Sidebar" rather than "Toggle…"; ⌘= is a hidden alias of Zoom In. Window ▸ Welcome to Referee (⇧⌘1) brings the welcome window back. Help ▸ Referee Help opens a small window with the keys and the commands, and a button for the README when one is found (in the app's resources, or by walking up from the executable to a folder with `README.md` and `Package.swift`).
18. Open Recent is the system's list of recent documents (`NSDocumentController`), with Clear Menu; it is built when it opens, never on a key press.

**Windows and life cycle (§9.1)**

19. A document is known by the SHA-256 of its bytes, read off the main actor before its window is made; opening an open document brings its window forward; the frame is autosaved under the hash. A document reopened while its old window is still closing waits for that window's save.
20. Files given at launch (Finder, Dock, command line) wait until the dependencies exist; with none, the welcome window shows (and logs `shell.welcome.shown`). A welcome window still being prepared is not shown over a document opened meanwhile, and opening a document closes the welcome window.
21. Command-line files are the arguments that are not options and name an existing file, relative paths read from the current folder (`scripts/run.sh` runs from the repository root).
22. Quitting: every window ends its text editing (fields hand over their text), every review saves (`flushPendingSave`), closing ones finish, and the app waits until 0.75 s after the last settings change (see contract problem 1).
23. `UIActions` on every window that hosts panes (review, reference viewer, settings): reference viewer window, Settings, and the browser for `http`/`https` addresses only (addresses can come from a model or a lookup service). The welcome and help windows host no pane and set none.
24. `shell.review.ready` (`pages`, `document`) is logged once the reader shows the document (waiting at most 3 s for it), `shell.review.failed` otherwise; no file name.

**Scenes**

25. `placeholder` is unchanged. The seven scenes of §10.1 follow, then `settings-references`, `settings-advanced` (the two tabs §10.1 does not list), `settings-api-key` (an API provider with a stored key and its model list; the key goes into the snapshot graph's in-memory store), `review-destination-menu` and `review-running`. Every scene has a `verify`. Review scenes wait for the plan before going on; `consent` answers "no" and `review-running` cancels in `verify`, after the capture.
26. The welcome scene replaces the root view the runner made with one whose provider line is the one `SnapshotSupport.settings()` gives ("AI: Local · mock"): `WelcomeView(recent:open:)` knows no provider.

## Contract problems

1. **`SettingsModel.flushPendingSave()` is internal** (Appendix A.9 lists no flush; §9.1 asks the app to flush on terminate). The model saves 0.5 s after the last change, so a setting changed just before ⌘Q would be lost. *Workaround:* the window manager notes the time of every `.refereeSettingsDidChange` and, when quitting, waits until 0.75 s after the last one. *Suggested:* make `flushPendingSave()` public, as on `ReviewSessionModel`.
2. **The window model has no availability of its provider** (§9.7 row "nothing ready"). `ReviewSessionModel` knows the active provider but not whether it is ready, so "No AI provider" can only mean "no usable provider configured"; an Ollama that is not running shows "Local · gemma4:e4b" until a job fails with its banner. *Workaround:* none needed for v1. *Suggested, if wanted:* an `activeProviderAvailability` property refreshed with the plan.
3. **Scenes reach view state through the hosting controller** (Gate 0's warning: `prepare` gets the window and the models only). The settings scenes and `review-destination-menu` read `rootView.navigation` / `rootView.windowState` from `NSHostingController<SettingsRootView>` / `<ReviewWindowView>`. This holds only while the runner makes its windows with `NSHostingController(rootView:)` on the bare view, as it does now; if Wave 3 wraps the root view in a modifier, these scenes fail their `verify` (they do not pass silently).
4. **The app bundle carries no README** (§9.1 Help: "opens README"; `scripts/bundle.sh`, frozen, copies no resources). *Workaround:* the help window shows the keys and offers the README when it finds one, which it does while the app runs from the checkout (`.build/…` or `build/Referee.app`). *Suggested:* Wave 3 copies `README.md` into `Contents/Resources`.

## What I saw in each scene

All at 1280 × 800 points (2560 × 1600 pixels) for review scenes, light appearance, window drawn in its inactive look. `consent`, `banner-error`, `settings-providers`, `settings-privacy`, `welcome` and `review-destination-menu` were also looked at with `--dark`, and the five review scenes at `--size 1000x640`: no clipping, no window that grew.

| Scene | What the PNG shows |
| --- | --- |
| `placeholder` | Three columns: the Navigator placeholder, page 1 of `ay_round_nolinks.pdf` from its top, the Sidebar placeholder; the toolbar with the navigator toggle, the title, "Local · mock" in green with the laptop icon and a chevron, "Review" and "Report" with their words, the sidebar toggle |
| `welcome` | 680 × 420 window: the "R" mark, "Referee", a one-line tagline, "Open PDF…", "or drop a PDF on this window", and at the bottom a green dot with "AI: Local · mock"; on the right "Recent reviews": the two sample reviews with title, file name and date, "12 comments · 3 pending" in orange and "7 comments · report drafted" |
| `review-empty` | As `placeholder`, no banner, nothing over the PDF; `verify`: indicator "Local · mock" green, no comments, Review enabled |
| `consent` | Indicator "Mock (remote) · mock · text only" in orange with a cloud. The window dimmed under the card: "Send this manuscript to Mock?", "Mock (remote) · mock", "The extracted text (4 pages) will be sent to mock.example.org in 1 request (about 900 tokens). Extracted text only: equations and tables may reach the model garbled.", "Later questions, discussions and the report will send it again to the same provider.", the journal-policy sentence in a tinted box, the "Ask again next time" box, Cancel and Send; `verify`: nothing was sent |
| `banner-error` | A red banner across the top of the PDF column: "Review stopped: The provider is overloaded." with Retry and ×; the PDF below it. "Two comments kept" is checked in `verify` against the model (2 comments, the run recorded as failed): the Sidebar here is a placeholder |
| `settings-providers` | The tab bar with Providers selected; the list: API key (Anthropic, xAI green; OpenAI, Gemini yellow), Subscription through an installed CLI (Claude Code green, Codex yellow, Antigravity yellow and Grok Build red, both tagged "Experimental"), Local (Ollama green), Built in (the four mocks); Ollama and the mocks switched on. Detail of Antigravity: the orange warning "Experimental — not yet verified against the real CLI on this machine", "Needs setup · Antigravity is not installed", the install command in a box with Copy, Model "CLI default", Path "Found automatically", Advanced closed, Send Test Prompt with its note, the retention note. The job-defaults bar: Review "Mock", Chat and Report "Same as Review". Nothing clipped |
| `settings-prompts` | Sections on the left (six prompts; Rubric, Quick questions, Output format; Restore Defaults… at the bottom); "Review" with its one-line explanation and the review prompt in an editor that scrolls |
| `settings-privacy` | Sending manuscripts (Local only off, Ask before the first send on, each with a line of explanation); Review data (the data folder, abbreviated in the middle, with Reveal in Finder; Delete all review data with Delete…); What leaves this Mac (the two summaries). Everything inside the window |
| `settings-references` | Lookups ("Look up references only when I click them" on; Crossref contact email, empty, "Optional; gives faster lookups."); Downloaded papers ("0 bytes", Clear disabled; Keep at most 500 MB) |
| `settings-advanced` | Remove margin line numbers: Automatic, "Applies to documents opened afterwards."; Advance to the next comment after a decision (on); Show highlights of rejected comments (off) |
| `settings-api-key` | Anthropic API: "Ready · Key set", "API key •••• stored" with Replace and Remove, "Kept in the Keychain; sent only to api.anthropic.com.", Model "Example Large (example-large)" with refresh and Custom…, "Context window 1,000,000 tokens · reads PDF files" |
| `review-destination-menu` | Under the indicator: "Send this document to" with the four mocks and Ollama (a check at Mock (remote), green laptops for the local ones, an orange cloud for the remote one, each with its destination and model), "What a review sends" with the text-only sentence, the retention note, Local only with its switch, Privacy Settings… |
| `review-running` | The toolbar's right side: a spinner, "Reading the paper…", "Cancel" with a stop icon, Report, the sidebar toggle |

## Outside my files

- The Reader and the Sidebar are placeholders in this worktree, so no picture here shows comments, highlights or the thumbnails; Wave 3 checks the whole window.
- macOS 26's toolbar picks up the colour of what lies under it: with the red banner just below, the toolbar band takes a faint pink. Cosmetic, from the system.
- With a long indicator ("Mock (remote) · mock · text only") the window title in the toolbar is truncated ("ay_round_nolinks....").
- `open -n build/Referee.app --args <pdf>` (§11.5 step 4) needs an absolute path: Launch Services starts the app in "/", so a path relative to the repository finds no file and the welcome window shows instead.
- `SnapshotSupport`'s `claude-cli` row reads "Logged in" where the real adapter says "Logged in · claude <version>". Cosmetic.

## For Wave 3

- The app path (delegate, window manager, window controller, menu) was never run here (only the snapshot mode may be). It compiles, its pure parts are tested (menu table and targets, key map, document hash, command-line files), and an independent read of it found the run-time problems fixed in commit `b625858`. Things worth watching at the launch check: the welcome window at a plain launch, the review window for an absolute path, `shell.review.ready pages=4 document=true` in `/usr/bin/log show --info`, the menus enabling as the key window changes.
- `check-triage-keys` can build its events with any key code: an ASCII character decides the intent.
- If WP9's `NavigatorPane` brings its own toggle, the Shell's toolbar toggle (decision 1) is the one to keep or drop.

## Acceptance

Run at commit `b625858` (this notes file was committed after it; no code changed). The full `scripts/test.sh` ran once.

| Command | Result | Final line |
| --- | --- | --- |
| `scripts/build.sh` | exit 0; no warning | `Build complete! (7.24s)` (incremental) |
| `scripts/test.sh --filter RefereeUITests` | exit 0; no warning | `test.sh: OK (68 tests)` |
| `scripts/snapshots.sh` | exit 0; 13 scenes, each `nonBlank` with `"failures":[]` | `build/snapshots/welcome.png` |
| `scripts/bundle.sh && codesign --verify build/Referee.app` | exit 0; no warning in the release build | `Built build/Referee.app` (`codesign --verify` prints nothing) |
| `build/Referee.app/Contents/MacOS/Referee --ui-snapshot build/snapshots-bundle --scene review-empty` | exit 0 | `{"scene":"review-empty","file":"build/snapshots-bundle/review-empty.png","width":2560,"height":1600,"nonBlank":true,"failures":[]}` |
| `scripts/test.sh` (once) | exit 0; six tests skipped visibly (delivery experiment, smoke prompt, real Keychain, live services, two real-paper tests); the known CoreGraphics notice of WP2's damaged-PDF tests | `test.sh: OK (877 tests)` |
| `git status --porcelain \| wc -l` | after the last commit | `0` |
