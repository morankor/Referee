# Design review (step 4)

A senior macOS designer's review of Referee as built at the end of Wave 3, for the programming agents of step 5. It
changes no behaviour; it proposes 35 changes (`D1`–`D35`) and adds 16 snapshot scenes that show the states the changes
touch. Plan §9 is the first-version UI spec; where this review differs, this review wins, and the docs pass at the end
of step 5 brings §9 and the README into line.

How the app was seen: `scripts/snapshots.sh` in light, `--dark` and `--size 1000x640`, every scene, plus the 16
`design-` scenes below. Snapshot windows are drawn inactive: prominent buttons (Review, Send, Save, Accept) look grey in
every picture, so tint cannot be judged from them.

## Contents

1. [Summary: the ten changes that matter most](#summary-the-ten-changes-that-matter-most)
2. [Journeys](#journeys)
3. [Change list](#change-list)
4. [Outside `Sources/RefereeUI`](#outside-sourcesrefereeui)
5. [Keep as is](#keep-as-is)
6. [Implementation split](#implementation-split)
7. [Scenes added for verification](#scenes-added-for-verification)

## Summary: the ten changes that matter most

In order of what they do for a referee triaging 20–30 comments and writing the report.

| # | Item | Change | What it fixes |
| --- | --- | --- | --- |
| 1 | D1 | Comment cards compact (header and title) except the selected one | Two cards per screen; 25 comments are 6,000 pt of scrolling |
| 2 | D2 | Esc in any sidebar field gives the keyboard back to triage; E and N put the cursor in the comment | After D, E or N the triage keys type into a field; only the mouse gets out |
| 3 | D3 | Destination indicator on two lines, at most 260 pt | At 1,000 pt a long indicator pushes Review, Report and the sidebar button into the toolbar's overflow |
| 4 | D5 | First run: "Set Up AI Provider…" in the welcome window; switching a provider on makes it the default | Switching Ollama or a key on still leaves every window at "No AI provider" |
| 5 | D6 | Comments tab: a real empty state, a no-provider state, and an "All decided · Write Report" state | Seven chips reading 0; "Run a review (⌘R)" shown when ⌘R cannot work; nothing leads to the report |
| 6 | D8 | Report tab gives the editor the room: venue and notes folded, recommendation in the header, style check folded, Copy Text first, spelling checked | At 1,000 × 640 the report editor shows about 210 pt |
| 7 | D7 | The selected card scrolls to the top of the list on every keyboard move | The next card lands at the bottom edge; the eye searches each time |
| 8 | D4 | The indicator names the chat and report provider when they differ from the review's | Per-job defaults can send chat or report text to a provider the toolbar does not show |
| 9 | D9 | Run progress: part gauge, elapsed time, "Stop" | A ten-minute local review says only "Reading the paper…" |
| 10 | D10 | "Add as Comment" from a chat answer opens the new comment in the editor | Today it adds a comment to the other tab and nothing on screen changes |

Totals: 35 items. By priority: P1 10, P2 15, P3 10. By area: Shell 16, Sidebar 12, Reader 5, Common 1, all areas 1 (D22,
accessibility). Three need code outside `RefereeUI` (O1–O3, all additive); three P3 items are new features, marked
"(new)".

## Journeys

Each journey: what works, what gets in the way (with the scene that shows it), and the items that change it.

### a. First launch, providers, Settings

- **Works.** The welcome window is plain and quick (welcome). With Ollama running, first launch switches it on and the
  line reads "AI: Local · gemma4:e4b" (design-welcome-many). Settings ▸ Providers groups providers by how they are paid
  for, gives each a status light, shows install and sign-in commands with Copy, warns in orange about experimental CLIs,
  and says where a key goes (settings-providers, settings-api-key).
- **In the way.**
  - With no provider, the only pointer is a caption at the bottom of the welcome window (design-welcome-first-run).
  - Switching a provider on does not make it the review default; every window keeps saying "No AI provider" until the
    referee finds the pickers at the bottom of Settings (design-settings-first-run, design-review-no-provider).
  - Send Test Prompt is enabled for a CLI that is not installed (settings-providers); its note ("sends 'Reply with
    exactly: OK'; uses a few tokens") is the same for an API key, a subscription and a local model.
  - After a key is saved, the provider is still off and nothing says so (settings-api-key).
  - Ollama installed but not running looks the same as running until a job fails (design-banner-provider-down).
- **Changes.** D5, D21, D13.

### b. Opening a manuscript, first look, navigator

- **Works.** Drag, ⌘O and recent reviews open one window per document; "Opening {file}…" covers the PDF while it loads;
  the PDF fits the width from the top of page 1; thumbnails, the outline when there is one, and References
  (review-empty, reader-references).
- **In the way.**
  - The sidebar's first sight is seven filter chips reading 0 and one sentence (review-empty).
  - Nothing says what the app found: pages, references, margin line numbers, a missing text layer.
  - At 1,000 × 640 the PDF column is 412 pt and the page is set at about two thirds of its width (review-running,
    small run).
  - A journal-system file name is cut to "ECTA-D-26-00412…" (design-review-long-names).
- **Changes.** D6, D19, D3, D26.

### c. Starting a review: destination, consent, progress, failure

- **Works.** The indicator is always there, green for this Mac and orange for anything else, with "text only" and
  "experimental" (review-empty, consent). The consent card blocks the window, Send is not the default button and Esc
  answers no (consent). Drafts appear under "Writing…" as they arrive (sidebar-streaming). A failure keeps the comments
  received so far and offers Retry (banner-error).
- **In the way.**
  - At 1,000 pt a long indicator ("Antigravity · example-extended-context-preview · text only · experimental") sends
    Review, Report and the sidebar toggle into the toolbar's overflow menu (design-review-long-names, small run).
  - Chat and report may go to other providers (Settings' per-job defaults) without the indicator saying so.
  - The consent card buries what, where, how much and who keeps it in one sentence; for a CLI it says "through claude";
    its button says "Send" without a name; in dark mode its scrim barely dims the sidebar (consent, dark run).
  - A long local review shows "Reading part 1 of 3…" and a spinner, nothing else (design-review-parts).
  - Running the review again re-sends the whole paper to a paid API without a word.
- **Changes.** D3, D4, D12, D13, D9, D20, D30.

### d. Triage of 20–30 comments by keyboard

- **Works.** The keymap (J/K, A, R/X, U, D, E, N, 1–4, Return, Esc) and auto-advance; the selected card's outline, its
  stronger highlight and the flash in the PDF; rejected comments as one grey line; similar comments folded with a link;
  "13 of 25 decided" with a bar (design-triage-25, check-triage-keys).
- **In the way.**
  - A pending card is 210–300 pt; two fit the column at 1,280 × 800, one and a half at 1,000 × 640 (design-triage-25).
  - The selected card is scrolled just into view, so it lands at the bottom edge (design-triage-25).
  - After D, E or N the keyboard stays in a text field: J types "j", Esc does nothing.
  - The chips wrap to two rows and Strength has no chip (sidebar-states).
  - A minor comment's grey badge looks like a rejected comment's muted one (sidebar-states).
  - "p. 3" with a dotted underline is unreadable as "page only" (sidebar-states).
  - Coming back to a paper, J walks decided comments too; there is no "next undecided".
  - After the last decision nothing points to the report (design-triage-done).
- **Changes.** D1, D7, D2, D11, D16, D17, D25, D6.

### e. Discussion, revisions, editing, anchoring states

- **Works.** The thread sits under its card; bubbles left and right; Stop while streaming; a failed reply is a red line
  with Retry, not a banner (design-reply-failed); a proposal never changes the comment by itself; the editor has every
  field and saves with ⌘↩ (sidebar-discussion, sidebar-editing); "≈", page-only and "Passage not found" each look
  different, and an unanchored comment offers Attach to Selection (sidebar-states).
- **In the way.**
  - The proposed revision comes after the reply field, and the referee compares the two versions by eye
    (sidebar-discussion).
  - At 1,000 × 640 the discussed card fills the column and the proposal is below the fold (sidebar-discussion, small).
  - "Discuss" with a chevron.up is the only sign that the thread is open.
- **Changes.** D18, D1, D2, D22.

### f. Own comments, questions about a passage, answers into comments

- **Works.** The selection is normalised (no margin numbers); the bar offers Ask AI, Comment, Copy and quick questions
  (reader-selection); the new comment's card shows the passage (design-compose-from-selection); a conversation shows
  its passage, location and a follow-up field (sidebar-chat).
- **In the way.**
  - After Ask AI or Comment the bar stays over the line above the passage (sidebar-chat,
    design-compose-from-selection).
  - Comment and N do not put the cursor in the comment.
  - "Make Comment ▾" adds a pending comment to the Comments tab and nothing on screen changes; the answer is in the
    assistant's voice and must be rewritten.
  - Copy gives no sign that it copied.
  - The Chat tab's empty state does not mention the field at its bottom (design-chat-empty).
- **Changes.** D14, D2, D10, D35.

### g. Citations, the cited PDF, References

- **Works.** A click on a citation opens a card by the mention, with the reference as printed, the record found, Open
  PDF, Open in Browser, Copy DOI, Search Google Scholar and Show in References (reader-citation); the viewer window has
  thumbnails, zoom and find (reference-viewer); failure and "no match" are worded plainly (design-citation-states).
- **In the way.**
  - The resolved title, which is what the referee wants, comes after the mention and the raw entry (reader-citation).
  - "Open access" is white on green, below 3:1 in light mode.
  - Failed and not-found cards show three disabled buttons (design-citation-states).
  - The References list clamps each raw entry to three lines, with no author–year headline and no way to find an entry
    (reader-references).
  - The viewer's controls sit in a bar inside the content rather than in its toolbar (reference-viewer).
- **Changes.** D15, D23, D27, D29.

### h. The report: generate, edit, check, export, paste

- **Works.** Generation from approved comments, streaming read-only; a Markdown editor with bold headings and Preview;
  Versions; Revise Voice; a style check whose findings select their text; the recommendation prefilled with a mismatch
  warning; four export formats and two copies; File ▸ Export Report… with a format picker (sidebar-report).
- **In the way.**
  - The editor gets about 330 pt at 1,280 × 800 and 210 pt at 1,000 × 640 (sidebar-report, small run).
  - Findings are labelled with rule ids in orange monospace ("check-word", "copula").
  - Regenerate stays the prominent button after the report exists; Copy gives no feedback.
  - Journal systems have one box for the authors and one, confidential, for the editor; the recommendation and the
    publication probability belong in the second, and the app offers one text.
  - No spell checking in the editor.
  - The empty state has no way back to the comments that need approving (design-report-empty).
- **Changes.** D8, D33.

### i. Returning days later, deleting review data

- **Works.** Reviews are found by the file's hash, so a renamed or moved PDF keeps its review; the welcome window lists
  reviews with counts; File ▸ Delete Review Data… and Settings ▸ Privacy ▸ Delete all review data confirm first and say
  the PDF is untouched (settings-privacy).
- **In the way.**
  - Recent titles are cut to one line and the whole progress line is orange (design-welcome-many).
  - No way to reveal a recent paper or delete its data from the list; a moved file fails on click.
  - No key for "next undecided comment".
  - Nothing shows what was sent where so far, although the session keeps every run.
- **Changes.** D26, D25, D34.

## Change list

Format of each item: priority (P1 must, P2 should, P3 nice to have) · area. *Files* lists the likely files (tests under
`Tests/RefereeUITests/<Area>/`). *Change* gives sizes in points, SF Symbol names, colours and every string. *Verify*
names the scene and what its PNG must show, or "manual". Strings in quotes are exact; in them `{name}` stands for a
value, for example `{vendor}` for "Anthropic". Where an item changes a string a test pins, the test is named.

### P1

#### D1 — Compact cards; the full card only for the selected comment · P1 · Sidebar

- *Files:* `SidebarCardState.swift`, `SidebarCommentCard.swift`, `SidebarCommentsTab.swift`, `SidebarScenes.swift`
  (verify of sidebar-states), `SidebarCardStateTests.swift`.
- *Change:*
  1. `SidebarCardState.Layout` gains `.compact`. In `make`: rejected stays `.collapsedRejected`; pending-and-similar
     stays `.collapsedSimilar`; otherwise `.full` when `isSelected || isEditing || isThreadOpen || isReceivingReply ||
     replyFailureMessage != nil || inputs.expandsAllCards`, else `.compact`. `actions` of `.compact` is `[]`.
  2. `SidebarCardInputs` gains `expandsAllCards: Bool = false`.
  3. The compact card: the header row as today (check mark, kind badge, tags, category, location on the right), then the
     title in `Theme.cardTitleFont`, `lineLimit(2)`. No quote, body, suggestion, "More" or buttons. Padding
     `Theme.cardPadding`. When `comment.thread` is not empty the header adds `Label("\(count)", systemImage:
     "bubble.left.and.bubble.right")` in `Theme.metadataFont`, secondary; when a proposal waits, `CommonTag("Revision
     proposed", color: .accentColor)` (D16). A click selects and reveals, as today.
  4. The ⋯ menu of the Comments header gains `Toggle("Show Full Text of Every Comment", isOn: $expandsAllCards)`, a
     per-window `@State` of `SidebarCommentsTab`, default off.
  5. sidebar-states' `verify` accepts `.compact` where it expects `.full` for the approved, fuzzy, page-only and
     unanchored cards.
- *Why:* 25 comments at 210–300 pt make 6,000 pt of list and two cards per screen; triage reads one comment at a time.
- *Verify:* design-triage-25 at 1,280 × 800: the selected card and at least three compact cards below it; only the
  selected one shows quote, body, suggestion and buttons. At 1,000 × 640: the selected card and at least two.
  sidebar-pending: the second card full, the others compact.

#### D2 — The keyboard comes back to triage · P1 · Sidebar (Reader for the selection bar's field)

- *Files:* `SidebarCommonViews.swift` (`SidebarMessageInput`), `SidebarCommentEditor.swift`, `SidebarChatTab.swift`,
  `ReaderSelectionBar.swift`, `ShellHelpView.swift` (one row, by the Shell agent).
- *Change:*
  1. `SidebarMessageInput`: `.onExitCommand` on its field calls `focus?.wrappedValue = false` and
     `NSApp.keyWindow?.makeFirstResponder(nil)`. Esc in the reply, follow-up or "Ask about the paper…" field gives the
     keyboard back; a second Esc reaches the key monitor and closes the thread (existing order).
  2. `SidebarCommentEditor`: `@FocusState private var focusedField: EditorField?` with `enum EditorField { case title,
     body, suggestion }`; `SidebarTextArea` gains `focus: FocusState<EditorField?>.Binding? = nil` and `field: EditorField`
     and applies `.focused(focus, equals: field)` when given; `.onAppear { focusedField = .body }` in both modes,
     so E and N land in the comment. After Save and after Cancel: `NSApp.keyWindow?.makeFirstResponder(nil)`.
  3. Title prompt: "Short title" → "Title (optional)" (the title is taken from the comment when empty).
  4. The selection bar's ask field: after Return and on Esc, `NSApp.keyWindow?.makeFirstResponder(nil)`.
  5. Help window, triage table: add ("Esc in a text field", "Give the keyboard back to the comment list").
- *Why:* triage is keyboard-first, but every field that takes the keyboard keeps it: after D, ⌘↩, J types "j".
- *Verify:* manual: (a) select a comment, D, type, ⌘↩, Esc, J: the next comment is selected; (b) E: typing goes into
  Comment; ⌘↩; A approves; (c) select text, N: typing goes into Comment; Esc closes the card; J works; (d) Ask AI field:
  Return sends, then J works.

#### D3 — The destination indicator on two lines, never wider than 260 pt · P1 · Shell

- *Files:* `ShellDestination.swift`, `ShellDestinationViews.swift`, `ShellDestinationTests.swift`.
- *Change:*
  1. `ShellDestinationState` gains `title: String` and `detail: String?`; `text` stays: the title, then " · " and the detail
     when there is one, so the welcome line, accessibility and tests keep their strings. Local: title "Local",
     detail the model. CLI: title `shortName` ("Claude Code"), detail `[model or "default", "text only"?,
     "experimental"?]` joined by " · ". API: title `displayName`, detail as for a CLI. No provider: title "No AI
     provider", no detail. Local only with a remote provider: title "Remote blocked", detail "Local only is on" (text
     "Remote blocked · Local only is on"; update `ShellDestinationTests` line 65).
  2. The label: `HStack(spacing: 7)`: the symbol at `.system(size: 15, weight: .medium)` in the tint; a `VStack(alignment:
     .leading, spacing: 0)` with the title in `.callout.weight(.semibold)`, tint, `lineLimit(1)`, and the detail in
     `.caption2`, `.secondary`, `lineLimit(1)`, `.truncationMode(.middle)`; the debug-dump tag and the chevron as today.
     `.frame(maxWidth: 260, alignment: .leading)`.
  3. `.help("Where this document is sent: \(state.text)")`, so a truncated detail can be read in full.
- *Why:* a long one-line indicator truncates the title at 1,280 pt and, at 1,000 pt, sends Review, Report and the
  sidebar toggle into the toolbar's "»" menu: the primary action disappears.
- *Verify:* design-review-long-names at 1,280 × 800 and 1,000 × 640: no "»" chevron; Review, Report and the sidebar
  toggle visible; "Antigravity" over a middle-truncated detail ending "experimental". review-empty: "Local" over "mock".
  consent: "Mock (remote)" over "mock · text only".

#### D4 — The indicator names the chat and report destinations when they differ · P1 · Shell (needs O1)

- *Files:* `ShellDestination.swift`, `ShellDestinationViews.swift`, `ShellDestinationTests.swift`, `ShellDesignScenes.swift`.
- *Change:*
  1. `ShellDestination.state(provider:…)` gains `chatProvider: ProviderDescriptor? = nil, reportProvider:
     ProviderDescriptor? = nil` (defaults, so existing calls and tests compile); `state(of:)` passes O1's values. When
     `chatProvider?.id` or `reportProvider?.id` differs from `model.activeProvider?.id`, the
     detail ends with " · chat: {name}", " · report: {name}" or " · chat and report: {name}", `{name}` being "Local" for
     a local provider, else `shortName`. Tint: green only when all three are local, else orange.
  2. The destination menu's "What a review sends" section adds, per differing job, a `.callout` line: "Chat questions go
     to {displayName} ({destination})." / "The report is written by {displayName} ({destination})."
  3. Under the menu's "Send this document to" title, a caption: "For the review, chat and report of this paper."
  4. New scene `design-review-split-destinations` (Shell): `ay_round_nolinks.pdf`; prepare enables `claude-cli` and sets
     `settings.defaults.chat = ProviderRef(providerID: "claude-cli", model: nil)` through `reloadSettings`.
- *Why:* the indicator is the privacy promise "where the text goes"; with per-job defaults, chat or report text can go to
  a provider it does not name (`resolveTarget` falls back to `defaults.chat` and `defaults.report` when the paper has no
  choice of its own).
- *Verify:* unit test: review Ollama, chat Claude Code gives text "Local · gemma4:e4b · chat: Claude Code", tint orange.
  design-review-split-destinations: the indicator's second line ends "chat: Claude Code", orange.

#### D5 — A first-run path that ends in a working provider · P1 · Shell

- *Files:* `ShellWelcomeView.swift`, `ShellSettingsProviders.swift` (`ShellProviderBindings.enabled`),
  `ShellDestination.swift`, `ShellDestinationViews.swift`, `ShellProviderRowsTests.swift`.
- *Change:*
  1. Welcome window, `.notSetUp`: below "or drop a PDF on this window", `Button { openSettings() } label: {
     Label("Set Up AI Provider…", systemImage: "cpu").frame(minWidth: 140) }`, `.buttonStyle(.bordered)`,
     `.controlSize(.large)`; under it, centred, `.caption`, `.secondary`, `.fixedSize(horizontal: false, vertical:
     true)`: "Reviews need an AI provider. A local model through Ollama keeps the manuscript on this Mac." The bottom line
     is not shown in this state.
  2. `.configured`: the bottom line becomes a borderless button that opens Settings ▸ Providers,
     `.help("Change the provider in Settings ▸ Providers")`.
  3. `ShellProviderBindings.enabled`, switching on: when `defaults.review == nil`, set it to `ProviderRef(providerID:
     id, model: entry.model)`. Switching off the review default: set it to the first other enabled provider, local ones
     first, else nil; a chat or report default naming it becomes nil ("Same as Review").
  4. `ShellDestination.state(provider:…)` gains `hasChoices: Bool = false` (`state(of:)` passes
     `!model.selectableProviders.isEmpty`). No active provider but choices: symbol "questionmark.circle", title
     "Choose AI provider", grey, a click opens the destination menu (not Settings). With nothing enabled it stays "No AI
     provider" and opens Settings.
- *Why:* on a first launch without Ollama the only pointer is a caption; switching a provider on leaves every window at
  "No AI provider" until the referee finds the default pickers at the bottom of Settings.
- *Verify:* design-welcome-first-run: the button and the sentence under Open PDF…, no bottom line. Unit test: switching
  Ollama on with no default makes it the review default. Manual: first launch with Ollama stopped, switch it on in
  Settings, open a PDF: the indicator reads "Local".

#### D6 — Comments tab: empty, no-provider, running and done states · P1 · Sidebar

- *Files:* `SidebarCommentsTab.swift`, `SidebarScenesTests.swift` if a string is pinned.
- *Change:*
  1. No comments, no drafts, not composing: hide the chip row and the progress row (keep "+" and "⋯" at the top right)
     and show `ContentUnavailableView` with `Label("No comments yet", systemImage: "text.badge.checkmark")`; description
     "Run a review to have the AI read the paper and draft comments, or select a passage and add your own."; under it a
     `.caption`, `.secondary` line of document facts: "{n} pages · {m} references · margin line numbers found" ("1 page",
     "1 reference", "no reference list found", "no margin line numbers"; "no text layer: comments can be tied to pages
     only" when `hasTextLayer` is false; the references part left out while `citations` is nil). Actions: "Run Review"
     (`.borderedProminent`, `model.startReview()`, disabled unless `model.canStartReview`, `.help(model.sendPlan?
     .blockingReason ?? "Run the review (⌘R)")`) and "Add Comment" (`.bordered`, `model.beginComposingComment()`,
     `.help("Add your own comment (N)")`).
  2. No provider (`model.activeProvider == nil`): description "Set up an AI provider to run a review. You can still read
     the paper and add your own comments."; actions "Set Up AI Provider…" (prominent, `uiActions.openSettings()`) and
     "Add Comment".
  3. A review running and nothing received yet: `ContentUnavailableView` with a `ProgressView`, title "Reviewing…",
     description "Comments appear here as the model writes them." While drafts stream, the label "Writing…" reads
     "Writing… · {n} received" (`n` = AI comments whose `createdAt` is at or after the run's `startedAt`).
  4. Every comment decided (`triage.total > 0 && decided == total`): the progress row shows
     `Label("All \(total) decided", systemImage: "checkmark.circle.fill")` in `Theme.statusColor(.approved)` and a
     button "Write Report" (`.bordered`, `.controlSize(.small)`, sets `model.sidebarTab = .report`).
- *Why:* the first sight of a paper is seven chips reading 0; without a provider the tab promises ⌘R, which cannot work
  (design-review-no-provider); after the last decision nothing leads on (design-triage-done).
- *Verify:* review-empty: the empty state with Run Review and Add Comment, no chips, "4 pages · 9 references · no margin
  line numbers" (counts as the fixture gives them). design-review-no-provider: "Set Up AI Provider…". review-running:
  "Writing… · 2 received". design-triage-done: "All 25 decided" and "Write Report".

#### D7 — The current card scrolls to the top on every keyboard move · P1 · Sidebar

- *Files:* `SidebarCommentsTab.swift`, `SidebarCommentCard.swift`.
- *Change:* `onChange(of: model.selectedCommentID)` scrolls with `anchor: .top` instead of `nil`, except when the
  selection came from a click on that card in the list: the card calls an `onSelectFromList(id)` closure that the tab
  records in a `@State`, and the tab skips scrolling for that id. Animation `.easeOut(duration: 0.2)`.
- *Why:* minimal scrolling leaves each newly selected card at the bottom edge; with a fixed place the eye goes to the
  same spot after every A, R, J or K.
- *Verify:* design-triage-25: the selected card's top edge is the first thing under the header (with D1, the rest of
  the list below it).

#### D8 — The report editor gets the room; checks and copies made clear · P1 · Sidebar

- *Files:* `SidebarReportTab.swift`, `SidebarReportFacts.swift`, `SidebarMarkdownEditor.swift`,
  `SidebarReportFactsTests.swift`.
- *Change:*
  1. Venue and Notes move into `DisclosureGroup("Venue and notes")`, expanded when there is no report, collapsed once one
     exists.
  2. One row under it: the approved summary (`Theme.metadataFont`, secondary), `Spacer`, `Text("Recommendation")`
     (`Theme.metadataFont`, secondary) and the recommendation picker (moved from the bottom), `.controlSize(.small)`; the
     mismatch warning stays under this row.
  3. Buttons with no report: "Generate" (prominent), the rest disabled as today. With a report: `Label("Copy Text",
     systemImage: "doc.on.doc")` (`.borderedProminent`, copies `reportText(format: .plainText)`), "Export" menu ("Copy
     Markdown", divider, "Markdown File…", "Text File…", "Word Document…", "PDF…"), "Revise Voice", "Regenerate",
     "Versions" (all `.bordered`).
  4. After a copy, the Copy Text label reads `Label("Copied", systemImage: "checkmark")` for `Theme.feedbackDuration`
     (D16), then returns.
  5. Style check: collapsed by default (`showsStyleCheck = false`); the header keeps the orange count; expanded, the list
     is at most 120 pt high. Each finding's first line shows `SidebarReportFacts.ruleTitle(finding.rule)` in
     `Theme.metadataFont.weight(.semibold)`, primary colour, then the quoted excerpt, secondary. Titles: banned-word
     "Machine-sounding word", check-word "Word to check", em-dash "Em dash", not-only "“Not only … but also”", copula
     "“Serves as”", gerund-tail "Trailing -ing clause", third-person "Third person", hedge-stack "Stacked hedge",
     flattering-opener "Opening praise", optimistic-closer "Optimistic ending", template-heading "Template heading",
     missing-section "Missing section", opens-with-summary "Opens with a summary", recommendation-mismatch
     "Recommendation mismatch"; any other id: hyphens to spaces, first letter capitalised.
  6. `SidebarMarkdownEditor`: `textView.isContinuousSpellCheckingEnabled = true` (automatic correction stays off).
  7. Empty state (no approved comment): under the sentence, a button "Show Pending Comments" (`.bordered`) that sets
     `model.filter = .pending` and `model.sidebarTab = .comments`.
- *Why:* at 1,000 × 640 the editor shows about 210 pt, less than a third of the column, for the document the referee came
  to write; rule ids are developer names; Copy gives no sign; the report goes into a web form where typos stay.
- *Verify:* sidebar-report at 1,280 × 800: the editor at least 470 pt high (about 330 today); "Style check 3"
  collapsed; the recommendation in the summary row; "Copy Text" prominent. At 1,000 × 640: the editor at least 320 pt
  high (about 210 today). design-report-empty: "Show Pending Comments". Manual: Copied feedback; misspelt words
  underlined.

#### D9 — Progress that tells a referee how far a long run is · P1 · Shell

- *Files:* `ShellReviewWindowView.swift` (`ShellReviewButton`), `ShellMainMenu.swift`, `ShellReviewWindowController.swift`,
  `ShellScenesTests.swift`, `ShellAppTests.swift`.
- *Change:*
  1. While the review lane runs: `[gauge] {phase} · {elapsed} [Stop]`. Gauge: for `.reading(part, total)` with `total
     > 1`, `ProgressView(value: Double(part - 1), total: Double(total + 1))` `.progressViewStyle(.circular)`
     `.controlSize(.small)` (the `+ 1` is the whole-paper pass that follows the parts); for every other phase, and for
     the report and voice revision, the spinner as today.
  2. Text: `phaseText` without its trailing "…", then " · ", then the elapsed time from `startedAt` in a
     `TimelineView(.periodic(from: startedAt, by: 1))`: "m:ss" under an hour, "h:mm:ss" above; `.monospacedDigit()`. New
     `ShellReviewButton.progressText(kind:phase:elapsed:)`, e.g. "Reading part 2 of 5 · 3:12"; `phaseText` stays.
  3. The button: `Label("Stop", systemImage: "stop.fill")`, `.help("Stop the running job (⌘.)")`. The Review menu item
     "Cancel" becomes "Stop" (⌘.); update `ShellAppTests` line 31.
- *Why:* a 16-page paper on phi4 takes about ten minutes (README); "Reading the paper…" alone does not say whether it is
  moving (design-review-parts). "Stop" matches the Report tab's and the thread's buttons.
- *Verify:* design-review-parts: "Reading part 1 of 3 · 0:0x" with a circular gauge and "Stop". review-running: "Reading
  the paper · 0:0x".

#### D10 — An answer turned into a comment opens in the editor · P1 · Sidebar

- *Files:* `SidebarChatTab.swift`.
- *Change:* `Menu("Make Comment")` becomes `Menu("Add as Comment")`, same four kinds ("Major", "Minor", "Question",
  "Strength"), `.help("Turn this answer into a comment of your own, then edit it")`. The action notes the ids of
  `model.session.comments`, calls `convertReplyToComment`, finds the one new id, then sets `model.selectedCommentID`,
  `model.sidebarTab = .comments` and `model.editingCommentID` to it; the editor opens with the cursor in the comment (D2).
- *Why:* today the comment appears in the other tab and nothing on screen changes; the answer is in the assistant's voice
  and needs rewriting before it can stand as the referee's comment.
- *Verify:* manual (the menu cannot be chosen in a scene). A unit test of the "new id" helper.

### P2

#### D11 — One row of filters, with a Kind menu that includes Strength · P2 · Sidebar

- *Files:* `SidebarFilterChip.swift`, `SidebarCommentsTab.swift`, `SidebarFilterChipTests.swift`.
- *Change:* chips "All", "Pending", "Approved", "Rejected" with counts, then a fifth chip that is a `Menu`: its label is
  "Kind" plus `Image(systemName: "chevron.down")` at 8 pt when no kind is filtered, else "{Kind} {count}" filled in the
  accent colour. Items, checked when in force: "Major (7)", "Minor (11)", "Questions (5)", "Strengths (2)"; choosing
  the item in force again sets `.all`.
- *Why:* seven chips wrap to two rows (about 90 pt) at every sidebar width; strengths cannot be filtered.
- *Verify:* sidebar-states and design-triage-25: one chip row at 1,280 × 800; "Kind ▾" last.

#### D12 — The consent card as facts, a named button, a scrim that shows · P2 · Shell

- *Files:* `ShellConsentCard.swift`, `ShellPlanText.swift`, `ShellPlanTextTests.swift`, `ShellScenes.swift` (consent's
  verify keeps `what`).
- *Change:*
  1. `ShellConsentText` keeps `what` (tests, VoiceOver) and gains `facts: [ShellConsentFact]` (`label`, `value`,
     `isWarning`), shown under the title as a two-column `Grid`, labels `.callout`, secondary, trailing:
     - "What": "The PDF file · 165 KB · 4 pages" or "Extracted text of 4 pages";
     - "To": the host ("api.anthropic.com"), or for a CLI "{vendor}, through {shortName}" ("Anthropic, through Claude
       Code");
     - "Requests": "1 · about 18,000 tokens", plus " · sent as page images" when the descriptor says so;
     - "Kept": `retentionNote`, for every remote provider (not only CLIs);
     - a warning row when text is sent: `exclamationmark.triangle.fill`, orange, "Extracted text only: equations and
       tables may reach the model garbled."
  2. Each paragraph `Text` gets `.fixedSize(horizontal: false, vertical: true)` and `.frame(maxWidth: .infinity,
     alignment: .leading)`; the container loses its `fixedSize` (the early wrap Wave 3 noted).
  3. Buttons: "Don't Send" (`.cancelAction`, Esc) and "Send to {vendor}" ("Send to Anthropic"), `.borderedProminent`,
     orange, no default key.
  4. Scrim `Color.black.opacity(colorScheme == .dark ? 0.5 : 0.28)`.
  5. `ShellPlanText.destinationPhrase` for a CLI: "to {vendor} through {shortName}" ("to OpenAI through Codex"); update
     `ShellPlanTextTests` lines 23, 35 and 79.
- *Why:* the four facts a referee weighs before sending a confidential manuscript are buried in a sentence; "Send" does
  not say to whom; "through claude" names a binary; in dark mode the window does not look blocked.
- *Verify:* consent and design-consent-subscription-pdf in light, dark and 1,000 × 640: the facts grid, "Kept" for both,
  "Don't Send" and "Send to Mock" / "Send to Anthropic"; dark: navigator and sidebar visibly dimmed.

#### D13 — Say when the local provider is not running, for free · P2 · Shell (needs O2; scene needs O3)

- *Files:* `ShellDestination.swift`, `ShellDestinationViews.swift`, `ShellReviewWindowController.swift`,
  `ShellDestinationTests.swift`.
- *Change:*
  1. `ShellDestination.state(provider:…)` gains `availability: ProviderAvailability? = nil`; `state(of:)` passes O2's
     `model.activeAvailability`. When it is
     `.needsSetup` or `.unavailable`: symbol "exclamationmark.triangle.fill", tint orange (red for `.unavailable`), title
     unchanged ("Local"), detail the reason ("Ollama is not running"), tooltip "{reason}. {hint}" with back quotes
     removed ("Ollama is not running. Start the Ollama app or run ollama serve.").
  2. In the destination menu that provider's row adds a caption in orange with the reason and a small "Check Again"
     button (`model.refreshActiveAvailability()`).
  3. The window controller calls `model.refreshActiveAvailability()` on `NSApplication.didBecomeActiveNotification`; the
     menu calls it when it opens.
  4. Remote providers are never checked here: an API check reads the Keychain and a CLI check starts a process.
- *Why:* Wave 3 decision (e): "Local · gemma4:e4b" stays green while Ollama is not running, until a job fails
  (design-banner-provider-down). Ollama's `/api/version` on loopback costs nothing.
- *Verify:* unit test (availability `.needsSetup` gives the symbol, tint and detail). With O3: scene
  `design-review-provider-offline` (Shell; `mock-offline` enabled and chosen): orange "Local" over "Ollama is not
  running". Manual: quit Ollama, open a paper.

#### D14 — The selection bar steps aside once it has been used · P2 · Reader

- *Files:* `ReaderPane.swift` (`ReaderOverlayLayer`), `ReaderSelectionBar.swift`.
- *Change:*
  1. The bar is not shown for a selection that already has its result in the sidebar: when `model.composing?.selection
     == selection`, or when a conversation of `model.session?.conversations` has `anchor?.spans == selection.spans`.
     The PDF selection itself stays, so the passage stays marked while the comment is written.
  2. Copy: the button's label becomes `Label("Copied", systemImage: "checkmark")` for `Theme.feedbackDuration`, then the
     bar hides until the selection changes.
  3. Comment's tooltip: "Write your own comment on this passage (N)".
- *Why:* after Ask AI or Comment the bar keeps covering the line above the passage (Wave 3's note).
- *Verify:* sidebar-chat and design-compose-from-selection: no selection bar over the passage.

#### D15 — Citation card: the record first, one clear next step · P2 · Reader

- *Files:* `ReaderCitationCard.swift`, `ReaderCitationText.swift`, `ReaderCitationTextTests.swift`.
- *Change:*
  1. Order: the mention as header (`Theme.cardTitleFont`) with the close button; the resolved title (`.body.weight
     (.semibold)`, 3 lines); one `.caption` secondary line "authors · year · venue" (2 lines); the tags "Open access"
     (`CommonTag`, green, D16) and the year note; then the reference as printed, `.caption`, secondary, `lineLimit(2)`,
     `.help(rawText)`. Before a lookup returns, the printed reference shows first, as today.
  2. Buttons: Open PDF, Open in Browser and Copy DOI are hidden, not disabled, when they cannot act. The first available
     of Open PDF, Open in Browser, Search Google Scholar is `.borderedProminent`; the others `.bordered`; Show in
     References always last.
  3. Not found: "No match in Crossref or OpenAlex." and, `.caption`, secondary: "Common for working papers and books."
     Update `ReaderCitationTextTests` where "No match found" is pinned.
- *Why:* the resolved title is what the referee wants; white on green "Open access" is below 3:1; failed and not-found
  cards show three disabled buttons (design-citation-states).
- *Verify:* reader-citation: the title above the printed reference, Open PDF prominent, "Open access" green on tint.
  design-citation-states: the failed card shows Retry, Search Google Scholar (prominent) and Show in References only;
  the not-found card the new wording.

#### D16 — Shared tokens: minor not grey, one tag style, one feedback time · P2 · Common (lands first)

- *Files:* `CommonTheme.swift`, a new `CommonTag.swift`, `CommonThemeTests.swift`; adopted in `SidebarCommonViews.swift`
  (`SidebarTag`), `ReaderCitationCard.swift`, `ShellSettingsProviders.swift` by their areas.
- *Change:*
  1. `Theme.kindColor(.minor)`: `.gray` → `.brown`.
  2. `Theme.tagFont: Font = .caption2.weight(.semibold)`.
  3. `Theme.feedbackDuration: Duration = .milliseconds(1_500)`.
  4. `struct CommonTag: View` with `init(_ text: String, color: Color)`; its body is `Text(text).font(Theme.tagFont)`,
     `.foregroundStyle(color)`, `.padding(.horizontal, 6)`, `.padding(.vertical, 1)`, `.background(color.opacity(0.15),
     in: Capsule())`, `.fixedSize()`. Used for "You", "verify", "Revision proposed", "Open access", "Experimental".
- *Why:* a minor comment is a live concern, but its grey badge matches the muted badge of a rejected comment
  (sidebar-states); three areas draw small tags three ways.
- *Verify:* sidebar-states and design-triage-25: MINOR badges brown, the rejected line's badge grey; "verify" and "You"
  filled capsules; settings-providers: "Experimental" unchanged in look.

#### D17 — Location labels say what they mean · P2 · Sidebar

- *Files:* `SidebarCommentCard.swift`, `SidebarCardState.swift`, `SidebarCardStateTests.swift`.
- *Change:* exact: the label; `.help("Show the passage in the PDF")`. Fuzzy: "≈ " + label; `.help("Approximate match:
  the quote differs slightly from the paper's text")`. Page-only: "{label} · page only" with no underline;
  `.help("The model named this page, but its quote was not found on it. Select the passage and choose Attach to
  Selection in the ⋯ menu.")`. Not found: unchanged. VoiceOver: "page 4, lines 14 to 16", ", approximate", ", page
  only".
- *Why:* a dotted underline at caption size is invisible (sidebar-states); the meaning lived in a tooltip.
- *Verify:* sidebar-states: "p. 3 · page only".

#### D18 — The proposal where the discussion ends, with what changed · P2 · Sidebar

- *Files:* `SidebarCommentCard.swift`, `SidebarThreadView.swift`.
- *Change:* with the thread open, the order is messages → proposal box → failed-reply line → reply field. The box gains
  a `.caption`, secondary line "Changes: kind Major → Minor · title · comment · suggestion" listing only what differs
  from the comment. Buttons "Accept Revision" (or "Accept Withdrawal") and "Discard". With the thread closed the box
  stays under the card, as today.
- *Why:* the proposal is the outcome of the discussion but sits under the reply field; the referee compares two versions
  by eye (sidebar-discussion).
- *Verify:* sidebar-discussion: the box right under the assistant's message, above "Reply…", reading "Changes: kind
  Major → Minor · title · comment · suggestion".

#### D19 — A narrow window gives the PDF the room · P2 · Shell

- *Files:* `ShellReviewWindowView.swift`, `ShellWindowServices.swift` (`ShellReviewWindowState`).
- *Change:* `ReviewWindowView` watches its width (`onGeometryChange`). Below 1,100 pt the navigator collapses
  (`navigatorVisibility = .detailOnly`) and `navigatorAutoHidden = true`; at 1,240 pt or more an auto-hidden navigator
  comes back. Showing or hiding it by hand (toolbar, ⌃⌘S) clears the flag, and the rule then leaves it alone for the
  window's life.
- *Why:* at 1,000 pt the PDF is 412 pt wide and set at about two thirds of the page (review-running, small run); the
  thumbnails are the column least needed while reading.
- *Verify:* review-empty at 1,000 × 640: no navigator, the PDF about 620 pt wide; at 1,280 × 800 unchanged.

#### D20 — Ask before re-sending the paper to a paid provider · P2 · Shell

- *Files:* `ShellReviewWindowView.swift`, `ShellReviewWindowController.swift`.
- *Change:* when the session holds AI comments, the button reads "Review Again" (`play.fill`). For a provider that is not
  local, Review Again and ⌘R first show an `NSAlert` sheet: message "Review this paper again?"; informative "The model
  reads the paper again: about 18,000 tokens to Anthropic through Claude Code. New comments are added; comments you have
  decided stay as they are." (figures from `sendPlan`, phrase from `ShellPlanText`); buttons "Review Again", "Cancel".
  Local providers do not ask.
- *Why:* a second review costs the same tokens again (plan R16) and nothing says so.
- *Verify:* manual (a sheet is not captured).

#### D21 — Settings ▸ Providers that leads to a tested provider · P2 · Shell

- *Files:* `ShellSettingsProviders.swift`, `ShellProviderStatus.swift`, `ShellProviderRowsTests.swift`.
- *Change:*
  1. "Send Test Prompt" is disabled unless the availability is `.ready`; `.help("{headline}: {detail}")` ("Needs setup:
     Antigravity is not installed").
  2. Its note by kind (`ShellProviderRows.testPromptNote(for:)`): API key "Sends “Reply with exactly: OK” to
     {destination}; costs a few tokens."; CLI "Runs {shortName} once with “Reply with exactly: OK”; uses one message of
     your plan."; local "Sends “Reply with exactly: OK” to the model on this Mac; costs nothing."; built in "Sends
     “Reply with exactly: OK” to the built-in stand-in." Update `ShellProviderRowsTests`.
  3. A key saved while the provider is off: the status block adds "Switch on {displayName} to use it." and a small
     button "Switch On" (through the binding of D5).
  4. No provider switched on: above the list, `Label("Start with a local model: Ollama keeps manuscripts on this Mac.",
     systemImage: "laptopcomputer")`, `.caption`, secondary, padding 10, `Color.green.opacity(0.08)` in a rounded
     rectangle of radius 8; the pane opens on Ollama.
- *Why:* the test prompt can be pressed for a tool that is not installed, and its note is wrong for subscriptions and
  local models; a saved key leaves the provider off without a word (settings-providers, settings-api-key,
  design-settings-first-run).
- *Verify:* settings-providers: Send Test Prompt disabled for Antigravity; settings-api-key: enabled, the API-key note;
  design-settings-first-run: the start box, Ollama shown.

#### D22 — VoiceOver labels and actions · P2 · all areas

- *Files:* `SidebarCommentCard.swift`, `SidebarCommonViews.swift`, `ShellConsentCard.swift`, `ReaderCitationCard.swift`.
- *Change:*
  1. Card: `.accessibilityLabel("{Kind} comment, {status}, {location}: {title}")`, status "pending", "approved",
     "rejected" or "your own"; `.accessibilityAction(named:)` "Approve", "Reject", "Discuss", "Edit".
  2. Bubbles: "You: {text}" and "Assistant: {text}".
  3. Consent card: `@AccessibilityFocusState` on the title when the card appears.
  4. Citation card: `.accessibilityElement(children: .contain)`, label "Citation {heading}".
- *Why:* a referee using VoiceOver cannot tell a card's status or whose message a bubble is, and must hunt for buttons.
- *Verify:* manual (VoiceOver).

#### D23 — A References list a referee can scan and search · P2 · Reader

- *Files:* `ReaderReferencesList.swift`, `ReaderCitationText.swift`.
- *Change:* above the list, a field (`TextField` with prompt "Filter references", `.roundedBorder`, `.controlSize(.small)`,
  leading `magnifyingglass`) filtering by printed text, case- and diacritic-insensitive, and a `.caption`, secondary count
  "9 references" ("3 of 9 references" while filtering). Each row: `ReaderCitationText.entryHeading(entry)` in
  `.callout.weight(.medium)`, then the printed reference in `Theme.metadataFont`, secondary, `lineLimit(2)`. Filtering
  sends nothing; a lookup still happens only on click.
- *Why:* economists scan references by author and year; "is X cited?" is a common referee question.
- *Verify:* reader-references: "9 references", the field, rows headed "{Surname} et al. (2011)".

#### D24 — The destination menu: providers, facts, keys · P2 · Shell

- *Files:* `ShellDestinationViews.swift`.
- *Change:* a row "Provider Settings…" above "Privacy Settings…" (opens Settings ▸ Providers); the plan sentence becomes
  the facts grid of D12 ("Sends", "To", "Requests", warning row) with the retention note under it; ↑ and ↓ move a
  highlight over the provider rows and Return chooses (`.focusable()`, `.onKeyPress`).
- *Why:* the menu chooses a provider but cannot reach the place to add one; the plan reads better as the consent card's
  facts.
- *Verify:* review-destination-menu: "Provider Settings…" and the grid. Keys: manual.

#### D25 — P: the next undecided comment · P2 · Shell

- *Files:* `ShellTriageKeymap.swift`, `ShellMainMenu.swift`, `ShellReviewWindowController.swift`, `ShellHelpView.swift`,
  `ShellTriageKeymapTests.swift`, `ShellAppTests.swift`.
- *Change:* `TriageIntent.nextPending`; "p" (and key code 35 in `usLetterKeys`) maps to it; `apply` calls
  `model.selectNextComment(pendingOnly: true)`. Review menu "Next Pending Comment" (key hint "p", no modifiers) after
  "Previous Comment". Help row ("P", "Next pending comment, from the top again at the end").
- *Why:* returning days later, the referee wants the next undecided comment; J walks decided ones too; the model already
  has the call.
- *Verify:* unit tests; manual.

### P3

#### D26 — Recent reviews: readable, revealable, deletable · P3 · Shell

- *Files:* `ShellWelcomeView.swift`, `ShellWindowManager.swift`.
- *Change:* titles `lineLimit(2)`; in the progress line only "{n} pending" orange, the rest secondary. Context menu:
  "Open", "Show in Finder" (disabled when the file is gone), "Delete Review Data…" (alert "Delete the review data of
  “{file name}”?" with the File menu's text; then `sessions.deleteSession(sha256:)` and `resolver.forget(documentSHA256:)`,
  closing that paper's window first). A missing file: "File not found" in secondary under the name, and a click opens the
  open panel.
- *Verify:* design-welcome-many: two-line titles, orange only on "12 pending". Menu: manual.

#### D27 — The reference viewer's controls in its toolbar · P3 · Reader

- *Files:* `ReaderReferenceViewerView.swift`.
- *Change:* the in-content bar moves into `.toolbar`: a zoom `ControlGroup` (`minus.magnifyingglass`,
  `plus.magnifyingglass`), "Fit Width", "2 pages" as text, "Find" (`magnifyingglass`), and "Open in Preview"
  (`arrow.up.forward.app`), which opens the file in Preview (`NSWorkspace.urlForApplication(withBundleIdentifier:
  "com.apple.Preview")`). Keys unchanged; the reference-viewer scene's ⌘+ and ⌘0 check must still pass.
- *Verify:* reference-viewer: no bar inside the content; the items in the toolbar.

#### D28 — The Settings window's title follows its tab · P3 · Shell

- *Files:* `ShellWindowManager.swift`.
- *Change:* the window manager observes `settingsNavigation.tab` (`withObservationTracking`) and sets
  `settingsWindow.title` to its title ("Providers", "Prompts", …), as preference windows do.
- *Verify:* manual.

#### D29 — Find dims the comment highlights · P3 · Reader

- *Files:* `ReaderHighlightPlan.swift`, `ReaderController.swift`.
- *Change:* while the find bar is shown, comment and question highlights are drawn at 40% of their alpha, so find's
  yellow matches do not mix with pending yellow; they return when the bar closes.
- *Verify:* reader-find on a paper with comments (a variant of reader-find with `sample.json` on `ay_nolinks.pdf`).

#### D30 — Review prominent before the first review · P3 · Shell

- *Files:* `ShellReviewWindowView.swift`.
- *Change:* idle and the session without comments: the Review button `.buttonStyle(.borderedProminent)`; otherwise as now.
- *Verify:* review-empty: a filled Review button (look past the inactive-window grey).

#### D31 — Earlier versions of a comment · P3 · Sidebar

- *Files:* `SidebarCommentCard.swift`.
- *Change:* the ⋯ menu gains "Earlier Versions" listing `comment.previousVersions` newest first by title (40 characters);
  choosing one calls `model.editComment` with its kind, title, body and suggestion and the comment's category (the model
  keeps the replaced version, so it can be undone the same way).
- *Verify:* manual.

#### D32 — The Dock says when a long job is done (new) · P3 · Shell

- *Files:* `ShellReviewWindowController.swift`.
- *Change:* when a review or report job ends while the app is inactive: `NSApp.requestUserAttention(.informationalRequest)`
  and `NSApp.dockTile.badgeLabel` set to the number of new comments ("✓" for a report); cleared on
  `NSApplication.didBecomeActiveNotification`.
- *Why:* a ten-minute local review is a natural time to switch to another app.
- *Verify:* manual.

#### D33 — Copy for the journal's two boxes (new) · P3 · Sidebar

- *Files:* `SidebarReportTab.swift`, `SidebarReportFacts.swift`.
- *Change:* the Export menu gains a section with "Copy Comments to the Authors" (every section except "Recommendation" and
  "Publication probability") and "Copy Confidential Comments to the Editor" ("Summary assessment", "Recommendation",
  "Publication probability"), sections found by heading text, case-insensitive, with `SidebarMarkdown.heading`, each
  converted with `ReportExporter.plainText(fromMarkdown:)`; the D8 "Copied" feedback.
- *Why:* journal systems have a box for the authors and a confidential box for the editor; the recommendation and the
  probability of publication must not reach the authors.
- *Verify:* unit test of the split on `report_sample.txt`; manual paste.

#### D34 — What was sent so far (new) · P3 · Shell

- *Files:* `ShellDestinationViews.swift`.
- *Change:* the destination menu gains a section "Sent so far": one line per provider from `session.runs`: "{displayName}:
  {n} times, last {date} (PDF file)" or "(extracted text)"; "Nothing has been sent yet." when there is no run.
- *Why:* the session already keeps every send; showing it lets the referee confirm that nothing went elsewhere.
- *Verify:* review-destination-menu with sample.json's run: one line.

#### D35 — Chat tab empty state · P3 · Sidebar

- *Files:* `SidebarChatTab.swift`.
- *Change:* `ContentUnavailableView` with `Label("No questions yet", systemImage: "text.bubble")` and "Select a passage in
  the PDF and choose Ask AI, or ask about the whole paper in the field below."
- *Verify:* design-chat-empty.

## Outside `Sources/RefereeUI`

All additive, with defaults; nothing existing changes meaning.

| # | Target | Addition | For | Tests |
| --- | --- | --- | --- | --- |
| O1 | AppCore, `ReviewSessionModel` | `public var chatProvider: ProviderDescriptor? { resolveTarget(for: .chat)?.descriptor }` and `public var reportProvider` the same for `.report`; read-only, observable through `session` and `settings` | D4 | one AppCore test: defaults.chat set, no preferred provider → `chatProvider` is it; a preferred provider → all three equal |
| O2 | AppCore, `ReviewSessionModel` | `public private(set) var activeAvailability: ProviderAvailability?` and `public func refreshActiveAvailability()`: for a local active provider calls its `availability()` (Ollama: `/api/version` on loopback, 2 s), for any other sets nil; called by the model after `refreshPlan` when the provider changes | D13 | AppCore test with a scripted local provider: needsSetup → published; remote → nil, `availability()` never called |
| O3 | TestSupport, `SnapshotSupport.providers()` (optional) | two stand-ins appended after the nine rows, not switched on by `settings()`: `mock-slow` (`MockLLMProvider`, every purpose with `delayPerChunk: .milliseconds(40)`), `mock-offline` (`StaticProvider`, local, availability `` .needsSetup(reason: "Ollama is not running", hint: "Start the Ollama app or run `ollama serve`.") ``) | scenes `design-report-streaming`, `design-review-provider-offline` | update `SnapshotSupportTests` line 14 (the two ids appended) and line 72, and `SnapshotRowsTests` line 17 (`.dropFirst(4)` → `.dropFirst(4).prefix(9)`) |

Without O3, the report mid-generation (D8's streaming state) and the offline indicator (D13) are verified by hand.

## Keep as is

These work and must not regress.

- The three columns (navigator, PDF, inspector) with no declared minimum width; the 1,000 × 640 window minimum.
- The triage keymap and its rules: single keys only when no text is being edited; Esc's order (consent, menu, card,
  composer, editor, thread, find bar, selection); auto-advance after A and R.
- Highlight meanings: pending yellow, approved green, own blue, question purple, fuzzy dashed border, selected stronger;
  the PDF never modified.
- In-window overlays with opaque backgrounds (citation card, selection bar, find bar), legible over a white page in dark
  mode.
- The consent card's rules: it blocks the window, Send is not the default button, Esc answers no, "Ask again next time",
  the journal-policy reminder; the always-visible indicator with green for this Mac and orange for anything else.
- Inline failures for replies (red line with Retry), banners only for the review lane.
- Rejected comments as one grey line with Undo on hover; similar comments folded with "Similar to:".
- Esc closing the find bar only after the model's transient UI; the find bar's count and orange current match.
- Search Google Scholar always available on a citation card; Show in References.
- The report's Markdown editor with bold headings, Preview, Versions, the style check selecting its range, the
  recommendation mismatch warning; the export panel's format picker keeping ".md".
- Settings ▸ Privacy's plain-language summary, the data folder with "~", the delete confirmations that say the PDFs are
  untouched; install and sign-in commands with Copy.
- File ▸ Delete Review Data… as a sheet with its wording.

## Implementation split

### First, on `main`, one agent (small)

1. D16's Common tokens and `CommonTag` (`CommonTheme.swift`, `CommonTag.swift`, `CommonThemeTests.swift`).
2. O1 and O2 in AppCore with their tests.
3. O3 in TestSupport, if wanted, with the three test updates.

Merge, build, `scripts/test.sh`, `scripts/snapshots.sh` (every scene passes; pictures change only where minor badges
turn brown). The three area agents start from this commit.

### Then three agents in parallel, one worktree each

| Agent | Items, P1 first | Owns |
| --- | --- | --- |
| Sidebar | D1, D2 (sidebar parts), D6, D7, D8, D10, D11, D17, D18, D22 (cards, bubbles), D31, D33, D35 | `Sources/RefereeUI/Sidebar/`, `Tests/RefereeUITests/Sidebar/` |
| Shell | D3, D4, D5, D9, D12, D13, D19, D20, D21, D24, D25, D2 (help row), D22 (consent), D26, D28, D30, D32, D34 | `Sources/RefereeUI/Shell/`, `Tests/RefereeUITests/Shell/` |
| Reader | D14, D15, D23, D2 (selection bar's field), D22 (citation card), D27, D29 | `Sources/RefereeUI/Reader/`, `Tests/RefereeUITests/Reader/` |

- No file is shared between the three. The couplings are through the model and Common only: D6 uses
  `uiActions.openSettings` (exists); D14 reads `model.composing` and `model.session.conversations`; D4 and D13 read O1
  and O2.
- Each agent extends the `verify` of its own `design-` scenes when an item makes a state checkable, adds the scenes this
  review names (`design-review-split-destinations`; with O3 `design-review-provider-offline` and
  `design-report-streaming`), and keeps `placeholder` and the three `check-` scenes passing.
- Each agent runs its area's tests, then `scripts/snapshots.sh` in light, `--dark` and `--size 1000x640`, and looks at
  every scene its items name.
- `README.md` and `plan.md` are shared: agents list their wording changes in their notes, and one docs pass after the
  merge updates the README (keys table with P and Esc-in-a-field, page-only wording, test-prompt note, consent card) and
  plan §9 (tables of §9.3, §9.4, §9.7, §9.8, §9.9, §9.10).

## Scenes added for verification

All pass (`"failures":[]`) in light, dark and 1,000 × 640. Run one with `scripts/snapshots.sh --scene <name>`.

| Scene | Area | Fixture | Shows | Items |
| --- | --- | --- | --- | --- |
| design-welcome-first-run | Shell | — | welcome window, no recent reviews, no provider | D5 |
| design-welcome-many | Shell | — | 14 recent reviews, long titles, journal file names; "AI: Local · gemma4:e4b" | D26 |
| design-review-no-provider | Shell | ay_round_nolinks.pdf | every provider off: "No AI provider", Review disabled | D5, D6 |
| design-review-long-names | Shell | ay_round_nolinks.pdf | long file name and the longest indicator (experimental CLI, long model, text only) | D3 |
| design-review-parts | Shell | ay_long.pdf | a review read in three parts, stalled in the first | D9 |
| design-consent-subscription-pdf | Shell | ay_round_nolinks.pdf | consent for a CLI that receives the PDF, with its retention line | D12 |
| design-banner-provider-down | Shell | ay_round_nolinks.pdf | a local provider failing at once: banner with Retry, indicator still green | D13 |
| design-settings-first-run | Shell | — | Settings ▸ Providers with nothing on and no default, Ollama shown | D5, D21 |
| design-citation-states | Reader | ay_links.pdf | citation cards for a failed lookup, no match, and no matching entry (drawn by the scene: the snapshot resolver always resolves) | D15 |
| design-find-no-matches | Reader | ay_round_nolinks.pdf | find bar, "No matches" | — |
| design-triage-25 | Sidebar | ay_long.pdf + design-triage.json | 25 comments in every state, the tenth selected | D1, D7, D11, D16, D17 |
| design-triage-done | Sidebar | ay_long.pdf + design-triage.json | every comment decided | D6 |
| design-compose-from-selection | Sidebar | ay_nolinks.pdf | N on a selected passage | D2, D14 |
| design-reply-failed | Sidebar | ay_nolinks.pdf + sample.json | a discussion reply that failed | D18 |
| design-report-empty | Sidebar | ay_round_nolinks.pdf | Report tab with nothing approved | D8 |
| design-chat-empty | Sidebar | ay_round_nolinks.pdf | Chat tab with no question | D35 |

Notes for whoever runs them:

- The scenes are registered with a one-line change in each area's `all`. Two tests pinned those lists exactly
  (`theSevenScenesOfSection101` in `SidebarScenesTests` and `ReaderViewerAndScenesTests`); each now compares the list
  without its `design-` scenes. Nothing else in the code changed.
- `Fixtures/sessions/design-triage.json` is invented text; its quotes come from `ay_long.pdf`, so the session anchors
  them when it opens (one quote is deliberately absent: page only; one has no page: unanchored).
- The full `scripts/test.sh` was run with `--skip LLMKitLiveOllamaTests`: Ollama was running on this Mac, and that one
  test sends a 16-token prompt to it, which this step's rules forbid. 983 tests passed.
