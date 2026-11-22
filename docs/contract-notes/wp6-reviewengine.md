# WP6 — ReviewEngine

Notes of WP6 (`plan.md` §11.4). Read by Gate 1. Everything is in `Sources/ReviewEngine/` and `Tests/ReviewEngineTests/`; nothing outside them changed.

## What exists after this step

| File | What it does |
| --- | --- |
| `ReviewEngine.swift` | The public class of §11.3. Every LLM job is a cold `JobStream`; `plan` and `lint` are direct. An internal initialiser takes the debug-dump folder (tests) |
| `Planning.swift` | The constants of §6.4, `TokenBudget` (context, reserve, input budget, Ollama cap), the PDF decision of §6.2 with its warnings, the review plan (one pass or parts), the paper-context decision for replies and the report (60% rule) |
| `PromptBuilder.swift` | System prompts and rubric block, the task texts filled by the rules of `FormatSpec`'s doc comment (one-pass replacement, so a value with braces is never re-filled), the discussion, question, report and voice-revision user turns |
| `CommentStreamParser.swift`, `CommentLineSyntax.swift`, `CommentValues.swift`, `Folding.swift` | The line state machine of §6.5 with the MARK/FIELD patterns, the value clean-up of rule 5, and §6.7's folding (the engine needs its own copy; it cannot import `PaperText`) |
| `ParserFallbacks.swift` | JSON fallback and "Unstructured model output" |
| `ReplyParser.swift` | The visible reply and the `@@REVISED` / `@@WITHDRAW` proposal of §6.8 |
| `ReviewJob.swift` | §6.6: phases, drafts, anchoring, the repeat / strength / same-passage rules, continuations, parts with notes and the digest, the PDF→text fallback, failure and cancellation |
| `ReplyJob.swift`, `ReportJob.swift`, `PaperContext.swift` | Discussion, question, report and voice revision, and the paper context of §6.3 |
| `ReportStructure.swift`, `ReportLinter.swift` | Headings, sections, the recommendation of §6.10, and the rules of Appendix B.7 |
| `EngineRun.swift`, `JobStream.swift`, `DebugDump.swift` | Run bookkeeping and the streaming of one request; the cold stream; §10.5 |
| Tests (80) | Every row of the acceptance table, plus the life of a stream, the reply and report failure paths, the debug dump. Fixtures in `Tests/ReviewEngineTests/Fixtures/.llm/` (contract problem 1) |

## Decisions

Where the plan was silent or left a choice.

