# Human in the Loop: brand

The app called Referee becomes **Human in the Loop**. This file is the spec the rename pass applies: the name, the
mark and icon, the palette, the type, the changes to the app's look and words, and every occurrence of the old name
with its decision. The idea behind all of it: the AI drafts, the human decides; the referee stays in the loop.

Already in the tree: `Sources/RefereeUI/Common/CommonBrand.swift` (the tokens), `CommonBrandMark.swift` (the mark in
SwiftUI), their tests, `scripts/make-icon.sh` (the icon), and the files of this folder.

## 1. Decisions at a glance

| Topic | Decision |
| --- | --- |
| Name | **Human in the Loop**, everywhere a person reads the app's name. No short form. |
| Tagline | **AI drafts. You referee.** |
| Descriptor | A PDF reader for refereeing papers with AI |
| Mark | The bead: a loop open at the upper right, closed by a dot. The loop is not complete until the human is in it. |
| Icon | The mark in near-white on an indigo rounded square; a flat `.icns` shaped to the macOS template |
| Brand colour | Indigo, on the mark and the icon only. Controls keep the system accent colour. |
| Type | System fonts. Wordmark: "Human" and "Loop" in SF Pro Semibold, "in the" in New York Italic. |
| In the app | Welcome window, About panel and Help header carry the brand; review windows do not |
| Motion | None |
| Internal names | Modules, targets, `local.referee.app`, the Keychain service, the log subsystem, `REFEREE_*` and `referee-cli` stay |

## 2. Name

| Form | Text | Used for |
| --- | --- | --- |
| Display name | `Human in the Loop` (`CommonBrand.name`) | The menu bar (`CFBundleName`), Finder and the Dock (the `.app`'s file name, `CFBundleDisplayName`), the About panel, window titles, menu items, the README's title, any sentence that must name the program |
| Wordmark | Human *in the* Loop (section 5) | The welcome window, the Help window's header, the README hero, `wordmark.svg`. Never below 20 pt. |
| Token | `HumanInTheLoop` (`CommonBrand.token`) | Where a space cannot go: the User-Agent product token. Not a short form; never shown in the UI. |
| In running text | `the app` | A sentence in which the app acts. Never the name as the subject: "Human in the Loop stops the run" reads as if a person stopped it. |
| Former name | `Referee` (`CommonBrand.formerName`) | Only the folder migration (7.2) and a release note |

- **No short form.** The full name fits the menu bar. Apple suggests 15 characters for `CFBundleName`; Apple's own
  System Information and Bluetooth File Exchange are longer. "HITL" is machine-learning jargon the referees who use
  the app do not say: never write it.
- **The role word stays.** "referee" and "referee report" mean the person and the document: the prompts' `Referee:`
  speaker label, "Referee report" as the export title and file name, "referee comments", "the referee's stance" all stay.
- **Tagline:** `AI drafts. You referee.` (`CommonBrand.tagline`). It uses the role word as a verb, keeps the old
  name's meaning, and says who does what.
- **Descriptor:** `A PDF reader for refereeing papers with AI` (`CommonBrand.descriptor`). It carries "reader"; use
  it in the About panel and the README's first sentence.

## 3. Mark and icon

### Concepts

Three concepts, each drawn as a macOS icon at 1024 px and checked at 32 and 16 px on light and dark backgrounds
(`concepts/`; `concepts/concepts-compared.png` puts them side by side).

| Concept | Verdict |
| --- | --- |
| **A, the bead:** a loop with a human mark (`concept-a-bead-*.png`) | **Chosen.** It is the name drawn: a loop that only the dot, the human, completes. Two large, simple shapes are what macOS 26 gives Liquid Glass and separates into layers. It stays a loop and a dot at 16 px. It also works as a one-colour glyph at 16 pt in the UI. |
| A with the gap at the top (`concept-a-variant-top-gap-sizes.png`) | Rejected: it reads as a power button. |
| **B, the margin loop:** a page with a passage circled (`concept-b-page-*.png`) | Literal and clear at 256 px. Below 64 px it is a white slip with a blob, one more document icon next to Preview and Pages. |
| **C, the nib:** a pen closing the loop (`concept-c-nib-*.png`) | Charming at 256 px. Below 64 px the nib turns into an arrowhead and the mark reads as Reload. |

### Geometry

Units: the icon's 1024-unit canvas (rounded square 824 units at 100 units of margin), the glyph's 640-unit canvas,
the tile's 824-unit canvas. The same numbers are in `make-icon.sh` and `CommonBrandMark.Geometry`; a test checks they agree.

| | Regular | Small |
| --- | --- | --- |
| Used | Icon from 64 px; glyph from 34 pt; tile from 44 pt | Icon at 16 and 32 px; smaller glyphs and tiles |
| Loop radius (centre line) | 250 | 236 |
| Loop width, round ends | 92 | 124 |
| Dot diameter | 136 | 161 |
| Space between the dot and each end | 28 | 68 (1 px at 16 px) |
| Gap | Centred at −45° (upper right) | the same |
| Rounded square | 824 at 100; corner radius 185.4 with continuous corners (smoothing 0.6) | the same |

### Icon colours

| Layer | Colour |
| --- | --- |
| Rounded square | Linear gradient, top `#454CC2` to bottom `#1E2266` |
| Loop | `#E8EBFF` at 92%: a cool white with a little indigo showing through |
| Dot | `#FFF5E8`: a warm white, the most solid thing on the icon |

### What Apple's guidelines say, and what follows for an `.icns` built without Xcode

Read on developer.apple.com: the Human Interface Guidelines' "App icons" page (format guidance updated October
2026), "Adopting Liquid Glass ▸ App icons", "Creating your app icon using Icon Composer", and the WWDC25 sessions
"Say hello to the new look of app icons" and "Create icons with Icon Composer".

