# Step 5 — Venues

Notes of the venue step, in the worktree `s5/venue` cut from `main` at `c1c6ee3`, in parallel with the Reader, Sidebar, Shell and brand agents. The user asked for "an option to choose a venue on the main screen (after all an ec review is not the same as a jet review)": EC is the ACM Conference on Economics and Computation, JET the Journal of Economic Theory. This step builds the core only: the types, the settings, the paper's venue, venue-aware prompts, the recommendation on the venue's scale, and the API of `AppCore`. The controls on screen come in a later UI pass, on top of this API. The plan's record is Appendix G.9.

Every change is additive, with defaults. `Recommendation` and every existing member keep their names and meanings; nothing under `Sources/RefereeUI/` or `Tests/RefereeUITests/` changed, and the UI branches compile against this one as they are.

## The public API

### RefereeCore (`Settings.swift`, `Session.swift`, `Engine.swift`: Appendix A.4, A.6, A.7, identical to the files)

```swift
public enum VenueKind: String, Codable, Sendable, CaseIterable { case journal, conference }

public struct VenueProfile: Codable, Sendable, Equatable, Identifiable {
    public var id: String                    // "jet"; a built-in's id is fixed, an added venue's is a new UUID string
    public var shortName: String             // "JET"
    public var fullName: String              // "Journal of Economic Theory"
    public var kind: VenueKind
    public var guidance: String              // what a review for this venue should weigh, inserted into the prompts; "" = nothing
    public var reportInstructions: String?   // more instructions, inserted into the report's request only
    public var recommendationScale: [String] // a conference's labels, most favourable first; a journal uses Recommendation
    public init(id: String, shortName: String, fullName: String, kind: VenueKind, guidance: String, reportInstructions: String? = nil,
                recommendationScale: [String] = [])
}

extension VenueProfile {
    public static let journalID = "journal"
    public static let conferenceID = "conference"
    public static let unspecifiedJournal: VenueProfile       // "Journal (unspecified)": every prompt as before venues
    public var isBuiltIn: Bool                               // one of DefaultSettings.venues: editable and resettable, not deletable
    public var isUnspecified: Bool                           // "journal" or "conference": the prompts name meta.targetVenue, if any
    public var displayName: String                           // "Journal of Economic Theory (JET)"; an unspecified venue's full name
    public var scale: [String]                               // journal: Recommendation's labels; conference: its cleaned scale, else the default
    public func scaleLabel(in text: String) -> String?       // the label of `scale` that `text` names, spelled as the scale spells it
    public func recommendationMismatch(label: String, majorConcerns: Int) -> Bool   // rule recommendation-mismatch on this scale
}

extension Recommendation {
    public var label: String                                 // "Accept", "Minor revision", "Major revision", "Reject"
    public init?(label: String)                              // ignoring case and surrounding white space
}

// PromptSet gains two optional fields (the init gains them at the end, defaulting to nil):
    public var conferenceReportSystem: String?   // reportSystem for a conference; nil = the default (settings written before venues)
    public var conferenceReportTemplate: String? // reportTemplate for a conference; nil = the default
extension PromptSet {
    public func reportSystem(for kind: VenueKind) -> String
    public func reportTemplate(for kind: VenueKind) -> String
}

// AppSettings gains two optional fields (the init gains them at the end, defaulting to nil):
    public var venueProfiles: [VenueProfile]?   // Settings ▸ Venues as stored; nil = the built-ins as shipped. Read and write `venues`
    public var defaultVenueID: String?          // the venue of a new paper; nil = Journal (unspecified)
extension AppSettings {
    public var venues: [VenueProfile] { get set }            // the stored list, repeated ids dropped, missing built-ins put back
    public var defaultVenue: VenueProfile { get }
    public func venue(id: String?) -> VenueProfile           // Journal (unspecified) for nil or an id that names none
}

// ManuscriptMeta: public var venueID: String?, and init(title:targetVenue:manuscriptID:reviewerNotes:venueID: String? = nil)
// ReportDraft: public var recommendationLabel: String?, declared after recommendation, and
//     init(markdown:recommendation:recommendationLabel: String? = nil, generatedAt:provider:basedOnCommentIDs:userEdited:versions:)
// EngineContext: public var venue: VenueProfile, and init(…, paperDigest: String? = nil, venue: VenueProfile = .unspecifiedJournal)
// ReviewEngineProtocol gains a requirement with a default implementation that runs lint(reportMarkdown:):
    func lint(reportMarkdown: String, venue: VenueProfile) -> [LintFinding]
```

