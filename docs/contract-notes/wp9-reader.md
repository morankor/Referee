# WP9 — Reader UI

Notes of work package WP9 (`plan.md` §11.4, Wave 2), on branch `wp/9-reader`, cut from `main` at `c593a0d`. Read by the Wave 3 integrator. Everything here lives in `Sources/RefereeUI/Reader/` and `Tests/RefereeUITests/Reader/`; no other file was changed, and no session fixture was added (the scenes use `Fixtures/sessions/sample.json`).

## What was built

| File | What it holds |
| --- | --- |
| `ReaderController.swift` | The public controller of §11.3: `attach()` (Wave 0 behaviour kept: idempotent, display document from the paper's bytes), and from then on it follows the model's paper, `readerCommand` and everything the highlights depend on; selections to the model (150 ms debounce, raw); clicks; find and zoom. Internal `ReaderOverlayState` (a geometry counter the overlays read) and `ReaderNavigatorState` (tab, marked entry) |
| `ReaderPDFView.swift` | `RefereePDFView`: `mouseDown(with:)` (citation → card and no `super`; highlight → select and `super`), `mouseDragged`/`mouseUp` of a citation click kept from PDFKit too, `areaOfInterest(forMouse:)` and `areaOfInterest(for:)` (`.linkArea` over citations) |
| `ReaderHighlightPlan.swift` | Pure: comments + filter + selected comment + "show rejected" → `[ReaderHighlight]` (rectangle, style, alpha, colour, owner id, fuzzy) |
| `ReaderHighlightController.swift` | Diffs that list against annotations on the display document; the fuzzy frame; the 0.8 s flash of a reveal |
| `ReaderHitTesting.swift` | Pure: point + highlights + mentions of a page → comment id or mention id; smallest rectangle wins; mentions 2 pt larger |
| `ReaderOverlayPlacement.swift` | Pure: AppKit rectangle (origin bottom left) + view size + overlay size → SwiftUI top-left origin inside the view |
| `ReaderScrolling.swift` | Scrolls a passage one third of the way down (reveal, find); "is it in sight below the find bar" |
| `ReaderFinder.swift`, `ReaderFindBar.swift` | Find (§7.6) for the manuscript and the viewer: `findString`, ≤ 5,000 results, all marked, current one orange, "3 of 17" |
| `ReaderPane.swift` | The public pane: the PDF view with the three overlays (find bar, selection bar, citation card); no minimum width |
| `ReaderSelectionBar.swift`, `ReaderCitationCard.swift`, `ReaderCitationText.swift` | The selection bar (§9.5) and the citation card (§8.6, §9.9); pure texts and addresses of the card and the References list |
| `ReaderNavigatorPane.swift`, `ReaderReferencesList.swift`, `ReaderOutlineList.swift`, `ReaderPDFViewRepresentable.swift` | Navigator: Pages (`PDFThumbnailView`), Outline (hidden when empty), References (status icons, click → `lookUpEntry`); the two `NSViewRepresentable`s |
| `ReaderReferenceViewerView.swift` | `ReferenceViewerView` (§7.7): thumbnails, PDF, its own bar (zoom, fit width, find) |
| `ReaderScenes.swift` | The seven scenes, each with a `verify` |
| Tests (`Tests/RefereeUITests/Reader/`, 46 new + Wave 0's 3) | `ReaderHighlightPlanTests`, `ReaderHitTestingTests`, `ReaderOverlayPlacementTests`, `ReaderCitationTextTests`, `ReaderFinderTests`, `ReaderControllerTests` (a real `PDFView` in a window that is never shown), `ReaderViewerAndScenesTests`, and Wave 0's `ReaderAttachTests`, unchanged |

## Decisions

Where the plan was silent or left a choice. Each source file lists its own at the top.

**Highlights (§7.3)**

1. A comment is highlighted when it passes the sidebar's filter (`model.filter`, as `visibleComments` applies it) and its anchor has rectangles. A conversation's passage (purple, 0.25) is always shown: it is no comment and no filter applies.
2. The reviewer's own comment is blue whatever its status (as `Theme.Highlight.own` says). A rejected AI comment has no highlight unless "Show highlights of rejected comments" is on; then grey 0.15, and 0.60 when selected.
3. Two highlights with exactly the same rectangle are drawn once: the sample session's "similar" pair would otherwise add up to the strength of a selected highlight. Kept: the selected comment's, else own, pending, approved, question, rejected, else the earlier.
4. PDFKit ignores the border of markup annotations (`PDFAnnotation.h`), so a fuzzy anchor's 1-pt dashed border (`Theme.fuzzyBorderDash`) is a second annotation, a square in the hue without fill. Both carry `userName = "referee:" + id`.
5. The selected comment's annotations are added last, so they lie on top. The flash of `.reveal(…, flash: true)` is one underline annotation per rectangle in the accent colour, removed after 0.8 s.

**Clicks (§7.4, §7.5, §8.6)**

6. Highlights and citations are one hit list and the smallest rectangle wins (WP9's "point + rect lists → comment id or mention id"). So a citation inside a highlighted passage is the citation: its rectangle is smaller than the line's, and the click opens the card instead of selecting the comment and letting PDFKit jump to the bibliography. On equal areas a mention wins.
7. Any click in the PDF first closes an open citation card ("a click elsewhere"); a click on a citation then opens the new one. The mouse-down of a citation click never reaches PDFKit, and neither do its drag and mouse-up.
8. The reader closes the card with `model.dismissTransientUI()`, and only while `citationLookup != .idle`: in that state the model's Esc closes the card and nothing else (see contract problem 1).

**Overlays (§7.4, §9.5)**

9. The selection bar sits 6 pt above the first rectangle of the normalised selection, left-aligned with it; below the selection when there is no room above; always inside the pane, 8 pt from its edges. It appears 200 ms after the selection (with its rectangles) settles, for selections of three characters or more.
10. The card sits 6 pt below the mention (all its rectangles on the page of the first), above it when there is no room below, inside the pane; a card from the References list is centred at the top of the pane (below the find bar when that is shown). It is at most as tall as the pane and scrolls inside when its entries need more.
11. **"Dismissed on scroll" is read as "never left floating away from what it belongs to".** The card follows its mention while the PDF scrolls or zooms and closes as soon as the mention leaves the visible area; it also closes on any click in the PDF, on a `.reveal` or `.goToPage` (the page changes under it), on an Outline click, on Esc (the model) and on its close button. The selection bar follows the selection and hides while it is out of sight; it goes when the selection goes (a click elsewhere clears PDFKit's selection). Reason: a scroll notification cannot tell a referee's scroll from a layout pass (window resized, sidebar shown), and dismissing on every bounds change would close the card on layout; PDFKit keeps its selection across scrolls, so a dismissed bar could only come back by selecting again. The find bar is not dismissed by scrolling (find scrolls).
12. The overlays are opaque (window background colour, hairline, shadow): they lie over a white page in both appearances, and a translucent material over white turned grey in dark mode, where secondary text all but disappeared (seen in `--dark`).

**Selection, find, commands (§7.4, §7.6)**

13. Selections reach the model raw (`SelectionInfoBuilder`), 150 ms after the last change; the model normalises. The current find match is the PDF view's selection (§7.6) but no passage of the referee's: while it is current the model is given `nil`, so no selection bar pops up over each match, and an earlier selection stops being the model's.
14. Find: typing searches 0.2 s after the last key; Return / Shift-Return step, wrapping round; the first match shown is the first on or after the current page; at most 5,000 results ("1 of 5000+"); "No matches"; the current match orange, the others in the system find colour. A match already in sight below the bar stays where it is; any other is scrolled one third of the way down. (`go(to:)` put the match at the top edge, under the bar, and scrolled or not depending on layout timing; both reveal and find now scroll the view's own scroll view.)
15. `.reveal` puts the top of the first rectangle one third of the way down the visible area, clamped at the ends of the document; the horizontal position is kept unless the rectangle lies outside it. A command issued before `attach()` is not replayed; one issued before the document is shown waits for it. Commands are read from the serial-numbered property, so of two issued in the same turn only the later is performed.

**Navigator, card, viewer**

16. Navigator: a segmented control Pages | Outline | References (Outline left out when the paper has no outline). Thumbnails are sized from the column width (36 pt narrower, letter-shaped); the size is set when the view's frame changes, never while SwiftUI sizes the view (that made SwiftUI lay the window out again for ever: "more Update Constraints in Window passes than there are views"). References: each row shows the entry as printed (three lines) and the icon of its latest lookup — none before, a green check (filled when an open-access PDF is known), a grey question mark (not found), an orange warning with the failure reason as its help (failed). A click calls `lookUpEntry` and marks the row; the row of an open `.entry` card is marked; "Show in References" switches to the tab, marks the entry and scrolls to it.
17. Card header: the mention's text runs to the end of the year (§8.4, "Acemoglu et al. [2011"); the header shows it readable — a word broken at a line end joined, an opened bracket closed ("Acemoglu et al. [2011]"). A card from the References list is headed "Acemoglu et al. (2011)" (surnames and year; "[13]" or "Reference 5" without names). Per candidate entry: the reference as printed (up to four lines) with a spinner while resolving; then title, authors, "year · venue", "Open access", "year differs: …"; "No match found"; "Lookup failed: <failureReason>" with Retry (`lookUpCitation` / `lookUpEntry`). Buttons: Open PDF (disabled without an open-access address; downloads through `model.fetchReferencePDF`, then `uiActions.openReferenceViewer`; a download error is shown under the entry), Open in Browser (landing page, else `https://doi.org/<doi>`, else the entry's URL; http/https only), Copy DOI (disabled without one), Search Google Scholar (`model.searchURL(for:)` through `uiActions.openInBrowser`), Show in References. A mention with no candidate entry: its text, a line saying so, and Search Google Scholar for a stand-in entry made of the mention's text.
18. Reference viewer: reads the file once off the main actor and shows it from its bytes (no URL: it can never write the file); thumbnails 150 pt; its own bar with zoom out, zoom in, Fit Width, the page count and Find, with ⌘−, ⌘+, ⌘0, ⌘F, ⌘G, ⇧⌘G as SwiftUI shortcuts; "This file could not be opened." / "This PDF is password-protected." otherwise.

**Scenes**

19. `reader-highlights` selects the approved fuzzy comment (so "the selected comment's highlight is stronger" can be seen next to the others); `reader-references` looks up the first three entries so that icons show, leaving the third one's card at the top; `reader-ruler` selects and reveals the Table 2 comment of the sample session on `s1_ruler.pdf`; `reader-find` searches "effect" in `ay_round_nolinks.pdf` (three matches, two on page 1).

## How `check-citation-click` was exercised

`reader-citation` opens its card exactly the way §10.1 describes Wave 3's check (`ReaderSceneSupport.click` in `ReaderScenes.swift`): the first rectangle of the mention whose text starts "Acemoglu et al." in `model.citations`, its centre converted to window coordinates (`pdfView.convert(_:from: page)`, then `convert(_:to: nil)`), `window.contentView.hitTest` at that point, a left-mouse-up posted with `NSApp.postEvent(_:atStart: false)`, then `mouseDown(with:)` on the hit view. Through the real review window (SwiftUI hosting, `NavigationSplitView`, the overlay layer over the PDF) the hit view is PDFKit's page view, which forwards to `RefereePDFView`. The scene's `verify` checks `citationLookup == .resolved(target: .mention(4), …)` (the fake resolver resolves at once), a resolved reference, and the current page still page 1: it passes in every run. `ReaderControllerTests.aClickOnACitationOpensTheCardWithoutPDFKitSeeingIt` does the same in a plain window (the PDF view placed away from the window's origin): `hitTest`, `mouseDown`, a mouse-up straight to the view, card resolved, page and selection unchanged, and the cursor's `.linkArea` there and not beside it. A measurement made on the way: PDFKit passes the point of `areaOfInterest(for:)` in **view** coordinates (a probe with the view at an offset recorded exactly `view.convert(windowPoint, from: nil)`), which the override relies on.

For Wave 3: the mention's first rectangle must not lie under an overlay at the time of the check (no selection bar, card or find bar open), or `hitTest` finds SwiftUI's view instead of the PDF; the layer has no background, so elsewhere clicks reach the PDF.

## Contract problems

1. **No way to close only the citation card** (Appendix A.9). `dismissTransientUI()` closes "citation card, composing, editing, open thread, then the PDF selection" — the first that is open. The reader needs to close the card on a click elsewhere, a page change or a mention scrolled away, and nothing else. *Workaround:* it calls `dismissTransientUI()` only while `citationLookup != .idle`, which with the model's order closes the card alone (`ReaderController.dismissCitationCard()`). *Suggested:* a `dismissCitationLookup()` on the model.
2. **Esc cannot close the find bar from the PDF** (§9.4 "Esc: close the open overlay…", §11.3). The Shell's key monitor turns Esc into `model.dismissTransientUI()`, and the model does not know about the find bar, which is the Reader's own state (find does not pass through the model, §2.4); §11.3 gives the Shell `showFind()` but no way to hide it. *Workaround:* Esc in the find field and the Done button close the bar. *Suggested:* a `ReaderController.dismissFind()` (or a general `dismissOverlay() -> Bool` the key monitor calls before the model) for Wave 3 to decide.

## Outside my files

- **Highlights one glyph short where a margin number is glued** (WP2 decision 1, known): in `reader-highlights` the yellow highlight of line 13 ends after "i" of "in" (the "n" is the character before the glued "13", whose box PDFKit makes implausible). From `PDFPaperService.rects`, not the reader.
- **PDFKit draws the raw selection**: in `reader-selection` the grey selection of line 11 runs from the page's left edge to the right margin, because the raw selection includes the glued "11", whose character box spans the line (§7.4's example: x −2.2, width 498.4). The model's normalised selection and the selection bar are right; replacing PDFKit's selection with the normalised one would not help, since the character before glued digits has the same wide box.
- **The menu and the reference viewer**: the viewer handles ⌘F, ⌘G, ⇧⌘G, ⌘+, ⌘−, ⌘0 with SwiftUI shortcuts on its own bar. If the Shell's main menu claims those key equivalents while a viewer window is key (its Find and View items reach the review window's `ReaderController` only, §9.1), the viewer's shortcuts never fire; the Shell's items should be disabled, or pass, when the key window is not a review window.
- `FakeResolver` titles are the first 30 characters of the entry ("Resolved: Acemoglu, D., Dahleh, M. A., L"), so the card's resolved title in `reader-citation` and `reader-references` is cut mid-word by the fake, not by the card.
- Shell placeholder in this worktree: the review window has no toolbar yet, so the PDF starts right under the title bar; with WP11's toolbar the overlays still place themselves inside the pane, since they are placed from the PDF view's own bounds.

## Scenes: what the PNGs show

All at 1280 × 800 (2560 × 1600 pixels), light; also looked at with `--dark` and with `--size 1000x640` (every window kept its size; at 1000 × 640 the PDF column is about 412 pt and the card, placed below the mention there, fits in it).

| Scene | What I saw |
| --- | --- |
| `reader-highlights` | `ay_nolinks.pdf`, page 1 from its top; line numbers 1–16 in the left margin, the "CONFIDENTIAL" watermark. Green on lines 5–7 ("Our" / "identification strategy exploits the staggered rollout of a disclosure" / "rule"), stronger than the others (selected, 0.60) and framed by the dashed border of a fuzzy anchor; yellow on lines 13–14 ("The coefficient i[n]" / "Table 2 is 0.91 with a confidence interval that crosses one", the similar pair drawn once); blue on lines 15–16 ("We define the office-specific iden-" / "tification threshold"). No highlight reaches into the margin. Navigator on Pages: four thumbnails, which show the highlights too |
| `reader-selection` | Same page; PDFKit's raw selection in grey (inactive window) over line 11 from "sky" … and line 12 up to "wheth"; the selection bar "✦ Ask AI · Comment · Copy · Questions ⌄" just above "As shown by Acemoglu et al. [2011]," starting at its left edge, over line 10. `verify`: text "As shown by Acemoglu et al. [2011], network structure determines wheth", two rectangles, both x ≥ 100 |
| `reader-citation` | `ay_links.pdf` (hyperref links in blue), navigator Pages \| Outline \| References. The card "Acemoglu et al. [2011]" just above the mention (no room below it), pushed left to stay inside the pane: the reference as printed in three grey lines, "Resolved: …" in bold, "Acemoglu, Dahleh, Lobel, Ozdaglar", "2011", a green "Open access" badge, then Open PDF, Open in Browser, Copy DOI (disabled: no DOI), Search Google Scholar, Show in References. Page unchanged |
| `reader-find` | `ay_round_nolinks.pdf` page 1 from its top; the find bar at the top of the pane: field "effect", "1 of 3", ‹ ›, Done; the abstract's "effect" in orange (current), the introduction's "effect" in yellow |
| `reader-references` | `ay_links.pdf`, navigator on References: the nine entries as printed, three lines each; green filled checks on the first three (looked up), the third (Banerjee) marked; the card "Banerjee (1992)" centred at the top of the PDF pane with its record and buttons |
| `reader-ruler` | `s1_ruler.pdf` scrolled so that the Table 2 sentence is one third down: ruler numbers 28–60 down the left margin of page 1, the yellow highlight (selected, strong) on "The coef-" / "ficient in Table 2 is 0.91 … crosses one" at ruler 47–49, green on 28–32, blue on 51–53, the URL footer, then page 2 ("Journal of Synthetic Economics", "Page 2 of 4") with its own ruler from 1. `verify`: label "p. 1, lines 47–49" |
| `reference-viewer` | 900 × 700 window titled `num_twocol_links`: two thumbnails on the left (page 1 marked), the bar (zoom out, zoom in, Fit Width, "2 pages", Find) and page 1 of the two-column paper: title, Anonymous, Abstract, the two columns with the numeric citation links |
| `placeholder` | Still passes: `ay_round_nolinks.pdf`, page 1 from the top, now with the real navigator (Pages \| References) |

## Acceptance

Filled in at the last commit (below).
