# Step 5b — Reader

Notes of the Reader agent of step 5b (`docs/design-review.md`, "Implementation split"), on branch `s5/reader`, cut from `main` at `c1c6ee3`. Read by the integrator who merges the three branches and does the docs pass. Everything changed lives in `Sources/RefereeUI/Reader/` and `Tests/RefereeUITests/Reader/`, plus this file. No other file was touched; no session fixture was added (the new scenes use `sample.json` or no session).

## Items

| Item | Done as | Where |
| --- | --- | --- |
| D14 selection bar steps aside | Done, with one case added (below) | `ReaderSelectionBar.swift` (view and `ReaderSelectionBarState`), `ReaderController.swift`, `ReaderPane.swift` |
| D15 citation card | Done as written | `ReaderCitationCard.swift`, `ReaderCitationText.swift` (`ReaderCardActions`) |
| D23 References list | Done as written; the filter's matching rule decided (below) | `ReaderReferencesList.swift`, `ReaderCitationText.swift`, `ReaderController.swift` |
| D2 selection bar's field | Done; also for Send and × | `ReaderSelectionBar.swift` |
| D22 citation card | Done as written | `ReaderCitationCard.swift` |
| D16 tokens | "Open access" is `CommonTag("Open access", color: .green)`; Copy's feedback uses `Theme.feedbackDuration`. The Reader shows no other tag | `ReaderCitationCard.swift`, `ReaderSelectionBar.swift` |
| D27 viewer toolbar (P3) | Done; the keys stay in the content (below) | `ReaderReferenceViewerView.swift` |
| D29 find dims highlights (P3) | Done as written | `ReaderHighlightPlan.swift`, `ReaderController.swift`, `ReaderHighlightController.swift` |

No item was deferred.

### D14

1. The bar is not shown for a selection whose result is in the sidebar: an own comment being written on it (`model.composing?.selection`), a conversation about it (`anchor?.spans == selection.spans`), and, **added**, an own comment (`origin == .user`) whose anchor has the selection's spans. Reason for the addition: after Save, `composing` is nil and the selection stays, so with the two written cases the bar comes back over the passage at once, which the item's own sentence ("a selection that already has its result in the sidebar") rules out. An AI comment does not count: a referee may select a highlighted passage precisely to ask about it. Cancel brings the bar back (nothing was made). As for a conversation in the written rule, this holds while the comment exists: selecting exactly that passage again later (the same spans, as a triple-click may give) shows no bar; a selection a little longer or shorter does.
2. Passages are compared by their spans, also for `composing` (the item writes `composing?.selection == selection`): `beginComposingComment()` captures the selection when N is pressed, possibly before its rectangles have arrived, and the whole values would then never be equal.
3. Copy: the button reads `Label("Copied", systemImage: "checkmark")` for `Theme.feedbackDuration`, then the bar steps aside until the selection changes (to another passage or to none; reselecting after a click elsewhere brings it back).
4. Comment's tooltip: "Write your own comment on this passage (N)".
5. How: the 200 ms settle moved from the overlay's `.task(id:)` into `ReaderSelectionBarState`, which the controller feeds with every change of `model.selection`; `ReaderController.selectionBarSelection` is the selection the overlay draws the bar for. So unit tests and scenes can check the rule, and Copy's timing is the controller's, not a view's (a bar scrolled out of sight does not lose it). `copySelection(_:to:)` takes the pasteboard, so tests and scenes never write to the referee's clipboard.

### D15

- After a lookup returns, its result comes first for every status: the record (title `.body.weight(.semibold)` 3 lines; "authors · year · venue" `.caption` secondary 2 lines; "Open access" and "year differs: …"), or "No match in Crossref or OpenAlex." with "Common for working papers and books." (`.caption`, secondary), or "Lookup failed: {reason}" with Retry. Then the reference as printed, `.caption`, secondary, 2 lines, the whole of it in the tooltip. Before the lookup returns: the printed reference first (4 lines) with the spinner, as before.
- Buttons (`ReaderCardActions`, pure, tested): Open PDF (a non-blank open-access address), Open in Browser (landing page, DOI or the entry's URL) and Copy DOI only when they can act; then Search Google Scholar and Show in References, always, Show in References last. Two rows: the link buttons (left out when none can act), then the search and Show in References. The first of Open PDF, Open in Browser and Search Google Scholar is `.borderedProminent`, the others `.bordered`. A card without an entry offers Search Google Scholar alone, prominent.
- The "Open access" tag and Open PDF follow the same rule (a non-blank address).
- The References list's icon for a reference nobody knows has the same text as its tooltip: "No match in Crossref or OpenAlex." (the test the item names pinned "No match found" there).
- Added: Copy DOI reads "Copied" for `Theme.feedbackDuration`, as the bar's Copy does (D16's feedback token; the item does not mention it).

