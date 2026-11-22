# WP8b — The two models

Notes of the work package "The two models" (`plan.md` §11.4, WP8b): `ReviewSessionModel`, `SettingsModel` and `SelectionNormalizer` in `Sources/AppCore`. Read by Gate 1 and by the three UI packages of Wave 2, who build every view on these models.

## What exists after this step

| File | What it holds |
| --- | --- |
| `Sources/AppCore/ReviewSessionModel.swift` | The window model: every member of Appendix A.9 with the behaviour of WP8b's list, plus an internal `init(dependencies:settings:clock:)` for tests |
| `Sources/AppCore/SettingsModel.swift` | The settings model, same pattern (internal init with a clock, internal `flushPendingSave()`) |
| `Sources/AppCore/SelectionNormalizer.swift` | §7.4 normalisation with the hyphen rule of §6.2 |
| `Sources/AppCore/CommentOrdering.swift` | The one display order of Appendix A.9, and the filter |
| `Sources/AppCore/ModelClock.swift` | The injected clock behind every date and debounce |
| `Sources/AppCore/ModelJobs.swift`, `ModelSupport.swift` | Internal job types; small pure rules (version caps, the recommendation parser, titles) |
| `Sources/AppCore/ModelTypes.swift` | Unchanged (Appendix A.9 value types) |
| `Tests/AppCoreTests/*` (not `Export/`) | 102 tests with the Wave 0 smoke test: every acceptance row, plus the behaviours below |

The public surface is exactly Appendix A.9 and the `SelectionNormalizer` entry of §11.3; nothing public was added. `exportReport` and `reportText` call WP8a's `ReportExporter` as the Wave 0 placeholder did.

## Decisions

Where the plan was silent. Each file also lists its own at the top.

**Jobs and lanes**

1. A lane is busy from the moment a job is accepted, through its consent card and the pre-run save, to the end of its run. A second job for a busy lane is ignored; `canStartReview` is false meanwhile.
2. `runState` describes the review lane only. It turns `.running(kind:phase:startedAt:)` as soon as the job is authorised (before the pre-run save), not while the consent card is up. The reply lane shows through `streamingTargetID`, which is set when the reply starts (after consent and the save) and cleared at its end.
3. Pre-flight is synchronous (`Task.immediate`): when `startReview()` and the other job methods return, a missing-provider or Local-only banner is already shown, and so is the consent card whenever `sendPlan` was computed for that very provider and context. For a job on another provider (a chat default, say) the card follows a call of `engine.plan` for that provider.
4. The provider of a job is the first non-nil of `session.preferredProvider`, `settings.defaults.<job>`, `settings.defaults.review` (review → `.review`, discussion and question → `.chat`, report and voice revision → `.report`). If that provider is not registered or not enabled, the job stops with the banner; there is no fall-back to the next default. The model id is `ref.model ?? settings.providers[id].model`.
5. `activeProvider` and `activeModel` describe the review job's provider, also a remote one while Local only is on (so the indicator can say "Remote blocked (Local only)"). `setActiveProvider` accepts only a provider of `selectableProviders`, and only with a document open.
6. `canStartReview` also requires `sendPlan != nil`. A plan computed for another provider or model is dropped the moment the provider or model changes; for other settings changes the old plan stays until the new one arrives. `reloadSettings` with settings equal to the current ones does nothing.
7. Model lists: a cached list is fresh when it is non-empty and `cachedModelsAt` is at most 24 h old (no date counts as stale). A fresh cache wins; otherwise the list this window fetched, then the stale cache. A failed fetch is not retried in that window. Nothing is fetched for a non-local provider while Local only is on. When the active provider's list arrives, the plan is computed again. The window never writes a list into the settings (only `SettingsModel.refreshModels` does).
8. Consent: one card at a time; a job that needs consent while another card is up is dropped. `cancelRun`/`cancelReply` of the card's lane, `close()` and `deleteReviewData()` answer it "no". A yes records one `ConsentRecord` per provider and document, never two.
9. Every run that reported `.started` is recorded in `session.runs`: as the engine finished it, or `.cancelled` when the job was cancelled, or `.failed` when the stream threw or ended without `.finished` ("The run ended before it finished."). A cancelled run shows no banner.
10. Failure banners, all errors with Retry: "Review stopped: …", "Report stopped: …", "Voice revision stopped: …", "Reply stopped: …". "Set up an AI provider" is an error with Open Settings; "Remote providers are blocked by Local only" is an error without an action.
11. Banners: one at a time; a new banner never replaces one of a more serious style (error > warning > info). Info notices fade after 6 s in the model itself (on its clock), so `BannerView` needs no timer.
12. `generateReport()` with no comment that is approved and included shows the info banner "Approve at least one comment first." and starts nothing.