1. **Cold streams and cancellation.** A job runs in a task of its own, started on the first `next()`; nothing is sent for a stream that is never iterated, and dropping a stream cancels its job. The stream never throws. A consumer cancelled *while it waits* for the next event receives the job's `.finished` with a cancelled run (anything in between is skipped), then the end. A consumer cancelled *between two events* sees the stream end at once: this is how `AsyncThrowingStream(unfolding:)`, the only cold form of the frozen return type, behaves (verified with a probe). See contract problem 3.
2. **The run record.** `.started` carries `requestCount` 0 and `sentPDF` false; `.finished` carries every request actually sent (continuations and a refused PDF request included), `sentPDF` true if any request carried the file, and usage summed over requests (nil when no provider reported any).
3. **Planning.**
   - "Provider is Ollama" means `descriptor.id == "ollama"`; "CLI" means `authMode == .subscriptionCLI`. A zero or negative override or model window counts as unknown.
   - A provider that accepts PDF files but has no `pdfTokensPerPage` entry (the mock) is charged 4,500 tokens a page, with no page limit. 30 MB is 30,000,000 bytes (Finder's megabytes).
   - Warnings: a failed PDF condition is reported whenever PDF mode was possible from the provider's side (also in automatic mode: the acceptance row "model == nil → text mode with a warning" needs that), and when `inputMode == .pdf` meets a text-only provider. Nothing is said for `inputMode == .text`, or for a text-only provider in automatic mode. When the window was assumed, the warning says so ("… 128,000 tokens were assumed."). A plan read in parts adds "Paper will be read in N parts, then once more as a whole (N+1 requests)."; an Ollama plan read in parts because of the memory cap adds a line naming the model's real window.
   - The estimate is the PDF's pages × rate, or the rendered text's characters / 3.5 (plus 2,400 notes characters per request after the first, for parts). Prompt overhead is not included, as in §9.7's "about 153,000 tokens".
   - Blocking: a context too small is checked first, then a missing text layer. An unknown provider id gives a blocking reason (`LLMError.notConfigured`'s message) and destination "". `providerSettings.enabled` is not consulted: AppCore decides what can be chosen.
   - Requests carry `model = context.provider.model`; for Ollama `contextWindow` and `maxOutputTokens` are the context and the reserve, otherwise `nil` and `providerSettings.maxOutputTokens`.
4. **Prompts.** The system prompt is `reviewSystem`, the rubric block and `FORMAT_REVIEW`, separated by an empty line. The rubric block uses B.2's header line; with nothing enabled it lists `- other: Other.`. Optional lines take the trimmed notes (line breaks kept), the venue, and the titles of existing non-rejected comments joined by "; ". A later part with no notes yet says "(none)"; `{titles}` with nothing to list says "none". Discussions and questions name the speakers "Referee:" and "Assistant:"; a last thread message equal to the new message is not repeated. Empty quote or suggestion lines are left out of the comment blocks; an unanchored comment has no location in the report's `[M1]` line.
5. **Parser.**
   - "First of major, minor, question, strength" is read in list order, then the synonyms critical, query, praise, positive. Category: the folded value or its first word against the enabled ids and names, else `other`. Quote: surrounding quotation marks, guillemets, backticks and emphasis markers removed. Title: emphasis and heading marks removed, cut at a word boundary to 119 characters plus "…".
   - Lines before any field in a block are kept and become the body if the block never sets one (a comment written as prose between markers).
   - A `@@COMMENT` line ends a notes section and opens a block (§6.5 rule 1 reads "all following text up to `@@DONE`"; models that write notes and then more comments keep the comments). Notes from several sections are joined.
   - Drafts: kind, category and page come from complete lines only; quote, title, body and suggestion also show the unfinished line once it can no longer become a marker or a field line. So a draft only grows, tested with chunks of 1 and 7 characters. A draft stops updating past 8 KB in its unfinished line or 16,000 characters in its block.
   - Bounds: lines are matched on their first 256 characters, a line is cut at a million characters, a stored field line at 20,000, a block at 100,000, notes at 50,000. The JSON fallback looks at 2 MB and eight candidate brackets at most.
6. **Review rules.**
   - Fallbacks apply to a request and its continuations together, and only when none of the answers had a block, `@@DONE` or `@@NOTES` (otherwise "If you have nothing to add, write only @@DONE" would become an "Unstructured model output" comment). An empty answer gives the notice "The model returned an empty answer." The unstructured comment bypasses the rules and is not listed in later tasks.
   - Same passage: when either comment has no spans (the matcher found neither quote, as `FakeQuoteMatcher` on the sample paper with the Table 2 quote), the same passage is the same folded quote. With spans, the 80% is of the new comment's span characters.
   - The repeat rule's key is the folded quote and the folded title; rejected existing comments neither count nor go into the task.
   - The strength notice comes at the end (before `.digest`), also on failure: "2 further strength comments were left out, because a review keeps at most 2: “A”; “B”."
   - A cut-off answer is continued with the same parts before the cache boundary (one pass) or the part's text (parts) and `TASK_CONTINUE`; its titles include the existing comments. After the second continuation, a notice says the answer was cut off. A refusal ends the request with its notice, without continuation.
   - On a provider error the open block is closed as it stands and emitted (§6.6); on cancellation it is not.
7. **Parts.** Notes carried to the next part and emitted as the digest are cut to 2,400 characters (`notesBudgetChars`) at a line or word break. The digest is emitted only when the run completes and the notes are not empty, so a failed or cancelled run never replaces an earlier, complete digest.
8. **PDF fallback.** In a review the whole job is planned again with text forced (possibly in parts), once, with the notice "The provider did not accept the PDF file (<message>), so the review was restarted with the text extracted from it." Comments already emitted stay; exact repeats are dropped by the repeat rule. Replies and the report retry silently (their events have no notice), and only before any text was streamed.
9. **Replies.** On failure or cancellation the reply is what was shown and the proposal is nil. A revision block that leaves out kind, title or body keeps the comment's own; a missing suggestion proposes none. Text after the block or after `@@WITHDRAW` is ignored.
10. **Report.** The approved, included comments go in the order major, minor, question, strength, each in the order of `visibleComments` (page, line of the first span, page-only first on its page, unanchored last, then creation time). An outer code fence is removed from the answer; an empty answer fails the run. On success `versions` is the session report's history unchanged: WP8b's block says the model pushes the old draft. On failure or cancellation the draft is the session's previous report (or an empty one), so a caller that stores it loses nothing. The recommendation is looked for in the section's first sentence, then in the whole section, in the order reject, major revision, minor revision, accept ("Accept with minor revisions" is a minor revision). A heading "Recommendation: Reject" counts.
11. **Lint.** Word-boundary wrapping only where a pattern starts or ends with a letter (the em dash and the comma of the "-ing" clause have none). A line of bold text naming one of the six sections counts as a heading. `missing-section` findings have an empty range at the end of the text. The mismatch rule counts numbered and bulleted items under "Major concerns". The `check-word` message is B.7's text as printed. Findings are in document order, numbered from 0.
12. **Paper context.** The excerpt is introduced in plain words ("The manuscript is too long to include in full. These notes … Pages 3 to 5 follow, as text extracted from a PDF …"). When the page and its neighbours do not fit the 60% allowance, the page goes alone, cut at a line break if needed. A reply whose paper has no text layer and no PDF route is sent without paper context (it is not blocked).
13. **Logging.** Event names: `engine.request`, `engine.response`, `engine.review.planned`, `engine.review.dropped`, `engine.review.fallback`, `engine.review.textfallback`, `engine.reply.textfallback`, `engine.report.textfallback`, `engine.run.finished`, `engine.debugdump.written`, `engine.debugdump.failed`. Values are provider ids, purposes, run kinds, statuses, stop reasons and `LLMError` case names, numbers and booleans. Model ids are never logged (a typed id may not pass the `.id` filter).
14. **Debug dump.** `<timestamp>-<purpose>.txt`, timestamp `yyyyMMdd'T'HHmmss.SSS'Z'` in UTC (`.1`, `.2` … added on a collision), mode 0600, one file per request with its parameters, the system prompt, every part (a PDF part by size only) and the raw output; written also for failed and cancelled requests.

## Contract problems

1. **Fixture files in a test target make `scripts/test.sh` warn** (§11.2 "Test data private to a target goes in `Tests/<Target>Tests/Fixtures/`", Appendix D.9, against the frozen `Package.swift`). Any file in a test target's folder that is not Swift makes `swift build --build-tests` print "warning: 'wp6-reviewengine': found 4 file(s) which are unhandled; explicitly declare them as resources or exclude from the target", and the manifest has no `exclude:` (and no `resources:`, by rule). `scripts/build.sh` alone does not show it. A probe package confirmed that hidden files and folders are skipped without a warning.
   *Done here:* the four files keep their names in the hidden folder `Tests/ReviewEngineTests/Fixtures/.llm/`; `Fixtures/FixtureFiles.swift` loads them and says why.
   *Suggested:* add `exclude: ["Fixtures"]` to the `ReviewEngineTests` target (and to any other test target with data files, such as `CLIProvidersTests` for its fake CLIs), then move the four files up one level and drop `.llm` from `EngineFixtures.folder`.
2. **No event retracts a draft** (Appendix A.6, `ReviewEvent`; §6.6). A draft whose block is then dropped (a repeat, a third `strength` comment, a block with neither title nor body such as the third block of `mock-fail`) is never replaced by a `.comment`. Only cancellation says that "open drafts are discarded".
   *Done here:* nothing can be done inside the engine; such a draft is simply not followed by a `.comment`.
   *Suggested:* say in §6.6 and WP8b that the model drops every draft not yet replaced when `.finished` arrives, whatever the status; or add `case draftDiscarded(UUID)`.
3. **`.finished` may not reach a consumer cancelled between two events** (Appendix A.6: "`.finished(RunRecord)` // last event"; §6.6 "Cancellation: `.finished(run)` with `.cancelled`"). With the frozen return type, a cold stream must be `AsyncThrowingStream(unfolding:)`, which returns `nil` without calling its closure once the consumer's task is cancelled. The engine answers a consumer that is waiting (an iterating loop spends nearly all its time there; the "cancellation" row is tested that way), but not one that is between events.
   *Done here:* see decision 1. *Suggested:* say in A.6 and WP8b that a stream that ends without `.finished` was cancelled, and that the model then records the run as cancelled itself (as Gate 0 already warns for provider streams).
4. **`REFEREE_DEBUG_DUMP` can only come from the process environment** (§10.5, §10.6, §11.3). The public initialiser has no environment or folder parameter, while `LiveDependencies.make(environment:)` and the snapshot runner pass environment dictionaries, so a dump folder given that way is ignored.
   *Done here:* the public initialiser reads `ProcessInfo.processInfo.environment`; an internal initialiser takes the folder, for tests. *Suggested:* add `debugDumpDirectory: URL? = nil` to the public initialiser and let `LiveDependencies` pass `environment["REFEREE_DEBUG_DUMP"]`.
5. **A voice revision's `ReportDraft` cannot be complete** (A.6: `reviseVoice(reportMarkdown:findings:context:)`). The engine does not receive the draft being revised, so the result has no `basedOnCommentIDs`, `versions` or `userEdited` of its own (it has `[]`, `[]` and `false`).
   *Done here:* those fields are empty. *Suggested:* say in WP8b that the model takes `markdown`, `recommendation`, `generatedAt` and `provider` from it and keeps the rest of the current draft (pushing the old text to `versions` with "before voice revision").
6. **Replies and reports have no notice** (A.6, `ReplyEvent`, `ReportEvent`; §6.2 "restarts the job once in text mode with a `.notice`"). Their automatic text fallback therefore happens without telling the user. *Done here:* decision 8.
7. **§6.2 and the "planning" row differ slightly.** §6.2 puts a reason in `warnings` "if `inputMode == .pdf` but a condition fails"; the row wants a warning for `model == nil` in automatic mode. Decision 3 follows the row. Worth one sentence in §6.2.

## For Gate 1

- **AppCore (WP8b):** problems 2, 3 and 5 are what the model must do on its side. The engine never pushes report versions (decision 10). `RunRecord.requestCount` in `.started` is 0.
- **`referee-cli review`:** everything the SUMMARY line needs is in the events: `.comment` anchors (`exact`/`fuzzy` → anchored, `pageOnly`, `none`), `similarTo`, and `run.requestCount` and `status` in `.finished`. `plan` gives `sendsPDF` and `destination` for the "sending … to …" line.
- **`scripts/e2e-ollama.sh phi4` will not exercise reading in parts with `ay_round_nolinks.pdf`** (Gate 1 acceptance). That paper renders to about 3,200 characters. The smallest Ollama context that is not blocked (about 7,400 tokens) still leaves an input budget of 1,500 tokens, 5,250 characters, so the paper always fits in one pass. A longer document is needed; `Fixtures/private/` papers would do.
- With the real `QuoteMatcher`, the engine passes `pageHint: page − 1` only for a page the paper has; a match without spans counts as no match.
- The frozen `SnapshotGraphTests` and the whole suite pass with this engine; `mock-fail` ends failed with two comments.

## Acceptance

Run on Command Line Tools 26.6 (Swift 6.3.3) at the last commit, after touching every file of this package (so that every one of them was compiled again).

| Command | Result | Final line |
| --- | --- | --- |
| `scripts/build.sh -j 2` | exit 0; no line with "warning" or "error" | `Build complete! (7.38s)` |
| `scripts/test.sh -j 2 --filter ReviewEngineTests` | exit 0; neither "warning" nor "error" anywhere in the output | `test.sh: OK (80 tests)` |
| `scripts/test.sh -j 2` | exit 0; no "warning"; every test of every target passes, `SnapshotGraphTests` included | `test.sh: OK (208 tests)` (before it: `✔ Test run with 208 tests in 35 suites passed after 1.787 seconds.`) |
| `git status --porcelain \| wc -l` | | `0` |

The filtered run was also repeated six times in a row while the machine's load average was about 7 (other worktrees building): no failure.