`DefaultSettings` and `FormatSpec` (§11.3):

```swift
public static let venues: [VenueProfile]          // DefaultSettings: journal, conference, jet, ec (Appendix B.8)
public static let conferenceScale: [String]       // DefaultSettings: ["Accept", "Weak accept", "Borderline", "Weak reject", "Reject"]
public static let conferenceReportSystem: String  // DefaultSettings: Appendix B.4, the conference report's prompt
public static let conferenceReportTemplate: String // DefaultSettings: and its template
public static var venue: String { get }           // FormatSpec: VENUE, the venue lines (B.2)
public static var conferenceWording: [(journal: String, conference: String)] { get }   // FormatSpec: the two phrase pairs (B.2)
```

### ReviewEngine

```swift
public func lint(reportMarkdown: String, venue: VenueProfile) -> [LintFinding]   // ReviewEngine: the conference rules for a conference
```

### AppCore (`ReviewSessionModelVenue.swift`, `SettingsModelVenues.swift`; Appendix A.9)

```swift
extension ReviewSessionModel {
    public var venues: [VenueProfile]                 // settings.venues, in menu order
    public var currentVenue: VenueProfile             // session.meta.venueID in `venues`; Journal (unspecified) for an old session or a deleted venue; no paper: settings.defaultVenue
    public func setVenue(id: String)                  // meta.venueID and meta.targetVenue; saves at once, refreshes the plan, lints again; keeps everything else
    public var recommendationScale: [String]          // currentVenue.scale
    public var recommendationLabel: String?           // the report's recommendation as a label of recommendationScale
    public func setRecommendation(label: String?)     // either scale; a label not on it, or no report: nothing
}

extension SettingsModel {
    public var venues: [VenueProfile]
    public var defaultVenue: VenueProfile
    @discardableResult
    public func addVenue(kind: VenueKind) -> String
    public func updateVenue(_ venue: VenueProfile)
    @discardableResult
    public func duplicateVenue(id: String) -> String?
    public func deleteVenue(id: String)
    public func moveVenues(fromOffsets source: IndexSet, toOffset destination: Int)
    public func resetVenue(id: String)
    public func setDefaultVenue(id: String)
}
```

`setRecommendation(_ recommendation: Recommendation?)` is unchanged and still sets the journal field whatever the venue; the label API is the one for either scale.

## What the prompts do now

The paper's venue reaches the engine in `EngineContext.venue`. For each venue:

- **Journal (unspecified)**, the venue of every session saved before venues: every prompt and every parse exactly as before. Its free-text `targetVenue` is still sent as "Target journal: …" in the one-pass review task and the report, and nowhere else, as before.
- **A named journal (JET)**: the review system prompt as before ("for a serious academic journal"). Its venue lines, "Target journal: Journal of Economic Theory (JET)" and "What a review for this journal should weigh: …", go into the one-pass review task (where "Target journal: …" went), every part, the whole-paper pass, and at the head of discussions, questions and the report's request.
- **A conference (EC, Conference (unspecified))**: the review system prompt says "for the program committee of a selective academic conference" and "to help the program committee decide". The venue lines say "Target conference: …". The report uses the conference prompt and template: the recommendation is one label of the venue's scale (given in the request: "Recommendation scale, most favourable first: Accept; Weak accept; Borderline; Weak reject; Reject"), "Chance of acceptance" replaces "Publication probability", and it asks for no revision plan. Conference (unspecified) is named by the paper's typed `targetVenue`, else "not specified".
- `reportInstructions`, when set, go into the report's request only: "Instructions for this report: …".

The voice revision and the continuation request (`TASK_CONTINUE`) carry no venue lines; their system prompt or paper context already does.

## Decisions