- **Shape and grid:** macOS icons are laid out on a 1024 × 1024 px square. The system masks every icon to its rounded
  rectangle ("Keep primary content centered to avoid truncation"). The grids are in Apple Design Resources' templates;
  the HIG page gives no margins in numbers.
- **Depth:** an icon is a background layer and one or more foreground layers. The system adds Liquid Glass:
  specular highlights, refraction, translucency and shadows. Do not draw in drop shadows, bevels, blurs or glows.
  Prefer large, simple shapes with clear edges; avoid thin lines and text.
- **Appearances:** default, dark, clear and tinted, light and dark. "The system automatically generates variants you
  don't provide."
- **Icons not in the layered format:** a bitmap icon is accepted. "The system attempts to segment your icon,
  isolating the foreground elements from the background to create an icon with two layers", and gives Liquid Glass
  only to foreground layers "that feature large, simple shapes". Existing Mac icons "similarly shaped as our rounded
  rectangle … automatically get masked or extended to fit into the template". For irregular ones "the system removes
  any drop shadows and then auto-scales the artwork into our rounded rectangle canvas", and they "receive a
  system-provided background".
- **What follows:** Icon Composer's `.icon` needs Xcode's `actool`, which is not installed, so the app ships a flat
  `.icns`. `make-icon.sh` therefore:
  - fills the template's rounded rectangle exactly, so the system masks the icon rather than setting it on a grey
    background. The numbers are the macOS template's as quoted on Apple's developer forums: 824 px at 100 px of
    margin, corner radius 185.4, continuous corners;
  - draws no shadow and no highlight; the system adds its own, and a drawn shadow outside the shape would be cut or doubled;
  - keeps one opaque background and one foreground of two large shapes in near-white, so that segmentation finds the
    mark and the dark, clear and tinted variants keep it; no text, no thin lines;
  - draws each of the ten iconset images at its own pixel size, with the small geometry at 16 and 32 px
    (`icon-sizes.png` shows them as built).