**Review, discussion, questions**

13. A `.comment` event whose id is already in the session replaces that comment (a retried run with the same ids does not double it). Drafts are cleared at the end of every run.
14. A discussion message or question is trimmed (an empty one is ignored) and joins the thread only once the job may run. The engine gets the comment or conversation as it was before that message (the transcript) and the message itself. On success the reply is appended (its `provider` filled in with the job's provider when the engine left it nil); a proposal replaces an earlier one only when the new reply carries one. A failed or cancelled reply adds nothing; the referee's message stays, and Retry sends it again without adding it a second time.
15. `ask` switches the sidebar to Chat at once. Conversations are stored in creation order; the Chat tab shows them newest first. A follow-up ignores the selection; a new question anchors to the normalised selection (nil = whole paper).
16. `convertReplyToComment`: pending, origin `.user`, category "other", body = the answer, title = its first ten words (at most 120 characters), anchor = the conversation's (unanchored when it has none), included in the report.

**Triage, ordering, editing, own comments**

17. Auto-advance happens after approve and reject only, not after "back to pending". The next pending comment after the decided one in visible order is selected and revealed, wrapping round to the first; with none left the selection stays.
18. `selectNextComment(pendingOnly: false)` stops at the end; `pendingOnly: true` wraps round. `selectPreviousComment()` stops at the start. With nothing selected, next picks the first and previous the last. A selected comment that the filter hides is placed by the unfiltered order. Both also reveal the passage (the key map only calls them).
19. Ordering details: a comment's page is that of its first span, else `anchor.pageIndex`; a span that starts between two lines counts as on the line before; equal keys keep the stored order.
20. `editComment` pushes a version only when something changed, turns a blank suggestion into nil, and ends editing of that comment. `setKind` pushes no version. Accepting a withdrawal rejects without pushing a version. `deleteComment` and `deletePendingAIComments` also clear the selection, editor, open thread and `similarTo` that pointed at a removed comment, and stop a reply streaming to it.
21. `addUserComment` and `reanchorComment` normalise the selection they are given again (idempotent), so a raw selection works too. The selection's rectangles are reused when normalising left the spans unchanged; otherwise they are fetched. Without a selection an own comment has `quote == ""`, no spans, no page and confidence `.none`. Re-anchoring replaces the quote with the normalised text.

**Report**

22. Versions are built from the old draft (an engine's own `versions` field is ignored), with the notes "before regenerate", "before voice revision" and "before restore"; an empty draft is not kept; at most 10, newest last. `restoreReportVersion` keeps the replaced text as a version, marks the draft `userEdited` and reads the recommendation from the restored text.
23. When the engine leaves them empty, `generatedAt` (now), `provider` (the job's), `basedOnCommentIDs` (the approved, included comments) and `recommendation` (parsed: of "reject", "major revision", "minor revision", "accept", the one that occurs first in the "Recommendation" section) are filled in. A voice revision keeps `basedOnCommentIDs` and the old recommendation when the new text names none; both generation and revision set `userEdited = false`.
24. Lint runs when a document with a report opens, at once after generation, revision and restore, and 0.5 s after the last edit. `updateReportMarkdown` with the current text does nothing; without a draft it creates one (`userEdited`).

**Opening, saving, deleting**

25. `paper` is published as soon as it is loaded (the reader can show the PDF), the session once it is complete. A new session's `meta.title` is `paper.text.titleGuess`; `fileName` and `lastKnownPath` come from the URL, for new and stored sessions. Anchors that have spans but no rectangles get rectangles on open too. The matcher and the citation index are built off the main actor. Opening while a document is open closes it first.
26. When the store cannot read the session: `.corrupt` (the store has moved the file aside) gives a new session that is saved; `.newerSchema`, `.io` or any other error gives an in-memory session that is never saved. Either way the error banner shows the store's message.
27. Autosave waits for a deadline on the injected clock; saves run one after another and write the session as it is then. A failed save shows its message as an error banner and keeps the changes pending. `flushPendingSave()` saves now and waits for a save already under way. `deleteReviewData()` stops all writing before it cancels the jobs, so nothing can recreate the folder.

**Citations and the reader**

28. A later lookup supersedes an earlier one; Esc (`dismissTransientUI`) discards a lookup in flight; a mention with no candidate entries resolves to empty lists; unknown ids are ignored.
29. `readerClickedComment` with a conversation's id switches the sidebar to Chat. `readerSelectionChanged` publishes the normalised selection at once with empty rectangles; late rectangles of an earlier selection are dropped.

**Selection normalisation**

30. Each clipped piece is also trimmed of white space, and its span with it (" As shown…" starts at "As"). Two spans on one line give one span (their union inside `contentRange`). Spans come back in text order. Hyphens for the rule of §6.2 are "-", U+2010 and U+00AD; "occurs unbroken elsewhere" is checked as a whole word, ignoring case, inside one `.body` line.

**Settings model**

31. `update` posts `.refereeSettingsDidChange` at once, with the model as the object; the save follows 0.5 s after the last change; a mutation that changes nothing neither posts nor saves.
32. `models` starts from each provider's `cachedModels`. `refreshModels` writes `cachedModels` and `cachedModelsAt`, and preselects the first listed model when none is chosen, except for subscription CLIs (whose default is the CLI's own, §5.2).
33. `storedSecrets` is read in `refreshAvailability` for API-key providers (the key name is the provider id, §5.8), not at init, so launching the app does not touch the Keychain. A blank value removes the key; values are trimmed.
34. With Local only on, `refreshModels` and `sendTestPrompt` do not contact a non-local provider (they report "Remote providers are blocked by Local only").
35. The test prompt is one user part "Reply with exactly: OK", an empty system prompt, purpose `.ping`, the provider's chosen model. Success means the stream reached `.finished`; the trimmed text is returned.
36. `resetPromptsToDefaults` restores the prompts, the quick questions and the rubric (everything on the Prompts tab), nothing else.
37. `applyFirstRunDefaultsIfNeeded` also requires the "ollama" descriptor to be local (an Ollama on another host is remote); it keeps a model already chosen for Ollama when the list has it, otherwise the first; it fills Ollama's `cachedModels`; chat and report defaults stay "Same as Review".

## Contract problems

None of the frozen tests failed. The shapes below were kept; each workaround lives in `Sources/AppCore`.

1. **The consent card's "Ask again next time" cannot reach the model** (§9.7; Appendix A.9 `answerConsent(granted:)`). *Workaround:* a yes always records consent. *Suggested:* `answerConsent(granted: Bool, askAgain: Bool = false)`.
2. **No state for a failed reply** (§9.3 "reply failed: red inline line under the thread with the error message and Retry"; §9.9 thread and Chat rows; Appendix A.9). *Workaround:* a failed discussion or question reply raises the banner "Reply stopped: …" with Retry. *Suggested:* a public `replyFailure: (targetID: UUID, message: String)?` cleared by the next reply or by Retry.
3. **No way to reveal a conversation's passage** (§9.5 Chat tab "the quoted passage (click → reveal)"; Appendix A.9). *Workaround:* `revealSelectedCommentInPDF()` also accepts a conversation id in `selectedCommentID`. *Suggested:* `revealConversationInPDF(_ id: UUID)`.
4. **`SettingsModel` has no place for a secret-store error** (WP8b row "settings model": "reports the error"; Appendix A.9). *Workaround:* the error's message goes into `modelErrors[key]` (the key is the provider id) and is removed when a later `setSecret` for that key succeeds. *Suggested:* a separate `secretErrors: [String: String]`.
5. **`SessionStoring.loadSession` cannot say that it fell back to the `.bak`** (§4.5: "a banner reports what happened"; Appendix A.4). The model shows a banner only when the store throws. For WP8a and Gate 1 to decide.
6. **`TextRange` clashes with a C struct of the same name** (Appendix A.1). `import Foundation` on macOS brings in `struct TextRange { fStart, fEnd, fHiliteStyle }` from CoreServices' `AERegistry.h`. Outside `RefereeCore`, `TextRange` as a type annotation is "ambiguous for type lookup"; an initialiser call with the labels `location:length:` still resolves. *Workaround:* write `RefereeCore.TextRange` (done in `SelectionNormalizer.swift` and the tests). Every UI file will meet this; Gate 1 may prefer to rename the type.

## For Gate 1

- Tests reach the internal `init(dependencies:settings:clock:)` and the internal waits (`waitForBackgroundWork()`, `reviewLaneTask`, `autosaveTask`, `lintTask`) through `@testable import AppCore`. With the public init the model uses the wall clock: autosave 1 s, lint 0.5 s, notices 6 s.
- "Selection on a real page": the rectangles arrive after `readerSelectionChanged` returns; wait until `model.selection?.rects.count == 2` before checking `x` and `width`.
- "Model end to end": a job runs in the background; wait for `model.runState == .idle` (review lane) or `model.streamingTargetID == nil` (reply lane), then `await model.flushPendingSave()` before reading the store. The provider must be registered and `settings.providers[id].enabled`.
- "File safety": `deleteReviewData()` writes nothing after it starts, so `sessions/<sha>/` stays gone.
- Merging with WP8a: the files are disjoint. My test helpers carry model-specific names (`ModelSample`, `ModelHarness`, `makeModelHarness`, `waitForModel`, `ManualModelClock`, `CountingModelProvider`, …) so they cannot clash with WP8a's tests in the same target.
- `scripts/snapshots.sh --scene placeholder` passes with these models in this worktree (window titled `ay_round_nolinks.pdf`, page 1 shown, no failures).

## For the UI packages (WP9, WP10, WP11)

- **Running state.** Review lane: `runState` (Review/Report buttons, phase text). Reply lane: `streamingTargetID` is the comment or conversation receiving a reply; disable Send while it is non-nil. Report and voice revision stream into `streamingReportText`; discussions and questions into `streamingReplyText`.
- **Banner** (Shell): show `model.banner`; `.retry` → `retryLastFailedJob()`, `.openSettings` → the window opens Settings; close → `dismissBanner()`. Do not fade notices yourself; the model does.
- **Consent card** (Shell): shown while `consentRequest != nil`; Send → `answerConsent(granted: true)`, Cancel → `answerConsent(granted: false)`. The "Ask again" box cannot be honoured yet (contract problem 1).
- **Destination indicator** (Shell): `activeProvider` (nil = "No AI provider"), `activeModel`, `sendPlan`, `settings.privacy.localOnly`; the menu lists `selectableProviders` and calls `setActiveProvider`.
- **Selection** (Reader): call `readerSelectionChanged` with the raw `SelectionInfo` (after your 150 ms debounce). `model.selection` comes back at once with `rects == []`; place the selection bar when the rectangles arrive.
- **Comments** (Sidebar): list `visibleComments`; drafts in `drafts` under "Writing…". An own comment without a passage has `anchor.quote == ""` and confidence `.none`: do not label it "Passage not found". Card clicks set `selectedCommentID` and call `revealSelectedCommentInPDF()`; J/K, auto-advance and highlight clicks already reveal or select.
- **Chat** (Sidebar): `session.conversations` is in creation order; show it reversed. To reveal a conversation's passage set `selectedCommentID` to its id and call `revealSelectedCommentInPDF()` (contract problem 3). Reply failures arrive as the banner (contract problem 2).
- **Report** (Sidebar): `session.report.versions` is newest last; pass its index to `restoreReportVersion(at:)`. Ask before regenerating when `session.report.userEdited`.
- **`TextRange`:** write `RefereeCore.TextRange` in type annotations (contract problem 6).

## Acceptance

Run on Command Line Tools 26.6 (Swift 6.3.3), with `-j 2`, after touching every file of `Sources/AppCore` and `Tests/AppCoreTests` outside `Export/`.

| Command | Result | Final line |
| --- | --- | --- |
| `scripts/build.sh -j 2` | exit 0; no line with "warning" or "error" | `Build complete! (5.88s)` (incremental, after the touch) |
| `scripts/test.sh -j 2 --filter AppCoreTests` | exit 0; no "warning" | `test.sh: OK (102 tests)` |
| `scripts/test.sh -j 2` | exit 0; no "warning"; every target passes | `test.sh: OK (228 tests)` |
| `git status --porcelain \| wc -l` | | `0` |