1. **Venues are settings records**, like `RubricCategory`, in `Settings.swift`, so Appendix A.1–A.8 stay the whole of `RefereeCore` apart from `DefaultSettings` and `FormatSpec`. The built-ins' texts are in `DefaultSettings` and Appendix B.8.
2. **Every new stored field is optional** (`venueProfiles`, `defaultVenueID`, `conferenceReportSystem`, `conferenceReportTemplate`, `venueID`, `recommendationLabel`), by §4.4's rule: a file written before venues decodes unchanged, and synthesised `Codable` stays, so a field another branch adds to the same types still decodes. The effective values are computed (`venues`, `defaultVenue`, `venue(id:)`, `reportSystem(for:)`, `reportTemplate(for:)`). A settings file saved again gains no venue key until a venue is edited, and a list equal to the shipped one is stored as nil, so later improvements of the built-ins' texts reach a user who never edited them.
3. **The built-ins are always in the list.** `AppSettings.venues` puts back any built-in a list lacks, at its shipped place, and drops a repeated id. `SettingsModel.deleteVenue` refuses a built-in; `resetVenue` restores one.
4. **Guidance is limited to well-established, non-numeric characteristics**: what each venue weighs, no page limits, score scales, deadlines or acceptance rates. EC's says that the decision is accept or reject with no revision round (the user's own statement). A test checks that no guidance holds a digit, a percent sign or an em dash. **The default conference scale ("Accept", "Weak accept", "Borderline", "Weak reject", "Reject") is a stand-in: the user should replace it, in Settings ▸ Venues, with the scale of the venue's actual review form** (EC's included).
5. **The paper keeps its venue by id**, `meta.venueID`, resolved against the settings at each job, so an edit of a venue in Settings applies to papers already on it. `setVenue(id:)` also sets `targetVenue` to the display name (nil for an unspecified venue), so anything reading `targetVenue` still names the venue. A deleted venue's papers fall back to Journal (unspecified) and keep their id and their `targetVenue` text.
6. **A new paper gets the default venue** (`metaForNewPaper`, used by `open`): `venueID` set, `targetVenue` the display name or nil. A session saved before venues keeps `venueID` nil until a venue is chosen, and opening it changes nothing in its metadata.
7. **`setVenue(id:)` does nothing for the venue the paper is already on** (an old session with no id is on Journal (unspecified), so choosing it keeps its free text), for an unknown id, or without a paper. Otherwise it saves at once (a tracked `flushPendingSave`), refreshes the plan, and lints the report for the new venue. Comments, conversations, the report and both recommendation fields stay as they are.
8. **Kind wording is a replacement of two phrases, not a placeholder.** `reviewSystem` is an editable setting, and settings files from before venues hold its old text word for word, so a placeholder would never reach them. For a conference the first occurrence of "for a serious academic journal" and of "to help the editor decide" is replaced; a phrase the referee edited away is left alone (the venue lines still say it is a conference). The discussion and question system prompts name no journal and are unchanged.
9. **`{venue}` replaces `{Target journal: …}`** in both `TASK_REVIEW` texts and is new in `TASK_PART` (after its first paragraph) and `TASK_WHOLE` (after the titles). It becomes the lines of `FormatSpec.venue` whose every placeholder has a value, or is removed with its line break. The values are filled in one pass, so braces in a referee's guidance are sent as written. The FormatSpec doc comment is the binding rule, extended accordingly.
10. **Journal (unspecified) is byte for byte what it was.** Its venue lines are the old "Target journal: …" lines in the one-pass review and the report and nothing elsewhere, unless the user gives it guidance, which is then sent like any venue's. Proven by `VenueJournalTests`: the SHA-256 of 21 serialised requests (one pass in text and PDF mode with and without notes, venue and titles; three parts and the whole-paper pass; a continuation; discussions and questions in text, PDF and excerpt mode; reports in text, PDF and excerpt mode; a voice revision) and of 8 style checks, taken by running the same scenarios on the code of `c1c6ee3` before any venue code existed, for four ways of reaching that venue.
11. **A conference's report has its own editable prompt and template** (`PromptSet.conferenceReportSystem`, `conferenceReportTemplate`), reset with the other prompts. They differ from the journal's in the recommendation (one label of the scale given in the request), "Chance of acceptance", no revision plan (no revision round), "the program committee" for "the editor", and minor concerns as fixes "in a final version". The voice rules are the journal's.
12. **A conference's recommendation is `ReportDraft.recommendationLabel`**, and `recommendation` stays nil for a report written for a conference. It is parsed as the journal's is (the first sentence under "Recommendation", else the section), on the venue's scale: whole words, ignoring case, emphasis and hyphens; the earliest label, and of two that start together the longer ("Weak accept", not "Accept"). A label not on the scale gives none ("Major revision" on EC). `AppCore`'s fallback for a draft that has none (`ModelSupport.completeRecommendation`, as for a journal's) takes the earliest label named in the section, its heading included, and sets `recommendation` to nil even when the draft carried one (only a scripted engine's does). A voice revision keeps the old label when the new text names none.
13. **A change of venue leaves the report alone**, both fields included: `ReviewSessionModel.recommendationLabel` reads the field of the current venue's kind and returns nil when the stored label is not on the current scale. Nothing is destroyed by switching back and forth.
14. **The mismatch rule on any scale**: a label in the more favourable half of the scale with a major concern, or in the less favourable half without one; the middle label of a scale of odd length ("Borderline") never mismatches. On the journal scale this is exactly the old rule. `VenueProfile.recommendationMismatch(label:majorConcerns:)` holds it, so the engine's style check and the UI's warning agree.
15. **The style check takes the venue through a new protocol requirement with a default** (`lint(reportMarkdown:venue:)` runs `lint(reportMarkdown:)`), so `ScriptedReviewEngine`, the AppCore tests' engines and the contract consumer keep compiling and behave as before. The model calls the venue form everywhere it lints (open, after a job, after an edit, after a restore, after `setVenue`).
16. **`referee-cli` and `e2e-ollama.sh` pass no venue**: their context gets Journal (unspecified) by default, so the real review of the acceptance runs the prompts of before.
17. **Logging**: one event, `model.venue.set`, with the venue's kind and whether it is built in; never a name or guidance, which the user types.

