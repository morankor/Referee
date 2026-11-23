# WP10 — Sidebar UI

Notes of WP10 (`plan.md` §11.4), for the Wave 3 integrator. The sidebar is the review window's inspector column: Comments | Chat | Report (§9.3, §9.5, §9.8), built on `ReviewSessionModel` alone.

## What exists after this step

| File (`Sources/RefereeUI/Sidebar/`) | What it holds |
| --- | --- |
| `SidebarReviewSidebar.swift` | `ReviewSidebar` (public, §11.3): the segmented tab switch bound to `model.sidebarTab`, the three tabs, a short placeholder before a session exists |
| `SidebarCommentsTab.swift` | Filter chips with counts, progress bar "N of M decided", "+" (`beginComposingComment`), ⋯ "Clear Undecided AI Comments…" (asked in place); the list: composing card, cards in `visibleComments` order, drafts under "Writing…"; follows the model's selection, open thread and editor by scrolling |
| `SidebarCommentCard.swift` | The card of §9.3 and its collapsed forms (rejected: one grey line; similar: two lines), buttons per state, ⋯ menu (change kind, include/exclude from report, attach to selection, delete), "More"/"Less" when a line limit cuts text |
| `SidebarCardState.swift` | Pure: `SidebarCardState.make(for:inputs:isExpanded:isHovered:)` (comment + window state → what the card shows) and `SidebarDraftState` |
| `SidebarDraftCard.swift` | A comment being streamed: badge once the kind is known, no buttons, pulsing left bar |
| `SidebarCommentEditor.swift` | Edit and compose: kind and category pickers, title (wraps), body and suggestion editors, Save ⌘↩ / Cancel Esc; `SidebarEditorRules` (pure) |
| `SidebarThreadView.swift` | Discussion: bubbles (referee right, assistant left), streaming reply, red failure line with Retry, reply field (Send ⌘↩ or Return; Stop while streaming; focused when the thread opens); `SidebarProposalBox` (Accept / Discard) |
| `SidebarChatTab.swift` | Conversations newest first: passage (click → `revealConversationInPDF`), location, messages, streaming answer, failure line, "Make Comment ▾" and Copy per answer, follow-up field, ⋯ Delete; "Ask about the paper…" at the bottom; empty state |
| `SidebarReportTab.swift` | Venue, notes, approved count, Generate/Regenerate (asks in place when edited), Revise Voice, Versions ▾, Export ▾; editor or preview; streaming text read-only with Stop; Style check (click selects the range); recommendation picker with the mismatch warning; export errors in red |
| `SidebarMarkdownEditor.swift` | `NSTextView` editor: 13 pt, line spacing 3, heading lines drawn bold (text stays plain), its own undo history, selects and shows a lint range |
| `SidebarMarkdown.swift`, `SidebarMarkdownPreviewView.swift` | Pure block conversion for the preview (headings, paragraphs, numbered and bulleted items, rules; inline text through `AttributedString(markdown:)`), and its view |
| `SidebarReportFacts.swift` | Pure: approved count line, report comments, major-concern count, recommendation mismatch (B.7), titles, lint excerpts and clamped ranges |
| `SidebarFilterChip.swift` | Pure: the seven chips with counts, the filter test, the triage text |
| `SidebarReportExport.swift` | `NSSavePanel` + `model.exportReport`, file name and type per format |
| `SidebarCommonViews.swift`, `SidebarFlowLayout.swift` | Kind badge, tags, card chrome, clamped text, bubble, message field, failure line, pasteboard; a wrapping layout for chips and button rows |
| `SidebarScenes.swift`, `SidebarSceneSupport.swift` | The seven scenes of §10.1, each with a `verify` that checks the model state the picture is meant to show |
| `Fixtures/sessions/sidebar-states.json` | Five short invented comments on `ay_nolinks.pdf` for `sidebar-states` (coordinator decision: new `sidebar-*.json` files only) |
| `Tests/RefereeUITests/Sidebar/` | 53 tests in 7 suites (71 in `RefereeUITests` with the 18 of Wave 0 and WP9's placeholder) |

Public declarations: only `ReviewSidebar` and `SidebarScenes`, as printed in §11.3. Every other top-level name starts with `Sidebar`; the one extension of a type I do not own is `View.sidebarCardChrome`, plus two `fileprivate` properties on `ReviewComment` and `DraftComment`.

## Decisions

1. **Rejected cards stay one grey line**, also when selected; selection or hover adds Undo. The thread can still open under the line; editing replaces it with the editor.
2. **Similar cards** collapse only while pending, unselected, not clicked open, and while the comment they resemble exists. `Similar to: <title>` selects that comment; a click elsewhere expands the card (it stays expanded).
3. **Own comments** keep the blue bar whatever their status, except rejected (grey line). An own comment without a passage (empty quote, `.none`) shows no location at all, not "Passage not found" (WP8b's note); an AI comment without one does show it.
4. **"Attach to selection"** sits on the unanchored card (disabled with a tooltip until the PDF has a selection) and in every card's ⋯ menu.
5. **Discuss** toggles the thread; while it is open the button shows a chevron (an earlier "Close" label could be read as closing the comment).
6. **Line limits**: quote 2, body 6, suggestion 3 lines, one "More" for all three, shown only when a limit really cuts something (measured, not guessed). Collapsed rows (rejected, similar) truncate by design and carry the full title as a tooltip.
7. **Header of a card**: kind · category · location on one line, or the location on a second line when they do not fit (no clipping with long category names).
8. **Drafts** use the pending yellow for their pulsing bar; "Writing the title and the comment…" while neither has arrived.
9. **The composing card** has no suggestion editor, because `addUserComment` takes none (contract problem 1). A title left empty becomes the first ten words of the body, the parser's rule (§6.5), in both modes.
10. **The report editor** is an `NSTextView`, not `TextEditor`, so that a lint finding can select and show its range. Heading lines are bold for legibility; nothing typed gets an attribute. While a report or revision streams, the editor shows `streamingReportText` read-only and follows its end; Preview is disabled meanwhile.
11. **Regenerate** of an edited report and **Clear undecided AI comments** ask in place (an inline strip), not in a sheet. **Export errors** (`ExportError.userMessage`) show in red under the buttons; the sidebar raises no banner.
12. **The recommendation warning** is computed for the picker's value with rule `recommendation-mismatch` of B.7 (major concerns = numbered items under "Major concerns"), so it follows a change of the picker at once; the lint list shows the linter's own finding.
13. **Rows of the Comments list are keyed by kind and id** (`SidebarListKey`): the engine gives a finished comment its draft's id, and with bare UUIDs the lazy stack kept drawing the finished comments as drafts (no buttons, faded bar). Found in the first `sidebar-pending` picture.
14. **No minimum size.** SwiftUI measures the window's minimum height at a width of zero, where a text with `.fixedSize(horizontal: false, vertical: true)` stands one word per line: the empty Chat tab asked for 628 points and the window grew to 1000 × 660 in a run at `--size 1000x640`. Texts in the tabs' fixed (non-scrolling) parts therefore wrap without it. `SidebarHostingTests` keeps every tab at most 320 points wide and 540 tall at its smallest (the 640-point window less a 52-point toolbar, less a margin).
15. **Scenes:** `sidebar-pending` and `sidebar-streaming` run the mock review on `ay_round_nolinks.pdf` ("mock", "mock-stall"); `sidebar-discussion`, `sidebar-editing` and `sidebar-report` use `sample.json` on `ay_nolinks.pdf`; `sidebar-chat` asks the quick question about the abstract's last sentence of `ay_nolinks.pdf`, selected through `model.readerSelectionChanged` (one span of the page string). `sidebar-streaming`'s `verify` cancels the stalled run.
16. **`sidebar-states` shows six states on five cards.** `sample.json` on `ay_nolinks.pdf` yields every state (B approved and fuzzy 0.91, "p. 1, lines 5–7"; C rejected; D similar to A; E page-only "p. 3"; F unanchored, "literature"), but its seven long cards need about 970 points. Six short cards still need about 870 with the header, more than the 748 points the sidebar has under WP11's toolbar. So `sidebar-states.json` has five: approved with a fuzzy anchor (as `sample.json`'s own approved comment), similar to it, rejected, page-only, unanchored. The scene's `verify` checks each state through `SidebarCardState`.

## Contract problems

1. **`addUserComment(kind:category:title:body:anchoredTo:)` has no suggestion** (Appendix A.9), while §9.3's editing card has a suggestion editor and the new own comment is "an editing card". *Workaround:* the composing card leaves the suggestion editor out; the referee can add one with Edit after saving. *Suggested:* a `suggestion: String? = nil` parameter.

No frozen file was changed and no frozen test failed.

## The scenes, as seen in the PNGs (1280 × 800, light; also checked `--dark` and `--size 1000x640`)

In this worktree the window has no toolbar (Wave 0's `ReviewWindowView`), so the sidebar starts at the window's top edge; under WP11's toolbar it will start about 52 points lower. Every scene's content of interest ends above 748 points, so it stays visible then.

- **sidebar-pending**: six pending cards from the mock review (MAJOR ×3, MINOR ×2, QUESTION), yellow bars, each with ✓ Approve, ✕ Reject, Discuss, Edit and ⋯; the second card has the accent outline (selected). Chips "All 6 · Pending 6 · Approved 0 · Rejected 0 · Major 3 · Minor 2 · Questions 1" on two rows, "0 of 6 decided", +, ⋯. Locations "p. 1" (that fixture has no line numbers). No text clipped.
- **sidebar-streaming**: two finished cards with their buttons, then "Writing…" with a spinner and the draft: MAJOR · Claims vs. evidence · p. 1, its quote, "Writing the title and the comment…", faded (pulsing) bar, no buttons. "0 of 2 decided".
- **sidebar-states**: approved card (green bar, ✓, Undo/Discuss/Edit, "≈ p. 1, lines 5–7"); similar card collapsed to two lines with "Similar to: Staggered adoption is asserted, not shown" underlined; rejected one grey line with ⊗ and a grey STRENGTH badge; page-only QUESTION card with "p. 3" dotted-underlined; unanchored MINOR card with "Missing work", the orange "verify" tag, "⚠ Passage not found" and a disabled "Attach to selection" (no selection). All five distinguishable; the last ends at about 712 points.
- **sidebar-discussion**: comment A scrolled to the top, selected: card with quote, body, suggestion, buttons (Discuss with its chevron), then the thread: the referee's question right-aligned (accent tint), the assistant's answer left (grey), "Reply…" with a disabled Send, then the "Proposed revision" box (MINOR, "\"Robust\" is not supported by the reported interval", its body, Accept / Discard). Below, the similar comment D collapsed (its two lines truncate with "…", by design). Ends at about 727 points.
- **sidebar-editing**: comment B in edit mode at the top with the outline: "Edit comment", Kind Major, Category "Hidden assumptions and omissions", the title wrapping on two lines, Comment and Suggestion editors filled, Cancel / Save. The next cards follow unchanged.
- **sidebar-chat**: Chat tab, one conversation with the purple bar: "p. 1, line 7", the quoted sentence, the question right, the mock's answer left, "Make Comment ▾" and Copy, "Ask a follow-up…"; "Ask about the paper…" with Send at the bottom.
- **sidebar-report**: Venue and Notes fields (placeholders), "2 approved comments (1 major, 1 minor)", Regenerate, Revise Voice, Versions (disabled, no versions yet) and the **Export ▾** button; Edit|Preview; the editor with the bold headings "## Summary assessment", "## Recommendation", "## Publication probability", "## Major concerns"; Style check (3): `em-dash` "—", `check-word` "robust", `copula` "serves as" with their messages; Recommendation "Major revision", no mismatch warning (two major concerns).

Dark (`--dark`): all seven pass and read well (cards on dark grey, kind colours, editor text). At `--size 1000x640` all seven pass after decision 14 (before it, `sidebar-chat` grew the window to 1000 × 660).

## Outside my files: things that look wrong or need a look in Wave 3

1. **A finished comment has its draft's id** (`Sources/ReviewEngine/ReviewJob.swift`, `ReviewComment(id: draft.id, …)`). Legitimate under A.6, but any view that lists drafts and comments together keyed by UUID shows stale views (decision 13). WP9's highlights are not affected (drafts have no anchor).
2. **Window minimum height**: any column (navigator, reader overlays, banner) with `.fixedSize(horizontal: false, vertical: true)` text outside a scroll view can make a review window grow at its 1000 × 640 minimum (decision 14). Worth running every scene with `--size 1000x640` once in Wave 3.
3. **The Markdown export type** is `UTType(filenameExtension: "md")`, whose preferred extension on this system is "markdown"; the panel is seeded with `<paper> report.md`. Check by hand that the panel keeps ".md".
4. **Not checkable by snapshot**, for a manual pass in Wave 3: Return and ⌘↩ in the reply and chat fields (Send), ⌘↩ and Esc in the editor (two ⌘↩ owners when an editor and a thread are open at once; SwiftUI picks one); D focusing the reply field (J/K then type into it, as §9.4 intends); Undo on hover over a rejected line; a lint finding selecting its range; Copy to the pasteboard; the save panels of Export.
5. Snapshot windows are drawn inactive (§10.1), so prominent buttons (Save, Accept, Generate) look grey in the pictures; in the app they are tinted.

## Acceptance

Run at the last code commit, in this worktree.

| Command | Result | Final line |
| --- | --- | --- |
| `scripts/build.sh` (after touching every file of `Sources/RefereeUI/Sidebar` and `Tests/RefereeUITests/Sidebar`, so all 19 sources recompiled) | exit 0; no line with "warning" or "error" | `Build complete! (1.99s)` |
| `scripts/test.sh --filter RefereeUITests` | exit 0; no "warning" | `test.sh: OK (71 tests)` |
| `scripts/snapshots.sh --scene sidebar-pending --scene sidebar-streaming --scene sidebar-states --scene sidebar-discussion --scene sidebar-editing --scene sidebar-chat --scene sidebar-report` | exit 0; seven manifest lines, each `"nonBlank":true,"failures":[]`, 2560 × 1600 | `build/snapshots/sidebar-streaming.png` (the script's last line lists the PNGs) |
| `scripts/snapshots.sh --out build/snapshots --scene placeholder` | exit 0; `{"scene":"placeholder",…,"nonBlank":true,"failures":[]}` | `build/snapshots/sidebar-streaming.png` |
| `scripts/test.sh` | exit 0; no "warning"; 880 tests in 122 suites, none failed; skipped by their own gates: the CLI smoke prompt, the delivery experiment, the two real-paper tests (`Fixtures/private` is empty in a worktree), the live reference services, the real Keychain | `test.sh: OK (880 tests)` |
| `git status --porcelain \| wc -l` | after the last commit | `0` |

Also run, not required: the seven scenes with `--dark` (exit 0) and with `--size 1000x640` (exit 0).
