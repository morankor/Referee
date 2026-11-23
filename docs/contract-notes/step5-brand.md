# Step 5 — Brand: Human in the Loop

Notes of the brand agent. The user asked: "I want it to be called 'human in the loop' reader. also fashion a modern style sleek logo and vibe". Phase 1 (on `s5/brand`) designed the brand and wrote its spec, `docs/brand/brand.md`. Phase 2 (alone on `main`) merged it, applied the rename and brought the brand into the app. The plan's record is the note at the top of `plan.md` and Appendix G.10.

## Phase 1: the brand (`s5/brand`, commits `92d4713`, `fd48fe1`)

- Three logo concepts, drawn as macOS icons at 1024, 32 and 16 px on light and dark (`docs/brand/concepts/`). Chosen: the bead, a loop open at the upper right and closed by a dot. The page with a circled passage and the pen nib closing the loop did not survive 16 px; the dot at twelve o'clock read as a power button.
- `scripts/make-icon.sh` draws the new icon: each of the ten iconset images at its own pixel size, with a heavier loop and a wider gap at 16 and 32 px, no shadow drawn in.
- `CommonBrand.swift` holds the name's forms, the tagline, the colours and the wordmark; `CommonBrandMark.swift` is the mark in SwiftUI, as a glyph or as the icon's tile. `CommonBrandTests` has 13 tests, one of which checks that the icon script draws the same mark.
- `docs/brand/` holds the spec, the SVGs, the README hero and the sheet of the built icon; `scripts/brand/render.sh` redraws them.
- Apple's macOS 26 icon guidelines, as read, and what they mean for an `.icns` built without Xcode, are in brand.md §3.

## Phase 2: the merge, the rename and the brand in the app (on `main`)

### The merge

`git merge --no-ff s5/brand` on `main` at `5cafe0d` gave `2ee7c50`, with no conflict: the branch touched only its new files and `scripts/make-icon.sh`, which `main` had not changed. After it, `scripts/build.sh` printed no warning (`Build complete! (2.29s)`), and `scripts/test.sh` printed `test.sh: OK (1191 tests)`: the 1178 of `main`, plus the 13 brand tests.

### The rename as applied

The occurrences were counted again on `main` with `grep -E '(^|[^A-Za-z_]|\\n)Referee([^A-Za-z_]|$)'`, against `5cafe0d`. **140 lines carried the old name: 111 changed, 29 stay.**