## Changes outside the paths named, and why

None outside `Sources/RefereeCore/`, `Sources/ReviewEngine/`, `Sources/AppCore/`, their tests, `plan.md` and this file. `Sources/TestSupport/` needed nothing: `ScriptedReviewEngine` gets the default `lint(reportMarkdown:venue:)`, and the AppCore tests record the venue with a wrapper of their own.

In `Sources/AppCore/ReviewSessionModel.swift`, for the merge with the Shell agent's `useCustomProviders()` and `usesCustomProviders` (nothing near `setActiveProvider`, `answerConsent` or `reloadSettings` changed):

- `open(url:)`: a new session's `meta` is `metaForNewPaper(title:)`; the stored report is linted with `venue: currentVenue`.
- `restoreReportVersion(at:)`: `ModelSupport.readRecommendation(of:venue:)` instead of the line that set `recommendation`.
- `resolveTarget(for:)`: `venue: currentVenue` added to the `EngineContext` it builds.
- `refreshPlan()`, `mutateSession(_:)`, `lint(_:)` and `track(_:)`: `private` removed (internal), for the extension file; `lint(_:)` and the debounced lint pass the venue.
- `applyGeneratedReport` and `applyRevisedReport`: `ModelSupport.completeRecommendation(of:venue:keeping:)` instead of the line that set `recommendation`.

Tests: `RefereeCoreSmokeTests` pinned `{Target journal: …}`; it now pins `{venue}` and the venue texts. `ContractConsumers` calls the new requirement through a conformer that knows nothing of venues.

## Contract problems

1. **The surface checks do not name the new members.** `Tests/IntegrationTests/SurfaceCheck.swift` and `Tests/RefereeUITests/Common/CommonSurfaceCheck.swift` are outside this step's paths; the new public members compile and are tested, but the merge should name them there as Gate 1 and step 5a did for theirs. Nothing switches over `VenueKind` yet.
2. **Until the UI pass, the Report tab still writes free text into `meta.targetVenue`** through `updateMeta`. Its text reaches the prompts only on an unspecified venue: a named venue is always named by its profile. And its recommendation picker still calls `setRecommendation(_:)`, which sets the journal field even on a conference. The UI pass replaces both (below).
3. **An edit in Settings ▸ Venues re-lints an open report only at its next edit, generation, restore or change of venue**, not at once: doing it at once needs a line in `reloadSettings`, which stays untouched here to keep clear of the Shell agent's lines. The prompts always use the edited venue.

## What the UI pass must build

