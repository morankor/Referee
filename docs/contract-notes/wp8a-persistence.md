# WP8a — Persistence and report export

Notes of WP8a (`plan.md` §11.4), for Gate 1 and for the packages that call these stores and the exporter (WP8b now, WP10 and WP11 in Wave 2).

## What exists after this step

| Part | State |
| --- | --- |
| `Sources/Persistence/AppPaths.swift` | Behaviour unchanged from Wave 0 (it already did what §11.3 says); now tested |
| `Sources/Persistence/FileSessionStore.swift` | Real: the files of §4.2–4.5 |
| `Sources/Persistence/FileSettingsStore.swift` | Real: §4.2 and §4.4 |
| `Sources/Persistence/StoreFiles.swift` | Internal: the JSON format, the schema check, the durable write, moving a damaged file aside |
| `Sources/AppCore/Export/` | `ReportExporter` and `PaperSize` real. Internal: `ExportMarkdown` (blocks), `ExportInline` (inline Markdown), `ExportPlainText`, `ExportRichText` (attributed string for Word and PDF), `ExportPrinter` (docx and PDF) |
| Tests | `PersistenceTests` 35 (the 3 Wave 0 smoke tests kept), `AppCoreTests/Export` 30 (plus the 3 Wave 0 smoke tests of `AppCoreTests`) |

No public declaration was added or changed: the surface is that of §11.3.

| Acceptance row | Tests |
| --- | --- |
| store round trip | `SessionStoreTests.aSavedSessionComesBackEqualAndASecondSaveKeepsTheFirstAsTheBackup`, `eachSaveKeepsExactlyOneBackupTheVersionBeforeIt` |
| atomicity | `SessionStoreTests.aFailureBetweenTheTemporaryWriteAndTheRenameLeavesTheOldFileReadable` (a hook throws once session.json.tmp is complete), `aTemporaryFileLeftByACrashIsIgnoredAndReplacedByTheNextSave` |
| corrupt file | `SessionRecoveryTests.garbageInTheSessionFileLoadsTheBackupAndKeepsTheGarbageAside`, `everyKindOfDamageIsTreatedAlike` (5 cases), `aDamagedSessionWithADamagedBackupThrowsCorruptAndKeepsBothAside`, `aDamagedSessionWithoutABackupThrowsCorrupt` |
| versions | `SessionRecoveryTests.aNewerSchemaThrowsAndLeavesTheFileUntouched`, `theSampleOfSection4Point3Decodes`, `aSessionFileWrittenBeforeSimilarToExistedDecodes`; `SettingsStoreTests.aSettingsFileWithoutVerifiedAtDecodes` |
| listing and delete | `SessionStoreTests.threeSessionsGiveThreeSummariesWithTheirCountsNewestFirst`, `deletingASessionRemovesItsWholeFolderAndNothingElse` |
| settings | `SettingsStoreTests.aMissingFileGivesTheDefaultsAndCreatesNothing`, `aFileLackingAProviderGainsItsDefaultsOnLoad`, `keysThisVersionDoesNotKnowAreIgnored` |
| paths | `AppPathsTests` (four tests; environments are passed as dictionaries, nothing is created) |
| export, text | `ExportPlainTextTests.markdownIsTheTextAsItIs`, `theSampleReportLosesOnlyItsHeadingMarks`, `emphasisMarkersAreRemoved`, and nine more |
| export, Word | `ExportWordTests.wordStartsWithPKAndReadsBackWithTheSixHeadingsInBold`, and four more |
| export, PDF ● | `ExportPDFTests.aLongReportHasTextOnEveryPage` (Letter and A4: 7 and 6 pages here; the shortest page, the last Letter page, has 1,265 characters), and four more |

## Decisions

Things the plan left open, decided inside this package's files. Items 1–10 concern the session store, 11–12 the settings store, 13–14 both, 15–23 the export.