### D23

- The field: `TextField` with prompt "Filter references", `.roundedBorder`, small, a leading `magnifyingglass`; under it the count, `.caption`, secondary: "9 references", "4 of 9 references" while filtering ("1 reference" when the list has one).
- The matching rule (decided): every word typed must occur in the reference as printed **or in the row's heading**, ignoring case and diacritics. Foundation's diacritic folding leaves "ø" as it is, so letters without a decomposition are spelled in plain Latin first (ø, æ, œ, ß, ł, đ, ð, þ, ı, ħ): "sorensen" finds "Sørensen". The heading counts so that what the row shows can be typed ("Acemoglu et al.").
- The filter lives in the navigator's state: it stays when the tab changes. "Show in References" clears it when it hides that entry. Esc in the field clears it and gives the keyboard back to the window (as D2 does for the other fields). Nothing matching: "No reference contains these words." Filtering sends nothing; a lookup still happens only on a click.
- Rows: the heading (`ReaderCitationText.entryHeading`) in `.callout.weight(.medium)`, the printed reference in `Theme.metadataFont`, secondary, 2 lines; the status icon on the left as before.

### D2 (the bar's field)

Return, Esc, Send and × all end asking and call `NSApp.keyWindow?.makeFirstResponder(nil)`: the field leaves the window in all four cases, so all four give the keyboard back (the item names Return and Esc).

### D27

- Toolbar, at the trailing end: a `ControlGroup` with Zoom Out (`minus.magnifyingglass`) and Zoom In (`plus.magnifyingglass`), "Fit Width", the page count as text ("2 pages", on no glass: `sharedBackgroundVisibility(.hidden)`), "Find" (`magnifyingglass`) and "Open in Preview" (`arrow.up.forward.app`), the last two with title and icon. All disabled until the file is shown; the count appears once it is.
- Keys unchanged (⌘−, ⌘+, ⌘0, ⌘F, ⌘G, ⇧⌘G), but they stay on buttons in the content that are not seen (as ⌘G and ⇧⌘G already were); the toolbar's buttons name them in their tooltips. Reason: the `reference-viewer` scene presses the keys through `window.performKeyEquivalent`, which goes through the content view; the toolbar's items live in their own hosting views outside it, and nothing showed that a shortcut there would be found the same way. The scene's ⌘+ and ⌘0 check passes.
- Open in Preview: `NSWorkspace.urlForApplication(withBundleIdentifier: "com.apple.Preview")`, then `open(_:withApplicationAt:configuration:completionHandler:)`; the default PDF application when Preview cannot be found. The viewer itself still never writes the file.

### D29

While `finder.isVisible`, every highlight of the plan (comments of every state and conversation passages) has 40% of its alpha (`ReaderHighlightPlan.findDimming`), the dashed frame of a fuzzy anchor included; pending 0.35 becomes 0.14, a selected 0.60 becomes 0.24. They return when the bar closes. The 0.8 s flash of a reveal is not dimmed.

## Commands

Run on Command Line Tools 26.6, on a machine shared with the Sidebar and Shell builds, at commit `67f3486` (the last code commit; the commit after it adds this file only). The snapshot runs wrote their pictures to a scratch folder outside the repository (`--out`), so nothing under `build/` or in the tree changed.