1. **The venue control on the main screen.** A menu or picker over `model.venues` (label: `displayName`, or `shortName` with `fullName`; `kind` for a badge or grouping), selection `model.currentVenue.id`, set with `model.setVenue(id:)`; disabled without a paper (`model.session == nil`, when `currentVenue` is the default venue). It is per paper and saved with it.
2. **A Settings ▸ Venues editor** on `SettingsModel`: the list in order (`venues`; `moveVenues(fromOffsets:toOffset:)` from `onMove`); add (`addVenue(kind:)` returns the id to select), duplicate (`duplicateVenue(id:)`), delete (`deleteVenue(id:)`, disabled when `isBuiltIn`), reset for a built-in (`resetVenue(id:)`); fields `shortName`, `fullName`, `kind`, `guidance` (several lines), `reportInstructions` (optional) and, for a conference, the ordered labels of `recommendationScale`, saved with `updateVenue(_:)` (stored as given; `scale` drops blank and repeated labels where it is used, so a row being typed may stay empty); the default venue for new papers (`defaultVenue`, `setDefaultVenue(id:)`). The scale editor should say that the default scale is a stand-in for the scale of the venue's own review form.
3. **The Report tab** shows the paper's venue (`model.currentVenue.displayName`, with its kind) instead of the free-text Target venue field, and its recommendation picker runs over `model.recommendationScale` with `model.recommendationLabel` and `model.setRecommendation(label:)`; its warning is `model.currentVenue.recommendationMismatch(label:majorConcerns:)` with the major concerns it already counts (`SidebarReportFacts.majorConcernCount(in:)`). `plan.md` §9.8 says so.
4. **Settings ▸ Prompts** gains editors for `prompts.conferenceReportSystem` and `prompts.conferenceReportTemplate` (show `prompts.reportSystem(for: .conference)` and `reportTemplate(for: .conference)` while the stored value is nil); "Restore defaults" (`resetPromptsToDefaults()`) already restores them.

No snapshot scene shows a venue yet; the UI pass adds its own. A scene can put a paper on EC with `model.setVenue(id: "ec")` after the document is open, and give a report a conference recommendation with `setRecommendation(label:)`.

## Acceptance

Final run at commit `0e22954`, after `rm -rf .build`, so that "no warning" covers every file. This notes file was committed after that run; no code changed.

| Command | Result | Final line |
| --- | --- | --- |
| `scripts/build.sh` | exit 0; no line with "warning:" or "error:" | `Build complete! (46.33s)` |
| `scripts/test.sh` | exit 0; no warning; 1029 tests in 142 suites (991 at step 5a, 38 new); six skipped visibly: the real Keychain, the live reference services, the delivery experiment, the CLI smoke prompt, and the two tests of `Fixtures/private`, which is empty in a worktree. `LLMKitLiveOllamaTests` ran, with its one 16-token prompt to the local Ollama server, and passed | `test.sh: OK (1029 tests)` |
| `scripts/e2e-ollama.sh` (the default model) | exit 0. The plan was one request; the model's answer was cut off twice and continued (§6.5), hence three | `e2e-ollama.sh: OK (gemma4:e4b on ay_round_nolinks.pdf: 26 comments, 26 anchored, 3 requests, 256 s)` |
| `scripts/snapshots.sh` (every scene) | exit 0; 46 scenes, each `"nonBlank":true,"failures":[]` | `build/snapshots/welcome.png` |
| Appendix A.1–A.8 against `Sources/RefereeCore/` (blocks extracted by a script of my own, compared with `cmp`, as Gate 0 did) | identical | `8 of 8 identical` |
| Appendix B against the prompt constants (written to files by a temporary test, not committed; the "← …" notes left out, `{same optional lines}` written out and the two text-mode blocks joined, as Gate 0 did): the six prompts of B.1 and B.3–B.5, the two conference report texts, the eight constants of `FormatSpec` and the three guidance texts of B.8 | identical | `19 of 19 identical` |
| The journal golden: the 21 requests and 8 style checks of `VenueGolden`, serialised by a temporary test on the code of `c1c6ee3` before any other change, then again on the venue code (`diff -r` of the two folders) | identical; the SHA-256 of each is now `VenueJournalTests.golden` | `ALL 30 FILES IDENTICAL` (21 requests, 8 style checks, the hash list) |
| `git status --porcelain \| wc -l` | after the last commit | `0` |

Before that, at commit `86ca46f` (the same code but for the access level of two `DefaultSettings` constants): `scripts/build.sh` after `rm -rf .build` (`Build complete! (42.18s)`, no warning), `scripts/test.sh` (`test.sh: OK (1029 tests)`) and `scripts/e2e-ollama.sh` (`e2e-ollama.sh: OK (gemma4:e4b on ay_round_nolinks.pdf: 11 comments, 11 anchored, 1 requests, 92 s)`). During the work: `scripts/test.sh --filter 'RefereeCoreTests|ReviewEngineTests|AppCoreTests|PersistenceTests'` (`test.sh: OK (400 tests)`) and `scripts/test.sh --filter Venue` (`test.sh: OK (41 tests)`).