- **Not verifiable here:** how macOS 26 renders the dark, clear and tinted variants of this `.icns`. Check it once by
  eye after installing: System Settings ▸ Appearance ▸ Icon & widget style, Dark, then Tinted; look at the Dock.
- **With Xcode one day:** make an Icon Composer file from `app-icon.svg`'s two layers (gradient; loop and dot) and
  let it replace the `.icns`.

### Files

| File | What |
| --- | --- |
| `logo.svg` | The mark, 640 units; ink, paper in dark mode (`prefers-color-scheme`) |
| `wordmark.svg` | The mark and the name, live text in the system fonts (no glyph outlines of Apple's fonts are embedded) |
| `app-icon.svg` | The icon at 1024 units, for reference and a future Icon Composer file |
| `icon-1024.png`, `icon-sizes.png` | The built icon, and its iconset at every size on light and dark |
| `readme-hero.png`, `readme-hero-dark.png` | Icon, wordmark and tagline; 1325 × 400 px (2x), 105 KB each, transparent |
| `concepts/` | The three concepts and the comparison |

## 4. Palette

| Token (`CommonBrand`) | sRGB | Where | Never |
| --- | --- | --- | --- |
| `ink` | `#23285E` | The glyph in the light appearance; the wordmark in documents | Text, controls, tags or highlights in the app |
| `paper` | `#F4F1EA` | The glyph in the dark appearance | the same |
| `mark` | ink, or paper in dark | `CommonBrandMark(style: .glyph)` | |
| `indigoTop`, `indigoBottom` | `#454CC2`, `#1E2266` | The icon, `CommonBrandMark(style: .tile)` | the same |
| `tileLoop`, `tileDot` | `#E8EBFF` at 92%, `#FFF5E8` | The mark on the icon and the tile | the same |

**With the semantic colours.** Pending yellow, approved green, rejected grey, own blue, question purple, the kind
colours (major red, minor brown, question purple, strength teal), local green and remote orange keep every hue they
have, and keep it alone:

- the brand appears only in the welcome window, the About panel, the Help header and the icon, never in a review window;
- the brand's indigo (hue 235°–237°) is at least 15° from every semantic colour in both appearances
  (`theBrandsIndigoIsNotTheHueOfAnythingThatCarriesAMeaning`). The nearest, own blue at 211°, is 24° away, and much
  lighter.

**Controls keep the system accent colour.** No `.tint(…)`, no `AccentColor` and no `NSApp` appearance override:

- the accent is the user's choice, and a Mac app that overrides it feels foreign;
- macOS 26 tints its Liquid Glass controls with it;
- a brand tint would compete with the semantic colours the triage depends on. The selected card's accent outline
  (plan §9.3) in indigo would sit 24° from own blue and blur "selected" with "yours".

## 5. Typography

System fonts only.

| Use | Font |
| --- | --- |
| Wordmark nouns, "Human" and "Loop" | SF Pro Semibold (`.system(size:weight: .semibold)`), tracking −1% (−0.01 em), `.primary` |
| Wordmark connective, "in the" | New York Italic Regular (`.system(size: size × 1.04, weight: .regular, design: .serif).italic()`), no tracking, `.secondary`. The 4% evens out New York's smaller x-height. |
| Wordmark sizes | 24 pt in the welcome window (200 pt wide), 20 pt in the Help header. Below 20 pt, the name is plain text in the context's font (menus, window titles). |
| Tagline | SF Pro Regular, `.secondary`: `.title3` (15 pt) in the welcome window, `.callout` in the Help header |
| Everything else | Unchanged: plan §9.10's fonts in `Theme` |
| Documents | The same faces; ink, or paper on dark, with "in the" and the tagline at 62% opacity |

`CommonBrand.wordmark(size:)` returns the wordmark as an `AttributedString`, so `Text(CommonBrand.wordmark(size: 24))`
follows the appearance by itself.

## 6. The brand in the app

### 6.1 Welcome window: `ShellWelcomeView.swift`, `ShellWindowManager.swift`

- The window (680 × 420) and the left column (250 pt, padding 20) keep their sizes.
- Window title: `CommonBrand.welcomeItemTitle` ("Welcome to Human in the Loop"), with `window.titleVisibility = .hidden`.
  The title still serves the Window menu, Mission Control and VoiceOver; the wordmark is the only name on screen.
- **Left column**, centred, `VStack(spacing: 14)`, top to bottom:
  1. Spacer.
  2. `CommonBrandMark(size: 72, style: .tile)`. It replaces `ShellAppGlyph` (84 pt), which is deleted with its struct.
  3. `VStack(spacing: 6)`: `Text(CommonBrand.wordmark(size: 24)).fixedSize()`, then
     `Text(CommonBrand.tagline).font(.title3).foregroundStyle(.secondary)`. They replace `Text("Referee")` and the
     line "Read a manuscript, triage AI comments, write the report.".
  4. "Open PDF…", "or drop a PDF on this window" and D5's first-run block: unchanged.
  5. Spacer, then the provider line: unchanged.
- **Right column on first run** (no recent reviews). It replaces the clock and "No reviews yet. Open a PDF to start one.":
  - header "How it works" (`.headline`, where "Recent reviews" sits);
  - three rows, 14 pt apart, 16 pt side padding. Each is `HStack(alignment: .firstTextBaseline, spacing: 10)`: an
    SF Symbol in `.title3`, `.secondary`, 22 pt wide, then `.callout` text that wraps:

    | Symbol | Text |
    | --- | --- |
    | `doc.text.magnifyingglass` | The AI reads the paper and drafts comments in the sidebar. |
    | `person.crop.circle.badge.checkmark` | You approve, reject, discuss or edit each one, with single keys. |
    | `doc.richtext` | The report is drafted from the comments you approved, for you to edit. |

  - 8 pt below, `.caption`, `.secondary`: "Nothing reaches the report until you approve it."
  - With recent reviews the column is unchanged ("Recent reviews" and D26's rows).
- **Verify:** scenes `welcome` and `design-welcome-first-run`, light and dark.

### 6.2 About panel: `ShellMainMenu.swift`, `ShellAppDelegate.swift`

- "About Human in the Loop" calls a new `shellShowAbout(_:)` on the app delegate instead of the bare selector:

  ```swift
  NSApp.orderFrontStandardAboutPanel(options: [
      .applicationName: CommonBrand.name,
      .applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0",
      .version: "",                    // no "(0.1.0)" build number after the version
      .credits: credits,               // centred: the tagline in 13 pt semibold labelColor, then on its own line
  ])                                   // the descriptor with a full stop, in 11 pt secondaryLabelColor
  ```

- The icon comes from the bundle. No copyright line: `NSHumanReadableCopyright` stays unset.
- Optional, for `scripts/run.sh` builds, which have no bundle icon: when `Bundle.main.bundleIdentifier` is nil, set
  `NSApp.applicationIconImage` to an `ImageRenderer` image of `CommonBrandMark(size: 103, style: .tile)` in a
  128 × 128 frame, the icon's margin. The Dock and the About panel then show the mark.
- **Verify:** by hand (the About panel is a system window).

### 6.3 Help window: `ShellHelpView.swift`, `ShellWindowManager.swift`

- Title: `CommonBrand.helpItemTitle` ("Human in the Loop Help").
- A header above "Keys for triage": `HStack(spacing: 12)` with `CommonBrandMark(size: 36)` and a
  `VStack(alignment: .leading, spacing: 2)` holding `Text(CommonBrand.wordmark(size: 20)).fixedSize()` and
  `Text(CommonBrand.tagline).font(.callout).foregroundStyle(.secondary)`. Then a `Divider()`.
- The width (460) and everything below stay.

### 6.4 Empty states

The review window's empty states keep the design review's symbols and words (D6 Comments, D35 Chat, D8 Report): the
brand stays out of the working window. Only the welcome window's first run changes (6.1).

### 6.5 Toolbar

Nothing. The review window's toolbar belongs to the paper and its destination; D3 needs the room.

### 6.6 Motion

None. A referee reads for hours: a moving mark would pull the eye from the paper. The app's motion stays functional:
the card scrolled to the top (D7), the pulse of a streaming draft, "Copied" (D16).

### 6.7 Microcopy

- **Who does what.** The AI *reads, drafts, suggests, answers*; the referee *decides, approves, rejects, edits, writes*.
  The AI never decides, reviews for you, knows or thinks.
- **The app is "the app".** Never "I" or "we", and not the name as a subject (section 2). The name appears in
  titles, menus, the About panel and Help, and where a person must know which program, such as "saved by a newer
  version of Human in the Loop".
- **Plain and exact.** Name the provider and the destination when text leaves the Mac; numbers as digits; "·" between
  facts; no exclamation marks, no emoji, no "magic", "smart", "powerful" or "seamless".
- **macOS case.** Title Case for buttons and menu items; sentence case for descriptions, help tags and empty states.

## 7. Rename plan

Applied on `main` in phase 2: `docs/contract-notes/step5-brand.md` lists the rename as applied, with current line numbers. The line numbers below are those of the branch point (`c1c6ee3`), and two decisions changed when the rename was applied (7.1 and 7.2).

### 7.1 Bundle: `scripts/bundle.sh`

| Line | Now | Becomes |
| --- | --- | --- |
| 5–6 | `--product Referee`, `…/Referee` | Unchanged: the SwiftPM product keeps its name |
| 7 | `APP="build/Referee.app"` | `APP="build/Human in the Loop.app"`. A former `build/Referee.app` is never touched: it may be running. The user deletes it. |
| 9 | `cp "$BIN" "$APP/Contents/MacOS/Referee"` | `…/Contents/MacOS/Human in the Loop` |
| 12 | comment "Help ▸ Referee Help" | "Help ▸ Human in the Loop Help" |
| 17 | `CFBundleIdentifier` `local.referee.app` | **Unchanged** |
| 18 | `CFBundleName` `Referee` | `Human in the Loop` |
| 19 | `CFBundleDisplayName` `Referee` | `Human in the Loop` |
| 20 | `CFBundleExecutable` `Referee` | `Human in the Loop`, as Apple names its own executables after the app, so crash reports and Console show the name. `ps -c` and `top` cut process names at 16 characters ("Human in the Loo"), which only developers see. |
| 40 | `strings -a "$APP/Contents/MacOS/Referee"` | The new executable's path, quoted |

`make-icon.sh` keeps its contract. `bundle.sh` runs it when `build/AppIcon.icns` is missing or older than the script, so a checkout that still has the old "R" icon gets the new one.

### 7.2 Data and cache folders: `Sources/Persistence/AppPaths.swift`

| Line | Now | Becomes |
| --- | --- | --- |
| 13 | `Application Support/Referee` | `Application Support/Human in the Loop` |
| 19 | `Caches/Referee` | `Caches/Human in the Loop` |
| 8, 10, 16 | doc comments naming the folders | the new names |

**Migration**, once per launch, before any store opens (`LiveDependencies.make`, before `FileSettingsStore`). It
runs only when `REFEREE_HOME` is unset and not in snapshot mode. For each pair, data and caches:

1. If the new folder exists, do nothing: never merge, never touch the old one.
2. Else, if another copy with the app's identifier is running (a former Referee.app has the same one), use the old folder for this launch, so that it is not moved from under that copy; a later launch moves it.
3. Else, if the old folder exists, move it with `FileManager.moveItem`, a rename within `~/Library` that is atomic and
   instant.
4. If the move fails, log `paths.migrate.failed` and use the old folder for this launch, so no review seems lost.
   The next launch tries again.

As applied: `AppPaths.directoriesMovingFormerFolders(environment:otherCopyRunning:applicationSupport:caches:)` takes the two
Library folders as parameters, so that tests run it in a temporary folder; `moveFormerFolder(_:to:otherCopyRunning:)` is
the rule for one folder. Nothing inside needs rewriting: sessions are found by file fingerprint,
and the downloaded PDFs by hash, under the folder in use. The Keychain item is not in the folder.

### 7.3 What the app sends or writes

| File:line | Now | Becomes |
| --- | --- | --- |
| `Sources/ScholarKit/ServiceRequests.swift:44` | User-Agent `Referee/<version>` (Crossref, OpenAlex, PDF downloads via `PDFDownloader.swift:22`) | `HumanInTheLoop/<version>`, followed as now by `(mailto:…)` when the user set an address; doc comments at lines 4 and 42 |
| `Sources/ScholarKit/ServiceRequests.swift:51` | the version is read only when the bundle is `local.referee.app` | Unchanged |
| `Sources/ReviewEngine/DebugDump.swift:27` | header `Referee debug transcript` | `Human in the Loop debug transcript` |
| `Sources/RefereeUI/Common/CommonSnapshotRunner.swift:40, 47, 52, 62` | messages prefixed `Referee:` | prefixed `ui-snapshot:`, the mode that prints them |
| `CommonSnapshotRunner.swift:270` (and the comment at 12) | `usage: Referee --ui-snapshot …` | Unchanged: it names the SwiftPM executable that `scripts/snapshots.sh` runs |
| `CommonSnapshotRunner.swift:124`, `136` | snapshot window titles `"Referee"` | `CommonBrand.name` (review window without a fixture), `CommonBrand.welcomeItemTitle` (welcome) |

### 7.4 Words in the app

| File:line | Now | Becomes |
| --- | --- | --- |
| `Shell/ShellMainMenu.swift:51` | `NSMenu(title: "Referee")` | `CommonBrand.name` |
| `ShellMainMenu.swift:52` | "About Referee" (bare selector) | `CommonBrand.aboutItemTitle`, calling `shellShowAbout(_:)` (6.2) |
| `ShellMainMenu.swift:58` | "Hide Referee" | `CommonBrand.hideItemTitle` |
| `ShellMainMenu.swift:62` | "Quit Referee" | `CommonBrand.quitItemTitle` |
| `ShellMainMenu.swift:142` | "Welcome to Referee" | `CommonBrand.welcomeItemTitle` |
| `ShellMainMenu.swift:150` | "Referee Help" | `CommonBrand.helpItemTitle` |
| `Shell/ShellWindowManager.swift:214` | welcome window title "Referee" | `CommonBrand.welcomeItemTitle`, title hidden (6.1) |
| `ShellWindowManager.swift:230` | "Referee Help" | `CommonBrand.helpItemTitle` |
| `Shell/ShellWelcomeView.swift:63–72` | `ShellAppGlyph`, `Text("Referee")`, the old subtitle | Mark, wordmark and tagline (6.1); delete `ShellAppGlyph` (214–228) |
| `Shell/ShellSettingsPrivacy.swift:21` | "Command-line tools are agents: Referee switches…" | "… agents: the app switches…" |
| `ShellSettingsPrivacy.swift:35` | "…, Referee says what will be sent and asks." | "…, the app says what will be sent and asks." |
| `Shell/ShellSettingsPrompts.swift:34` | "…quick questions Referee came with" | "…quick questions the app came with" |
| `Shell/ShellSettingsProviders.swift:373` | "…the copy Referee finds…" | "…the copy the app finds…" |
| `ShellSettingsProviders.swift:430` | "The options Referee needs for safety…" | "The options the app needs for safety…" |
| `RefereeCore/Settings.swift:108` | "…a newer version of Referee (format…" | "…a newer version of Human in the Loop (format…" |
| `ScholarKit/ReferenceLookup.swift:144` | "…an answer Referee could not read." | "…an answer the app could not read." |
| `CLIProviders/CLIProvider.swift:71` | "…so Referee cannot run it safely" | "…so the app cannot run it safely" |
| `CLIProvider.swift:74` | "…which Referee needs in order to run it safely" | "…which the app needs in order to run it safely" |
| `CLIProviders/AntigravityAdapter.swift:15` | "…: Referee stops the run if it uses one." | "…: the app stops the run if it uses one." |
| `CLIProviders/GrokBuildAdapter.swift:16` | "…; Referee deletes the local copy…" | "…; the app deletes the local copy…" |
| `GrokBuildAdapter.swift:191` | "…; Referee speaks version 1" | "…; the app speaks version 1" |
| `TestSupport/SnapshotSupport.swift:46, 78, 83` | the snapshot copies of the three CLI texts | Same changes as their originals |
| `Shell/ShellAppDelegate.swift:28`, `ShellHelpView.swift:4`, `ShellWindowManager.swift:225` | comments naming `Referee.app`, "Referee Help" | The new names |
| `AppCore/Export/ExportPrinter.swift:9`, `Sidebar/SidebarReportExport.swift:48` | "Referee report" | **Unchanged**: the role word |
| `ReviewEngine/PromptBuilder.swift:123, 134, 249, 257` | `Referee:` speaker label | **Unchanged**: the role word, in the prompt format |

### 7.5 README.md

| Line | Becomes |
| --- | --- |
| 1 | The hero, centred, then the text (see below) |
| 3 | "**Human in the Loop** is a PDF reader for refereeing papers with AI. The manuscript sits…" (rest unchanged) |
| 36, 37, 40, 44, 248 | `build/Human in the Loop.app`, quoted in commands: `open "build/Human in the Loop.app"`; `ditto "build/Human in the Loop.app" "/Applications/Human in the Loop.app"`; `open -a "build/Human in the Loop.app" paper.pdf`. Add to 40: "Delete an old Referee.app: both carry the identifier local.referee.app, and macOS may open the old one." |
| 50 | "when you first start the app" |
| 53 | "Help ▸ Human in the Loop Help" |
| 108 (×2), 117, 119, 121 (×2), 125, 129, 150, 152 (×3), 160 (×2), 197, 203, 220 | "Referee" → "the app" ("The app" at the start of a sentence) |
| 154 | `~/Library/Application Support/Human in the Loop/sessions/`, `~/Library/Caches/Human in the Loop/papers/`; "outside the app's control"; "The app never modifies your PDF". Add: "A first launch after the rename moves the folders of Referee here." |
| 172 | "whether Human in the Loop may read the Keychain item "local.referee.app"" (macOS names the app here); "the app refuses to save…" |
| 177, 181 | certificate `Human in the Loop Local Signing`; add "(a certificate made under the old name keeps working: pass its name)" |
| 265 | `~/Library/Application Support/Human in the Loop` |
| 81, 100, 148, 216, 227–228, 235, 244–245, 257 | **Unchanged**: "referees" (the role word), `local.referee.app`, `referee-cli`, `Sources/RefereeCore`, `REFEREE_*` |

The head of the README:

```html
<h1 align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/brand/readme-hero-dark.png">
    <img src="docs/brand/readme-hero.png" alt="Human in the Loop" width="662">
  </picture>
</h1>
```

The README copied into the app (`bundle.sh`) shows the alt text in place of the picture.

### 7.6 Tests to update with the strings

| Test file:line | Change |
| --- | --- |
| `RefereeUITests/Shell/ShellAppTests.swift:25, 27, 45, 48` | The menu titles of 7.4 |
| `RefereeUITests/Shell/ShellScenesTests.swift:80–81` | The example path `…/Human in the Loop` |
| `RefereeUITests/Shell/ShellTestSupport.swift:31` | Antigravity's note, "the app stops…" |
| `PersistenceTests/AppPathsTests.swift:25–28` | The new folder names; add migration tests (moves, never merges, falls back when the move fails) |
| `ScholarKitTests/ScholarKitTextTests.swift:133–134`, `ScholarKitPDFTests.swift:31`, `ScholarKitCrossrefTests.swift:29, 52, 55, 69`, `ScholarKitHostTests.swift:42`, `ScholarKitLiveTests.swift:9` (comment) | `HumanInTheLoop/0.1.0` |
| `ScholarKitTests/ScholarKitContractTests.swift:26` | "…an answer the app could not read." |
| `CLIProvidersTests/CLIResolverTests.swift:168`, `CLIDescriptorTests.swift:30, 33` | "the app" in the CLI texts |
| `AppCoreTests/Export/ExportPDFTests.swift:54, 59`, `ExportWordTests.swift:59`, `SidebarReportFactsTests.swift:121`, `ReviewEngineTests/ReplyTests.swift:100, 103, 128, 146`, `CommonSnapshotRunnerTests.swift:31, 38` | **Unchanged**: the role word, and the SwiftPM executable as `argv[0]` |

### 7.7 Unchanged and internal

These change nothing a person sees. Changing the first three would orphan the API keys in the Keychain and the
saved settings.

| What | Where |
| --- | --- |
| Bundle identifier `local.referee.app` | `bundle.sh:17`; `ServiceRequests.swift:51` |
| Keychain service `local.referee.app` | `LLMKit/KeychainSecretStore.swift:22` |
| Log subsystem `local.referee.app` | `RefereeCore/Support.swift:73`; README 148 |
| Settings notification `local.referee.app.settingsDidChange` | `AppCore/SettingsModel.swift:21` |
| Modules and targets: `RefereeCore`, `RefereeUI`, `Referee`, `referee-cli`, the test targets; types `RefereeError`, `RefereePDFView` | `Package.swift`, `Sources/`, `scripts/run.sh`, `scripts/snapshots.sh`, `scripts/bundle.sh:5–6` |
| Environment variables `REFEREE_*` | `Composition/LiveDependencies.swift`, `CLIProviders`, `referee-cli`, the README |
| Window frame names `Referee.Settings`, `Referee.Review.<hash>` (renaming loses saved frames) | `ShellWindowManager.swift:189`, `ShellReviewWindowController.swift:43` |
| Menu identifier `Referee.OpenRecent` | `ShellMainMenu.swift:13` |
| PDF annotation names `referee:` | `Reader/ReaderHighlightController.swift:19–20` |
| Temporary names `referee-cli-`, `referee-export-`, `referee-snapshot-`; thread names `referee.cli.*` | `CLIWorkspace.swift:7`, `ExportPrinter.swift:55`, `CommonSnapshotRunner.swift:57`, `CLIProcess.swift:105, 107`, `StdinWriter.swift:27` |
| Grok's `clientInfo` name `referee` (pinned by the fake CLI's fixtures) | `GrokBuildAdapter.swift:123` |
| Test-only header `X-Referee-Stub-Scope` | `TestSupport/StubURLProtocol.swift:64` |
| `plan.md`, `docs/` | The build's history. Update only plan §9.1's menu table and §4.2's folder names. |

**Count** (`grep -E '(^|[^A-Za-z_]|\\n)Referee([^A-Za-z_]|$)'`): 126 lines carry the old name, in `Sources/` (54), the
scripts (13), the README (25) and the tests (34). **98 change:**

- 42 in `Sources/` (7.2–7.4);
- 7 in `bundle.sh` (7.1);
- all 25 in the README (7.5);
- 24 in the tests (7.6).

**28 stay:** the role word, the SwiftPM product, saved-state keys and the snapshot usage line. Add the lower-case
internal names of 7.7.

## 8. Regenerating the files

`scripts/brand/render.sh` redraws everything here from the numbers above:

- `make-icon.sh` draws the icon;
- `concepts.swift` draws `concepts/`;
- `docs.swift` writes the SVGs, `icon-sizes.png` and the hero PNGs.

It needs only `swift` and `iconutil`. `CommonBrandTests` checks the tokens, the geometry, the colours in both
appearances, the distance from the semantic hues, the wordmark's width in the welcome column, and that
`make-icon.sh` draws the same mark.