| Command | Result | Final line |
| --- | --- | --- |
| `scripts/build.sh` | exit 0; no line with "warning:" or "error:" | `Build complete! (9.20s)` |
| `scripts/test.sh --filter RefereeUITests` | exit 0; no warning; 186 tests (173 at step 5a, 13 new) | `test.sh: OK (186 tests)` |
| `scripts/test.sh` (everything, once) | exit 0; no warning; 1004 tests in 138 suites (991 at step 5a, 13 new); `LLMKitLiveOllamaTests` ran, with its one 16-token prompt to the local Ollama server, and passed; skipped visibly: real Keychain, live reference services, the delivery experiment, the CLI smoke prompt, and the two real-paper tests (this worktree's `Fixtures/private` holds no PDF) | `test.sh: OK (1004 tests)` |
| `scripts/snapshots.sh` | exit 0; 50 scenes, each `"nonBlank":true,"failures":[]` | `…/welcome.png` (the script lists the PNGs) |
| `scripts/snapshots.sh --dark` | exit 0; 50 scenes, each `"nonBlank":true,"failures":[]` | `…/welcome.png` |
| `scripts/snapshots.sh --size 1000x640` | exit 0; 50 scenes, each `"nonBlank":true,"failures":[]`; no window grew | `…/welcome.png` |
| `git status --porcelain \| wc -l` | after the last commit | `0` |

On the way, after the first code commit (`cdfd86d`), the same three snapshot runs passed too (exit 0, 50 scenes each). No test outside the Reader failed at any run. No network request went anywhere but the local Ollama server, and only from `LLMKitLiveOllamaTests`; no AI command-line tool was run; nothing was installed.

## Scenes

Every scene of this branch passes in light, `--dark` and `--size 1000x640` (50 scenes: step 5a's 46 and the four new ones, each `"nonBlank":true,"failures":[]`). Pictures that changed, and the four new scenes:

- `reader-selection`: as before: the bar over "As shown by Acemoglu et al. [2011],". `verify` adds: the bar is shown for the selection (nothing was done with it).
- `reader-citation`: the card "Acemoglu et al. [2011]": the resolved title, "Acemoglu, Dahleh, Lobel, Ozdaglar · 2011", "Open access" green on a green tint, the reference as printed in two lines, then Open PDF and Open in Browser, then Search Google Scholar and Show in References; Copy DOI is gone (no DOI). `verify` adds: Open PDF prominent, those four buttons only. The prominent fill cannot be seen: snapshot windows are drawn inactive.
- `check-citation-click`: the same card, opened by the hit-test click; passes as before (no overlay covers the mention).
- `reader-references`: the filter field and "9 references" above the list; rows headed "Acemoglu et al. (2011)", "Avery and Zemsky (1998)", "Banerjee (1992)" (marked, its card at the top), …, "Smith and Sørensen (2000)", each over two lines of the printed reference. `verify` adds the count, the first heading and no filter.
- `reference-viewer`: no bar in the content; the toolbar holds zoom out and in, Fit Width, "2 pages", Find and Open in Preview; the thumbnails and the page start right under it. `verify` adds: a toolbar with "Find" and "Open in Preview" among at least five items, and the PDF's top edge at the toolbar's; ⌘+ and ⌘0 still work.
- `design-citation-states`: the three cards, now on a blank of the page's white: "Kogan (2020)" with "Lookup failed: Crossref is busy; try again in a minute." and Retry, the printed reference, Search Google Scholar and Show in References only; "Osborne and Rubinstein (1994)" with "No match in Crossref or OpenAlex." / "Common for working papers and books.", the printed reference, the same two buttons; "[14]" with "No entry of the reference list matches this citation." and Search Google Scholar. The contents now come from `ReaderCardContent.make`, the overlay's own path, from the `CitationLookup` the model would hold (see "Contract problems", 2). `verify` adds each card's lookup status and buttons.
- `design-selection-asked` (new, D14): `ay_nolinks.pdf`, the abstract's last sentence selected as a drag selects it, the bar up, then a question about it: the Chat tab with the conversation, the purple passage, no bar. `verify`: the selection settled (the bar was due), it is still the model's and the PDF's, a conversation has its spans, and the bar is not shown.
- `design-selection-copied` (new, D14): the same passage, Copy pressed: the bar reads "✓ Copied" (captured 0.5 s after the copy, inside the 1.5 s of feedback). `verify`: the scene's own pasteboard holds the passage; within 3 s "Copied" goes and the bar steps aside while the passage stays selected.
- `design-references-filter` (new, D23): `ay_links.pdf`, References, "learning" typed: "4 of 9 references", rows Acemoglu et al. (2011), Kogan (2020), Lee (2021), Smith and Sørensen (2000). `verify`: the count, the four headings, and no lookup made.
- `design-find-with-comments` (new, D29): `ay_nolinks.pdf` with `sample.json`, "Table 2" found ("1 of 3"): the orange match inside the pale pending passage of lines 13–14, the green fuzzy passage (lines 5–7, its dashed frame faint too) and the blue own passage (lines 15–16) at 40%. `verify`: every highlight dimmed, no fill above 0.15; after closing the bar, none dimmed and the fills back (0.35 for pending).
- The Sidebar's scenes that D14 names: `sidebar-chat` and `design-compose-from-selection` show no bar over the passage any more (their `verify` is the Sidebar's; `design-selection-asked` checks the rule in a scene of mine).
- Unchanged pictures: `reader-highlights`, `reader-find` (a paper without comments), `reader-ruler`, `design-find-no-matches`, `placeholder`, `check-document-loaded`, `check-triage-keys`.

## Contract problems

1. **With the sidebar hidden, the bar's Comment and Ask AI change nothing on screen, and the bar now steps aside.** The bar calls `model.beginComposingComment()` or `model.ask(…)`; the composing card or the conversation then sits in a hidden inspector. The key monitor shows the sidebar for N, but the bar cannot: the inspector's visibility is the Shell's (`ShellReviewWindowState.showSidebar`), which the Reader does not reach (§9.1: panes never reach into the shell). Before D14 the bar at least stayed. *Suggested:* the Shell shows the sidebar when `model.composing` becomes non-nil or a conversation is added (or a `UIActions.showSidebar` for panes). Nothing was changed outside the Reader.
2. **No scene can put the model into a failed or not-found lookup.** The snapshot graph's `FakeResolver` resolves every entry (TestSupport, read-only), and the overlay shows one card at a time, so `design-citation-states` still draws its three cards itself. It is the real card view with the content the overlay would make (`ReaderCardContent.make` from a `CitationLookup` value and the paper's index), but not reached through the model. *Suggested, for whoever owns TestSupport:* let `FakeResolver` answer `.failed` or `.notFound` for entries whose text carries a marker (or for chosen entry ids); the scene could then click a mention and show the real overlay.