No tracked file holds a home-directory path, a login name or an email address, and `Sources/` has no `#file`, `#filePath`, `fatalError`, `precondition`, `preconditionFailure` or `assertionFailure` (checked by hand and by `IntegrationTreeTests` in the full run). No network request went anywhere but the local Ollama server: the 16-token prompt of `scripts/test.sh` and the two runs of `scripts/e2e-ollama.sh`. No AI command-line tool or paid API was used, nothing was installed, the screen was never driven, and the app ran only in its `--ui-snapshot` mode.

## Phase 2: the merge into `main` and the venue UI

The coordinator's second brief: merge `s5/venue` into `main` and build the venue UI, working alone on `main`. Commits: the merge `2e6fa8f`, then `27c3abe` (the UI, its tests and the docs). The plan's record is the last rows of Appendix G.9.

### The merge

- `git merge --no-ff s5/venue` on `main` at `72c096c`. Only `plan.md` conflicted, in three places: §9.8 (`main`'s text kept, then rewritten in this phase), A.9 (both sides: `usesCustomProviders`, then the venue members) and Appendix G (step 5c's table, then G.9). `ReviewSessionModel.swift`, `Session.swift` and `ReplyJob.swift` merged on their own with both sides kept.
- The A.4 block was copied again from `Session.swift`: one comment had drifted on `main` since step 5c ("(section 6.6, step 5c)" against the file's "(plan.md section 6.6, step 5c)"). Appendix A was then 8 of 8 identical.
- After the merge, `scripts/build.sh` had no warning (`Build complete! (11.06s)`). `scripts/test.sh` ran 1150 tests in 150 suites with two failures, both timing tests outside the venue code, run while other agents were building (load average near 37): `LLMKitCancellationTests.cancellingTheConsumerCancelsTheRequestAndEndsTheStream` and `StubURLProtocolTests.cancellingTheConsumerStopsADelayedDelivery`. Run alone they passed (`test.sh: OK (14 tests)`).

### The UI as built

- **The toolbar's venue control** (`ShellVenueControl.swift`), in the principal item beside the destination indicator: the kind's symbol (`Theme.venueSymbol`: `book.closed`, `person.3`), the short name ("Journal", "JET", "EC"; else the full name, else "Venue") and a chevron, at most 120 pt wide. Its tooltip gives the full name and what the venue does; without a paper it is disabled. `ShellVenueState` derives all of it and is unit-tested.
- **The venue menu**, drawn in the window under the toolbar like the destination menu: "Review this paper for", the caption "The venue decides what the review weighs and how the report is written.", "Journals" then "Conferences" in Settings' order, each row a check mark, the symbol, the full name and the short name at the trailing edge; choosing a row calls `setVenue(id:)`. "Edit Venues…" opens Settings ▸ Venues on the paper's venue. At most one of the two toolbar menus is open; Esc (the window's key monitor), a click outside or a consent card closes it.
- **Settings ▸ Venues** (`ShellSettingsVenues.swift`), a tab after Prompts: the list with "Built in" and "Default" tags; "+" (Add Journal, Add Conference), Duplicate, "−" (not for a built-in; asks first), up and down arrows, and dragging. The editor: "Default for New Papers"; "Reset…" for a built-in (asks first; disabled while it is as shipped); Short name, Kind, Full name; "What a review for it weighs" with the note that the venue's guidelines for reviewers can be pasted there; for a conference the scale, one field per label with up, down and remove, "Add Label" and "Use Default Scale", under the caption "The labels of the venue's review form, most favourable first. The default scale is a stand-in: replace it with the scale of the venue's real review form."; and "Report instructions". Orange warnings name what the venue loses where it is used (no name; a blank, repeated or lone label; an empty scale).
- **Settings ▸ Prompts**: "Conference report" and "Conference template" under "For a conference", each with its own "Reset" (disabled while the text is the default).
- **The Report tab**: in "Venue and notes" the venue row (symbol, display name, kind, "Change…") replaces the free-text target venue field; the disclosure's title carries the short name, which stays in view when it is folded. The recommendation picker runs on the venue's scale (`recommendationScale`, `recommendationLabel`, `setRecommendation(label:)` for a conference); the mismatch warning uses `VenueProfile.recommendationMismatch(label:majorConcerns:)`. "Chance of acceptance" goes with the committee's copy, titled "Copy Confidential Comments to the Program Committee", and never with the authors'.

### Decisions

1. **The menu is drawn in the window, not a native `Menu`.** The snapshot mode cannot capture a native menu (a child window, plan §10.1), and the destination menu already sets the pattern; Esc goes through the window's key monitor.
2. **The control sits in the principal item with the indicator and is at most 120 pt wide**, so that at 1,000 × 640 nothing of Review, Report or the sidebar toggle goes into the overflow (D3). `ShellSceneSupport.toolbarFits` compares `NSToolbar.visibleItems` with `items`; `design-venue-menu` and `design-review-long-names` run it. A mutation proved the check: with the control forced to 420 pt it reported Navigator, Review, Report and Sidebar in the overflow.
3. **"Change…" reaches the menu through a new `UIActions.chooseVenue`.** A pane never reaches into the Shell (§9.1). Each review window sets the closure on top of the app's actions (`ReviewWindowView.windowActions`), so the action opens that window's own menu; the default does nothing, as for every other action.
4. **Every edit in Settings ▸ Venues re-reads the venue from the model before `updateVenue(_:)`**, so two fields that hand on their text in turn never overwrite each other. Fields hand on at Return or when they lose the keyboard, text editors half a second after the last keystroke, as in Settings ▸ Prompts.
5. **A journal turned into a conference with a blank scale gets the default scale**; a conference turned into a journal keeps its labels, unused, so switching back loses nothing.
6. **The editor's scale warnings mirror `VenueProfile.scale`**, which drops blank and repeated labels and falls back to the default scale when none is left, and add one rule of their own: a single label leaves nothing to choose.
7. **A target typed before venues is named on screen.** Phase 1 kept sending an old session's free text on an unspecified venue ("Target journal: …"), and the field that showed it is gone. The Report tab now reads "Journal, named “JET” in the prompts", and the control's tooltip "Journal (unspecified), with “JET” named as the target: …", until a venue is chosen. The same holds for a paper whose venue was deleted.
8. **`reloadSettings(_:)` lints the open report again when the paper's venue changed with the settings.** This settles contract problem 3 above: an edit of the venue's kind or scale in Settings ▸ Venues updates the style check at once. A change that leaves the paper's venue as it was runs nothing.

The core's three contract problems (above) are settled: the surface checks name every new member (1); the Report tab no longer writes free text into `meta.targetVenue`, and its picker sets the field of the venue's kind (2); and decision 8 (3).

### Known limits

- The venue menu has no arrow keys (the destination menu has ↑, ↓ and Return): a click chooses and Esc closes.
- The consent card still says "Check the journal's policy on AI tools before sending a manuscript under review." for a paper reviewed for a conference.
- **For the rename to "Human in the Loop"**, three new strings name the app: `ShellSettingsVenues.swift`, "Its names, kind, guidance, report instructions and scale go back to those Referee came with." and the help "Put back this venue as Referee came with it"; `ShellSettingsPrompts.swift`, the help "Put back the text Referee came with". The README's venue sections name it too.

### Tests

28 new tests: `ShellVenueControlTests` (11: the control's states and tooltips, no paper, fallback titles, a typed target, the menu's groups and rows, choosing a venue through a model, a new paper on the default venue, "Edit Venues…", at most one menu, `windowActions`), `ShellVenueEditorTests` (8: the tab, the list's rows, the name and scale checks, a change of kind, the scale edits, an edit and a reset through `SettingsModel`, the Prompts conference texts), `SidebarReportVenueTests` (6: the venue lines, a typed target, the mismatch on a conference's scale, the two copies and their titles, the picker through the model), one each in `ShellScenesTests` and `SidebarScenesTests` (the new scenes exist), and `ReviewSessionModelVenueTests.anEditOfThePapersVenueInSettingsChecksTheReportAgain`. `Tests/IntegrationTests/SurfaceCheck.swift` and `Tests/RefereeUITests/Common/CommonSurfaceCheck.swift` now name every public member venues added (contract problem 1 above), and the first switches over `VenueKind`.

### Scenes

- `design-venue-menu` (new, Shell): `ay_round_nolinks.pdf` on EC with the venue menu open; EC checked, its full name whole; `verify`: the menu open and the destination menu closed, the control "EC" with `person.3`, the groups, the toolbar without overflow.
- `settings-venues` (new, Shell): Settings ▸ Venues on EC; the five labels of its stand-in scale, "Add Label" and "Use Default Scale" visible in 780 × 560.
- `design-report-conference` (new, Sidebar): the Report tab of an EC paper (`Fixtures/sessions/design-sidebar-conference.json`), "Venue and notes EC", "Weak reject" on the scale, "Chance of acceptance", a clean style check; `verify`: the label, no journal recommendation, no finding, the committee's copy with the chance and the authors' without.
- `design-review-long-names` (changed `verify`): the control reads "Journal" and is enabled; the toolbar has no overflow at 1,000 × 640.
- Every review scene's toolbar now shows the venue control, the Report tab scenes show the venue row, and `settings-prompts` shows the "For a conference" section. The pictures looked at: the three new scenes in light, `--dark` and at 1,000 × 640, `design-review-long-names` at 1,000 × 640 and `settings-prompts`.

### Acceptance

Run at commit `27c3abe`, after `rm -rf .build`, so that "no warning" covers every file. This notes file, one README sentence and one wording of plan §9.8 were committed after these runs; no code changed.

| Command | Result | Final line |
| --- | --- | --- |
| `scripts/build.sh` | exit 0; no line with "warning:" or "error:" | `Build complete! (43.40s)` |
| `scripts/test.sh` | exit 0; no warning; 1178 tests in 153 suites (1150 after the merge, 28 new). Four skipped visibly: the real Keychain, the CLI smoke prompt, the delivery experiment and the live reference services; the two tests of `Fixtures/private` ran, since the main checkout has it. `LLMKitLiveOllamaTests` ran, with its one 16-token prompt to the local Ollama server, and passed | `test.sh: OK (1178 tests)` |
| `scripts/snapshots.sh` (every scene) | exit 0; 60 scenes, each `"nonBlank":true,"failures":[]` | `…/welcome.png` (the script lists the PNGs) |
| `scripts/snapshots.sh --dark` | exit 0; 60 scenes, each clean | `…/welcome.png` |
| `scripts/snapshots.sh --size 1000x640` | exit 0; 60 scenes, each clean; no window grew, and the two scenes that check it found no toolbar item in the overflow | `…/welcome.png` |
| `scripts/e2e-ollama.sh` (the default model) | exit 0. The plan was one request; the model's answer was cut off twice and continued (§6.5), hence three | `e2e-ollama.sh: OK (gemma4:e4b on ay_round_nolinks.pdf: 21 comments, 21 anchored, 3 requests, 214 s, reported model gemma4:e4b)` |
| `scripts/bundle.sh && codesign --verify build/Referee.app` (with this commit's README, which the bundle carries) | exit 0 both; the script's own check printed "valid on disk" and "satisfies its Designated Requirement"; `codesign --verify` printed nothing | `Built build/Referee.app` |
| Appendix A.1–A.8 against `Sources/RefereeCore/` (the script of phase 1, `cmp`) | identical | `8 of 8 identical` |
| Appendix B against the prompt constants (a temporary test, not committed, as in phase 1) | identical, and no constant changed since phase 1 | `19 of 19 identical` |
| `git status --porcelain \| wc -l` | after the last commit | `0` |

During the work: `scripts/test.sh --filter 'ShellVenue|SidebarReportVenue|SidebarHosting|SidebarReport|ShellScenes|SidebarScenes'` (`test.sh: OK (69 tests)`) and `scripts/test.sh --filter 'ReviewSessionModelVenueTests|ReviewSessionModelProviderTests|ReviewSessionModelOpenTests'` (`test.sh: OK (37 tests)`). Every sweep was also run before the last changes of wording (60 scenes, clean in light, dark and at 1,000 × 640).

No tracked file holds a home-directory path, a login name or an email address, and no file changed here put a `#file`, `#filePath`, `fatalError` or any of the `precondition` family into `Sources/` (checked by hand and by `IntegrationTreeTests` in the full run). No network request went anywhere but the local Ollama server: the 16-token prompt of `scripts/test.sh` and the run of `scripts/e2e-ollama.sh`. No AI command-line tool or paid API was used, nothing was installed, the screen was never driven, the app ran only in its `--ui-snapshot` mode, and no Referee process was signalled. `s5/brand` was not merged.