| Where | Lines | Changed | Stay | New lines that name the former name on purpose |
| --- | --- | --- | --- | --- |
| `Sources/` | 57 | 45 | 12 | 3: `AppPaths.formerFolderName` and its comment, the comment of `LiveDependencies.anotherCopyIsRunning` |
| `scripts/`, `Makefile` | 13 | 7 (`bundle.sh`) | 6: the SwiftPM product `Referee` in `bundle.sh`, `run.sh`, `snapshots.sh` | 2: `bundle.sh`'s header, which leaves `build/Referee.app` alone |
| `README.md` | 34 | 34 | 0 | 2: "The app used to be called Referee." and the note on an existing signing certificate |
| `Tests/` | 36 | 25 | 11: the role word ("Referee report", the prompts' `Referee:` label) and the SwiftPM executable as `argv[0]` | 6: the migration tests' former folders |

What changed, by kind:

- **Menus:** the application menu "Human in the Loop", and in it About, Hide and Quit Human in the Loop; Window ▸ Welcome to Human in the Loop; Help ▸ Human in the Loop Help. These are `ShellMainMenu.swift` lines 51, 52, 58, 62, 143 and 151. About now calls `ShellAppDelegate.shellShowAbout(_:)`.
- **Window titles:**
  - the welcome window: "Welcome to Human in the Loop", the title kept but not shown;
  - the Help window: "Human in the Loop Help";
  - the snapshot runner's welcome window, and its review window when a scene has no PDF.
- **Settings texts,** each now "the app": Privacy (two), Prompts (two help tags), Venues (the reset text and its help tag, step 5's), Providers (the path field's note, the extra arguments' note).
- **Error and status messages:**
  - "This review was saved by a newer version of Human in the Loop", in `Settings.swift` and Appendix A.7, which is still 8 of 8 identical to the files;
  - "… sent an answer the app could not read.";
  - the CLI texts: the missing safety option, the unexpected answer, Grok's protocol version, and Antigravity's and Grok Build's notes, with their snapshot copies in `SnapshotSupport`.
- **The debug transcript:** its first line is "Human in the Loop debug transcript".
- **The snapshot mode's messages:** they begin "ui-snapshot:". The usage line still names the SwiftPM executable, `Referee`, which `scripts/snapshots.sh` runs.
- **The bundle:**
  - `build/Human in the Loop.app`, whose `CFBundleName`, `CFBundleDisplayName` and `CFBundleExecutable` are all "Human in the Loop";
  - the identifier stays `local.referee.app`;
  - the icon is drawn again when `scripts/make-icon.sh` is newer than `build/AppIcon.icns`.
- **The data folders:** `~/Library/Application Support/Human in the Loop` and `~/Library/Caches/Human in the Loop`, through a one-time migration (next section).
- **The User-Agent:** `HumanInTheLoop/<version>`, sent to Crossref, OpenAlex and the PDF downloads.
- **The README:**
  - it opens with the hero in a `<picture>`, the dark version for a dark GitHub, with the alt text "Human in the Loop: AI drafts. You referee.";
  - its first sentence names the app;
  - every "Referee" that meant the app now reads "the app", the new name, or the new paths, quoted;
  - a paragraph on the old name, the old bundle and the folders;
  - the welcome window as it now looks.
- **The plan:**
  - the note at the top and G.10;
  - §9.1 (the menus, the welcome window, the About panel, Help), §9.6 (Venues), §9.7 (the CLI notes) and §9.10 (the brand);
  - §3.3 and §3.4 (the bundle, the printed `bundle.sh`, the icon), §4.2 and §12 (the folders), §8.7 (the User-Agent), §10.1 (the `help` scene);
  - §11.3 (`AppPaths`, the printed Composition), and the bundle commands of §11.4 and §11.5.
- **Unchanged and internal:**
  - module and target names, and the SwiftPM products `Referee` and `referee-cli`;
  - `local.referee.app` as the bundle identifier, Keychain service, log subsystem and settings notification;
  - the `REFEREE_*` variables, the event names (`shell.review.ready`), the window frame names and the menu identifier;
  - the role word "referee"; `docs/contract-notes/` of earlier steps, which record what was run then; the repository.

### The migration of the data folders

`AppPaths.directoriesMovingFormerFolders(environment:otherCopyRunning:applicationSupport:caches:)` runs once at launch, in `LiveDependencies.make`, before any store opens. For each of `Application Support/Referee` and `Caches/Referee` it applies `moveFormerFolder(_:to:otherCopyRunning:)`:

1. If the new folder exists, it is used, and the former one is left as it is: nothing is merged.
2. If neither exists, the new one is used.
3. If only the former exists and another copy of the app is running, the former is used for this launch. This rule was added in phase 2 and is not in the spec. Such a copy is a process with the app's bundle identifier other than this one: a former Referee.app has the same identifier, and the user had one running during this pass. A later launch moves the folder.
4. Otherwise the folder is moved, a rename within the Library. If the move fails, the former folder is used for this launch, and a later launch tries again.

Nothing is ever deleted or copied. Nothing moves when `REFEREE_HOME` is set, which the snapshot mode, the tests and `referee-cli` always set. The running-copy check is made only when a folder would move. `AppPathsTests` runs six new tests on temporary Libraries:

- a move, then a second launch that moves nothing;
- both folders present: neither changes, byte for byte;
- a running copy: nothing moves until a later launch;
- a failed move: the former folder stays in use, untouched;
- nothing to move: nothing created, nothing asked;
- `REFEREE_HOME` set: nothing moves or is asked.

### The brand in the app

- **Welcome window** (brand.md 6.1):
  - the title "Welcome to Human in the Loop", not shown (`WelcomeView.dress`, which the snapshot runner calls too);
  - the tile (`CommonBrandMark(size: 72, style: .tile)`), the wordmark (24 pt, 200 pt wide in the 210 pt column) and the tagline "AI drafts. You referee." (`.title3`, secondary);
  - with no review yet, "How it works" on the right, in three lines with symbols, and "Nothing reaches the report until you approve it.";
  - `ShellAppGlyph` and its "R" are gone.
- **About panel** (6.2):
  - the standard panel with "Human in the Loop" and the version without a build number (`.version: ""`);
  - the credits: the tagline in 13 pt semibold over "A PDF reader for refereeing papers with AI." in 11 pt, secondary;
  - a build without a bundle (`scripts/run.sh`) shows the mark in the panel, and in the Dock (`unbundledIcon()`).
- **Help window** (6.3): the mark at 36 pt, the wordmark at 20 pt and the tagline, then a divider, over the keys.
- **Elsewhere:** nothing. Review windows, the toolbar and the empty states are unchanged, and there is no motion.

### Decisions beyond the spec

1. **The old bundle is never touched.** The spec had `bundle.sh` delete a leftover `build/Referee.app`; the coordinator ruled that out, because the user may be running it, and the user was. **You can delete `build/Referee.app` once it is not running.** Delete an old `Referee.app` in Applications too: it has the same identifier, and macOS might open it for a PDF.
2. **The folders do not move from under a running copy** (rule 3 above).
3. **A `help` scene.** `SnapshotScene.Kind` is public and frozen (§11.3), so the scene puts the Help view into a welcome scene's window, with the Help window's title.
4. **The welcome scenes check the window's title** (`ShellSceneSupport.welcomeWindowIsDressed`).
5. **About is always enabled,** even in the moment before the window manager exists (`validateMenuItem`).

### Scenes

61 scenes: the 60 of `main`, plus `help`. Changed or new in this pass:

- `welcome`: the tile, the wordmark and the tagline over Open PDF… and the drop hint; two recent reviews; the title hidden (`verify`).
- `design-welcome-first-run`: the same column, with Set Up AI Provider…; on the right "How it works", its three lines and the promise.
- `design-welcome-many`: the same column; fourteen recent reviews; the title hidden (`verify`).
- `help` (new): "Human in the Loop Help"; the mark, the wordmark and the tagline; the keys, the commands and Open the README.
- `settings-providers`: Antigravity's note "… the app stops the run if it uses one."; the path field's "… the copy the app finds …".
- `settings-privacy`: "Before a remote provider first receives a manuscript, the app says what will be sent and asks."

The other 55 scenes look as before.

### Acceptance

The runs were made at commit `350fde2` (the rename and the brand), after `rm -rf .build`, so that "no warning" covers every file. The snapshot pictures went to a scratch folder outside the repository (`--out`). This section was committed after the runs; no code changed.

| Command | Result | Final line |
| --- | --- | --- |
| `scripts/build.sh` | exit 0; every module compiled; no line with "warning:" or "error:" | `Build complete! (45.85s)` |
| `scripts/test.sh` | exit 0; no warning. 1200 tests in 154 suites: the 1191 after the merge, plus 9 new (two in `ShellAppTests`, seven in `AppPathsTests`). Four were skipped visibly, as before: the real Keychain, the CLI smoke prompt, the delivery experiment and the live reference services. `LLMKitLiveOllamaTests` ran with its one 16-token prompt to the local Ollama server, and passed | `test.sh: OK (1200 tests)` |
| `scripts/snapshots.sh` (every scene) | exit 0; 61 scenes, each `"nonBlank":true,"failures":[]` | `…/welcome.png` (the script lists the PNGs) |
| `scripts/snapshots.sh --dark` | exit 0; 61 scenes, each clean | `…/welcome.png` |
| `scripts/snapshots.sh --size 1000x640` | exit 0; 61 scenes, each clean; no window grew | `…/welcome.png` |
| `scripts/e2e-ollama.sh` | exit 0. `PLAN sendsPDF=false requests=1 estimatedInputTokens=901 destination=127.0.0.1:11434 local=true model=gemma4:e4b contextWindow=131072`; `SUMMARY comments=16 anchored=15 pageOnly=1 unanchored=0 similar=1 requests=2 status=completed seconds=158.0 model=gemma4:e4b` (the model's answer was cut off once and continued, §6.5) | `e2e-ollama.sh: OK (gemma4:e4b on ay_round_nolinks.pdf: 16 comments, 15 anchored, 2 requests, 163 s, reported model gemma4:e4b)` |
| `scripts/bundle.sh` | exit 0; no warning in the release build. `Built build/AppIcon.icns`: the old "R" icon of this checkout (03:31) was older than `make-icon.sh` (08:14), so the icon was drawn again. `Info.plist: OK`, "valid on disk", "satisfies its Designated Requirement". The bundle holds `Contents/MacOS/Human in the Loop`, the new `AppIcon.icns` (identical to `build/AppIcon.icns`, ten sizes) and `README.md`. `CFBundleName`, `CFBundleDisplayName` and `CFBundleExecutable` are "Human in the Loop", and `CFBundleIdentifier` is `local.referee.app`. `build/Referee.app` was untouched, its time unchanged | `Built build/Human in the Loop.app` |
| `codesign --verify "build/Human in the Loop.app"` | exit 0, nothing printed | — |
| `"build/Human in the Loop.app/Contents/MacOS/Human in the Loop" --ui-snapshot build/snapshots-bundle --scene welcome` | exit 0; the welcome window with the tile, the wordmark and the tagline | `{"scene":"welcome","file":"build/snapshots-bundle/welcome.png","width":1360,"height":904,"nonBlank":true,"failures":[]}` |
| The launch check | See the list below | `shell.review.ready document=bool(true) pages=int(4)` |
| `git status --porcelain \| wc -l` | after the last commit | `0` |

The launch check:

1. `open -n --env REFEREE_HOME=<a new temporary folder> --env REFEREE_NO_KEYCHAIN=1 "build/Human in the Loop.app" --args <the absolute path of Fixtures/pdf/ay_round_nolinks.pdf>`.
2. `pgrep -f "Human in the Loop.app/Contents/MacOS"` found one process, whose command is the bundle's executable.
3. `/usr/bin/log show --info --last 2m --predicate 'subsystem == "local.referee.app"'` showed that process's line: `Human in the Loop: [local.referee.app:app] shell.review.ready document=bool(true) pages=int(4)`. The log names the process "Human in the Loop", in full.
4. `kill <that pid>` ended it.
5. The temporary folder was removed.

The user's `build/Referee.app`, running throughout, was never signalled or touched. With `REFEREE_HOME` set nothing migrated: `~/Library/Application Support/Referee` is where it was, and no "Human in the Loop" folder exists yet. The move happens on the first launch of the new app while the old one is not running.

Pictures looked at:

- in light and dark: `welcome`, `design-welcome-first-run`, `design-welcome-many` and `help`;
- in light: `settings-privacy`, `settings-providers` and `review-empty`, which is unchanged;
- the bundled binary's `welcome`, and the bundled icon.

At 1,000 × 640 the welcome and Help windows have their own size (`--size` applies to review and viewer windows), and each scene passed there too.

Nothing left the Mac except requests to the local Ollama server: the 16-token prompt of `scripts/test.sh`, the end-to-end review and its question, and the launched app's own checks of Ollama on loopback. No AI command-line tool or paid API was used, nothing was installed, and the screen was never driven. The app ran outside `--ui-snapshot` once, for the launch check above. No tracked file holds a home-directory path, a login name or an email address, and `Sources/` has no `#file`, `#filePath`, `fatalError` or any of the `precondition` family; `IntegrationTreeTests` checked both in the full run.