1. **A missing session.json with a backup loads the backup.** Once a damaged file has been moved aside, the backup is the latest good version until the next save. Without this, the second opening would start an empty session, and two saves later the good backup would be gone.
2. **Damaged files.** session.json → `session.corrupt-<UTC time>.json`, a damaged backup → `session.corrupt-<UTC time>-backup.json`; the time is ISO 8601 basic (`20261122T183012Z`, no colons, which Finder shows as slashes); a second file in the same second gets `-2`, `-3`…. When both are bad, both are moved aside and `StoreError.corrupt(path:)` names the moved session.json; the next load returns nil, so a fresh session can be saved. An unreadable file (permissions) is not damage: `StoreError.io`, nothing moved.
3. **`save` never replaces a file of a newer schema** (it throws `.newerSchema`), so the empty in-memory session the UI shows for such a file (§4.4) cannot overwrite it even if the model autosaves it. `save` also never keeps a damaged session.json as the backup: it moves it aside first. Cost: one read and JSON parse of the existing file per save.
4. **Durability.** The temporary file is flushed (`FileHandle.synchronize`) before `replaceItemAt` swaps it in. `replaceItemAt(_:withItemAt:backupItemName: "session.json.bak", options: .withoutDeletingBackupItem)` is used when session.json exists, `moveItem` otherwise.
5. **The document key must be a plain folder name**: letters, digits, `-`, `_`, 1–128 characters; anything else is `StoreError.io` from load, save and delete. Otherwise `deleteSession(sha256: "")` would remove the whole sessions folder and `"../x"` would reach outside it. A real hash always passes; a session whose `document.sha256` is something like the §4.3 sample's `"9f2c…"` cannot be saved.
6. **Listing** reads only (renames nothing) and falls back to the backup as load does; it leaves out folders without a session (a `references.json` alone), damaged ones and newer ones. `SessionSummary.id` is the folder name, which equals the hash for every file the store wrote, so `deleteSession(sha256: summary.id)` always reaches the right folder. Newest first, ties by id descending, as `InMemorySessionStore`.
7. **Delete** removes the document's whole folder; a folder that is not there is not an error.
8. **Folders are created with mode 0700**: review data holds quotes from the manuscript (§12.4).
9. **Non-finite numbers** (a rectangle of an empty PDF selection, a score of 0/0) are written as the strings `"Infinity"`, `"-Infinity"`, `"NaN"` and read back as numbers. Without this, one such value would make the whole session impossible to save. Finite values are written as before; otherwise the format is exactly §3.7's.
10. `currentSchemaVersion` is an internal `static let` on both stores: §11.3 prints no public member, and no other target can use it.
11. Missing or unreadable → `DefaultSettings.make()`. Damaged → renamed `settings.corrupt-<UTC time>.json`, defaults. Newer schema → defaults, the file untouched, and `save` throws `.newerSchema` (§4.4: "settings.json follows the same rule"). No backup (§4.2 lists none); the file is written atomically, its folder created when needed.
12. Missing providers are filled in from `DefaultSettings.make().providers` (the nine real ids). Ids this version does not know (`mock` from the snapshot settings, or a future provider) are kept. Unknown keys are ignored on load and dropped by the next save.
13. Log events, with numbers and booleans only (no hash, no path): `persistence.session.newerSchema`, `.damaged`, `.restoredFromBackup`, `.backupDamaged`, `.saveRefusedNewerSchema`, `.damagedBeforeSave`, `.saveFailed`; `persistence.settings.unreadable`, `.newerSchema`, `.damaged`, `.saveRefusedNewerSchema`, `.saveFailed`.
14. The atomicity test injects its failure through one internal initializer, `FileSessionStore(directory:beforeReplacing:)`, reached with `@testable import Persistence` (as `CommonSnapshotRunnerTests` does for `RefereeUI`).
15. **One reading of the Markdown** feeds plain text, Word and PDF, so the three agree. Blocks: ATX and setext headings; paragraphs (a soft line break is a space; two trailing spaces or a backslash make a hard break); numbered (`1.`, `1)`) and bulleted lists, nested by indentation; block quotes; fenced code; thematic breaks. A numbered line interrupts a paragraph only when it starts at 1 (CommonMark), so "…introduced in\n2019. Since then…" stays a paragraph. Inline: `*` and `_` emphasis under CommonMark's flanking rules and rule of three, so `x_i`, `snake_case`, `2 * 3` and `p < 0.05*` keep their characters; code spans; links and images; autolinks; backslash escapes; a few character references. Kept as written: tables, HTML, reference-style links, indented code, strikethrough. The parser is total and bounded (a test feeds it 300 random strings and twelve pathological ones).
16. **Plain text**, beyond §6.10's three rules: a bullet becomes a hyphen and a space; nested items are indented three spaces a level; a link becomes "text (url)" (only the url when the two are equal), an image its alt text; a quote keeps its `>` and the space after it; code keeps its characters (the fences go); thematic breaks are dropped. One blank line between blocks, none between the items of a tight list, one kept between items that had one. The text ends with one line break; empty input gives "".
17. **Word and PDF typography**: Times New Roman 12 pt (then Times, then the system font), which Word has on every system. Headings are bold at 16, 14 and 12 pt by level. Items have a hanging indent and keep their number as written (bullets become "•"). Emphasis is italic, strong emphasis bold, code Courier New. All text is black, so an export made in dark mode still prints black on white. The Word file gets the paper size and the 72-point margins of the PDF.
18. **Anonymity.** A referee report must not name its author. Measured here: the docx's core and app properties are empty, and the PDF's information has only Title, Producer and dates. The title is the neutral "Referee report", set through `NSPrintOperation.jobTitle`. Tests pin the absence of an author in both formats and the PDF's title.
19. **PDF**: §6.10 steps 1–3 as written, plus `lineFragmentPadding = 0` and `textContainerInset = .zero` (the text sits exactly between the margins). An empty report gives a one-page PDF. The temporary file is `referee-export-<UUID>.pdf` in the system's temporary folder, deleted at once; an internal `scratch:` parameter lets a test check that nothing is left.
20. **A4 comes out as 595.28 × 841.89 points**: the printing system snaps 595 × 842 to ISO A4. Letter is exactly 612 × 792. The test compares rounded points, as the row's "595 × 842" allows.
21. `PaperSize.current` goes through an internal `forRegion(_:)` (case-insensitive), so the rule is tested without touching the process's locale.
22. Export failures throw `StoreError.io`, as the Wave 0 placeholder did (contract problem 4).
23. `ExportPDFTests` imports PDFKit to read the PDF back, as the row requires (`PDFDocument(data:)`). Only that test file does; `Sources/AppCore` does not (§2.1).