## For the docs pass

What `README.md` and plan §9 (and §7.3, §7.6, §7.7, §8.6, which §9 points to) describe and this step changed:

- **Selection bar** (README "Middle: the PDF"; §9.5): once the passage has been asked about or commented on (while the comment is written and after it is saved), the bar steps aside, and it does not cover a passage that has a conversation or an own comment when that passage is selected again; the passage stays selected. After Copy it reads "Copied" for 1.5 s, then steps aside until the selection changes. Comment's tooltip: "Write your own comment on this passage (N)". Return or Esc in the "Ask about this passage…" field gives the keyboard back, so J and K work again.
- **Citation card** (README "Middle: the PDF"; §8.6, §9.5, §9.9's "Citation card" row): the record first (title; "authors · year · venue"; "Open access" as a green tag; "year differs: …"), then the reference as printed in two lines (whole in the tooltip); before the lookup returns, the printed reference with a spinner. Buttons: Open PDF, Open in Browser, Copy DOI only when they can act (hidden, not disabled); Search Google Scholar always; Show in References last; the first of Open PDF, Open in Browser and Search Google Scholar is the prominent one. Copy DOI reads "Copied". Not found: "No match in Crossref or OpenAlex." and "Common for working papers and books." (§9.9 says "No match found"). Failed: "Lookup failed: {reason}" with Retry, then Search Google Scholar (prominent) and Show in References. For VoiceOver the card is "Citation {heading}".
- **README "Troubleshooting"**: 'A citation card says "No match found"' becomes '… says "No match in Crossref or OpenAlex."'; the card itself now adds that this is common for working papers and books.
- **References tab** (README "Left: the navigator"; §7.6): a "Filter references" field with a count ("9 references", "3 of 9 references"); every word typed must appear in the reference or its heading, case and accents ignored ("sorensen" finds "Sørensen"); Esc clears it; nothing is sent while filtering. Each row is headed "Surname et al. (2011)" over two lines of the reference as printed. The icon of a reference nobody knows has the tooltip "No match in Crossref or OpenAlex.". "Show in References" clears a filter that hides the entry.
- **Find** (README "⌘F finds text"; §7.3's highlight table, §7.6): while the find bar is open, comment and question highlights are drawn at 40% of their alpha, so the matches stand out; they return when it closes.
- **Reference viewer** (§7.7; README's "Open PDF … in a viewer window"): its controls are in the window's toolbar: zoom out and in, Fit Width, the page count, Find, and Open in Preview (opens the downloaded PDF in Preview). Keys unchanged: ⌘−, ⌘+, ⌘0, ⌘F, ⌘G, ⇧⌘G.
- No key of the triage keymap changed in the Reader.

## Manual checks

What a snapshot cannot show, for a pass in the app:

1. D2: select text, Ask AI, type, Return: the question goes to the Chat tab and J selects the next comment (the field gave the keyboard back). Again with Esc in the field: the field closes, J works, a second Esc clears the selection.
2. D14: select a passage, Comment: the bar goes while the comment is written; Save: it stays away (the passage has its own comment now; selecting exactly that passage again shows no bar either, a slightly different selection does). Cancel instead of Save: the bar comes back at once. Copy: "Copied", then the bar goes until another selection; paste elsewhere: the passage without margin numbers. With the sidebar hidden, Comment and Ask AI show nothing (contract problem 1).
3. D15: the prominent button's accent fill in an active window; Open PDF downloads and opens the viewer; Copy DOI reads "Copied" and puts the DOI on the clipboard; Retry on a failed lookup (needs a real failure, for instance with the network off).
4. D22: VoiceOver on a citation card reads "Citation …" and reaches each button.
5. D23: typing in the filter narrows the list as you type; Esc clears it and J works again; a click on a row still looks the entry up (the icon appears); "Show in References" from a card with a filter that hides the entry clears it and scrolls to it.
6. D27: in a viewer window, the toolbar's buttons; ⌘−, ⌘+, ⌘0, ⌘F, ⌘G, ⇧⌘G; Open in Preview opens the file in Preview; at a narrow width the items move into the toolbar's overflow menu.
7. D29: ⌘F in a paper with comments: the highlights go faint; Done or Esc: they return.