## Contract problems

1. **The model cannot learn that the backup was loaded** (§4.5 "a banner reports what happened"; A.7 `SessionStoring.loadSession`). The protocol returns a session or throws. The acceptance row wants the backup returned when session.json is garbage, so the store cannot report the recovery at the same time. That is also why `StoreError.corrupt`'s message ("…the previous backup was loaded if available") cannot go with a session.
   *Done here:* the backup is returned without a message, and `persistence.session.restoredFromBackup` is logged. `.corrupt` is thrown only when nothing could be loaded.
   *Suggested:* let `loadSession` report it, for example with a result type that carries an optional notice, or with `func recoveryNotice(sha256:) async -> String?` that the model asks after loading.
2. **Dates do not round-trip below a second** (§3.7, §4.3: `.iso8601` writes whole seconds). A session saved with `Date()` values comes back with truncated dates and is not `==` to what was saved, while `InMemorySessionStore` returns it exactly. Tests written against the fake (WP8b) can therefore assume more than the file store gives.
   *Done here:* nothing needed in this target. The round-trip tests use whole seconds, as the Wave 0 smoke test does.
   *Suggested:* say so in the comment of `SessionStoring`, or have the model round the dates it sets. Writing fractional seconds would need every reader of session files to change its decoder, the snapshot runner's included.
3. **`report_sample.txt` has no emphasis** (WP8a "export, text": "plain text conversion of `report_sample.txt` (headings, numbered lists, emphasis)"). The frozen fixture has headings and numbered lists only.
   *Done here:* the sample's conversion is checked character for character, and emphasis is checked on a variant of it (`ExportPlainTextTests.emphasisMarkersAreRemoved`).
4. **No error type fits an export failure** (§2.5, A.7). The exporter throws `StoreError.io`, so the user reads "Could not read or write review data (the PDF could not be created)." This works; a dedicated case would read better.

## For Gate 1 and Wave 2

- **§6.10's defect did not reproduce here.** On this machine (macOS 26.6.1), three naive set-ups printed text on every page of the long report: a plain `NSTextView(frame:)` followed by `sizeToFit()`; a TextKit 2 view of the full height filled through `textContentStorage`; a plain view of the full height filled through `textStorage`. Each was put in temporarily and reverted. The TextKit 1 construction of §6.10 is kept. The test checks the text of every page, so it would catch the defect if it came back, but no mutation here showed it failing.
- **WP8b: a file of a newer format makes every save throw `.newerSchema`.** For a session, the model should not autosave the empty session it shows, or should at least not raise the error banner again on each autosave. For settings, `SettingsModel.update` gets `.newerSchema` for as long as a newer settings.json is on disk.
- **WP11 (recent reviews):** `listSessions` is newest first; `id` is the hash, and `lastKnownPath` and `fileName` come from the session.
- **The snapshot runner now reaches the real stores.** The settings.json and session.json it writes into a scene's `REFEREE_HOME` are read by the real stores through `LiveDependencies`. The whole suite passes, `IntegrationTests` and `RefereeUITests` included.

## Acceptance

Run on Command Line Tools 26.6 (Swift 6.3.3) at the last commit, after touching every file of this package, with `-j 2` (nine agents share the machine).

| Command | Result | Final line |
| --- | --- | --- |
| `scripts/build.sh -j 2` | exit 0; no line with "warning" or "error" | `Build complete! (7.04s)` |
| `scripts/test.sh -j 2 --filter PersistenceTests` | exit 0; no warning | `test.sh: OK (35 tests)` |
| `scripts/test.sh -j 2 --filter AppCoreTests` | exit 0; no warning | `test.sh: OK (33 tests)` |
| `scripts/test.sh -j 2` | exit 0; no warning, no failure | `test.sh: OK (191 tests)` |
| `git status --porcelain \| wc -l` | | `0` |
